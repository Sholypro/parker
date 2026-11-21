import Cocoa
import AVFoundation
import CoreImage
import Metal
import VideoToolbox

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

/// A piece of the recording between two cuts. `removed` pieces are left out of the video.
struct Segment: Codable, Equatable {
    var start: Double
    var end: Double
    var removed: Bool = false
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
    /// Cuts in the middle (nil: one piece).
    var segments: [Segment]?
    /// Diagnostics: camera frames written, and the time of the first one in the recording.
    var cameraFrames: Int?
    var cameraFirstSeconds: Double?
    /// Export quality chosen in the editor: maximum height in pixels. nil: default (1440p), 0: as recorded.
    var exportMaxHeight: Int?
    static let defaultExportHeight = 1440
    /// Height limit actually applied to the finished video (0: none).
    var effectiveExportHeight: Int { exportMaxHeight ?? Self.defaultExportHeight }

    /// Pieces covering the whole recording.
    func allSegments(duration: Double) -> [Segment] {
        guard let segments, !segments.isEmpty else { return [Segment(start: 0, end: duration)] }
        return segments
    }

    /// What ends up in the video: kept pieces inside the start and end handles, in order.
    func keptRanges(duration: Double) -> [(start: Double, end: Double)] {
        let lo = max(0, trimStart)
        let hi = min(trimEnd ?? duration, duration)
        var result: [(start: Double, end: Double)] = []
        for segment in allSegments(duration: duration) where !segment.removed {
            let s = max(segment.start, lo)
            let e = min(segment.end, hi)
            guard e - s > 0.01 else { continue }
            if let last = result.last, abs(last.end - s) < 0.01 {
                result[result.count - 1].end = e
            } else {
                result.append((s, e))
            }
        }
        return result
    }

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
    /// `ranges` (seconds): pieces to keep, played one after the other. nil: the whole recording.
    static func build(_ project: RecordingProject, ranges: [(start: Double, end: Double)]? = nil,
                      withCamera: Bool = true) async throws -> Built {
        let screen = AVURLAsset(url: project.screenURL)
        guard let screenVideo = try await screen.loadTracks(withMediaType: .video).first else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let sourceDuration = try await screen.load(.duration)

        // The camera asset stays alive for the whole build: a track only holds a weak reference
        // to its asset, and once the asset is gone the track cannot be inserted any more.
        var cameraAsset: AVURLAsset?
        var cameraSource: AVAssetTrack?
        if withCamera, project.hasCamera, FileManager.default.fileExists(atPath: project.cameraURL.path) {
            let camera = AVURLAsset(url: project.cameraURL)
            cameraAsset = camera
            cameraSource = try? await camera.loadTracks(withMediaType: .video).first
        }
        defer { withExtendedLifetime(cameraAsset) {} }
        if cameraSource == nil && ranges == nil {
            return Built(asset: screen, videoComposition: nil, duration: sourceDuration)
        }

        let pieces: [CMTimeRange] = (ranges ?? [(0, sourceDuration.seconds)]).map {
            CMTimeRange(start: CMTime(seconds: $0.start, preferredTimescale: 600),
                        end: CMTimeMinimum(CMTime(seconds: $0.end, preferredTimescale: 600), sourceDuration))
        }

        let composition = AVMutableComposition()
        guard let screenTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let screenRange = try await screenVideo.load(.timeRange)
        insert(pieces, from: screenVideo, sourceRange: screenRange, offset: .zero, into: screenTrack)

        for audio in try await screen.loadTracks(withMediaType: .audio) {
            let range = try await audio.load(.timeRange)
            if let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                insert(pieces, from: audio, sourceRange: range, offset: .zero, into: track)
            }
        }

        var cameraTrackID = kCMPersistentTrackID_Invalid
        if let cameraSource, let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
            let cameraRange = try await cameraSource.load(.timeRange)
            // Where the camera file really has images (its timeline may start with an empty edit)
            let sourceSegments = (try? await cameraSource.load(.segments)) ?? []
            let filled = sourceSegments.filter { !$0.isEmpty }.map { $0.timeMapping.target }
            let firstImage = filled.map(\.start).min() ?? cameraRange.start
            let lastImage = filled.map(\.end).max() ?? cameraRange.end
            let imageRange = CMTimeRange(start: firstImage, end: lastImage)

