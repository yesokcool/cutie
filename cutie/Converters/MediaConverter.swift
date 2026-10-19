import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// Audio and video through AVFoundation when it can, ffmpeg otherwise.
/// Native paths are tried first because they're hardware-accelerated and can
/// often pass the streams through untouched (MOV → MP4 in a second).
nonisolated enum MediaConverter {
    static func convert(_ input: URL, to format: Format, at output: URL, context: JobContext, scratch: Scratch) async throws {
        let ext = FileKind.fileExtension(of: input)
        let kind = FileKind.of(input)
        let nativeVideo = kind == .video && Catalog.nativeVideo.contains(ext)
        let nativeAudio = kind == .audio && Catalog.nativeAudio.contains(ext)
        let hasFFmpeg = context.toolbox.ffmpeg != nil

        if [.mp3, .m4a, .wav, .flac, .aiff, .ogg, .opus, .wma].contains(format), hasFFmpeg,
           !(await FFmpeg.hasAudio(input, context: context)) {
            throw CutieError("This file has no sound.")
        }

        // (A `where` on a multi-pattern `case` only guards the last pattern, so this is an if chain.)
        if (format == .mp4 || format == .mov) && nativeVideo {
            try await export(input, to: output, fileType: format == .mp4 ? .mp4 : .mov, preferPassthrough: true, context: context)
        } else if format == .m4a && (nativeVideo || (nativeAudio && !hasFFmpeg)) {
            try await export(input, to: output, fileType: .m4a, preset: AVAssetExportPresetAppleM4A, context: context)
        } else if [.wav, .aiff, .flac].contains(format) && nativeAudio && !hasFFmpeg {
            try writeAudioFile(input, as: format, to: output, progress: context.progress)
        } else if format == .gif && nativeVideo && !hasFFmpeg {
            try await makeGIF(input, to: output, context: context)
        } else {
            try await FFmpeg.convert(input, to: format, at: output, context: context)
        }
    }

    // MARK: - AVFoundation

    /// Exports with an AVAssetExportSession, passing streams through untouched when the container allows it.
    static func export(
        _ input: URL, to output: URL, fileType: AVFileType,
        preset: String = AVAssetExportPresetHighestQuality, preferPassthrough: Bool = false,
        asset: AVAsset? = nil, timeRange: CMTimeRange? = nil, videoComposition: AVVideoComposition? = nil,
        context: JobContext
    ) async throws {
        let asset = asset ?? AVURLAsset(url: input)
        var presetName = preset
        if preferPassthrough,
           await AVAssetExportSession.compatibility(ofExportPreset: AVAssetExportPresetPassthrough, with: asset, outputFileType: fileType) {
            presetName = AVAssetExportPresetPassthrough
        }
        guard let session = AVAssetExportSession(asset: asset, presetName: presetName) else {
            throw CutieError("Couldn't start the export.")
        }
        if let timeRange { session.timeRange = timeRange }
        if let videoComposition { session.videoComposition = videoComposition }
        nonisolated(unsafe) let watched = session
        let progress = context.progress
        let watcher = Task {
            for await state in watched.states(updateInterval: 0.25) {
                if case .exporting(let report) = state { progress(report.fractionCompleted) }
            }
        }
        defer { watcher.cancel() }
        try await session.export(to: output, as: fileType)
    }

    /// WAV, AIFF or FLAC straight from AVAudioFile.
    static func writeAudioFile(_ input: URL, as format: Format, to output: URL, progress: @Sendable (Double) -> Void) throws {
        let source = try AVAudioFile(forReading: input)
        let processing = source.processingFormat
        var settings: [String: Any] = [
            AVSampleRateKey: processing.sampleRate,
            AVNumberOfChannelsKey: processing.channelCount,
        ]
        switch format {
        case .wav, .aiff:
            settings[AVFormatIDKey] = kAudioFormatLinearPCM
            settings[AVLinearPCMBitDepthKey] = 16
            settings[AVLinearPCMIsFloatKey] = false
            settings[AVLinearPCMIsBigEndianKey] = format == .aiff
            settings[AVLinearPCMIsNonInterleaved] = false
        case .flac:
            settings[AVFormatIDKey] = kAudioFormatFLAC
        default:
            throw CutieError("Can't write \(format.title) without ffmpeg.")
        }
        let destination = try AVAudioFile(forWriting: output, settings: settings,
                                          commonFormat: processing.commonFormat, interleaved: processing.isInterleaved)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: processing, frameCapacity: 32_768) else {
            throw CutieError("Couldn't read the audio.")
        }
        let length = max(Double(source.length), 1)
        while source.framePosition < source.length {
            try source.read(into: buffer)
            if buffer.frameLength == 0 { break }
            try destination.write(from: buffer)
            progress(Double(source.framePosition) / length)
        }
    }

    /// A looping GIF (12 fps, up to 480 px wide) without ffmpeg.
    static func makeGIF(_ input: URL, to output: URL, context: JobContext) async throws {
        let asset = AVURLAsset(url: input)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw CutieError("This video has no frames.") }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 480)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        let fps = 12.0
        let count = max(1, min(Int(duration * fps), 600)) // 50 s at most
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.gif.identifier as CFString, count, nil) else {
            throw CutieError("Couldn't create the GIF.")
        }
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let frameProperties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps]] as CFDictionary
        for index in 0..<count {
            try Task.checkCancellation()
            let time = CMTime(seconds: Double(index) / fps, preferredTimescale: 600)
            let (image, _) = try await generator.image(at: time)
            CGImageDestinationAddImage(destination, image, frameProperties)
            context.progress(Double(index + 1) / Double(count))
        }
        guard CGImageDestinationFinalize(destination) else { throw CutieError("Couldn't write the GIF.") }
    }
}
