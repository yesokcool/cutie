import Foundation

/// Homebrew's ffmpeg, for every format AVFoundation can't write (MP3, OGG,
/// Opus, WMA, MKV, WebM, AVI, WMV) or read (MKV, WebM, AVI…). Never bundled.
nonisolated enum FFmpeg {
    /// Encoder arguments for each output format.
    static func codecArguments(for format: Format) -> [String] {
        switch format {
        case .mp4, .mov:
            ["-c:v", "libx264", "-preset", "medium", "-crf", "20", "-pix_fmt", "yuv420p",
             "-c:a", "aac", "-b:a", "192k"] + (format == .mp4 ? ["-movflags", "+faststart"] : [])
        case .mkv:
            ["-c:v", "libx264", "-preset", "medium", "-crf", "20", "-c:a", "aac", "-b:a", "192k"]
        case .webm:
            ["-c:v", "libvpx-vp9", "-crf", "32", "-b:v", "0", "-row-mt", "1", "-deadline", "good",
             "-cpu-used", "4", "-c:a", "libopus", "-b:a", "128k"]
        case .avi:
            ["-c:v", "mpeg4", "-q:v", "3", "-c:a", "libmp3lame", "-q:a", "3"]
        case .wmv:
            ["-c:v", "wmv2", "-q:v", "3", "-c:a", "wmav2", "-b:a", "192k"]
        case .gif:
            ["-vf", "fps=12,scale='min(640,iw)':-2:flags=lanczos,split[a][b];[a]palettegen[p];[b][p]paletteuse",
             "-loop", "0"]
        case .mp3: ["-vn", "-c:a", "libmp3lame", "-q:a", "2"]
        case .m4a: ["-vn", "-c:a", "aac", "-b:a", "192k"]
        case .wav: ["-vn", "-c:a", "pcm_s16le"]
        case .aiff: ["-vn", "-c:a", "pcm_s16be"]
        case .flac: ["-vn", "-c:a", "flac"]
        case .ogg, .opus: ["-vn", "-c:a", "libopus", "-b:a", "160k"]
        case .wma: ["-vn", "-c:a", "wmav2", "-b:a", "192k"]
        default: []
        }
    }

    /// Runs one ffmpeg command, reporting progress from its `-progress` stream.
    static func run(input: URL, output: URL, arguments: [String], context: JobContext, inputOptions: [String] = []) async throws {
        guard let ffmpeg = context.toolbox.ffmpeg else {
            throw CutieError("This needs ffmpeg (brew install ffmpeg).")
        }
        let duration = await duration(of: input, context: context)
        let progress = context.progress
        let args = ["-hide_banner", "-nostdin", "-loglevel", "error", "-nostats", "-progress", "pipe:1", "-y"]
            + inputOptions + ["-i", input.path] + arguments + [output.path]
        try await Shell.run(ffmpeg, args) { line in
            guard let duration, duration > 0, line.hasPrefix("out_time_us=") || line.hasPrefix("out_time_ms="),
                  let micros = Double(line.split(separator: "=").last ?? "") else { return }
            progress(min(1, micros / 1_000_000 / duration))
        }
    }

    static func convert(_ input: URL, to format: Format, at output: URL, context: JobContext) async throws {
        try await run(input: input, output: output, arguments: codecArguments(for: format), context: context)
    }

    /// Seconds, from ffprobe.
    static func duration(of input: URL, context: JobContext) async -> Double? {
        guard let ffprobe = context.toolbox.ffprobe else { return nil }
        let text = try? await Shell.run(ffprobe, ["-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", input.path])
        return text.flatMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    /// Whether a file has an audio stream (so "MP3" on a silent video fails kindly).
    static func hasAudio(_ input: URL, context: JobContext) async -> Bool {
        guard let ffprobe = context.toolbox.ffprobe else { return true }
        let text = try? await Shell.run(ffprobe, ["-v", "error", "-select_streams", "a", "-show_entries", "stream=index", "-of", "csv=p=0", input.path])
        return !(text ?? "x").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
