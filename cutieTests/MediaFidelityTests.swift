import AVFoundation
import Testing
@testable import cutie

/// Video and audio must come out as complete as they went in: every track,
/// subtitle, chapter, tag and cover; HDR stays HDR; hi-res stays hi-res;
/// copies stay copies; damaged files are refused. Needs ffmpeg (skips without).
@Suite(.serialized)
struct MediaFidelityTests {
    let fixtures: Fixtures
    let context: JobContext

    init() throws {
        fixtures = try Fixtures()
        context = fixtures.fullContext
    }

    var ffmpeg: URL? { context.toolbox.ffmpeg }

    // MARK: Fixtures

    func make(_ name: String, _ arguments: [String]) async throws -> URL {
        let url = fixtures.url(name)
        try await Shell.run(ffmpeg!, ["-hide_banner", "-loglevel", "error", "-y"] + arguments + [url.path])
        return url
    }

    /// 4 s MKV: H.264, English AAC + Italian 5.1 AC-3, English and Italian SRT, two chapters, a title.
    func movie() async throws -> URL {
        let english = try fixtures.text("en.srt", "1\n00:00:00,500 --> 00:00:01,500\nHello there\n\n2\n00:00:02,000 --> 00:00:03,000\nGoodbye\n")
        let italian = try fixtures.text("it.srt", "1\n00:00:00,500 --> 00:00:01,500\nCiao\n")
        let chapters = try fixtures.text("meta.txt", ";FFMETADATA1\ntitle=Test Movie\n[CHAPTER]\nTIMEBASE=1/1000\nSTART=0\nEND=2000\ntitle=Opening\n[CHAPTER]\nTIMEBASE=1/1000\nSTART=2000\nEND=4000\ntitle=Ending\n")
        return try await make("movie.mkv", [
            "-f", "lavfi", "-i", "testsrc=duration=4:size=320x240:rate=15",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=4",
            "-f", "lavfi", "-i", "sine=frequency=220:duration=4",
            "-i", english.path, "-i", italian.path, "-i", chapters.path,
            "-map", "0:v", "-map", "1:a", "-map", "2:a", "-map", "3:s", "-map", "4:s",
            "-map_metadata", "5", "-map_chapters", "5",
            "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a:0", "aac", "-c:a:1", "ac3", "-ac:a:1", "6",
            "-metadata:s:a:0", "language=eng", "-metadata:s:a:1", "language=ita",
            "-metadata:s:s:0", "language=eng", "-metadata:s:s:1", "language=ita", "-c:s", "srt",
        ])
    }

    /// An iPhone-style MOV with a capture place and date, written the way the
    /// camera does (QuickTime "mdta" keys, by AVFoundation).
    func phoneMOV() async throws -> URL {
        let plain = try await make("plain.mov", [
            "-f", "lavfi", "-i", "testsrc=duration=3:size=320x240:rate=15", "-f", "lavfi", "-i", "sine=frequency=440:duration=3",
            "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac",
        ])
        func item(_ identifier: AVMetadataIdentifier, _ value: String) -> AVMetadataItem {
            let item = AVMutableMetadataItem()
            item.identifier = identifier
            item.value = value as NSString
            item.dataType = kCMMetadataBaseDataType_UTF8 as String
            return item
        }
        let url = fixtures.url("phone.mov")
        let session = try #require(AVAssetExportSession(asset: AVURLAsset(url: plain), presetName: AVAssetExportPresetPassthrough))
        session.metadata = [item(.quickTimeMetadataLocationISO6709, "+45.4642+009.1900+000.000/"),
                            item(.quickTimeMetadataCreationDate, "2025-06-01T10:20:30+0200")]
        try await session.export(to: url, as: .mov)
        return url
    }

    /// Whether AVFoundation (and so Photos and Finder) sees a capture place.
    func hasPlace(_ url: URL) async throws -> Bool {
        try await AVURLAsset(url: url).load(.commonMetadata).contains { $0.commonKey == .commonKeyLocation }
    }

