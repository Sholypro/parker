import Cocoa
import AVFoundation
import CoreImage

/// Where the webcam bubble sits in the final video. Coordinates are fractions of the video,
/// origin top-left, so they survive any video size.
struct CameraLayout: Codable, Equatable {
    var centerX: Double = 0.88
    var centerY: Double = 0.82
    /// Diameter as a fraction of the video's smaller side.
    var size: Double = 0.22
    var visible: Bool = true

    static let minSize = 0.10
    static let maxSize = 0.50
}

/// One screen recording kept editable: the screen video (sound included) and, if the camera
/// was on, the camera video recorded separately, so the bubble can be moved after the fact.
/// Files live in ~/Library/Application Support/Parker/Projects/<id>/.
/// The finished video (what the history, copy and share use) is `outputURL`.
struct RecordingProject: Codable {
    var id: String
    var outputPath: String
    var hasCamera: Bool
    var layout: CameraLayout
    var trimStart: Double = 0
    /// nil: until the end.
    var trimEnd: Double?

    var folder: URL { Self.projectsDirectory.appendingPathComponent(id, isDirectory: true) }
    var screenURL: URL { folder.appendingPathComponent("screen.mp4") }
    var cameraURL: URL { folder.appendingPathComponent("camera.mp4") }
    var outputURL: URL { URL(fileURLWithPath: outputPath) }
    private var jsonURL: URL { folder.appendingPathComponent("project.json") }

    static var projectsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let url = base.appendingPathComponent("Parker/Projects", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// New empty project folder. Keeps only the 10 most recent projects on disk.
    static func create(outputURL: URL) -> RecordingProject {
        prune(keeping: 9)
        let project = RecordingProject(
            id: UUID().uuidString,
            outputPath: outputURL.path,
            hasCamera: false,
            layout: CameraLayout()
        )
        try? FileManager.default.createDirectory(at: project.folder, withIntermediateDirectories: true)
        return project
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            try? data.write(to: jsonURL, options: .atomic)
        }
    }

    /// The project that produced this finished video, if it is still on disk.
    static func find(forOutput url: URL) -> RecordingProject? {
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(at: projectsDirectory, includingPropertiesForKeys: nil) else { return nil }
        let target = url.standardizedFileURL.path
        for folder in folders {
            let json = folder.appendingPathComponent("project.json")
            guard let data = try? Data(contentsOf: json),
                  let project = try? JSONDecoder().decode(RecordingProject.self, from: data) else { continue }
            if URL(fileURLWithPath: project.outputPath).standardizedFileURL.path == target,
               fm.fileExists(atPath: project.screenURL.path) {
                return project
            }
        }
        return nil
    }

    private static func prune(keeping count: Int) {
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(
            at: projectsDirectory, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles]
        ) else { return }
        let sorted = folders.sorted {
            let a = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return a > b
        }
        for folder in sorted.dropFirst(count) {
            try? fm.removeItem(at: folder)
        }
    }
}

// MARK: - Composition (shared by the editor preview and the export)

enum RecordingComposer {
    struct Built {
        let asset: AVAsset
        let videoComposition: AVVideoComposition?
        let duration: CMTime
    }

    /// Screen + sound + (optionally) the camera bubble drawn by `CameraOverlayCompositor`.
    static func build(_ project: RecordingProject) async throws -> Built {
        let screen = AVURLAsset(url: project.screenURL)
        guard let screenVideo = try await screen.loadTracks(withMediaType: .video).first else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let duration = try await screen.load(.duration)

        var cameraTrackSource: AVAssetTrack?
        if project.hasCamera, FileManager.default.fileExists(atPath: project.cameraURL.path) {
            let camera = AVURLAsset(url: project.cameraURL)
            cameraTrackSource = try? await camera.loadTracks(withMediaType: .video).first
        }
        guard let cameraSource = cameraTrackSource else {
            return Built(asset: screen, videoComposition: nil, duration: duration)
        }

        let composition = AVMutableComposition()
        let full = CMTimeRange(start: .zero, duration: duration)
        guard let screenTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try screenTrack.insertTimeRange(full, of: screenVideo, at: .zero)

        for audio in try await screen.loadTracks(withMediaType: .audio) {
            let range = try await audio.load(.timeRange)
            if let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                try? track.insertTimeRange(range, of: audio, at: range.start)
            }
        }

