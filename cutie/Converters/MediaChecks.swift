import AVFoundation

/// Keeps a broken media file from turning into a "successful" short result:
/// ffmpeg and AVFoundation both stop quietly at damage, so a cut-off film
/// could come out as a few seconds of video with no error.
nonisolated enum MediaChecks {
    /// Containers made of ISO boxes (MP4, MOV, M4A…), checked by their structure.
    static let isoExtensions: Set<String> = ["mp4", "m4v", "mov", "m4a", "m4b", "3gp"]

    /// Refuses a file that was cut off (an interrupted download or copy).
    static func checkComplete(_ input: URL) throws {
        guard isoExtensions.contains(FileKind.fileExtension(of: input)),
              let data = try? Data(contentsOf: input, options: .alwaysMapped), data.count >= 8 else { return }
        if !FileIntegrity.isoBoxesAreComplete(data) {
            throw CutieError("This file is damaged or incomplete (it ends early).")
        }
    }

    /// Seconds: ffprobe when it's installed, AVFoundation otherwise.
    static func duration(of url: URL, context: JobContext) async -> Double? {
        if let seconds = await FFmpeg.duration(of: url, context: context) { return seconds }
        guard let duration = try? await AVURLAsset(url: url).load(.duration), duration.isNumeric else { return nil }
        return duration.seconds
    }

    /// Fails when the result is clearly shorter than the original.
    static func checkLength(of output: URL, against input: URL, expected: Double? = nil, context: JobContext) async throws {
        var expected = expected
        if expected == nil { expected = await duration(of: input, context: context) }
        guard let expected, expected > 1, let actual = await duration(of: output, context: context) else { return }
        if actual + max(1, expected * 0.03) < expected {
            throw CutieError("The result is \(clock(actual)) long instead of \(clock(expected)), so the original is probably damaged.")
        }
    }

    private static func clock(_ seconds: Double) -> String {
        Duration.seconds(seconds.rounded()).formatted(.time(pattern: seconds >= 3600 ? .hourMinuteSecond : .minuteSecond))
    }
}
