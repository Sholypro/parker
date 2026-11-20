import AVFoundation
import CoreImage

/// `Parker --selftest-camera`: builds a fake recording (grey screen file + red camera file,
/// written exactly like the recorder writes them), runs the editor's composition and render,
/// and checks that the camera bubble really is in the frames. Run by the Mac CI.
enum CameraSelfTest {
    static func run(big: Bool = false) -> Int32 {
        let semaphore = DispatchSemaphore(value: 0)
        var code: Int32 = 1
        Task.detached {
            do {
                code = big ? try await bigTest() : try await test()
            } catch {
                print("SELFTEST error: \(error)")
                code = 1
            }
            semaphore.signal()
        }
        semaphore.wait()
        return code
    }

    private static func test() async throws -> Int32 {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("parker-selftest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let output = folder.appendingPathComponent("out.mp4")
        var project = RecordingProject.create(outputURL: output)

        // Screen: 3 s grey, 640x360. Camera: red, 320x240, from 0.05 s (like real frames that
        // arrive a bit after the first screen frame).
        try await writeVideo(to: project.screenURL, size: CGSize(width: 640, height: 360),
                             color: (90, 90, 90), start: 0, duration: 3)
        try await writeVideo(to: project.cameraURL, size: CGSize(width: 320, height: 240),
                             color: (230, 20, 20), start: 0.05, duration: 2.9)
        project.hasCamera = true
        project.layout = CameraLayout(centerX: 0.5, centerY: 0.5, size: 0.4, visible: true)
        project.save()

        let built = try await RecordingComposer.build(project)
        print("SELFTEST composition: \(built.videoComposition == nil ? "none" : "with camera")")
        guard let comp = built.videoComposition else { return 1 }

        // Editor preview path: a frame at 1 s
        let generator = AVAssetImageGenerator(asset: built.asset)
        generator.videoComposition = comp
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let preview = try await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600)).image
        let previewRed = isRed(preview)
        print("SELFTEST preview centre red: \(previewRed)")

        // Export path
        try await RecordingRenderer().render(project)
        let exported = AVURLAsset(url: project.outputURL)
        let exportGenerator = AVAssetImageGenerator(asset: exported)
        exportGenerator.requestedTimeToleranceBefore = .zero
        exportGenerator.requestedTimeToleranceAfter = .zero
        let frame = try await exportGenerator.image(at: CMTime(seconds: 1, preferredTimescale: 600)).image
        let exportRed = isRed(frame)
        print("SELFTEST export centre red: \(exportRed)")
        return previewRed && exportRed ? 0 : 1
    }

    /// Real-life size: 4K screen at 60 fps for 10 s + 720p camera. Prints how long the
    /// "Finalisation" export takes, and fails if it does not finish within 3 minutes.
    private static func bigTest() async throws -> Int32 {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("parker-bigtest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var project = RecordingProject.create(outputURL: folder.appendingPathComponent("out.mp4"))
        try await writeVideo(to: project.screenURL, size: CGSize(width: 3840, height: 2160),
                             color: (90, 90, 90), start: 0, duration: 10, fps: 60)
        try await writeVideo(to: project.cameraURL, size: CGSize(width: 1280, height: 720),
                             color: (230, 20, 20), start: 0.05, duration: 9.9, fps: 30)
        project.hasCamera = true
        project.layout = CameraLayout()
        project.save()

        let renderer = RecordingRenderer()
        let started = Date()
        let task = Task { try await renderer.render(project) }
        var last: Float = -1
        while true {
            try await Task.sleep(nanoseconds: 2_000_000_000)
            let elapsed = Date().timeIntervalSince(started)
            if renderer.progress != last {
                last = renderer.progress
                print(String(format: "SELFTEST big: %.0f s, %.0f %%", elapsed, last * 100))
            }
            if FileManager.default.fileExists(atPath: project.outputURL.path), renderer.progress == 0, elapsed > 2 {
                break
            }
            if elapsed > 180 {
                renderer.cancel()
                print("SELFTEST big: still not finished after 180 s")
                return 1
            }
        }
        _ = try await task.value
        print(String(format: "SELFTEST big: done in %.1f s", Date().timeIntervalSince(started)))
        return 0
    }

    private static func isRed(_ image: CGImage) -> Bool {
        let w = image.width, h = image.height
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.draw(image, in: CGRect(x: -CGFloat(w / 2), y: -CGFloat(h / 2), width: CGFloat(w), height: CGFloat(h)))
        print("SELFTEST centre pixel: \(pixel[0]),\(pixel[1]),\(pixel[2])")
        return pixel[0] > 150 && pixel[1] < 90
    }

    /// Same writer setup as the recorder's camera file: session at zero, frames at given times.
    private static func writeVideo(to url: URL, size: CGSize, color: (UInt8, UInt8, UInt8),
                                   start: Double, duration: Double, fps: Int = 30) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(url: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
        ])
        input.expectsMediaDataInRealTime = true
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        let frames = Int(duration * Double(fps))
        var filled: CVPixelBuffer?
        for i in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            if let filled {
                adaptor.append(filled, withPresentationTime: CMTime(seconds: start + Double(i) / Double(fps), preferredTimescale: 600))
                continue
            }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            guard let buffer else { throw CocoaError(.fileWriteUnknown) }
            filled = buffer
            CVPixelBufferLockBaseAddress(buffer, [])
            let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            let bytes = CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer)
            var p = 0
            while p + 3 < bytes {
                base[p] = color.2; base[p + 1] = color.1; base[p + 2] = color.0; base[p + 3] = 255
                p += 4
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(seconds: start + Double(i) / Double(fps), preferredTimescale: 600))
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }
}
