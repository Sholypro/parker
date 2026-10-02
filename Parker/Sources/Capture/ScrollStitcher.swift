import Cocoa

/// Incremental stitcher for scrolling captures (same algorithm as the Windows version).
///
/// Every frame is reduced to a compact grayscale signature (64 columns × full height).
/// Sticky header / footer rows are detected, the scroll delta is searched in the moving band
/// only, and only newly revealed rows are appended. Positions are tracked in "content"
/// coordinates (rows of the final image), which allows two recoveries:
///  - batches: frames received while the stitcher was busy are kept, and when the newest one
///    jumped too far, the intermediate frames bridge the gap;
///  - re-anchoring: a frame that no longer overlaps the reference (scrolled too far, or back up)
///    is searched in the already stitched content, so the capture resumes on its own as soon as
///    the view shows something already captured.
/// Not thread-safe: use from a single serial queue.
final class ScrollStitcher {
    enum AddResult {
        case first
        case appended(Int)
        case repositioned
        case unchanged
        case noMatch

        var grew: Bool {
            switch self {
            case .first, .appended: return true
            default: return false
            }
        }
    }

    private static let cols = 64
    private static let ignoreLeft = 1   // window edge
    private static let ignoreRight = 2  // overlay scrollbar that appears while scrolling
    private static var usedCols: Int { cols - ignoreLeft - ignoreRight }
    private static let verifyThreshold = 4.0

    private var refFrame: CGImage?
    private var refGray: [Int32] = []
    private var refTop = 0            // content row displayed at row 0 of the reference frame
    private var contentBottom = 0     // content rows stitched so far (sticky footer excluded)
    private var lastFooter = Int.max
    private var started = false
    private var slices: [CGImage] = []
    private var footerImage: CGImage?
    private var contentGray: [Int32] = []
    private(set) var lastDelta = 0

    var hasContent: Bool { refFrame != nil }

    /// Height in pixels of the image `compose()` would produce.
    var totalHeight: Int {
        guard started else { return refFrame?.height ?? 0 }
        return contentBottom + (footerImage?.height ?? 0)
    }

    func reset() {
        refFrame = nil
        refGray = []
        refTop = 0
        contentBottom = 0
        started = false
        lastFooter = Int.max
        slices.removeAll()
        footerImage = nil
        contentGray = []
        lastDelta = 0
    }

    func add(_ frame: CGImage, expectedDelta: Int? = nil) -> AddResult {
        addBatch([frame], expectedDelta: expectedDelta)
    }

    /// Frames captured since the last call, oldest first.
    /// `expectedDelta` applies to the newest frame (auto-scroll).
    func addBatch(_ frames: [CGImage], expectedDelta: Int? = nil) -> AddResult {
        guard !frames.isEmpty else { return .unchanged }
        let n = frames.count
        var grays = [[Int32]?](repeating: nil, count: n)
        func grayOf(_ i: Int) -> [Int32]? {
            if let g = grays[i] { return g }
            let g = Self.grayRows(frames[i])
            grays[i] = g
            return g
        }

        var result: AddResult = .noMatch
        var progressed = false
        var lo = 0
        var expected = expectedDelta
        while true {
            guard let newestGray = grayOf(n - 1) else { return .noMatch }
            let r = match(frames[n - 1], newestGray, expected)
            expected = nil
            if case .noMatch = r {} else { result = r; break }

            // The newest frame jumped too far: bridge the gap with intermediate frames
            var found = -1
            var i = n - 2
            while i >= lo {
                if let g = grayOf(i) {
                    let ri = match(frames[i], g, nil)
                    switch ri {
                    case .first, .appended, .repositioned: found = i
                    default: break
                    }
                    if found >= 0 { break }
                    if case .unchanged = ri { break } // older frames are even closer to the reference
                }
                i -= 1
            }
            if found >= 0 { progressed = true; lo = found + 1; continue }

            // Last resort: find the newest frame in what was already stitched
            result = reanchor(frames[n - 1], newestGray)
            break
        }

        if progressed {
            switch result {
            case .unchanged, .repositioned: return .appended(lastDelta)
            default: break
            }
        }
        return result
    }

