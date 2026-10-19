import Foundation
import Testing
@testable import cutie

/// Subtitles keep their styling and placement across SRT, VTT and ASS; text
/// files open whatever encoding they were saved in.
@Suite(.serialized)
struct SubtitleAndTextTests {
    func convert(_ input: URL, to format: Format, _ fixtures: Fixtures) async throws -> String {
        let output = try #require(try await Executor.run(.convert(format), inputs: [input], context: fixtures.context).files.first)
        return try String(contentsOf: output, encoding: .utf8)
    }

    @Test func vttToSRTTranslatesStyling() async throws {
        let fixtures = try Fixtures(); defer { fixtures.remove() }
        let vtt = try fixtures.text("talk.vtt", """
        WEBVTT

        STYLE
        ::cue(.warn) { color: #ff8800; }

        NOTE a comment, not a cue

        intro
        00:00:01.000 --> 00:00:02.500 line:0
        <v Roger>Hello &amp; <i>welcome</i></v>

        00:00:03.000 --> 00:00:04.000
        <c.yellow>Caution</c> <c.warn>hot</c> <00:00:03.500>karaoke <ruby>漢<rt>かん</rt></ruby>

        00:01:02.040 --> 00:01:03.000 align:left
        Left &lt;3
        """)
        let cues = Subtitles.parse(try await convert(vtt, to: .srt, fixtures))
        #expect(cues.count == 3)
        #expect(cues[0] == Subtitles.Cue(start: 1000, end: 2500, text: "Hello & <i>welcome</i>", position: 8))
        #expect(cues[1].text == ##"<font color="#FFFF00">Caution</font> <font color="#FF8800">hot</font> karaoke 漢"##)
        #expect(cues[2] == Subtitles.Cue(start: 62_040, end: 63_000, text: "Left <3", position: 1))
    }

    @Test func srtToVTTEscapesAndStyles() async throws {
        let fixtures = try Fixtures(); defer { fixtures.remove() }
        let srt = try fixtures.text("talk.srt", """
        1
        00:00:01,000 --> 00:00:02,500
        {\\an8}<font color="#ff8800">Orange</font> & <b>bold</b>

        2
        00:00:03,000 --> 00:00:04,000
        {\\i1}Italic{\\i0} 5 < 6 {not a tag}
        """)
        let vtt = try await convert(srt, to: .vtt, fixtures)
        #expect(vtt.contains("::cue(.c_ff8800) { color: #FF8800; }"))
        #expect(vtt.contains("00:00:01.000 --> 00:00:02.500 line:0\n<c.c_ff8800>Orange</c> &amp; <b>bold</b>"))
        #expect(vtt.contains("<i>Italic</i> 5 &lt; 6 {not a tag}"))
        // And back: the same cues.
        try FileManager.default.removeItem(at: srt)
        let cues = Subtitles.parse(try await convert(fixtures.url("talk.vtt"), to: .srt, fixtures))
        #expect(cues[0] == Subtitles.Cue(start: 1000, end: 2500, text: ##"<font color="#FF8800">Orange</font> & <b>bold</b>"##, position: 8))
        #expect(cues[1].text == "<i>Italic</i> 5 < 6 {not a tag}")
    }

    static let ass = """
    [Script Info]
    ScriptType: v4.00+

    [V4+ Styles]
    Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
    Style: Default,Arial,20,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2,2,2,10,10,10,1
    Style: Sign,Arial,20,&H0000FFFF,&H000000FF,&H00000000,&H00000000,-1,0,0,0,100,100,0,0,1,2,2,8,10,10,10,1
    Style: Thought,Arial,20,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,-1,0,0,100,100,0,0,1,2,2,2,10,10,10,1

    [Events]
    Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
    Dialogue: 0,0:00:05.00,0:00:06.50,Default,,0,0,0,,Second, with a comma
    Dialogue: 0,0:00:01.23,0:00:02.50,Sign,,0,0,0,,EXIT
    Comment: 0,0:00:03.00,0:00:04.00,Default,,0,0,0,,not shown
    Dialogue: 0,0:00:03.00,0:00:04.00,Thought,,0,0,0,,{\\an8}Line one\\Nline {\\b1}two{\\b0} {\\c&H0000FF&}red{\\c}
    Dialogue: 0,0:00:07.00,0:00:08.00,Default,,0,0,0,,{\\p1}m 0 0 l 100 0 100 100{\\p0}Drawn
    """