    /// HDR10: 10-bit HEVC with PQ and BT.2020 tags.
    func hdr10(_ name: String = "hdr10.mkv") async throws -> URL {
        try await make(name, [
            "-f", "lavfi", "-i", "testsrc2=duration=2:size=320x240:rate=15",
            "-c:v", "libx265", "-pix_fmt", "yuv420p10le",
            "-x265-params", "colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:log-level=error",
            "-color_primaries", "bt2020", "-color_trc", "smpte2084", "-colorspace", "bt2020nc",
        ] + (name.hasSuffix(".mov") ? ["-tag:v", "hvc1"] : []))
    }

    func hiResWAV() async throws -> URL {
        try await make("hires.wav", ["-f", "lavfi", "-i", "sine=frequency=1000:sample_rate=96000:duration=3", "-af", "volume=-20dB", "-c:a", "pcm_s24le"])
    }

    func songWithCover() async throws -> URL {
        let cover = try await make("cover.jpg", ["-f", "lavfi", "-i", "color=c=orange:s=300x300", "-frames:v", "1"])
        return try await make("song.mp3", [
            "-f", "lavfi", "-i", "sine=frequency=440:duration=3", "-i", cover.path, "-map", "0", "-map", "1",
            "-c:a", "libmp3lame", "-c:v", "copy", "-disposition:v", "attached_pic", "-id3v2_version", "3",
            "-metadata", "title=Song", "-metadata", "artist=Band",
        ])
    }

    func surround() async throws -> URL {
        try await make("surround.wav", [
            "-f", "lavfi", "-i", "aevalsrc=sin(440*2*PI*t)|sin(550*2*PI*t)|sin(660*2*PI*t)|sin(110*2*PI*t)|sin(330*2*PI*t)|sin(220*2*PI*t):s=48000:d=3:c=5.1",
            "-c:a", "pcm_s16le",
        ])
    }

    // MARK: Helpers

    func run(_ item: WheelItem, _ input: URL) async throws -> URL {
        let outcome = try await Executor.run(item, inputs: [input], context: context)
        #expect(outcome.failures.isEmpty)
        return try #require(outcome.files.first)
    }

    func probe(_ url: URL) async throws -> FFmpeg.Probe {
        try await FFmpeg.probe(url, context: context)
    }

    /// ffprobe's view of the container tags and chapters.
    func formatTags(_ url: URL) async throws -> String {
        try await Shell.run(context.toolbox.ffprobe!, ["-v", "error", "-show_entries", "format_tags", "-show_chapters", "-of", "compact", url.path])
    }

    /// A checksum of the video packets: identical means the video was copied, not re-encoded.
    func videoHash(_ url: URL) async throws -> String {
        try await Shell.run(ffmpeg!, ["-v", "error", "-i", url.path, "-map", "0:v:0", "-c", "copy", "-f", "framemd5", "-"])
            .split(separator: "\n").filter { !$0.hasPrefix("#") }
            .map { $0.split(separator: ",").last.map(String.init) ?? "" }.joined(separator: ",")
    }

    // MARK: Tests

    @Test func mkvToMP4IsARemuxThatKeepsEverything() async throws {
        defer { fixtures.remove() }
        guard ffmpeg != nil else { return }
        let input = try await movie()
        let output = try await run(.convert(.mp4), input)
        let streams = try await probe(output)
        #expect(streams.video.map(\.codec) == ["h264"])
        #expect(streams.audio.map(\.codec) == ["aac", "ac3"])
        #expect(streams.audio.map(\.language) == ["eng", "ita"])
        #expect(streams.audio.last?.channels == 6)
        #expect(streams.subtitles.filter { $0.codec == "mov_text" }.count == 2)
        #expect(streams.chapters == 2)
        #expect(try await formatTags(output).contains("Test Movie"))
        #expect(try await videoHash(output) == (try await videoHash(input)))
    }

    @Test func webmKeepsEveryTrack() async throws {
        defer { fixtures.remove() }
        guard ffmpeg != nil else { return }
        let output = try await run(.convert(.webm), try await movie())
        let streams = try await probe(output)
        #expect(streams.video.map(\.codec) == ["vp9"])
        #expect(streams.audio.map(\.codec) == ["opus", "opus"])
        #expect(streams.subtitles.map(\.codec) == ["webvtt", "webvtt"])
    }