    // MARK: - Matching against the reference frame

    private func match(_ frame: CGImage, _ gray: [Int32], _ expectedDelta: Int?) -> AddResult {
        guard let ref = refFrame else {
            adopt(frame, gray, top: 0)
            return .first
        }
        guard frame.width == ref.width, frame.height == ref.height else { return .noMatch }

        let h = frame.height
        let n = Self.usedCols
        guard let hf = bands(gray, h) else { return .unchanged }
        let header = hf.header, footer = hf.footer

        let band = h - header - footer
        guard band >= 40 else { return .noMatch }
        let minOverlap = max(12, band / 10)
        let maxDelta = band - minOverlap
        guard maxDelta >= 1 else { return .noMatch }

        // Coarse search (sampled rows), then full verification of the best candidates
        let step = max(2, band / 300)
        var scores = [Double](repeating: .infinity, count: maxDelta + 1)
        var minScore = Double.infinity
        refGray.withUnsafeBufferPointer { a in
            gray.withUnsafeBufferPointer { b in
                for d in 1...maxDelta {
                    var sum = 0
                    var count = 0
                    var y = header
                    let end = h - footer - d
                    while y < end {
                        sum += Self.rowDiff(b, y, a, y + d)
                        count += 1
                        y += step
                    }
                    if count > 0 {
                        scores[d] = Double(sum) / Double(count * n)
                        if scores[d] < minScore { minScore = scores[d] }
                    }
                }
            }
        }
        guard minScore.isFinite else { return .noMatch }

        // Near-equal scores (blank areas): the expected delta, else the previous one (steady scrolling)
        let prefer = expectedDelta ?? (lastDelta > 0 ? lastDelta : nil)
        var best = -1
        refGray.withUnsafeBufferPointer { a in
            gray.withUnsafeBufferPointer { b in
                for d in Self.candidates(scores, from: 1, to: maxDelta, minScore: minScore, prefer: prefer) {
                    var sum = 0
                    var count = 0
                    var y = header
                    let end = h - footer - d
                    while y < end {
                        sum += Self.rowDiff(b, y, a, y + d)
                        count += 1
                        y += 1
                    }
                    if Double(sum) / Double(max(count, 1) * n) <= Self.verifyThreshold {
                        best = d
                        break
                    }
                }
            }
        }
        guard best > 0 else { return .noMatch }

        if !started { start(footer: footer) }
        if refTop + best + header > contentBottom { return .noMatch } // would leave a gap
        let appended = place(frame, gray, top: refTop + best, header: header, footer: footer)
        lastDelta = best
        return appended ? .appended(best) : .repositioned
    }

    // MARK: - Re-anchoring in the stitched content