    @Test func assReadsStylesOverridesAndOrder() async throws {
        let fixtures = try Fixtures(); defer { fixtures.remove() }
        let cues = Subtitles.parse(try await convert(try fixtures.text("show.ass", Self.ass), to: .srt, fixtures))
        #expect(cues.map(\.start) == [1230, 3000, 5000, 7000])
        #expect(cues[0] == Subtitles.Cue(start: 1230, end: 2500, text: ##"<b><font color="#FFFF00">EXIT</font></b>"##, position: 8))
        #expect(cues[1] == Subtitles.Cue(start: 3000, end: 4000, text: "<i>Line one\nline <b>two</b> <font color=\"#FF0000\">red</font></i>", position: 8))
        #expect(cues[2].text == "Second, with a comma")
        #expect(cues[3].text == "Drawn")
    }

    @Test func srtThroughASSRoundTrips() async throws {
        let fixtures = try Fixtures(); defer { fixtures.remove() }
        let original = [
            Subtitles.Cue(start: 1230, end: 2500, text: "<i>Hello</i>\n<font color=\"#FF8800\">there</font>", position: 8),
            Subtitles.Cue(start: 3_600_000, end: 3_601_000, text: "<b>An hour in</b>", position: 2),
        ]
        let srt = try fixtures.text("round.srt", Subtitles.srt(original))
        let ass = try await convert(srt, to: .ass, fixtures)
        #expect(ass.contains("Dialogue: 0,0:00:01.23,0:00:02.50,Default,,0,0,0,,{\\an8}{\\i1}Hello{\\i0}\\N{\\c&H0088FF&}there{\\c}"))
        try FileManager.default.removeItem(at: srt)
        #expect(Subtitles.parse(try await convert(fixtures.url("round.ass"), to: .srt, fixtures)) == original)
    }

    @Test func plainTextDropsAllMarkup() {
        let cues = Subtitles.parse(Self.ass)
        #expect(Subtitles.text(cues) == "EXIT\nLine one\nline two red\nSecond, with a comma\nDrawn\n")
    }

    // MARK: Text encodings

    @Test func encodingsAreDetected() throws {
        let french = "Café crème, naïve façade — 5 €"
        let polish = "Zażółć gęślą jaźń, źdźbło"
        let czech = "Příliš žluťoučký kůň úpěl ďábelské ódy"
        let german = "Grüße aus München, schöne Straße"
        #expect(try TextDecoding.decode(french.data(using: .windowsCP1252)!) == french)
        #expect(try TextDecoding.decode(polish.data(using: .windowsCP1250)!) == polish)
        #expect(try TextDecoding.decode(czech.data(using: .windowsCP1250)!) == czech)
        #expect(try TextDecoding.decode(german.data(using: .macOSRoman)!) == german)
        #expect(try TextDecoding.decode(Data([0xEF, 0xBB, 0xBF]) + Data(french.utf8)) == french)
        #expect(try TextDecoding.decode(Data([0xFF, 0xFE]) + french.data(using: .utf16LittleEndian)!) == french)
        #expect(try TextDecoding.decode(Data([0xFE, 0xFF]) + french.data(using: .utf16BigEndian)!) == french)
        #expect(try TextDecoding.decode("Plain old text, line two".data(using: .utf16LittleEndian)!) == "Plain old text, line two")
    }

    @Test func oldSubtitleFilesOpen() async throws {
        let fixtures = try Fixtures(); defer { fixtures.remove() }
        let url = fixtures.url("vieux.srt")
        try "1\n00:00:01,000 --> 00:00:02,000\nÇa va très bien, merci\n".data(using: .windowsCP1252)!.write(to: url)
        let vtt = try await convert(url, to: .vtt, fixtures)
        #expect(vtt.contains("Ça va très bien, merci"))
    }
}
