import Cocoa

/// Incremental stitcher for scrolling captures.
///
/// Every frame is reduced to a compact grayscale signature (64 columns × full height).
/// For each new frame we:
///  1. detect sticky header / footer rows (rows identical at the same position in both frames),
///  2. search the vertical scroll delta inside the moving band only,
///  3. append just the newly revealed rows.
///
/// The reference frame is only replaced when a match is found, so if the user scrolls too
/// fast (no overlap) nothing is lost: scrolling back a little lets the capture resume.
/// Not thread-safe: use from a single serial queue.
final class ScrollStitcher {
    enum AddResult {
        case first
        case appended(Int)
        case unchanged
        case noMatch
    }

    private static let cols = 64
    private static let ignoreLeft = 1   // window edge
    private static let ignoreRight = 2  // overlay scrollbar that appears while scrolling
    private static var usedCols: Int { cols - ignoreLeft - ignoreRight }

    private var refFrame: CGImage?
    private var refGray: [Int32] = []
    private var refBandBottom = 0
    private var started = false
    private var slices: [CGImage] = []
    private var footerImage: CGImage?

    var hasContent: Bool { refFrame != nil }

    /// Height in pixels of the image `compose()` would produce.
    var totalHeight: Int {
        guard started else { return refFrame?.height ?? 0 }
        return slices.reduce(0) { $0 + $1.height } + (footerImage?.height ?? 0)
    }

    func reset() {
        refFrame = nil
        refGray = []
        refBandBottom = 0
        started = false
        slices.removeAll()
        footerImage = nil
    }

    func add(_ frame: CGImage, expectedDelta: Int? = nil) -> AddResult {
        guard let gray = Self.grayRows(frame) else { return .noMatch }

        guard let ref = refFrame else {
            refFrame = frame
            refGray = gray
            return .first
        }
        guard frame.width == ref.width, frame.height == ref.height else { return .noMatch }

        let h = frame.height
        let n = Self.usedCols

        // 1. Same-position comparison: unchanged frame + sticky header/footer detection
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
        if total < h * n { return .unchanged }

        var header = 0
        while header < h / 3 && same[header] { header += 1 }
        var footer = 0
        while footer < h / 4 && same[h - 1 - footer] { footer += 1 }

        let band = h - header - footer
        guard band >= 40 else { return .noMatch }
        let minOverlap = max(12, band / 10)
        let maxDelta = band - minOverlap
        guard maxDelta >= 1 else { return .noMatch }

        // 2. Coarse search of the scroll delta (every other row)
        var scores = [Double](repeating: .infinity, count: maxDelta + 1)
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
                        y += 2
                    }
                    if count > 0 {
                        scores[d] = Double(sum) / Double(count * n)
                    }
                }
            }
        }

        var minScore = Double.infinity
        for d in 1...maxDelta where scores[d] < minScore { minScore = scores[d] }
        guard minScore.isFinite else { return .noMatch }

        // Among near-equal candidates (blank areas), prefer the expected delta if we know it
        var best = -1
        for d in 1...maxDelta where scores[d] <= minScore + 0.25 {
            if best < 0 { best = d; continue }
            if let expected = expectedDelta {
                if abs(d - expected) < abs(best - expected) { best = d }
            } else if scores[d] < scores[best] {
                best = d
            }
        }
        guard best > 0 else { return .noMatch }

        // 3. Full-resolution verification
        var sum = 0
        var count = 0
        refGray.withUnsafeBufferPointer { a in
            gray.withUnsafeBufferPointer { b in
                var y = header
                let end = h - footer - best
                while y < end {
                    sum += Self.rowDiff(b, y, a, y + best)
                    count += 1
                    y += 1
                }
            }
        }
        let refined = Double(sum) / Double(max(count, 1) * n)
        guard refined <= 4.0 else { return .noMatch }

        // 4. Append
        if !started {
            guard let firstSlice = Self.copyRows(ref, from: 0, to: h - footer) else { return .noMatch }
            slices.append(firstSlice)
            refBandBottom = h - footer
            started = true
        }

        let start = max(0, refBandBottom - best)
        let end = h - footer
        if end > start, let slice = Self.copyRows(frame, from: start, to: end) {
            slices.append(slice)
        }
        footerImage = footer > 0 ? Self.copyRows(frame, from: h - footer, to: h) : nil

        refFrame = frame
        refGray = gray
        refBandBottom = end
        return .appended(best)
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