    private func reanchor(_ frame: CGImage, _ gray: [Int32]) -> AddResult {
        guard started, let ref = refFrame else { return .noMatch }
        guard frame.width == ref.width, frame.height == ref.height else { return .noMatch }

        let h = frame.height
        let n = Self.usedCols
        guard let hf = bands(gray, h) else { return .unchanged }
        let header = hf.header, footer = hf.footer
        let band = h - header - footer
        guard band >= 40 else { return .noMatch }
        let minOverlap = max(24, band / 4)

        // Window: the last few screens of content (where the user can plausibly be)
        let hi = contentBottom - header - minOverlap
        let lo = max(0, contentBottom - 5 * h)
        guard hi >= lo else { return .noMatch }

        let step = max(3, band / 200)
        var scores = [Double](repeating: .infinity, count: hi - lo + 1)
        var minScore = Double.infinity
        let bottom = contentBottom
        contentGray.withUnsafeBufferPointer { c in
            gray.withUnsafeBufferPointer { b in
                for top in lo...hi {
                    let end = min(h - footer, bottom - top)
                    var sum = 0
                    var count = 0
                    var y = header
                    while y < end {
                        sum += Self.rowDiff(b, y, c, top + y)
                        count += 1
                        y += step
                    }
                    if count > 0 {
                        let s = Double(sum) / Double(count * n)
                        scores[top - lo] = s
                        if s < minScore { minScore = s }
                    }
                }
            }
        }
        guard minScore.isFinite else { return .noMatch }

        // Blank areas match everywhere: refuse when near-equal candidates are far apart
        var firstNear = -1
        var lastNear = -1
        for i in 0..<scores.count where scores[i] <= minScore + 0.25 {
            if firstNear < 0 { firstNear = i }
            lastNear = i
        }
        guard lastNear - firstNear <= band / 2 else { return .noMatch }

        let order = Self.candidates(scores, from: 0, to: scores.count - 1, minScore: minScore, prefer: refTop - lo)
        var chosen = -1
        contentGray.withUnsafeBufferPointer { c in
            gray.withUnsafeBufferPointer { b in
                for idx in order {
                    let top = idx + lo
                    let end = min(h - footer, bottom - top)
                    var sum = 0
                    var count = 0
                    var y = header
                    while y < end {
                        sum += Self.rowDiff(b, y, c, top + y)
                        count += 1
                        y += 1
                    }
                    guard count >= minOverlap else { continue }
                    if Double(sum) / Double(count * n) <= Self.verifyThreshold {
                        chosen = top
                        break
                    }
                }
            }
        }
        guard chosen >= 0 else { return .noMatch }
        return place(frame, gray, top: chosen, header: header, footer: footer) ? .appended(0) : .repositioned
    }

    // MARK: - Internals

    /// Header/footer detection against the reference. Returns nil when the frame is unchanged.
    private func bands(_ gray: [Int32], _ h: Int) -> (header: Int, footer: Int)? {
        let n = Self.usedCols
        var total = 0
        var same = [Bool](repeating: false, count: h)
        refGray.withUnsafeBufferPointer { a in
            gray.withUnsafeBufferPointer { b in
                for y in 0..<h {
                    let s = Self.rowDiff(a, y, b, y)
                    total += s
                    same[y] = s < 2 * n
                }
            }
        }
        if total < h * n { return nil }

        var header = 0
        while header < h / 3 && same[header] { header += 1 }
        var footer = 0
        while footer < h / 4 && same[h - 1 - footer] { footer += 1 }
        // The sticky footer can only shrink: blank content rows above a footer look "unchanged"
        // on small scrolls, and letting the footer grow would duplicate those rows.
        if started { footer = min(footer, lastFooter) }
        return (header: header, footer: footer)
    }

    /// Up to 3 verification candidates: among near-equal scores, closest to `prefer` first
    /// (or lowest score without preference), then the next best distinct scores.
    private static func candidates(_ scores: [Double], from: Int, to: Int, minScore: Double, prefer: Int?) -> [Int] {
        guard from <= to else { return [] }
        var list: [Int] = []
        var best = -1
        for d in from...to where scores[d] <= minScore + 0.25 {
            if best < 0 { best = d; continue }
            if let prefer = prefer {
                if abs(d - prefer) < abs(best - prefer) { best = d }
            } else if scores[d] < scores[best] {
                best = d
            }
        }
        if best >= 0 { list.append(best) }
        for _ in 0..<2 {
            var next = -1
            for d in from...to {
                if list.contains(where: { abs($0 - d) <= 2 }) { continue }
                if next < 0 || scores[d] < scores[next] { next = d }
            }
            guard next >= 0, scores[next].isFinite else { break }
            list.append(next)
        }
        return list
    }

    private func start(footer: Int) {
        guard let ref = refFrame else { return }
        let h = ref.height
        if let slice = Self.copyRows(ref, from: 0, to: h - footer) { slices.append(slice) }
        contentGray.append(contentsOf: refGray[0..<((h - footer) * Self.cols)])
        contentBottom = h - footer
        refTop = 0
        started = true
    }

