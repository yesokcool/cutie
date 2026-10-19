import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// Audio and video through AVFoundation when it can, ffmpeg otherwise.
/// Native paths are tried first because they're hardware-accelerated and can
/// often pass the streams through untouched (MOV → MP4 in a second).
nonisolated enum MediaConverter {
    static let audioFormats: Set<Format> = [.mp3, .m4a, .wav, .flac, .aiff, .ogg, .opus, .wma]

    static func convert(_ input: URL, to format: Format, at output: URL, context: JobContext, scratch: Scratch) async throws {
        try MediaChecks.checkComplete(input)
        let ext = FileKind.fileExtension(of: input)
        let kind = FileKind.of(input)
        let nativeVideo = kind == .video && Catalog.nativeVideo.contains(ext)
        let nativeAudio = kind == .audio && Catalog.nativeAudio.contains(ext)
        let hasFFmpeg = context.toolbox.ffmpeg != nil
        let probe = hasFFmpeg ? try await FFmpeg.probe(input, context: context) : FFmpeg.Probe()

        if audioFormats.contains(format), hasFFmpeg, probe.audio.isEmpty {
            throw CutieError("This file has no sound.")
        }

        // (A `where` on a multi-pattern `case` only guards the last pattern, so this is an if chain.)
        if (format == .mp4 || format == .mov) && nativeVideo {
            try await export(input, to: output, fileType: format == .mp4 ? .mp4 : .mov, preferPassthrough: true, context: context)
        } else if format == .m4a && !hasFFmpeg && (nativeVideo || nativeAudio) {
            try await exportAudio(input, to: output, context: context)
        } else if [.wav, .aiff, .flac].contains(format) && nativeAudio && !hasFFmpeg {
            try writeAudioFile(input, as: format, to: output, progress: context.progress)
        } else if format == .gif && nativeVideo && !hasFFmpeg {
            return try await makeGIF(input, to: output, context: context)
        } else {
            // GIF, AVI and WMV can't hold HDR: tone-map to SDR first instead of
            // writing washed-out (or PQ-tagged 8-bit) video.
            if probe.isHDR, [.gif, .avi, .wmv].contains(format) {
                let sdr = try await sdrCopy(of: input, probe: probe, context: context, scratch: scratch)
                return try await FFmpeg.convert(sdr, to: format, at: output, context: context)
            }
            return try await FFmpeg.convert(input, to: format, at: output, context: context, probe: probe)
        }
        try await MediaChecks.checkLength(of: output, against: input, context: context)
    }

    // MARK: - AVFoundation

    /// Exports with an AVAssetExportSession, passing streams through untouched
    /// when the container allows it. The source's metadata (capture date,
    /// location, camera) is written to the result.
    static func export(
        _ input: URL, to output: URL, fileType: AVFileType,
        preset: String = AVAssetExportPresetHighestQuality, preferPassthrough: Bool = false,
        asset: AVAsset? = nil, timeRange: CMTimeRange? = nil, videoComposition: AVVideoComposition? = nil,
        context: JobContext
    ) async throws {
        let source = AVURLAsset(url: input)
        let asset = asset ?? source
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
        if let metadata = try? await source.load(.metadata), !metadata.isEmpty {
            session.metadata = metadata
        }
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

    /// ffmpeg can't write the QuickTime keys Photos and Finder read (capture
    /// place and date) in a way AVFoundation understands. For a source that
    /// has them, the result is re-saved by AVFoundation with the source's
    /// metadata: a passthrough copy, nothing re-encoded. Skipped when the
    /// result has chapters, which that copy would drop.
    static func restoreAppleMetadata(from input: URL, into output: URL, keepsChapters: Bool, context: JobContext) async throws {
        guard !keepsChapters, Catalog.nativeVideo.contains(FileKind.fileExtension(of: input)),
              let metadata = try? await AVURLAsset(url: input).load(.metadata) else { return }
        let places: Set<AVMetadataIdentifier> = [
            .quickTimeMetadataLocationISO6709, .quickTimeMetadataCreationDate, .quickTimeUserDataLocationISO6709,
            .isoUserDataDate, .quickTimeUserDataCreationDate,
        ]
        guard metadata.contains(where: { $0.identifier.map(places.contains) == true }) else { return }
        let resaved = output.deletingLastPathComponent().appending(path: UUID().uuidString + "." + output.pathExtension)
        let session = AVAssetExportSession(asset: AVURLAsset(url: output), presetName: AVAssetExportPresetPassthrough)
        guard let session else { return }
        session.metadata = metadata
        try await session.export(to: resaved, as: output.pathExtension == "mov" ? .mov : .mp4)
        _ = try FileManager.default.replaceItemAt(output, withItemAt: resaved)
    }

    /// The sound as M4A: copied as is when it's already AAC or Apple Lossless, Apple's AAC otherwise.
    static func exportAudio(_ input: URL, to output: URL, context: JobContext) async throws {
        let asset = AVURLAsset(url: input)
        let composition = AVMutableComposition()
        let duration = try await asset.load(.duration)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw CutieError("This file has no sound.") }
        for track in tracks.prefix(1) {
            let copy = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            try copy?.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: track, at: .zero)
        }
        try await export(input, to: output, fileType: .m4a, preset: AVAssetExportPresetAppleM4A, preferPassthrough: true,
                         asset: composition, context: context)
    }

    /// WAV, AIFF or FLAC straight from AVAudioFile, at the source's sample
    /// rate and bit depth (24-bit stays 24-bit, float stays float).
    static func writeAudioFile(_ input: URL, as format: Format, to output: URL, progress: @Sendable (Double) -> Void) throws {
        let source = try AVAudioFile(forReading: input)
        let processing = source.processingFormat
        let (depth, isFloat) = sourceDepth(source.fileFormat)
        var settings: [String: Any] = [
            AVSampleRateKey: processing.sampleRate,
            AVNumberOfChannelsKey: processing.channelCount,
        ]
        switch format {
        case .wav, .aiff:
            settings[AVFormatIDKey] = kAudioFormatLinearPCM
            settings[AVLinearPCMBitDepthKey] = depth
            settings[AVLinearPCMIsFloatKey] = isFloat && format == .wav
            settings[AVLinearPCMIsBigEndianKey] = format == .aiff
            settings[AVLinearPCMIsNonInterleaved] = false
            if isFloat && format == .aiff { settings[AVLinearPCMBitDepthKey] = 24 }
        case .flac:
            settings[AVFormatIDKey] = kAudioFormatFLAC
            settings[AVEncoderBitDepthHintKey] = min(depth, 24)
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

    /// Bits per sample of the stored audio: PCM says so directly, Apple
    /// Lossless and FLAC in their format flags; lossy audio counts as 16-bit.
    static func sourceDepth(_ format: AVAudioFormat) -> (bits: Int, isFloat: Bool) {
        let description = format.streamDescription.pointee
        switch description.mFormatID {
        case kAudioFormatLinearPCM:
            let isFloat = description.mFormatFlags & kAudioFormatFlagIsFloat != 0
            return (max(16, Int(description.mBitsPerChannel)), isFloat)
        case kAudioFormatFLAC, kAudioFormatAppleLossless:
            switch description.mFormatFlags {
            case kAppleLosslessFormatFlag_20BitSourceData, kAppleLosslessFormatFlag_24BitSourceData: return (24, false)
            case kAppleLosslessFormatFlag_32BitSourceData: return (32, false)
            default: return (16, false)
            }
        default:
            return (16, false)
        }
    }

    /// A looping GIF (12 fps, up to 480 px wide) without ffmpeg. HDR is tone-mapped to SDR.
    static func makeGIF(_ input: URL, to output: URL, context: JobContext) async throws {
        let asset = AVURLAsset(url: input)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw CutieError("This video has no frames.") }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.dynamicRangePolicy = .forceSDR
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

    // MARK: - HDR

    /// A MOV that AVFoundation can open: the file itself when it already is
    /// one, otherwise its first video and audio copied (not re-encoded) into a MOV.
    static func nativeCopy(of input: URL, probe: FFmpeg.Probe, context: JobContext, scratch: Scratch) async throws -> URL {
        if Catalog.nativeVideo.contains(FileKind.fileExtension(of: input)) { return input }
        guard let video = probe.video.first, ["hevc", "h264"].contains(video.codec) else {
            throw CutieError("This HDR video can't be turned into SDR here (it needs HEVC or H.264 video).")
        }
        let copy = scratch.file(UUID().uuidString + ".mov")
        var arguments = ["-map", "0:v:0", "-map", "0:a:0?", "-c", "copy", "-map_metadata", "0"]
        if video.codec == "hevc" { arguments += ["-tag:v", "hvc1"] }
        try await FFmpeg.run(input: input, output: copy, arguments: arguments, context: context)
        return copy
    }

    /// An SDR copy of an HDR video, for formats that can't show HDR. AVFoundation
    /// tone-maps when a video composition asks for Rec. 709 colour.
    static func sdrCopy(of input: URL, probe: FFmpeg.Probe, context: JobContext, scratch: Scratch) async throws -> URL {
        let native = try await nativeCopy(of: input, probe: probe, context: context, scratch: scratch)
        let asset = AVURLAsset(url: native)
        var configuration = try await AVVideoComposition.Configuration(for: asset)
        configuration.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        configuration.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        configuration.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        let sdr = scratch.file(UUID().uuidString + ".mov")
        try await export(native, to: sdr, fileType: .mov, preset: AVAssetExportPresetAppleProRes422LPCM, asset: asset,
                         videoComposition: AVVideoComposition(configuration: configuration), context: context)
        return sdr
    }
}