    @Test func captureDateAndPlaceSurvive() async throws {
        defer { fixtures.remove() }
        guard ffmpeg != nil else { return }
        let input = try await phoneMOV()
        // ffmpeg paths and AVFoundation paths alike.
        for (item, ctx) in [(WheelItem.tool(.compressVideo), context), (.tool(.muteVideo), context),
                            (.tool(.rotateVideo), context), (.convert(.mp4), context), (.convert(.mkv), context),
                            (.tool(.compressVideo), fixtures.context)] {
            let outcome = try await Executor.run(item, inputs: [input], context: ctx)
            let output = try #require(outcome.files.first)
            let tags = try await formatTags(output)
            #expect(tags.contains("+45.4642+009.1900"), "\(item)")
            if output.pathExtension != "mkv" { #expect(try await hasPlace(output), "\(item)") }
            try? FileManager.default.removeItem(at: output)
        }
    }

    @Test func hdr10StaysHDR10() async throws {
        defer { fixtures.remove() }
        guard ffmpeg != nil else { return }
        let input = try await hdr10()
        let copied = try await probe(try await run(.convert(.mp4), input)).video.first
        #expect(copied?.codec == "hevc")
        #expect(copied?.colorTransfer == "smpte2084")

        for item in [WheelItem.tool(.compressVideo), .tool(.resizeVideo)] {
            let video = try #require(try await probe(try await run(item, input)).video.first, "\(item)")
            #expect(video.codec == "hevc", "\(item)")
            #expect(video.pixelFormat == "yuv420p10le", "\(item)")
            #expect(video.colorTransfer == "smpte2084", "\(item)")
            #expect(video.colorPrimaries == "bt2020", "\(item)")
        }
        let webm = try #require(try await probe(try await run(.convert(.webm), input)).video.first)
        #expect(webm.codec == "vp9")
        #expect(webm.pixelFormat == "yuv420p10le")
        #expect(webm.colorTransfer == "smpte2084")
    }

    @Test func hdrIsToneMappedForSDROnlyFormats() async throws {
        defer { fixtures.remove() }
        guard ffmpeg != nil else { return }
        let input = try await hdr10()
        let avi = try #require(try await probe(try await run(.convert(.avi), input)).video.first)
        #expect(avi.colorTransfer != "smpte2084")
        let gif = try await run(.convert(.gif), input)
        #expect((try? gif.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 > 1000)
        let snapshot = try await run(.tool(.snapshot), input)
        #expect(snapshot.pathExtension == "png")
    }

    @Test func hiResAudioStaysHiRes() async throws {
        defer { fixtures.remove() }
        guard ffmpeg != nil else { return }
        let input = try await hiResWAV()
        for (format, codec) in [(Format.flac, "flac"), (.aiff, "pcm_s24be")] {
            let audio = try #require(try await probe(try await run(.convert(format), input)).audio.first)
            #expect(audio.codec == codec, "\(format)")
            #expect(audio.bitDepth == 24, "\(format)")
            #expect(audio.sampleRate == 96_000, "\(format)")
        }
        let even = try #require(try await probe(try await run(.tool(.normalizeAudio), input)).audio.first)
        #expect(even.codec == "pcm_s24le")
        #expect(even.sampleRate == 96_000)
    }

    @Test func hiResAudioStaysHiResWithoutFFmpeg() async throws {
        defer { fixtures.remove() }
        guard ffmpeg != nil else { return }
        let input = try await hiResWAV()
        for format in [Format.flac, .aiff] {
            let outcome = try await Executor.run(.convert(format), inputs: [input], context: fixtures.context)
            let file = try AVAudioFile(forReading: try #require(outcome.files.first))
            #expect(file.fileFormat.sampleRate == 96_000, "\(format)")
            #expect(MediaConverter.sourceDepth(file.fileFormat).bits == 24, "\(format)")
        }
    }

    @Test func evenVolumeReachesTheTarget() async throws {
        defer { fixtures.remove() }
        guard ffmpeg != nil else { return }
        let output = try await run(.tool(.normalizeAudio), try await hiResWAV())
        let log = try await FFmpeg.runCapturingLog(["-hide_banner", "-nostdin", "-i", output.path,
                                                    "-af", "loudnorm=print_format=json", "-f", "null", "-"], context: context)
        let loudness = try #require(MediaTools.loudnessMeasurements(in: log)?["input_i"].flatMap(Double.init))
        #expect(abs(loudness - -16) < 1.5)
    }

    @Test func coverArtAndTagsCarryOver() async throws {
        defer { fixtures.remove() }
        guard ffmpeg != nil else { return }
        let input = try await songWithCover()
        for item in [WheelItem.convert(.m4a), .convert(.flac), .tool(.compressAudio)] {
            let output = try await run(item, input)
            let streams = try await probe(output)
            #expect(streams.covers.count == 1, "\(item)")
            #expect(try await formatTags(output).contains("Song"), "\(item)")
        }
    }

    @Test func surroundKeepsItsChannels() async throws {
        defer { fixtures.remove() }
        guard ffmpeg != nil else { return }
        let input = try await surround()
        for format in [Format.m4a, .opus, .flac] {
            let audio = try #require(try await probe(try await run(.convert(format), input)).audio.first)
            #expect(audio.channels == 6, "\(format)")
        }
        #expect(FFmpeg.audioEncoder(for: .m4a, stream: try #require(try await probe(input).audio.first),
                                    options: .init(), toolbox: context.toolbox).contains("576k"))
    }