    /// Makes `frame` the reference at content row `top`; appends the rows below the content.
    private func place(_ frame: CGImage, _ gray: [Int32], top: Int, header: Int, footer: Int) -> Bool {
        let h = frame.height
        let startRow = max(header, contentBottom - top)
        let end = h - footer
        var appended = false
        if end > startRow, let slice = Self.copyRows(frame, from: startRow, to: end) {
            slices.append(slice)
            contentGray.append(contentsOf: gray[(startRow * Self.cols)..<(end * Self.cols)])
            contentBottom = top + end
            footerImage = footer > 0 ? Self.copyRows(frame, from: h - footer, to: h) : nil
            appended = true
        }
        adopt(frame, gray, top: top)
        lastFooter = footer
        return appended
    }

    private func adopt(_ frame: CGImage, _ gray: [Int32], top: Int) {
        refFrame = frame
        refGray = gray
        refTop = top
    }

    /// Builds the stitched image. `maxWidth` produces a downscaled preview.
    func compose(maxWidth: Int? = nil) -> CGImage? {
        guard let ref = refFrame else { return nil }
        var parts = started ? slices : [ref]
        if started, let footer = footerImage { parts.append(footer) }

        let width = ref.width
        let totalH = parts.reduce(0) { $0 + $1.height }
        guard width > 0, totalH > 0 else { return nil }

        var scale: CGFloat = 1
        if let maxWidth, maxWidth > 0, width > maxWidth {
            scale = CGFloat(maxWidth) / CGFloat(width)
        }
        let outW = max(1, Int((CGFloat(width) * scale).rounded()))
        let outH = max(1, Int((CGFloat(totalH) * scale).rounded()))

        let colorSpace = ref.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(data: nil, width: outW, height: outH, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: colorSpace, bitmapInfo: bitmapInfo)
                ?? CGContext(data: nil, width: outW, height: outH, bitsPerComponent: 8,
                             bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bitmapInfo)
        else { return nil }

        ctx.interpolationQuality = scale < 1 ? .medium : .none
        ctx.scaleBy(x: scale, y: scale)

        // CoreGraphics origin is bottom-left: draw from the top down
        var accumulated = 0
        for part in parts {
            let y = totalH - accumulated - part.height
            ctx.draw(part, in: CGRect(x: 0, y: y, width: part.width, height: part.height))
            accumulated += part.height
        }
        return ctx.makeImage()
    }

    // MARK: - Helpers

    @inline(__always)
    private static func rowDiff(_ a: UnsafeBufferPointer<Int32>, _ rowA: Int,
                                _ b: UnsafeBufferPointer<Int32>, _ rowB: Int) -> Int {
        let oa = rowA * cols
        let ob = rowB * cols
        var s: Int32 = 0
        var c = ignoreLeft
        let end = cols - ignoreRight
        while c < end {
            s &+= abs(a[oa + c] &- b[ob + c])
            c += 1
        }
        return Int(s)
    }

    /// Row-major grayscale signature, row 0 = top of the image.
    private static func grayRows(_ image: CGImage) -> [Int32]? {
        let h = image.height
        guard h > 0, image.width > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: cols * h)
        let ok: Bool = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: cols, height: h,
                                      bitsPerComponent: 8, bytesPerRow: cols,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: cols, height: h))
            return true
        }
        guard ok else { return nil }
        return bytes.map { Int32($0) }
    }

    /// Copies rows [top, bottom) (top-left origin) into an independent image so the
    /// full source frame can be released.
    private static func copyRows(_ image: CGImage, from top: Int, to bottom: Int) -> CGImage? {
        let height = bottom - top
        guard height > 0,
              let cropped = image.cropping(to: CGRect(x: 0, y: top, width: image.width, height: height))
        else { return nil }

        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(data: nil, width: cropped.width, height: cropped.height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: colorSpace, bitmapInfo: bitmapInfo) else { return cropped }
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: cropped.width, height: cropped.height))
        return ctx.makeImage() ?? cropped
    }
}
