import Cocoa
import ScreenCaptureKit

/// Screen capture through ScreenCaptureKit.
///
/// Replaces CGWindowListCreateImage / CGDisplayCreateImage: on recent macOS versions those
/// legacy APIs return a blank (uniform gray) image, which produced gray screenshots.
/// The calls here are synchronous for simplicity at the call sites: ScreenCaptureKit delivers
/// its results on its own queues, so waiting from the main thread cannot deadlock.
enum ScreenGrabber {
    enum Failure: Error {
        case noPermission
        case noDisplay
        case timedOut
        case captureFailed
    }

    /// Last error, used to show a helpful message when a capture fails.
    private(set) static var lastFailure: Failure?
    private static var didWarnAboutPermission = false

    // MARK: - Public API (coordinates: global, top-left origin, points, like CGDisplayBounds)

    /// Captures a rectangle of the screen. Parker's own windows (overlays, HUD) are excluded.
    /// `maxContentAge` (seconds) lets repeated captures reuse the list of displays and apps.
    static func capture(rect: CGRect, excludingOwnWindows: Bool = true, maxContentAge: TimeInterval = 0) -> CGImage? {
        guard rect.width >= 1, rect.height >= 1 else { return nil }
        return run(maxContentAge: maxContentAge) { content in
            guard let display = display(for: rect, in: content) else { throw Failure.noDisplay }
            let filter = makeFilter(display: display, content: content, excludeOwn: excludingOwnWindows)
            let scale = pixelScale(for: filter, display: display)

            let local = CGRect(
                x: rect.minX - display.frame.minX,
                y: rect.minY - display.frame.minY,
                width: rect.width,
                height: rect.height
            ).intersection(CGRect(origin: .zero, size: display.frame.size))
            guard !local.isNull, local.width >= 1, local.height >= 1 else { throw Failure.noDisplay }

            let config = baseConfiguration()
            config.sourceRect = local
            config.width = max(1, Int((local.width * scale).rounded()))
            config.height = max(1, Int((local.height * scale).rounded()))
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        }
    }

