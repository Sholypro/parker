import Cocoa
import CoreMedia
import ScreenCaptureKit

/// Continuous capture of a screen area for the scrolling capture.
///
/// Uses a ScreenCaptureKit stream (up to 30 frames per second, delivered off the main thread),
/// so fast scrolling still leaves overlapping frames. Frames wait in a buffer until the stitcher
/// takes them; when it falls behind, every other frame is dropped (the newest is always kept),
/// which keeps memory bounded while the gaps stay small.
/// If the stream cannot start, it falls back to periodic screenshots on a background queue.
final class ScrollFrameSource: NSObject, SCStreamOutput, SCStreamDelegate {
    /// Called on a background queue each time a frame is buffered.
    var onFrame: (() -> Void)?
    /// Pixels per point of the delivered frames.
    private(set) var pixelScale: CGFloat = 2

    private let rect: CGRect  // global points, top-left origin
    private let queue = DispatchQueue(label: "parker.scroll.frames", qos: .userInitiated)
    private let lock = NSLock()
    private var frames: [CGImage] = []
    private var latest: CGImage?
    private var maxFrames = 8
    private var stream: SCStream?
    private var pollTimer: DispatchSourceTimer?
    private var stopped = false

    init(rect: CGRect) {
        self.rect = rect
        super.init()
    }

    /// Starts the capture. `completion` (main queue) receives false if the stream was
    /// unavailable and the slower fallback is used instead.
    func start(completion: @escaping (Bool) -> Void) {
        let rect = self.rect
        Task { [weak self] in
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                let center = CGPoint(x: rect.midX, y: rect.midY)
                guard let display = content.displays.first(where: { $0.frame.contains(center) }) ?? content.displays.first else {
                    throw ScreenGrabber.Failure.noDisplay
                }
                let ownPID = ProcessInfo.processInfo.processIdentifier
                let ownApps = content.applications.filter { $0.processID == ownPID }
                let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
                var scale = CGFloat(filter.pointPixelScale)
                if scale <= 0 { scale = 2 }

                let local = CGRect(
                    x: rect.minX - display.frame.minX,
                    y: rect.minY - display.frame.minY,
                    width: rect.width,
                    height: rect.height
                ).intersection(CGRect(origin: .zero, size: display.frame.size))
                guard !local.isNull, local.width >= 1, local.height >= 1 else { throw ScreenGrabber.Failure.noDisplay }

                let config = SCStreamConfiguration()
                config.sourceRect = local
                config.width = max(1, Int((local.width * scale).rounded()))
                config.height = max(1, Int((local.height * scale).rounded()))
                config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
                config.queueDepth = 6
                config.showsCursor = false
                config.captureResolution = .best
                config.pixelFormat = kCVPixelFormatType_32BGRA
                config.colorSpaceName = CGColorSpace.sRGB

                guard let self = self else { return }
                let stream = SCStream(filter: filter, configuration: config, delegate: self)
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.queue)
                try await stream.startCapture()

                let alreadyStopped = self.adopt(stream, scale: CGFloat(config.height) / max(1, local.height))
                if alreadyStopped { try? await stream.stopCapture() }
                DispatchQueue.main.async { completion(true) }
            } catch {
                guard let self = self else { return }
                self.startPolling()
                DispatchQueue.main.async { completion(false) }
            }
        }
    }

    /// Keeps the started stream. Returns true if `stop()` was called in the meantime.
    private func adopt(_ stream: SCStream, scale: CGFloat) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        pixelScale = scale
        if stopped { return true }
        self.stream = stream
        return false
    }

    func stop() {
        lock.lock()
        stopped = true
        let stream = self.stream
        self.stream = nil
        let timer = pollTimer
        pollTimer = nil
        lock.unlock()
        timer?.cancel()
        stream?.stopCapture { _ in }
    }

    /// Frames received since the last call, oldest first.
    func drain() -> [CGImage] {
        lock.lock()
        defer { lock.unlock() }
        let list = frames
        frames.removeAll()
        return list
    }

    /// Most recent frame, even if already drained.
    var latestFrame: CGImage? {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }

    // MARK: - Stream

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: statusRaw),
              status == .complete,
              let pixelBuffer = sampleBuffer.imageBuffer,
              let image = Self.makeImage(pixelBuffer)
        else { return }
        push(image)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.lock()
        let wasStopped = stopped
        self.stream = nil
        lock.unlock()
        if !wasStopped { startPolling() }
    }

    // MARK: - Fallback: periodic screenshots

    private func startPolling() {
        lock.lock()
        guard !stopped, pollTimer == nil else { lock.unlock(); return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        pollTimer = timer
        lock.unlock()

        let rect = self.rect
        timer.schedule(deadline: .now(), repeating: .milliseconds(90))
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            guard let image = ScreenGrabber.capture(rect: rect, maxContentAge: 5) else { return }
            if rect.height > 0 { self.pixelScale = CGFloat(image.height) / rect.height }
            // Only keep frames that differ from the previous one (the stream does the same)
            if let previous = self.latestFrame, Self.looksIdentical(previous, image) { return }
            self.push(image)
        }
        timer.resume()
    }

    // MARK: - Buffer

    private func push(_ image: CGImage) {
        lock.lock()
        if stopped { lock.unlock(); return }
        if frames.isEmpty && latest == nil {
            let bytes = max(1, image.bytesPerRow * image.height)
            maxFrames = max(3, min(16, (240 * 1024 * 1024) / bytes))
        }
        frames.append(image)
        latest = image
        if frames.count > maxFrames {
            // Drop every other frame, newest kept
            var i = frames.count - 2
            while i >= 1 {
                frames.remove(at: i)
                i -= 2
            }
        }
        lock.unlock()
        onFrame?()
    }

    /// Copies the pixel buffer (the stream reuses its buffers) into an independent image.
    private static func makeImage(_ pixelBuffer: CVPixelBuffer) -> CGImage? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard width > 0, height > 0, let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let data = Data(bytes: base, count: bytesPerRow * height)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: bytesPerRow, space: space, bitmapInfo: info, provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// Cheap equality test on the raw bytes (fallback mode only).
    private static func looksIdentical(_ a: CGImage, _ b: CGImage) -> Bool {
        guard a.width == b.width, a.height == b.height, a.bytesPerRow == b.bytesPerRow,
              let da = a.dataProvider?.data, let db = b.dataProvider?.data,
              CFDataGetLength(da) == CFDataGetLength(db),
              let pa = CFDataGetBytePtr(da), let pb = CFDataGetBytePtr(db)
        else { return false }
        return memcmp(pa, pb, CFDataGetLength(da)) == 0
    }
}