        var cameraTrackID = kCMPersistentTrackID_Invalid
        let cameraRange = try await cameraSource.load(.timeRange)
        if let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
            // The camera file shares the screen's time line (same zero), so it goes at the same time
            let start = cameraRange.start
            let end = CMTimeMinimum(cameraRange.end, duration)
            if end > start {
                try? track.insertTimeRange(CMTimeRange(start: start, end: end), of: cameraSource, at: start)
                cameraTrackID = track.trackID
            }
        }

        let renderSize = try await screenVideo.load(.naturalSize)
        let videoComposition = AVMutableVideoComposition()
        videoComposition.customVideoCompositorClass = CameraOverlayCompositor.self
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        videoComposition.instructions = [
            CameraOverlayInstruction(
                timeRange: full,
                screenTrackID: screenTrack.trackID,
                cameraTrackID: cameraTrackID,
                layout: project.layout
            ),
        ]
        return Built(asset: composition, videoComposition: videoComposition, duration: duration)
    }

    /// Same composition with a new bubble layout (used live by the editor).
    static func videoComposition(_ base: AVVideoComposition, with layout: CameraLayout) -> AVVideoComposition {
        guard let copy = base.mutableCopy() as? AVMutableVideoComposition else { return base }
        copy.instructions = base.instructions.compactMap { instruction in
            guard let old = instruction as? CameraOverlayInstruction else { return instruction }
            return CameraOverlayInstruction(
                timeRange: old.timeRange,
                screenTrackID: old.screenTrackID,
                cameraTrackID: old.cameraTrackID,
                layout: layout
            )
        }
        return copy
    }
}

// MARK: - Export

final class RecordingRenderer {
    private var session: AVAssetExportSession?

    func cancel() {
        session?.cancelExport()
        session = nil
    }

    /// Writes the finished video to `project.outputURL` (replacing it).
    func render(_ project: RecordingProject) async throws {
        cancel()
        let built = try await RecordingComposer.build(project)
        let start = CMTime(seconds: max(0, project.trimStart), preferredTimescale: 600)
        let end = project.trimEnd.map { CMTime(seconds: $0, preferredTimescale: 600) } ?? built.duration
        let range = CMTimeRange(start: start, end: CMTimeMinimum(end, built.duration))
        let isFull = start.seconds < 0.01 && range.end.seconds >= built.duration.seconds - 0.01

        let output = project.outputURL
        let fm = FileManager.default
        try? fm.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)

        // Nothing to draw and nothing cut: the screen file is the result
        if built.videoComposition == nil && isFull {
            let tmp = output.deletingLastPathComponent().appendingPathComponent(".parker-\(UUID().uuidString).mp4")
            try fm.copyItem(at: project.screenURL, to: tmp)
            try replace(output, with: tmp)
            return
        }

        let preset = built.videoComposition == nil ? AVAssetExportPresetPassthrough : AVAssetExportPresetHighestQuality
        guard let session = AVAssetExportSession(asset: built.asset, presetName: preset) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let tmp = output.deletingLastPathComponent().appendingPathComponent(".parker-\(UUID().uuidString).mp4")
        session.outputURL = tmp
        session.outputFileType = .mp4
        session.timeRange = range
        session.videoComposition = built.videoComposition
        session.shouldOptimizeForNetworkUse = true
        self.session = session

        await session.export()
        self.session = nil
        guard session.status == .completed else {
            try? fm.removeItem(at: tmp)
            if session.status == .cancelled { throw CancellationError() }
            throw session.error ?? CocoaError(.fileWriteUnknown)
        }
        try replace(output, with: tmp)
    }

    private func replace(_ url: URL, with tmp: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            _ = try fm.replaceItemAt(url, withItemAt: tmp)
        } else {
            try fm.moveItem(at: tmp, to: url)
        }
    }
}

// MARK: - Compositor: draws the round, mirrored camera over the screen

final class CameraOverlayInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid

    let screenTrackID: CMPersistentTrackID
    let cameraTrackID: CMPersistentTrackID
    let layout: CameraLayout

    init(timeRange: CMTimeRange, screenTrackID: CMPersistentTrackID, cameraTrackID: CMPersistentTrackID, layout: CameraLayout) {
        self.timeRange = timeRange
        self.screenTrackID = screenTrackID
        self.cameraTrackID = cameraTrackID
        self.layout = layout
        var ids = [NSNumber(value: screenTrackID)]
        if cameraTrackID != kCMPersistentTrackID_Invalid { ids.append(NSNumber(value: cameraTrackID)) }
        self.requiredSourceTrackIDs = ids
    }
}