    /// Captures a whole display at full resolution.
    static func capture(displayID: CGDirectDisplayID, excludingOwnWindows: Bool = true) -> CGImage? {
        run { content in
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                throw Failure.noDisplay
            }
            let filter = makeFilter(display: display, content: content, excludeOwn: excludingOwnWindows)
            let scale = pixelScale(for: filter, display: display)
            let config = baseConfiguration()
            config.width = max(1, Int((display.frame.width * scale).rounded()))
            config.height = max(1, Int((display.frame.height * scale).rounded()))
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        }
    }

    /// Captures a single window, even if partly covered by other windows.
    static func capture(windowID: CGWindowID, includeShadow: Bool) -> CGImage? {
        run { content in
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                throw Failure.captureFailed
            }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let scale = CGFloat(filter.pointPixelScale)
            let config = baseConfiguration()
            config.ignoreShadowsSingleWindow = !includeShadow
            config.shouldBeOpaque = false
            config.width = max(1, Int((window.frame.width * scale).rounded()))
            config.height = max(1, Int((window.frame.height * scale).rounded()))
            if includeShadow {
                // Room for the shadow around the window
                let content = filter.contentRect
                config.width = max(1, Int((content.width * scale).rounded()))
                config.height = max(1, Int((content.height * scale).rounded()))
            }
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        }
    }

    // MARK: - Snapshot (for live loupes: capture once, then crop for free)

    struct Snapshot {
        let image: CGImage
        let frame: CGRect      // global points, top-left origin
        let scale: CGFloat     // pixels per point

        /// Crops a global rect (points) out of the snapshot.
        func crop(_ rect: CGRect) -> CGImage? {
            let local = CGRect(
                x: (rect.minX - frame.minX) * scale,
                y: (rect.minY - frame.minY) * scale,
                width: rect.width * scale,
                height: rect.height * scale
            ).integral
            let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            let clipped = local.intersection(bounds)
            guard !clipped.isNull, clipped.width >= 1, clipped.height >= 1 else { return nil }
            return image.cropping(to: clipped)
        }

        /// sRGB color of the pixel under a global point.
        func color(at point: CGPoint) -> (r: UInt8, g: UInt8, b: UInt8)? {
            guard let pixel = crop(CGRect(x: point.x, y: point.y, width: 1 / scale, height: 1 / scale)) else { return nil }
            var data = [UInt8](repeating: 0, count: 4)
            let ok: Bool = data.withUnsafeMutableBytes { buffer in
                guard let ctx = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                ctx.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
                return true
            }
            return ok ? (data[0], data[1], data[2]) : nil
        }
    }

    /// Full-resolution image of the display under `point` (global, top-left origin).
    static func snapshot(displayContaining point: CGPoint) -> Snapshot? {
        guard let id = displayID(containing: point) else { return nil }
        guard let image = capture(displayID: id) else { return nil }
        let frame = CGDisplayBounds(id)
        guard frame.width > 0 else { return nil }
        return Snapshot(image: image, frame: frame, scale: CGFloat(image.width) / frame.width)
    }

    static func displayID(containing point: CGPoint) -> CGDirectDisplayID? {
        var count: UInt32 = 0
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        guard CGGetDisplaysWithPoint(point, 16, &ids, &count) == .success, count > 0 else {
            return CGMainDisplayID()
        }
        return ids[0]
    }

    /// Shows a clear message (once per launch) when the capture failed for lack of permission.
    static func reportFailureIfNeeded() {
        guard lastFailure == .noPermission || !CGPreflightScreenCaptureAccess() else {
            Toast.show(message: "La capture a échoué", style: .error)
            return
        }
        didWarnAboutPermission = true
        DispatchQueue.main.async {
            PermissionAssistant.shared.show()
        }
    }

    // MARK: - Internals

    private static func baseConfiguration() -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.showsCursor = false
        config.captureResolution = .best
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        return config
    }

    private static func makeFilter(display: SCDisplay, content: SCShareableContent, excludeOwn: Bool) -> SCContentFilter {
        guard excludeOwn else { return SCContentFilter(display: display, excludingWindows: []) }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let ownApps = content.applications.filter { $0.processID == ownPID }
        return SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
    }

    private static func pixelScale(for filter: SCContentFilter, display: SCDisplay) -> CGFloat {
        let scale = CGFloat(filter.pointPixelScale)
        if scale > 0 { return scale }
        if let mode = CGDisplayCopyDisplayMode(display.displayID), display.frame.width > 0 {
            return CGFloat(mode.pixelWidth) / display.frame.width
        }
        return 2
    }

    /// Display containing the center of the rect (falls back to the one with the largest overlap).
    private static func display(for rect: CGRect, in content: SCShareableContent) -> SCDisplay? {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        if let hit = content.displays.first(where: { $0.frame.contains(center) }) { return hit }
        return content.displays.max { a, b in
            let ia = a.frame.intersection(rect), ib = b.frame.intersection(rect)
            return (ia.isNull ? 0 : ia.width * ia.height) < (ib.isNull ? 0 : ib.width * ib.height)
        }
    }

    private final class Box: @unchecked Sendable {
        var image: CGImage?
        var failure: Failure?
    }

    private static let cacheLock = NSLock()
    private static var cachedContent: SCShareableContent?
    private static var cachedAt = Date.distantPast

    private static func shareableContent(maxAge: TimeInterval) async throws -> SCShareableContent {
        if maxAge > 0, let cached = ScreenGrabber.cachedContent(maxAge: maxAge) { return cached }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        ScreenGrabber.storeContent(content)
        return content
    }

    private static func cachedContent(maxAge: TimeInterval) -> SCShareableContent? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        guard Date().timeIntervalSince(cachedAt) <= maxAge else { return nil }
        return cachedContent
    }

    private static func storeContent(_ content: SCShareableContent) {
        cacheLock.lock()
        cachedContent = content
        cachedAt = Date()
        cacheLock.unlock()
    }

    private static func run(maxContentAge: TimeInterval = 0, _ work: @escaping (SCShareableContent) async throws -> CGImage) -> CGImage? {
        let box = Box()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            do {
                let content = try await ScreenGrabber.shareableContent(maxAge: maxContentAge)
                box.image = try await work(content)
            } catch let failure as Failure {
                box.failure = failure
            } catch {
                box.failure = CGPreflightScreenCaptureAccess() ? .captureFailed : .noPermission
            }
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + 5) == .timedOut {
            lastFailure = .timedOut
            return nil
        }
        lastFailure = box.failure
        if box.image == nil && box.failure == nil { lastFailure = .captureFailed }
        return box.image
    }
}