    @Test func getAudioCopiesTheTrack() async throws {
        defer { fixtures.remove() }
        guard ffmpeg != nil else { return }
        let audio = try await run(.tool(.extractAudio), try await movie())
        #expect(audio.pathExtension == "m4a")
        #expect(try await probe(audio).audio.map(\.codec) == ["aac"])
    }

    @Test func rotateOnlyTurnsTheFlag() async throws {
        defer { fixtures.remove() }
        guard ffmpeg != nil else { return }
        let input = try await movie()
        let output = try await run(.tool(.rotateVideo), input)
        let video = try #require(try await probe(output).video.first)
        #expect(video.rotation == -90)
        #expect(try await videoHash(output) == (try await videoHash(input)))
        #expect(try await probe(output).audio.count == 2)
    }

    @Test func getSubtitles() async throws {
        defer { fixtures.remove() }
        guard ffmpeg != nil else { return }
        let folder = try await run(.tool(.extractSubtitles), try await movie())
        #expect(folder.lastPathComponent == "movie (Subtitles)")
        let english = folder.appending(path: "movie.eng.srt")
        #expect(try String(contentsOf: english, encoding: .utf8).contains("Hello there"))
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "movie.ita.srt").path))

        let clip = try await fixtures.mp4(ffmpeg!)
        await #expect(throws: (any Error).self) { _ = try await Executor.run(.tool(.extractSubtitles), inputs: [clip], context: context) }
    }

    @Test func damagedFilesAreRefused() async throws {
        defer { fixtures.remove() }
        guard ffmpeg != nil else { return }
        let clip = try await fixtures.mp4(ffmpeg!)
        let whole = try Data(contentsOf: clip)
        let cutMP4 = fixtures.url("cut.mp4")
        try whole.prefix(whole.count * 2 / 3).write(to: cutMP4)
        await #expect(throws: (any Error).self) { _ = try await Executor.run(.convert(.mov), inputs: [cutMP4], context: context) }
        await #expect(throws: (any Error).self) { _ = try await Executor.run(.tool(.compressVideo), inputs: [cutMP4], context: fixtures.context) }

        let movie = try Data(contentsOf: try await movie())
        let cutMKV = fixtures.url("cut.mkv")
        try movie.prefix(movie.count / 2).write(to: cutMKV)
        await #expect(throws: (any Error).self) { _ = try await Executor.run(.convert(.mp4), inputs: [cutMKV], context: context) }
    }
}
