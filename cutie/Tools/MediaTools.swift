import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// The video and audio half of the Tools wheel.
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

    static func compressVideo(_ input: URL, to output: URL, context: JobContext) async throws {
        if context.toolbox.ffmpeg != nil {
            try await FFmpeg.run(input: input, output: output, arguments: [
                "-c:v", "libx264", "-preset", "medium", "-crf", "28", "-pix_fmt", "yuv420p",
                "-c:a", "aac", "-b:a", "128k", "-movflags", "+faststart",
            ], context: context)
        } else {
            try await MediaConverter.export(input, to: output, fileType: .mp4, preset: AVAssetExportPresetHEVC1920x1080, context: context)
        }
    }

    static func mute(_ input: URL, to output: URL, context: JobContext) async throws {
        guard isNative(input) else {
            return try await FFmpeg.run(input: input, output: output, arguments: ["-c:v", "copy", "-an"], context: context)
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

    static func extractAudio(_ input: URL, to output: URL, context: JobContext) async throws {
        if isNative(input) {
            try await MediaConverter.export(input, to: output, fileType: .m4a, preset: AVAssetExportPresetAppleM4A, context: context)
        } else {
            try await FFmpeg.convert(input, to: .m4a, at: output, context: context)
        }
    }

    /// 90° clockwise. Natively it only changes the track's rotation flag, so the video isn't re-encoded.
    static func rotate(_ input: URL, to output: URL, context: JobContext) async throws {
        guard isNative(input) else {
            return try await FFmpeg.run(input: input, output: output, arguments: ["-vf", "transpose=1"] + FFmpeg.codecArguments(for: .mp4), context: context)
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
        if isNative(input) {
            try await MediaConverter.export(input, to: output, fileType: .mp4, preset: AVAssetExportPreset1280x720, context: context)
        } else {
            try await FFmpeg.run(input: input, output: output, arguments: ["-vf", "scale=-2:'min(720,ih)'"] + FFmpeg.codecArguments(for: .mp4), context: context)
        }
    }

    /// The frame in the middle of the video, as a PNG.
    static func snapshot(_ input: URL, to output: URL, context: JobContext) async throws {
        guard isNative(input) else {
            let middle = (await FFmpeg.duration(of: input, context: context) ?? 0) / 2
            return try await FFmpeg.run(input: input, output: output, arguments: ["-frames:v", "1"], context: context,
                                        inputOptions: ["-ss", String(format: "%.2f", middle)])
        }
        let asset = AVURLAsset(url: input)
        let duration = try await asset.load(.duration)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let (image, _) = try await generator.image(at: CMTime(seconds: duration.seconds / 2, preferredTimescale: 600))
        try ImageConverter.write(image, as: .png, to: output, quality: 1)
    }

    static func compressAudio(_ input: URL, to output: URL, context: JobContext) async throws {
        if context.toolbox.ffmpeg != nil {
            try await FFmpeg.run(input: input, output: output, arguments: ["-vn", "-c:a", "aac", "-b:a", "128k"], context: context)
        } else {
            try await MediaConverter.export(input, to: output, fileType: .m4a, preset: AVAssetExportPresetAppleM4A, context: context)
        }
    }

    /// Loudness evened out to −16 LUFS (podcast level), same format as the input.
    static func normalize(_ input: URL, to output: URL, context: JobContext) async throws {
        let format = Format.matching(extension: FileKind.fileExtension(of: input)) ?? .m4a
        try await FFmpeg.run(input: input, output: output,
                             arguments: ["-af", "loudnorm=I=-16:TP=-1.5:LRA=11"] + FFmpeg.codecArguments(for: format),
                             context: context)
    }

    /// One after the other, in the order dropped, as M4A.
    static func mergeAudio(_ inputs: [URL], to output: URL, context: JobContext) async throws {
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw CutieError("Couldn't merge these.")
        }
        var cursor = CMTime.zero
        for input in inputs {
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
}