final class CameraOverlayCompositor: NSObject, AVVideoCompositing {
    private static let pixelFormat: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    ]
    var sourcePixelBufferAttributes: [String: Any]? { Self.pixelFormat }
    var requiredPixelBufferAttributesForRenderContext: [String: Any] { Self.pixelFormat }

    private let context = CIContext(options: [.cacheIntermediates: false])

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let instruction = request.videoCompositionInstruction as? CameraOverlayInstruction,
              let screenBuffer = request.sourceFrame(byTrackID: instruction.screenTrackID),
              let output = request.renderContext.newPixelBuffer() else {
            request.finish(with: CocoaError(.fileReadCorruptFile))
            return
        }
        var image = CIImage(cvPixelBuffer: screenBuffer)
        let extent = image.extent

        if instruction.layout.visible,
           instruction.cameraTrackID != kCMPersistentTrackID_Invalid,
           let cameraBuffer = request.sourceFrame(byTrackID: instruction.cameraTrackID) {
            image = Self.overlay(camera: CIImage(cvPixelBuffer: cameraBuffer), on: image, layout: instruction.layout)
        }

        context.render(image.cropped(to: extent), to: output)
        request.finish(withComposedVideoFrame: output)
    }

    static func overlay(camera: CIImage, on screen: CIImage, layout: CameraLayout) -> CIImage {
        let W = screen.extent.width
        let H = screen.extent.height
        let diameter = CGFloat(layout.size) * min(W, H)
        let radius = diameter / 2
        let cx = CGFloat(layout.centerX) * W
        let cy = (1 - CGFloat(layout.centerY)) * H   // Core Image: origin bottom-left

        // Square crop of the camera, mirrored like the on-screen bubble, scaled and placed
        let ce = camera.extent
        let side = min(ce.width, ce.height)
        var cam = camera.cropped(to: CGRect(x: ce.midX - side / 2, y: ce.midY - side / 2, width: side, height: side))
        cam = cam.transformed(by: CGAffineTransform(translationX: -cam.extent.minX, y: -cam.extent.minY))
        let scale = diameter / side
        cam = cam.transformed(by: CGAffineTransform(scaleX: -scale, y: scale)
            .concatenating(CGAffineTransform(translationX: diameter, y: 0)))
        cam = cam.transformed(by: CGAffineTransform(translationX: cx - radius, y: cy - radius))

        let center = CIVector(x: cx, y: cy)
        func disk(_ r: CGFloat) -> CIImage {
            CIFilter(name: "CIRadialGradient", parameters: [
                "inputCenter": center,
                "inputRadius0": max(0, r - 0.75),
                "inputRadius1": r + 0.75,
                "inputColor0": CIColor.white,
                "inputColor1": CIColor.black,
            ])?.outputImage?.cropped(to: screen.extent) ?? CIImage.empty()
        }

        // Soft shadow under the bubble
        let shadowMask = CIFilter(name: "CIRadialGradient", parameters: [
            "inputCenter": CIVector(x: cx, y: cy - diameter * 0.03),
            "inputRadius0": radius * 0.9,
            "inputRadius1": radius * 1.12,
            "inputColor0": CIColor(red: 0, green: 0, blue: 0, alpha: 0.35),
            "inputColor1": CIColor(red: 0, green: 0, blue: 0, alpha: 0),
        ])?.outputImage?.cropped(to: screen.extent)
        var result = shadowMask.map { $0.composited(over: screen) } ?? screen

        result = cam.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: result,
            kCIInputMaskImageKey: disk(radius),
        ])

        // Thin white ring, like the bubble
        let ringWidth = max(2, diameter * 0.018)
        let ringMask = disk(radius - ringWidth).applyingFilter("CISubtractBlendMode", parameters: [
            kCIInputBackgroundImageKey: disk(radius),
        ])
        let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 0.92)).cropped(to: screen.extent)
        result = white.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: result,
            kCIInputMaskImageKey: ringMask,
        ])
        return result
    }
}
