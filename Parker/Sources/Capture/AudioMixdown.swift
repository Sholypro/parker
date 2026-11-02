import AVFoundation

/// A recording with the microphone and the Mac's sound is written with two audio tracks.
/// Most players (browsers, Slack, Notion) only play the first one, so once the recording
/// ends both tracks are mixed into a single stereo track. The video is copied as is
/// (no re-encoding), so this takes a few seconds even for a long video.
enum AudioMixdown {
    /// Returns true when the file now has a single audio track (or nothing had to change).
    static func mergeAudioTracks(of url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        guard let videoTrack = try? await asset.loadTracks(withMediaType: .video).first,
              let audioTracks = try? await asset.loadTracks(withMediaType: .audio) else { return false }
        guard audioTracks.count > 1 else { return true }

        // Tracks that really hold sound (an empty one would make the mix fail)
        var tracks: [AVAssetTrack] = []
        for track in audioTracks {
            if let range = try? await track.load(.timeRange), range.duration.seconds > 0.05 {
                tracks.append(track)
            }
        }
        guard !tracks.isEmpty else { return false }

        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".parker-mix-\(UUID().uuidString).mp4")
        guard let reader = try? AVAssetReader(asset: asset),
              let writer = try? AVAssetWriter(url: tmp, fileType: .mp4) else { return false }

        let videoOut = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
        videoOut.alwaysCopiesSampleData = false
        let audioOut = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        guard reader.canAdd(videoOut), reader.canAdd(audioOut) else { return false }
        reader.add(videoOut)
        reader.add(audioOut)

        let hint = try? await videoTrack.load(.formatDescriptions).first
        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: hint)
        if let transform = try? await videoTrack.load(.preferredTransform) {
            videoIn.transform = transform
        }
        let audioIn = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 160000,
        ])
        guard writer.canAdd(videoIn), writer.canAdd(audioIn) else { return false }
        writer.add(videoIn)
        writer.add(audioIn)

        guard reader.startReading(), writer.startWriting() else {
            try? FileManager.default.removeItem(at: tmp)
            return false
        }
        writer.startSession(atSourceTime: .zero)

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let group = DispatchGroup()
            pump(videoOut, into: videoIn, queue: DispatchQueue(label: "parker.mix.video"), group: group)
            pump(audioOut, into: audioIn, queue: DispatchQueue(label: "parker.mix.audio"), group: group)
            group.notify(queue: .global()) { continuation.resume() }
        }

        guard reader.status == .completed else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: tmp)
            return false
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: tmp)
            return false
        }
        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
            return true
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            return false
        }
    }

    private static func pump(_ output: AVAssetReaderOutput, into input: AVAssetWriterInput,
                             queue: DispatchQueue, group: DispatchGroup) {
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
            }
        }
    }
}
