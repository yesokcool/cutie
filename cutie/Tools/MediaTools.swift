import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// The video and audio half of the Tools wheel. Every tool keeps what it
/// isn't about: other tracks, subtitles, chapters, cover art, capture date
/// and location, HDR, sample rate and bit depth.
nonisolated enum MediaTools {
    static func isNative(_ input: URL) -> Bool {
        let ext = FileKind.fileExtension(of: input)
        return Catalog.nativeVideo.contains(ext) || Catalog.nativeAudio.contains(ext)
    }

    /// The container a tool writes: the input's own when AVFoundation writes it.
    static func fileType(for input: URL) -> (AVFileType, String) {
        switch FileKind.fileExtension(of: input) {
        case "mov": (.mov, "mov")
        case "m4v": (.m4v, "m4v")
        case "m4a": (.m4a, "m4a")
        default: (.mp4, "mp4")
        }
    }

    /// Smaller video: H.264 (HDR: 10-bit HEVC) at a higher CRF. Lossy audio
    /// is copied as is (re-encoding it would only lose quality); subtitles,
    /// chapters and metadata stay.
    static func compressVideo(_ input: URL, to output: URL, context: JobContext) async throws {
        try MediaChecks.checkComplete(input)
        if context.toolbox.ffmpeg != nil {
            try await FFmpeg.convert(input, to: .mp4, at: output, context: context,
                                     options: FFmpeg.Options(reencodeVideo: true, compact: true))
        } else {
            try await MediaConverter.export(input, to: output, fileType: .mp4, preset: AVAssetExportPresetHEVC1920x1080, context: context)
            try await MediaChecks.checkLength(of: output, against: input, context: context)
        }
    }

    static func mute(_ input: URL, to output: URL, context: JobContext) async throws {
        try MediaChecks.checkComplete(input)
        guard isNative(input) else {
            // Everything but the sound, copied as is; as long as the picture, which the sound may outlast.
            let probe = try await FFmpeg.probe(input, context: context)
            try await FFmpeg.run(input: input, output: output, arguments: [
                "-map", "0", "-map", "-0:a", "-c", "copy", "-map_metadata", "0", "-map_chapters", "0",
            ], context: context)
            let expected = probe.isKnown ? probe.expectedDuration(audioOnly: false, dropAudio: true) : nil
            return try await MediaChecks.checkLength(of: output, against: input, expected: expected, context: context)
        }
        let asset = AVURLAsset(url: input)
        let composition = AVMutableComposition()
        let duration = try await asset.load(.duration)
        for track in try await asset.loadTracks(withMediaType: .video) {
            guard let copy = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            try copy.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: track, at: .zero)
            copy.preferredTransform = try await track.load(.preferredTransform)
        }
        let (type, _) = fileType(for: input)
        try await MediaConverter.export(input, to: output, fileType: type, preferPassthrough: true, asset: composition, context: context)
    }

    /// The format Get Audio writes: the sound's own codec copied as is when a
    /// format holds it (AAC → M4A, MP3 → MP3, FLAC → FLAC, PCM → WAV…), M4A otherwise.
    static func audioFormat(for input: URL, context: JobContext) async -> Format {
        guard context.toolbox.ffmpeg != nil, let audio = try? await FFmpeg.probe(input, context: context).mainAudio else { return .m4a }
        switch audio.codec {
        case "mp3": return .mp3
        case "flac": return .flac
        case "opus": return .opus
        case "vorbis": return .ogg
        case let codec where codec.hasPrefix("pcm_"): return .wav
        default: return .m4a
        }
    }

    static func extractAudio(_ input: URL, as format: Format = .m4a, to output: URL, context: JobContext) async throws {
        try MediaChecks.checkComplete(input)
        if context.toolbox.ffmpeg != nil {
            let probe = try await FFmpeg.probe(input, context: context)
            guard !probe.isKnown || !probe.audio.isEmpty else { throw CutieError("This file has no sound.") }
            try await FFmpeg.convert(input, to: format, at: output, context: context, probe: probe)
        } else {
            try await MediaConverter.exportAudio(input, to: output, context: context)
            let expected = await MediaChecks.trackDuration(of: input, type: .audio)
            try await MediaChecks.checkLength(of: output, against: input, expected: expected, context: context)
        }
    }

    /// 90° clockwise. It only changes the video's rotation flag, so nothing is
    /// re-encoded; a video codec MP4 can't hold is re-encoded turned.
    static func rotate(_ input: URL, to output: URL, context: JobContext) async throws {
        try MediaChecks.checkComplete(input)
        guard isNative(input) else {
            let probe = try await FFmpeg.probe(input, context: context)
            let copyable = probe.video.first.map { FFmpeg.copiesVideo($0.codec, into: .mp4) } ?? false
            let options = copyable ? FFmpeg.Options(addRotation: -90) : FFmpeg.Options(videoFilter: "transpose=1")
            return try await FFmpeg.convert(input, to: .mp4, at: output, context: context, probe: probe, options: options)
        }
        let asset = AVURLAsset(url: input)
        let composition = AVMutableComposition()
        let duration = try await asset.load(.duration)
        let range = CMTimeRange(start: .zero, duration: duration)
        for track in try await asset.loadTracks(withMediaType: .audio) {
            let copy = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            try copy?.insertTimeRange(range, of: track, at: .zero)
        }
        for track in try await asset.loadTracks(withMediaType: .video) {
            guard let copy = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            try copy.insertTimeRange(range, of: track, at: .zero)
            let (transform, size) = try await track.load(.preferredTransform, .naturalSize)
            copy.preferredTransform = transform.concatenating(rotationClockwise(renderedHeight: size.applying(transform).height))
        }
        let (type, _) = fileType(for: input)
        try await MediaConverter.export(input, to: output, fileType: type, preferPassthrough: true, asset: composition, context: context)
    }

    /// (x, y) → (h − y, x) in video coordinates: a quarter turn clockwise that stays on canvas.
    static func rotationClockwise(renderedHeight: CGFloat) -> CGAffineTransform {
        CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: abs(renderedHeight), ty: 0)
    }

    static func resize720(_ input: URL, to output: URL, context: JobContext) async throws {
        try MediaChecks.checkComplete(input)
        if isNative(input) {
            try await MediaConverter.export(input, to: output, fileType: .mp4, preset: AVAssetExportPreset1280x720, context: context)
            try await MediaChecks.checkLength(of: output, against: input, context: context)
        } else {
            try await FFmpeg.convert(input, to: .mp4, at: output, context: context,
                                     options: FFmpeg.Options(reencodeVideo: true, videoFilter: "scale=-2:'min(720,ih)'"))
        }
    }

    /// The frame in the middle of the video, as a PNG (HDR tone-mapped to SDR).
    static func snapshot(_ input: URL, to output: URL, context: JobContext, scratch: Scratch) async throws {
        try MediaChecks.checkComplete(input)
        var source = input
        if !isNative(input) {
            let probe = try await FFmpeg.probe(input, context: context)
            if probe.isHDR {
                source = try await MediaConverter.nativeCopy(of: input, probe: probe, context: context, scratch: scratch)
            } else {
                let middle = (probe.duration ?? 0) / 2
                return try await FFmpeg.run(input: input, output: output, arguments: ["-map", "0:v:0", "-frames:v", "1"], context: context,
                                            inputOptions: ["-ss", String(format: "%.2f", middle)])
            }
        }
        let asset = AVURLAsset(url: source)
        let duration = try await asset.load(.duration)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.dynamicRangePolicy = .forceSDR
        let (image, _) = try await generator.image(at: CMTime(seconds: duration.seconds / 2, preferredTimescale: 600))
        try ImageConverter.write(image, as: .png, to: output, quality: 1)
    }

    /// Smaller audio as AAC (64 kbps a channel), cover art and tags kept.
    static func compressAudio(_ input: URL, to output: URL, context: JobContext) async throws {
        try MediaChecks.checkComplete(input)
        if context.toolbox.ffmpeg != nil {
            try await FFmpeg.convert(input, to: .m4a, at: output, context: context,
                                     options: FFmpeg.Options(compact: true, reencodeAudio: true))
        } else {
            try await MediaConverter.export(input, to: output, fileType: .m4a, preset: AVAssetExportPresetAppleM4A, context: context)
            try await MediaChecks.checkLength(of: output, against: input, context: context)
        }
    }

    /// Loudness evened out to −16 LUFS (podcast level), same format, codec,
    /// sample rate and bit depth as the input (Apple Lossless stays lossless).
    /// Two passes: the first measures, the second applies one exact, constant
    /// gain (no pumping).
    static func normalize(_ input: URL, to output: URL, context: JobContext) async throws {
        try MediaChecks.checkComplete(input)
        let probe = try await FFmpeg.probe(input, context: context)
        if probe.isKnown, probe.mainAudio == nil { throw CutieError("This file has no sound.") }
        let track = probe.mainAudio.map { "0:\($0.index)" } ?? "0:a:0"
        let target = "I=-16:TP=-1.5:LRA=11"
        var filter = "loudnorm=\(target)"
        let log = try await FFmpeg.runCapturingLog(["-hide_banner", "-nostdin", "-i", input.path, "-map", track,
                                                    "-af", "loudnorm=\(target):print_format=json", "-f", "null", "-"], context: context)
        if let measured = loudnessMeasurements(in: log) {
            filter += ":measured_I=\(measured["input_i"]!):measured_TP=\(measured["input_tp"]!)"
                + ":measured_LRA=\(measured["input_lra"]!):measured_thresh=\(measured["input_thresh"]!)"
                + ":offset=\(measured["target_offset"]!):linear=true"
        }
        let format = Format.matching(extension: FileKind.fileExtension(of: input)) ?? .m4a
        // loudnorm works at 192 kHz inside; the plan asks for the source's own rate back.
        let options = FFmpeg.Options(reencodeAudio: true, audioFilter: filter, keepCodec: true)
        let arguments = FFmpeg.arguments(for: format, probe: probe, options: options, toolbox: context.toolbox)
        try await FFmpeg.run(input: input, output: output, arguments: arguments, context: context)
        try await MediaChecks.checkLength(of: output, against: input, expected: probe.mainAudio?.duration ?? probe.duration, context: context)
    }

    /// The numbers loudnorm prints after its measuring pass.
    static func loudnessMeasurements(in log: String) -> [String: String]? {
        guard let start = log.range(of: "{", options: .backwards),
              let end = log.range(of: "}", options: .backwards), start.lowerBound < end.upperBound,
              let object = try? JSONSerialization.jsonObject(with: Data(log[start.lowerBound..<end.upperBound].utf8)) as? [String: String]
        else { return nil }
        let keys = ["input_i", "input_tp", "input_lra", "input_thresh", "target_offset"]
        guard keys.allSatisfy({ object[$0].flatMap(Double.init)?.isFinite == true }) else { return nil }
        return object
    }

    /// One after the other, in the order dropped, as M4A.
    static func mergeAudio(_ inputs: [URL], to output: URL, context: JobContext) async throws {
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw CutieError("Couldn't merge these.")
        }
        var cursor = CMTime.zero
        for input in inputs {
            try MediaChecks.checkComplete(input)
            let asset = AVURLAsset(url: input)
            let duration = try await asset.load(.duration)
            guard let source = try await asset.loadTracks(withMediaType: .audio).first else { continue }
            try track.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: source, at: cursor)
            cursor = cursor + duration
        }
        try await MediaConverter.export(inputs[0], to: output, fileType: .m4a, preset: AVAssetExportPresetAppleM4A, asset: composition, context: context)
    }

    /// Exports `range` of a file without re-encoding (used by the Trim window).
    static func trim(_ input: URL, range: CMTimeRange, to output: URL, context: JobContext) async throws {
        let (type, _) = fileType(for: input)
        try await MediaConverter.export(input, to: output, fileType: type, preferPassthrough: true, timeRange: range, context: context)
    }

    /// Each text subtitle track as an SRT named the way players look for them
    /// ("film.eng.srt"): one file, or a folder when there are several.
    static func extractSubtitles(_ input: URL, in work: URL, context: JobContext) async throws -> URL {
        try MediaChecks.checkComplete(input)
        let probe = try await FFmpeg.probe(input, context: context)
        guard probe.isKnown else { throw CutieError("Getting subtitles needs ffprobe, which comes with ffmpeg (brew install ffmpeg).") }
        let tracks = probe.subtitles.filter(\.isTextSubtitle)
        guard !tracks.isEmpty else {
            throw CutieError(probe.subtitles.isEmpty
                ? "This video has no subtitles."
                : "These subtitles are pictures (from a DVD or Blu-ray), so they can't become text.")
        }
        let base = Output.baseName(of: input)
        let folder = tracks.count == 1 ? work : work.appending(path: "\(base) (Subtitles)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var used = Set<String>()
        var written: [URL] = []
        for (number, track) in tracks.enumerated() {
            let language = track.language.flatMap { $0 == "und" ? nil : $0 }
            var name = language.map { "\(base).\($0)" } ?? (tracks.count == 1 ? base : "\(base) \(number + 1)")
            if used.contains(name) { name += " \(number + 1)" }
            used.insert(name)
            let file = folder.appending(path: "\(name).srt")
            try await FFmpeg.run(input: input, output: file, arguments: ["-map", "0:\(track.index)", "-c:s", "srt"], context: context)
            written.append(file)
            context.progress(Double(number + 1) / Double(tracks.count))
        }
        return tracks.count == 1 ? written[0] : folder
    }
}