            // Normal case: the camera file shares the screen's time line
            insert(pieces, from: cameraSource, sourceRange: imageRange, offset: .zero, into: track)
            if !track.segments.contains(where: { !$0.isEmpty }) {
                // Older recordings: camera images outside the video's time line. Lay them from
                // the start of the video instead of losing them.
                for segment in track.segments {
                    track.removeTimeRange(segment.timeMapping.target)
                }
                insert(pieces, from: cameraSource, sourceRange: imageRange,
                       offset: CMTimeSubtract(.zero, firstImage), into: track)
            }
            if track.segments.contains(where: { !$0.isEmpty }) {
                cameraTrackID = track.trackID
            } else if let empty = Optional(track) {
                composition.removeTrack(empty)
            }
        }

        let duration = composition.duration
        guard cameraTrackID != kCMPersistentTrackID_Invalid else {
            return Built(asset: composition, videoComposition: nil, duration: duration)
        }

        let renderSize = try await screenVideo.load(.naturalSize)
        let videoComposition = AVMutableVideoComposition()
        videoComposition.customVideoCompositorClass = CameraOverlayCompositor.self
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        videoComposition.instructions = [
            CameraOverlayInstruction(
                timeRange: CMTimeRange(start: .zero, duration: duration),
                screenTrackID: screenTrack.trackID,
                cameraTrackID: cameraTrackID,
                layout: project.layout
            ),
        ]
        return Built(asset: composition, videoComposition: videoComposition, duration: duration)
    }

    /// Lays each kept piece of `source` one after the other. `offset` moves the source's own
    /// times onto the recording's time line.
    private static func insert(_ pieces: [CMTimeRange], from source: AVAssetTrack, sourceRange: CMTimeRange,
                               offset: CMTime, into track: AVMutableCompositionTrack) {
        var cursor = CMTime.zero
        for piece in pieces {
            // Piece in the source's own times
            let wanted = CMTimeRange(start: CMTimeSubtract(piece.start, offset), duration: piece.duration)
            let available = wanted.intersection(sourceRange)
            if available.duration.seconds > 0 {
                let at = CMTimeAdd(cursor, CMTimeSubtract(available.start, wanted.start))
                do {
                    try track.insertTimeRange(available, of: source, at: at)
                } catch {
                    NSLog("Parker: insertion impossible (\(error))")
                }
            }
            cursor = CMTimeAdd(cursor, piece.duration)
        }
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
    private var reader: AVAssetReader?
    private var writer: AVAssetWriter?
    private let lock = NSLock()
    private var encodeProgress: Float = 0
    private var cancelled = false

    /// 0 to 1 while exporting.
    var progress: Float {
        if let session { return session.progress }
        lock.lock(); defer { lock.unlock() }
        return encodeProgress
    }

    func cancel() {
        session?.cancelExport()
        session = nil
        lock.lock()
        cancelled = true
        let reader = self.reader, writer = self.writer
        lock.unlock()
        reader?.cancelReading()
        writer?.cancelWriting()
    }

    /// Writes the finished video to `project.outputURL` (replacing it).
    func render(_ project: RecordingProject) async throws {
        cancel()
        let sourceDuration = (try? await AVURLAsset(url: project.screenURL).load(.duration).seconds) ?? 0
        let kept = project.keptRanges(duration: sourceDuration)
        guard !kept.isEmpty else { throw CocoaError(.fileWriteUnknown) }
        let isFull = kept.count == 1 && kept[0].start < 0.01 && kept[0].end >= sourceDuration - 0.01
        // Camera hidden: nothing to draw, so the video is copied instead of re-encoded
        let built = try await RecordingComposer.build(project, ranges: isFull ? nil : kept,
                                                      withCamera: project.layout.visible)

        let output = project.outputURL
        let fm = FileManager.default
        try? fm.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = output.deletingLastPathComponent().appendingPathComponent(".parker-\(UUID().uuidString).mp4")

        // Export quality: a smaller size than the recording means re-encoding
        var sourceSize = CGSize.zero
        if let track = try? await AVURLAsset(url: project.screenURL).loadTracks(withMediaType: .video).first,
           let natural = try? await track.load(.naturalSize) {
            sourceSize = natural
        }
        var outputSize = built.videoComposition?.renderSize ?? sourceSize
        let limit = project.effectiveExportHeight
        if limit > 0, outputSize.height > CGFloat(limit) + 1 {
            let scale = CGFloat(limit) / outputSize.height
            outputSize = CGSize(width: (outputSize.width * scale / 2).rounded() * 2, height: CGFloat(limit))
        }
        let resized = outputSize.height < (built.videoComposition?.renderSize ?? sourceSize).height - 1

        // Nothing to draw, nothing cut, same size: the screen file is the result
        if built.videoComposition == nil && isFull && !resized {
            try fm.copyItem(at: project.screenURL, to: tmp)
            try replace(output, with: tmp)
            return
        }

        // Camera to draw or smaller size: our own encoder, tuned for speed (see encodeFast)
        if built.videoComposition != nil || resized {
            var composition = built.videoComposition
            if composition == nil {
                composition = try await AVMutableVideoComposition.videoComposition(withPropertiesOf: built.asset)
            }
            lock.lock(); cancelled = false; encodeProgress = 0; lock.unlock()
            do {
                try await encodeFast(built, composition: composition!, outputSize: outputSize,
                                     screenURL: project.screenURL, to: tmp)
            } catch {
                try? fm.removeItem(at: tmp)
                throw error
            }
            try replace(output, with: tmp)
            return
        }

        // Only cuts: the pieces are copied, nothing is re-encoded
        guard let session = AVAssetExportSession(asset: built.asset, presetName: AVAssetExportPresetPassthrough) else {
            throw CocoaError(.fileWriteUnknown)
        }
        session.outputURL = tmp
        session.outputFileType = .mp4
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

    /// Reads the composition (camera drawn by the compositor) and encodes it with the hardware
    /// encoder set to favour speed, at about the bit rate of the original recording.
    /// AVAssetExportSession's "highest quality" preset encoded several times slower.
    private func encodeFast(_ built: RecordingComposer.Built, composition: AVVideoComposition,
                            outputSize: CGSize, screenURL: URL, to url: URL) async throws {
        let asset = built.asset
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let size = outputSize
        let duration = max(0.01, built.duration.seconds)

        // Bit rate of the original screen file, within sensible limits
        var bitRate = Double(size.width * size.height) * 30 * 0.12
        if let track = try? await AVURLAsset(url: screenURL).loadTracks(withMediaType: .video).first,
           let rate = try? await track.load(.estimatedDataRate), rate > 0 {
            // Same quality per pixel as the recording, fewer pixels when the size is reduced
            let shrink = size.height / max(composition.renderSize.height, 1)
            bitRate = Double(rate) * 1.1 * Double(min(1, shrink * shrink))
        }
        bitRate = min(max(bitRate, 4_000_000), 60_000_000)

        let reader = try AVAssetReader(asset: asset)
        let videoOut = AVAssetReaderVideoCompositionOutput(videoTracks: videoTracks, videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ])
        videoOut.videoComposition = composition
        videoOut.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOut) else { throw CocoaError(.fileReadUnknown) }
        reader.add(videoOut)

        var audioOut: AVAssetReaderAudioMixOutput?
        if !audioTracks.isEmpty {
            let out = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
            if reader.canAdd(out) { reader.add(out); audioOut = out }
        }

        let writer = try AVAssetWriter(url: url, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width) & ~1,
            AVVideoHeightKey: Int(size.height) & ~1,
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Int(bitRate),
                AVVideoExpectedSourceFrameRateKey: 30,
                AVVideoMaxKeyFrameIntervalKey: 60,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality as String: true,
            ] as [String: Any],
        ])
        videoIn.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoIn) else { throw CocoaError(.fileWriteUnknown) }
        writer.add(videoIn)
        var audioIn: AVAssetWriterInput?
        if audioOut != nil {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 160000,
            ])
            if writer.canAdd(input) { writer.add(input); audioIn = input }
        }

        lock.lock()
        let stop = cancelled
        self.reader = reader
        self.writer = writer
        lock.unlock()
        if stop { throw CancellationError() }

        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadUnknown) }
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let group = DispatchGroup()
            pump(videoOut, into: videoIn, queue: DispatchQueue(label: "parker.encode.video"), group: group) { [weak self] time in
                guard let self else { return }
                self.lock.lock()
                self.encodeProgress = Float(min(1, time.seconds / duration))
                self.lock.unlock()
            }
            if let audioOut, let audioIn {
                pump(audioOut, into: audioIn, queue: DispatchQueue(label: "parker.encode.audio"), group: group, onSample: nil)
            }
            group.notify(queue: .global()) { continuation.resume() }
        }

        lock.lock()
        let wasCancelled = cancelled
        self.reader = nil
        self.writer = nil
        lock.unlock()
        if wasCancelled { throw CancellationError() }
        guard reader.status == .completed else {
            writer.cancelWriting()
            throw reader.error ?? CocoaError(.fileReadUnknown)
        }
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }

    private func pump(_ output: AVAssetReaderOutput, into input: AVAssetWriterInput, queue: DispatchQueue,
                      group: DispatchGroup, onSample: ((CMTime) -> Void)?) {
        group.enter()
        var done = false
        input.requestMediaDataWhenReady(on: queue) {
            guard !done else { return }
            while input.isReadyForMoreMediaData {
                guard let buffer = output.copyNextSampleBuffer(), input.append(buffer) else {
                    done = true
                    input.markAsFinished()
                    group.leave()
                    return
                }
                onSample?(CMSampleBufferGetPresentationTimeStamp(buffer))
            }
        }
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
    // Frames stay in the video's own format (YUV 4:2:0, what the decoder gives and the encoder
    // takes): no full-frame conversion to RGB and back for every frame. BGRA is still accepted.
    private static let pixelFormats: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: [
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelFormatType_32BGRA,
        ],
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
    ]
    private static let outputFormat: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
    ]
    var sourcePixelBufferAttributes: [String: Any]? { Self.pixelFormats }
    var requiredPixelBufferAttributesForRenderContext: [String: Any] { Self.outputFormat }

    /// GPU context without color management: pixels are copied as they are (the screen already
    /// is in the video's color space), which removes two full-frame conversions per frame.
    private let context: CIContext = {
        let options: [CIContextOption: Any] = [
            .workingColorSpace: NSNull(),
            .outputColorSpace: NSNull(),
            .cacheIntermediates: false,
        ]
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: options)
        }
        return CIContext(options: options)
    }()

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let instruction = request.videoCompositionInstruction as? CameraOverlayInstruction,
              let screenBuffer = request.sourceFrame(byTrackID: instruction.screenTrackID),
              let output = request.renderContext.newPixelBuffer() else {
            request.finish(with: CocoaError(.fileReadCorruptFile))
            return
        }
        let raw: [CIImageOption: Any] = [.colorSpace: NSNull()]
        var image = CIImage(cvPixelBuffer: screenBuffer, options: raw)
        let extent = image.extent

        if instruction.layout.visible,
           instruction.cameraTrackID != kCMPersistentTrackID_Invalid,
           let cameraBuffer = request.sourceFrame(byTrackID: instruction.cameraTrackID) {
            image = Self.overlay(camera: CIImage(cvPixelBuffer: cameraBuffer, options: raw), on: image,
                                 layout: instruction.layout)
        }

        context.render(image.cropped(to: extent), to: output, bounds: extent, colorSpace: nil)
        request.finish(withComposedVideoFrame: output)
    }

    /// Draws the round, mirrored camera over the screen. Every filter works on the bubble's
    /// square only (not on the whole 4K frame), then the bubble is laid over the screen.
    static func overlay(camera: CIImage, on screen: CIImage, layout: CameraLayout) -> CIImage {
        let W = screen.extent.width
        let H = screen.extent.height
        let diameter = (CGFloat(layout.size) * min(W, H)).rounded()
        let radius = diameter / 2
        let cx = (CGFloat(layout.centerX) * W).rounded()
        let cy = ((1 - CGFloat(layout.centerY)) * H).rounded()   // Core Image: origin bottom-left
        let box = CGRect(x: cx - radius, y: cy - radius, width: diameter, height: diameter)

        // Square crop of the camera, mirrored like the on-screen bubble, scaled and placed
        let ce = camera.extent
        let side = min(ce.width, ce.height)
        var cam = camera.cropped(to: CGRect(x: ce.midX - side / 2, y: ce.midY - side / 2, width: side, height: side))
        cam = cam.transformed(by: CGAffineTransform(translationX: -cam.extent.minX, y: -cam.extent.minY))
        let scale = diameter / side
        cam = cam.transformed(by: CGAffineTransform(scaleX: -scale, y: scale)
            .concatenating(CGAffineTransform(translationX: box.minX + diameter, y: box.minY)))
            .cropped(to: box)

        let center = CIVector(x: cx, y: cy)
        func disk(_ r: CGFloat, in rect: CGRect) -> CIImage {
            CIFilter(name: "CIRadialGradient", parameters: [
                "inputCenter": center,
                "inputRadius0": max(0, r - 0.75),
                "inputRadius1": r + 0.75,
                "inputColor0": CIColor.white,
                "inputColor1": CIColor.black,
            ])?.outputImage?.cropped(to: rect) ?? CIImage.empty()
        }

        // Soft shadow under the bubble (its own small square)
        let shadowBox = box.insetBy(dx: -radius * 0.15, dy: -radius * 0.2)
        let shadow = CIFilter(name: "CIRadialGradient", parameters: [
            "inputCenter": CIVector(x: cx, y: cy - diameter * 0.03),
            "inputRadius0": radius * 0.9,
            "inputRadius1": radius * 1.12,
            "inputColor0": CIColor(red: 0, green: 0, blue: 0, alpha: 0.35),
            "inputColor1": CIColor(red: 0, green: 0, blue: 0, alpha: 0),
        ])?.outputImage?.cropped(to: shadowBox) ?? CIImage.empty()

        // Camera cut into a circle, transparent around it
        let round = cam.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.empty(),
            kCIInputMaskImageKey: disk(radius, in: box),
        ]).cropped(to: box)

        // Thin white ring, like the bubble on screen
        let ringWidth = max(2, diameter * 0.018)
        let ringMask = disk(radius - ringWidth, in: box).applyingFilter("CISubtractBlendMode", parameters: [
            kCIInputBackgroundImageKey: disk(radius, in: box),
        ])
        let ring = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 0.92)).cropped(to: box)
            .applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: CIImage.empty(),
                kCIInputMaskImageKey: ringMask,
            ]).cropped(to: box)

        return ring.composited(over: round).composited(over: shadow).composited(over: screen)
    }
}
