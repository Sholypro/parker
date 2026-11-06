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
    /// A row "matches" below this average difference per column.
    private static let rowMatchThreshold = 3
    /// Share of matching rows that validates a position even when part of the view changes on its
    /// own (animation, video, carousel, blinking cursor): those rows spoil the average.
    private static let robustMatchFraction = 0.85
    /// Share of identical rows above which a frame counts as "not scrolled" (only animations moved).
    private static let staticFraction = 0.6

    private var refFrame: CGImage?
    private var refGray: [Int32] = []
    private var refTop = 0            // content row displayed at row 0 of the reference frame
    private var contentBottom = 0     // content rows stitched so far (sticky footer excluded)
    private var lastFooter = Int.max
    private var started = false
    /// Content pieces, top to bottom, covering rows 0..<contentBottom without gaps.
    private var slices: [(image: CGImage, top: Int)] = []
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

    // MARK: - Equal steps (auto-scroll)

    /// Auto-scroll frame taken after a scroll of a known size (`expectedDelta` pixels).
    /// The image comparison only refines the position near the expected one: when it cannot
    /// confirm it (parallax, animations, video), the frame is placed at the expected distance
    /// anyway, so the capture never stops on "no match".
    /// Returns `.unchanged` when the page did not move (end of the page).
    /// `measured` gives the delta actually used (to calibrate the next steps).
    func addStep(_ frame: CGImage, expectedDelta: Int) -> (result: AddResult, measured: Int?) {
        guard let gray = Self.grayRows(frame) else { return (.noMatch, nil) }
        guard let ref = refFrame else {
            adopt(frame, gray, top: 0)
            return (.first, nil)
        }
        guard frame.width == ref.width, frame.height == ref.height else { return (.noMatch, nil) }

        let h = frame.height
        let n = Self.usedCols
        guard let hf = bands(gray, h) else { return (.unchanged, 0) }
        let header = hf.header, footer = hf.footer
        let band = h - header - footer
        guard band >= 40 else { return (.unchanged, 0) }
        if Self.mostlyStatic(refGray, gray, from: header, to: h - footer) {
            return (.unchanged, 0) // only something animated moved: the page itself did not scroll
        }

        let minOverlap = max(12, band / 10)
        let maxDelta = band - minOverlap
        guard maxDelta >= 1 else { return (.unchanged, 0) }
        let expected = min(max(1, expectedDelta), maxDelta)

        // Search up to a bit beyond the expected step (the last step is shorter at the end of the page)
        let hi = min(maxDelta, Int(Double(expected) * 1.3) + 2)
        var bestD = -1
        var bestScore = Double.infinity
        var scores = [Double](repeating: .infinity, count: hi + 1)
        refGray.withUnsafeBufferPointer { a in
            gray.withUnsafeBufferPointer { b in
                for d in 1...hi {
                    var sum = 0
                    var count = 0
                    var y = header
                    let end = h - footer - d
                    while y < end {
                        sum += Self.rowDiff(b, y, a, y + d)
                        count += 1
                        y += 2
                    }
                    if count > 0 {
                        scores[d] = Double(sum) / Double(count * n)
                        if scores[d] < bestScore { bestScore = scores[d]; bestD = d }
                    }
                }
            }
        }

        // Verify the best candidates (closest to the expected step first among near-equal scores)
        var chosen = -1
        if bestD > 0 {
            refGray.withUnsafeBufferPointer { a in
                gray.withUnsafeBufferPointer { b in
                    for d in Self.candidates(scores, from: 1, to: hi, minScore: bestScore, prefer: expected) {
                        var sum = 0
                        var count = 0
                        var matched = 0
                        var y = header
                        let end = h - footer - d
                        while y < end {
                            let r = Self.rowDiff(b, y, a, y + d)
                            sum += r
                            if r <= Self.rowMatchThreshold * n { matched += 1 }
                            count += 1
                            y += 1
                        }
                        let meanOK = Double(sum) / Double(max(count, 1) * n) <= Self.verifyThreshold
                        let robustOK = count >= minOverlap && Double(matched) >= 0.7 * Double(count)
                        if meanOK || robustOK {
                            chosen = d
                            break
                        }
                    }
                }
            }
        }
        let confirmed = chosen > 0
        let delta = confirmed ? chosen : expected

        if !started { start(footer: footer) }
        // Never leave a gap: at most what keeps the frame touching the stitched content
        let maxTop = contentBottom - header
        let previousTop = refTop
        let top = min(previousTop + delta, maxTop)
        let grew = place(frame, gray, top: top, header: header, footer: footer)
        lastDelta = max(0, top - previousTop)
        return (grew ? .appended(delta) : .repositioned, confirmed ? chosen : nil)
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
                    var matched = 0
                    var y = header
                    let end = h - footer - d
                    while y < end {
                        let r = Self.rowDiff(b, y, a, y + d)
                        sum += r
                        if r <= Self.rowMatchThreshold * n { matched += 1 }
                        count += 1
                        y += 1
                    }
                    let meanOK = Double(sum) / Double(max(count, 1) * n) <= Self.verifyThreshold
                    let robustOK = count >= minOverlap && Double(matched) >= Self.robustMatchFraction * Double(count)
                    if meanOK || robustOK {
                        best = d
                        break
                    }
                }
            }
        }
        guard best > 0 else {
            // Not scrolled, only something animated in the view: not an error
            return Self.mostlyStatic(refGray, gray, from: header, to: h - footer) ? .unchanged : .noMatch
        }

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

    /// True when most rows are identical at the same place (the page did not move).
    private static func mostlyStatic(_ ref: [Int32], _ gray: [Int32], from: Int, to: Int) -> Bool {
        guard to > from else { return false }
        let n = usedCols
        var same = 0
        ref.withUnsafeBufferPointer { a in
            gray.withUnsafeBufferPointer { b in
                for y in from..<to where rowDiff(a, y, b, y) <= rowMatchThreshold * n {
                    same += 1
                }
            }
        }
        return Double(same) >= staticFraction * Double(to - from)
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
        if let slice = Self.cropRows(ref, from: 0, to: h - footer) { slices = [(slice, 0)] }
        contentGray.append(contentsOf: refGray[0..<((h - footer) * Self.cols)])
        contentBottom = h - footer
        refTop = 0
        started = true
    }

    /// Makes `frame` the reference at content row `top`.
    ///
    /// "Last view wins": every content row the frame shows is replaced by this newer view, not
    /// only the rows it reveals at the bottom. A row's final pixels therefore come from the last
    /// frame that showed it, when it had scrolled up near the top of the view. Two things this
    /// fixes (the way CleanShot X behaves):
    ///  - content that fades or slides in when it enters the view (very common on websites) is
    ///    captured once it has finished animating, not half transparent at the bottom edge;
    ///  - floating widgets fixed on screen (chat bubble, badges, "back to top" buttons) are no
    ///    longer copied into every new strip: they only remain where the last frame shows them.
    /// Returns true when the content grew.
    private func place(_ frame: CGImage, _ gray: [Int32], top: Int, header: Int, footer: Int) -> Bool {
        let h = frame.height
        let from = top + header           // first content row replaced
        let to = top + h - footer         // end of the rows this frame shows
        guard to > from, from <= contentBottom,
              let fresh = Self.cropRows(frame, from: header, to: h - footer) else {
            adopt(frame, gray, top: top)
            lastFooter = footer
            return false
        }
        let grew = to > contentBottom

        // Keep what lies outside [from, to); older pieces are copied so the frames they came
        // from can be released (only the newest piece points into a full frame).
        var kept: [(image: CGImage, top: Int)] = []
        var inserted = false
        for piece in slices {
            let a = piece.top
            let b = piece.top + piece.image.height
            if b <= from || a >= to {
                if a >= to && !inserted { kept.append((fresh, from)); inserted = true }
                kept.append(piece)
                continue
            }
            if a < from, let upper = Self.copyRows(piece.image, from: 0, to: from - a) {
                kept.append((upper, a))
            }
            if !inserted { kept.append((fresh, from)); inserted = true }
            if b > to, let lower = Self.copyRows(piece.image, from: to - a, to: b - a) {
                kept.append((lower, to))
            }
        }
        if !inserted { kept.append((fresh, from)) }
        slices = kept

        // Signature of the content, for re-anchoring
        let cols = Self.cols
        if to > contentBottom {
            contentGray.append(contentsOf: [Int32](repeating: 0, count: (to - contentBottom) * cols))
        }
        contentGray.replaceSubrange((from * cols)..<(to * cols), with: gray[(header * cols)..<((h - footer) * cols)])
        contentBottom = max(contentBottom, to)
        if grew {
            footerImage = footer > 0 ? Self.copyRows(frame, from: h - footer, to: h) : nil
        }
        adopt(frame, gray, top: top)
        lastFooter = footer
        return grew
    }

    private func adopt(_ frame: CGImage, _ gray: [Int32], top: Int) {
        refFrame = frame
        refGray = gray
        refTop = top
    }

    /// Builds the stitched image. `maxWidth` produces a downscaled preview.
    func compose(maxWidth: Int? = nil) -> CGImage? {
        guard let ref = refFrame else { return nil }
        var parts: [(image: CGImage, top: Int)] = started ? slices : [(ref, 0)]
        var totalH = started ? contentBottom : ref.height
        if started, let footer = footerImage {
            parts.append((footer, contentBottom))
            totalH += footer.height
        }

        let width = ref.width
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

        // CoreGraphics origin is bottom-left
        for part in parts {
            let y = totalH - part.top - part.image.height
            ctx.draw(part.image, in: CGRect(x: 0, y: y, width: part.image.width, height: part.image.height))
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
    /// Rows of `image` without copying (shares the frame's memory).
    private static func cropRows(_ image: CGImage, from top: Int, to bottom: Int) -> CGImage? {
        guard bottom > top else { return nil }
        return image.cropping(to: CGRect(x: 0, y: top, width: image.width, height: bottom - top))
    }

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
