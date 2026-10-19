import Foundation
import Synchronization

/// Homebrew's ffmpeg, for every format AVFoundation can't write (MP3, OGG,
/// Opus, WMA, MKV, WebM, AVI, WMV) or read (MKV, WebM, AVI…). Never bundled.
///
/// Every job starts with ffprobe. Each stream the target container can hold
/// as it is gets copied untouched (MKV H.264/AAC → MP4 is a remux, not a
/// re-encode); only what doesn't fit is re-encoded. All audio tracks,
/// subtitles, chapters, cover art and tags come along; HDR stays HDR.
nonisolated enum FFmpeg {
    // MARK: - Probing

    struct Stream: Sendable, Equatable {
        var index: Int
        /// "video", "audio", "subtitle", "attachment" or "data".
        var type: String
        var codec: String
        var pixelFormat: String?
        var colorPrimaries: String?
        var colorTransfer: String?
        var colorSpace: String?
        var channels = 0
        var sampleRate = 0
        /// Bits per sample of a lossless or PCM stream (24 for hi-res audio), 0 when unknown.
        var bitDepth = 0
        /// Album art or a poster frame rather than video.
        var isCover = false
        /// Display rotation in degrees, counter-clockwise (ffmpeg's convention).
        var rotation = 0.0
        var isDefault = false
        var language: String?

        /// PQ (HDR10, Dolby Vision base) or HLG.
        var isHDR: Bool { ["smpte2084", "arib-std-b67"].contains(colorTransfer ?? "") }
        /// Subtitles stored as text (as opposed to Blu-ray/DVD pictures).
        var isTextSubtitle: Bool { ["subrip", "srt", "ass", "ssa", "webvtt", "mov_text", "text", "microdvd", "subviewer", "jacosub"].contains(codec) }
        var isLossless: Bool { codec.hasPrefix("pcm_") || ["flac", "alac", "wavpack", "ape", "tta", "truehd", "mlp"].contains(codec) }
    }

    struct Probe: Sendable {
        var streams: [Stream] = []
        var duration: Double?
        var chapters = 0

        var video: [Stream] { streams.filter { $0.type == "video" && !$0.isCover } }
        var audio: [Stream] { streams.filter { $0.type == "audio" } }
        var subtitles: [Stream] { streams.filter { $0.type == "subtitle" } }
        var covers: [Stream] { streams.filter { $0.type == "video" && $0.isCover } }
        var attachments: [Stream] { streams.filter { $0.type == "attachment" } }
        var isHDR: Bool { video.first?.isHDR ?? false }
        /// The audio track a single-track format gets: the default one, else the first.
        var mainAudio: Stream? { audio.first { $0.isDefault } ?? audio.first }
    }

    /// What's inside a media file. Throws when ffprobe can't read it (damaged or not media).
    static func probe(_ input: URL, context: JobContext) async throws -> Probe {
        guard let ffprobe = context.toolbox.ffprobe else { return Probe() }
        let json: String
        do {
            json = try await Shell.run(ffprobe, ["-v", "error", "-print_format", "json",
                                                 "-show_format", "-show_streams", "-show_chapters", input.path])
        } catch {
            throw CutieError("This file is damaged or isn't audio or video ffmpeg can read.")
        }
        guard let root = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return Probe() }
        var probe = Probe()
        probe.duration = number((root["format"] as? [String: Any])?["duration"])
        probe.chapters = (root["chapters"] as? [Any])?.count ?? 0
        for item in root["streams"] as? [[String: Any]] ?? [] {
            let disposition = item["disposition"] as? [String: Any] ?? [:]
            let tags = item["tags"] as? [String: Any] ?? [:]
            var stream = Stream(index: Int(number(item["index"]) ?? 0),
                                type: item["codec_type"] as? String ?? "data",
                                codec: item["codec_name"] as? String ?? "")
            stream.pixelFormat = item["pix_fmt"] as? String
            stream.colorPrimaries = item["color_primaries"] as? String
            stream.colorTransfer = item["color_transfer"] as? String
            stream.colorSpace = item["color_space"] as? String
            stream.channels = Int(number(item["channels"]) ?? 0)
            stream.sampleRate = Int(number(item["sample_rate"]) ?? 0)
            stream.bitDepth = Int(number(item["bits_per_raw_sample"]) ?? number(item["bits_per_sample"]) ?? 0)
            stream.isCover = number(disposition["attached_pic"]) == 1
            stream.isDefault = number(disposition["default"]) == 1
            stream.language = tags["language"] as? String
            for side in item["side_data_list"] as? [[String: Any]] ?? [] {
                if let rotation = number(side["rotation"]) { stream.rotation = rotation }
            }
            probe.streams.append(stream)
        }
        return probe
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    /// Seconds, from ffprobe.
    static func duration(of input: URL, context: JobContext) async -> Double? {
        guard let ffprobe = context.toolbox.ffprobe else { return nil }
        let text = try? await Shell.run(ffprobe, ["-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", input.path])
        return text.flatMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    // MARK: - Planning

    /// How a job treats the streams beyond "keep everything that fits".
    struct Options {
        /// Re-encode the video even when it could be copied (Compress, 720p).
        var reencodeVideo = false
        /// A filter for the re-encoded video ("scale=…", "transpose=1").
        var videoFilter: String?
        /// Smaller files: higher CRF, lower audio bitrate.
        var compact = false
        /// Re-encode audio even when it could be copied (Compress for audio, Even Volume).
        var reencodeAudio = false
        /// A filter for re-encoded audio (Even Volume's loudnorm); the sample rate is kept.
        var audioFilter: String?
        var dropAudio = false
        /// Degrees (counter-clockwise) to add to the display rotation of copied video.
        var addRotation = 0.0
    }

    /// Containers each video codec can be copied into as is.
    static func copiesVideo(_ codec: String, into format: Format) -> Bool {
        switch format {
        case .mp4: ["h264", "hevc", "av1", "mpeg4"].contains(codec)
        case .mov: ["h264", "hevc", "prores", "mpeg4", "mjpeg", "dnxhd"].contains(codec)
        case .mkv: true
        case .webm: ["vp8", "vp9", "av1"].contains(codec)
        case .avi: ["mpeg4", "msmpeg4v3", "mjpeg"].contains(codec)
        default: false
        }
    }

    /// Containers each audio codec can be copied into as is.
    static func copiesAudio(_ codec: String, into format: Format) -> Bool {
        switch format {
        case .mp4: ["aac", "alac", "mp3", "ac3", "eac3"].contains(codec)
        case .mov: ["aac", "alac", "mp3", "ac3", "eac3"].contains(codec) || codec.hasPrefix("pcm_")
        case .m4a: ["aac", "alac"].contains(codec)
        case .mkv: true
        case .webm: ["opus", "vorbis"].contains(codec)
        case .avi: ["mp3", "ac3"].contains(codec) || codec == "pcm_s16le"
        case .mp3: codec == "mp3"
        case .flac: codec == "flac"
        case .opus: codec == "opus"
        case .ogg: ["opus", "vorbis", "flac"].contains(codec)
        default: false
        }
    }

    /// The full ffmpeg argument list (after `-i`) that turns `probe`'s streams into `format`.
    static func arguments(for format: Format, probe: Probe, options: Options = Options(), toolbox: Toolbox) -> [String] {
        if format == .gif { return gifArguments }
        let audioOnly = [.mp3, .m4a, .wav, .flac, .aiff, .ogg, .opus, .wma].contains(format)
        var maps: [String] = []
        var codecs: [String] = []
        var output = 0

        func add(_ stream: Stream, _ arguments: [String]) {
            maps += ["-map", "0:\(stream.index)"]
            codecs += arguments.map { $0.replacingOccurrences(of: "{i}", with: String(output)) }
            output += 1
        }

        if !audioOnly {
            for stream in probe.video {
                if !options.reencodeVideo, options.videoFilter == nil, copiesVideo(stream.codec, into: format) {
                    var copy = ["-c:{i}", "copy"]
                    if stream.codec == "hevc", [.mp4, .mov].contains(format) { copy += ["-tag:{i}", "hvc1"] }
                    add(stream, copy)
                } else {
                    add(stream, videoEncoder(for: format, stream: stream, options: options))
                }
            }
        }

        if !options.dropAudio {
            let tracks = audioOnly ? probe.mainAudio.map { [$0] } ?? [] : probe.audio
            for stream in tracks {
                // Lossy audio is copied even when compressing a video (re-encoding only loses quality);
                // lossless audio becomes AAC then.
                if copiesAudio(stream.codec, into: format), !options.reencodeAudio, !(options.compact && stream.isLossless) {
                    add(stream, ["-c:{i}", "copy"])
                } else {
                    var encoder = audioEncoder(for: format, stream: stream, options: options, toolbox: toolbox)
                    var filters = [options.audioFilter].compactMap { $0 }
                    // Opus takes surround only in its own layouts (5.1 side → 5.1).
                    if [.webm, .ogg, .opus].contains(format), stream.channels > 2 {
                        filters.append("aformat=channel_layouts=7.1|6.1|5.1|5.0|quad|3.0")
                        encoder += ["-mapping_family:{i}", "1"]
                    }
                    if !filters.isEmpty { encoder += ["-filter:{i}", filters.joined(separator: ",")] }
                    if options.audioFilter != nil, stream.sampleRate > 0 {
                        let opus = [.webm, .ogg, .opus].contains(format)
                        encoder += ["-ar:{i}", String(opus ? 48_000 : stream.sampleRate)]
                    }
                    add(stream, encoder)
                }
            }
        }

        if !audioOnly {
            // (A `where` on a multi-pattern `case` only guards the last pattern, so this is an if chain.)
            for stream in probe.subtitles {
                if format == .mkv {
                    add(stream, ["-c:{i}", "copy"])
                } else if (format == .mp4 || format == .mov) && stream.isTextSubtitle {
                    add(stream, ["-c:{i}", "mov_text"])
                } else if format == .webm && stream.isTextSubtitle {
                    add(stream, ["-c:{i}", "webvtt"])
                } // AVI and WMV have no subtitles; picture subtitles can't become text.
            }
        }

        // Album art and poster frames, where the format keeps them.
        if [.mp4, .mov, .m4a, .mkv, .mp3, .flac].contains(format) {
            for stream in probe.covers where ["mjpeg", "png"].contains(stream.codec) {
                add(stream, ["-c:{i}", "copy", "-disposition:{i}", "attached_pic"])
            }
        }
        if format == .mkv {
            for stream in probe.attachments { add(stream, ["-c:{i}", "copy"]) }
        }

        var arguments = maps + codecs + ["-map_metadata", "0", "-map_chapters", "0"]
        switch format {
        case .mp4, .mov, .m4a:
            // Custom tags (QuickTime keys) need use_metadata_tags, but it makes the muxer drop cover art.
            let keepCover = [.m4a, .mp4, .mov].contains(format) && !probe.covers.isEmpty
            arguments += ["-movflags", keepCover ? "+faststart" : "+faststart+use_metadata_tags"]
        case .mp3: arguments += ["-id3v2_version", "3"]
        case .wav: arguments += ["-rf64", "auto"]
        default: break
        }
        return arguments
    }

    /// The GIF palette recipe (two passes in one filter graph), first video stream only.
    static let gifArguments = [
        "-map", "0:v:0", "-vf", "fps=12,scale='min(640,iw)':-2:flags=lanczos,split[a][b];[a]palettegen[p];[b][p]paletteuse",
        "-loop", "0",
    ]

    /// Re-encoding settings per container. HDR becomes 10-bit HEVC (VP9
    /// profile 2 in WebM) with its colour tags; SDR becomes H.264 (VP9 in WebM).
    static func videoEncoder(for format: Format, stream: Stream, options: Options) -> [String] {
        var arguments: [String] = []
        if let filter = options.videoFilter { arguments += ["-filter:{i}", filter] }
        let hdr = stream.isHDR && [.mp4, .mov, .mkv, .webm].contains(format)
        let colour = hdr ? colourTags(stream) : []
        switch format {
        case .mp4, .mov, .mkv:
            if hdr {
                let x265Colour = "colorprim=\(stream.colorPrimaries ?? "bt2020"):transfer=\(stream.colorTransfer ?? "smpte2084")"
                    + ":colormatrix=\(stream.colorSpace ?? "bt2020nc")"
                arguments += ["-c:{i}", "libx265", "-preset:{i}", "medium", "-crf:{i}", options.compact ? "26" : "20",
                              "-pix_fmt:{i}", "yuv420p10le", "-profile:{i}", "main10",
                              "-x265-params:{i}", "\(x265Colour):hdr10-opt=1:repeat-headers=1:log-level=error"] + colour
                if format != .mkv { arguments += ["-tag:{i}", "hvc1"] }
            } else {
                arguments += ["-c:{i}", "libx264", "-preset:{i}", "medium", "-crf:{i}", options.compact ? "26" : "18",
                              "-pix_fmt:{i}", "yuv420p"]
            }
        case .webm:
            arguments += ["-c:{i}", "libvpx-vp9", "-crf:{i}", options.compact ? "36" : "31", "-b:{i}", "0",
                          "-row-mt", "1", "-deadline", "good", "-cpu-used", "4"]
            arguments += hdr ? ["-pix_fmt:{i}", "yuv420p10le", "-profile:{i}", "2"] + colour : ["-pix_fmt:{i}", "yuv420p"]
        case .avi:
            arguments += ["-c:{i}", "mpeg4", "-q:{i}", "2", "-pix_fmt:{i}", "yuv420p"]
        case .wmv:
            arguments += ["-c:{i}", "wmv2", "-q:{i}", "2"]
        default:
            break
        }
        return arguments
    }

    private static func colourTags(_ stream: Stream) -> [String] {
        ["-color_primaries:{i}", stream.colorPrimaries ?? "bt2020",
         "-color_trc:{i}", stream.colorTransfer ?? "smpte2084",
         "-colorspace:{i}", stream.colorSpace ?? "bt2020nc"]
    }

    /// Audio encoding per format, keeping the sample rate and the bit depth of
    /// lossless sources; bitrates grow with the channel count.
    static func audioEncoder(for format: Format, stream: Stream, options: Options, toolbox: Toolbox) -> [String] {
        let channels = max(1, stream.channels)
        func perChannel(_ kbps: Int, cap: Int = 640) -> String { "\(min(cap, kbps * channels))k" }
        let deep = stream.bitDepth > 16
        switch format {
        case .mp4, .mov, .m4a:
            // A lossless track in a video stays lossless (ALAC); M4A means AAC.
            if stream.isLossless, format != .m4a, !options.compact {
                return ["-c:{i}", "alac"] + (deep ? ["-sample_fmt:{i}", "s32p"] : [])
            }
            let rate = options.compact ? perChannel(64) : perChannel(channels <= 2 ? 128 : 96)
            return aacEncoder(toolbox) + ["-b:{i}", rate]
        case .mkv:
            return stream.isLossless ? ["-c:{i}", "flac"] : aacEncoder(toolbox) + ["-b:{i}", perChannel(options.compact ? 64 : 128)]
        case .webm, .ogg, .opus:
            return ["-c:{i}", "libopus", "-b:{i}", perChannel(options.compact ? 48 : 80, cap: 510)]
        case .avi, .mp3:
            return ["-c:{i}", "libmp3lame", "-q:{i}", options.compact ? "4" : "0", "-ac:{i}", String(min(2, channels))]
        case .wmv, .wma:
            return ["-c:{i}", "wmav2", "-b:{i}", "192k", "-ac:{i}", String(min(2, channels))]
        case .wav:
            if stream.codec.hasPrefix("pcm_f") { return ["-c:{i}", "pcm_f32le"] } // float stays float
            return ["-c:{i}", deep ? "pcm_s24le" : "pcm_s16le"]
        case .aiff:
            return ["-c:{i}", deep ? "pcm_s24be" : "pcm_s16be"]
        case .flac:
            return ["-c:{i}", "flac", "-sample_fmt:{i}", deep ? "s32" : "s16"]
        default:
            return ["-c:{i}", "copy"]
        }
    }

    /// Apple's AAC encoder (better than ffmpeg's own at the same bitrate), constrained VBR.
    static func aacEncoder(_ toolbox: Toolbox) -> [String] {
        hasEncoder("aac_at", toolbox: toolbox) ? ["-c:{i}", "aac_at", "-aac_at_mode:{i}", "cvbr"] : ["-c:{i}", "aac"]
    }

    private static let encoders = Mutex<[String: Set<String>]>([:])

    /// Whether this ffmpeg build has an encoder (asked once per ffmpeg).
    static func hasEncoder(_ name: String, toolbox: Toolbox) -> Bool {
        guard let ffmpeg = toolbox.ffmpeg else { return false }
        if let known = encoders.withLock({ $0[ffmpeg.path] }) { return known.contains(name) }
        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = ["-hide_banner", "-encoders"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        var names = Set<String>()
        if (try? process.run()) != nil {
            let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            for line in text.split(separator: "\n") {
                let parts = line.split(separator: " ", omittingEmptySubsequences: true)
                if parts.count > 1 { names.insert(String(parts[1])) }
            }
        }
        encoders.withLock { $0[ffmpeg.path] = names }
        return names.contains(name)
    }

    // MARK: - Running

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

    /// Converts with the stream plan, then checks the result isn't cut short.
    static func convert(_ input: URL, to format: Format, at output: URL, context: JobContext,
                        probe: Probe? = nil, options: Options = Options()) async throws {
        var probe = probe
        if probe == nil { probe = try await self.probe(input, context: context) }
        guard let probe else { return }
        var inputOptions: [String] = []
        if options.addRotation != 0, let video = probe.video.first, !options.reencodeVideo, options.videoFilter == nil,
           copiesVideo(video.codec, into: format) {
            inputOptions = ["-display_rotation:v:0", String(Int(video.rotation + options.addRotation))]
        }
        try await run(input: input, output: output, arguments: arguments(for: format, probe: probe, options: options, toolbox: context.toolbox),
                      context: context, inputOptions: inputOptions)
        if format != .gif { try await MediaChecks.checkLength(of: output, against: input, expected: probe.duration, context: context) }
        if [.mp4, .mov].contains(format) {
            try await MediaConverter.restoreAppleMetadata(from: input, into: output, keepsChapters: probe.chapters > 0, context: context)
        }
    }

    /// Whether a file has an audio stream (so "MP3" on a silent video fails kindly).
    static func hasAudio(_ input: URL, context: JobContext) async -> Bool {
        guard let ffprobe = context.toolbox.ffprobe else { return true }
        let text = try? await Shell.run(ffprobe, ["-v", "error", "-select_streams", "a", "-show_entries", "stream=index", "-of", "csv=p=0", input.path])
        return !(text ?? "x").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Runs ffmpeg with its log (stderr) captured, for filters that report
    /// through it (loudnorm's measurements).
    static func runCapturingLog(_ arguments: [String], context: JobContext) async throws -> String {
        guard let ffmpeg = context.toolbox.ffmpeg else { throw CutieError("This needs ffmpeg (brew install ffmpeg).") }
        return try await Shell.run(URL(fileURLWithPath: "/bin/sh"), ["-c", "exec \"$0\" \"$@\" 2>&1", ffmpeg.path] + arguments)
    }
}
