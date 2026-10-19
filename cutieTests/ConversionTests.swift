import AppKit
import AVFoundation
import ImageIO
import PDFKit
import Testing
@testable import cutie

/// End-to-end: real files in, real files out, through `Executor`.
@Suite(.serialized)
struct ConversionTests {
    func pixelSize(_ url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return CGSize(width: width, height: height)
    }

    func convert(_ input: URL, to format: Format, _ context: JobContext) async throws -> URL {
        let outcome = try await Executor.run(.convert(format), inputs: [input], context: context)
        #expect(outcome.failures.isEmpty)
        let file = try #require(outcome.files.first)
        #expect(FileManager.default.fileExists(atPath: file.path))
        return file
    }

    // MARK: Images

    @Test func imageToEveryNativeFormat() async throws {
        let fixtures = try Fixtures(); defer { fixtures.remove() }
        let input = try fixtures.png()
        for format in [Format.jpg, .heic, .avif, .tiff, .bmp, .gif] {
            let output = try await convert(input, to: format, fixtures.context)
            #expect(output.lastPathComponent == "photo.\(format.fileExtension)")
            #expect(pixelSize(output) == CGSize(width: 200, height: 100), "\(format)")
        }
        let pdf = try await convert(input, to: .pdf, fixtures.context)
        #expect(PDFDocument(url: pdf)?.pageCount == 1)
    }

    @Test func secondConversionGetsAFreshName() async throws {
        let fixtures = try Fixtures(); defer { fixtures.remove() }
        let input = try fixtures.png()
        let first = try await convert(input, to: .jpg, fixtures.context)
        let second = try await convert(input, to: .jpg, fixtures.context)
        #expect(first.lastPathComponent == "photo.jpg")
        #expect(second.lastPathComponent == "photo 2.jpg")
    }

    @Test func phoneOrientationIsBakedIn() async throws {
        let fixtures = try Fixtures(); defer { fixtures.remove() }
        let output = try await convert(try fixtures.rotatedJPEG(), to: .png, fixtures.context)
        #expect(pixelSize(output) == CGSize(width: 100, height: 200))
    }

    @Test func svgIsRasterized() async throws {
        let fixtures = try Fixtures(); defer { fixtures.remove() }
        let output = try await convert(try fixtures.svg(), to: .png, fixtures.context)
        #expect(pixelSize(output) == CGSize(width: 2048, height: 1024))
    }

    @Test func imageTools() async throws {
        let fixtures = try Fixtures(); defer { fixtures.remove() }
        let input = try fixtures.png()
        let expectations: [(Tool, CGSize, String)] = [
            (.resizeImage, CGSize(width: 100, height: 50), "photo half.png"),
            (.rotateImage, CGSize(width: 100, height: 200), "photo rotated.png"),
            (.flipImage, CGSize(width: 200, height: 100), "photo flipped.png"),
            (.cropSquare, CGSize(width: 100, height: 100), "photo square.png"),
            (.grayscale, CGSize(width: 200, height: 100), "photo bw.png"),
            (.stripMetadata, CGSize(width: 200, height: 100), "photo clean.png"),
        ]
        for (tool, size, name) in expectations {
            let outcome = try await Executor.run(.tool(tool), inputs: [input], context: fixtures.context)
            let file = try #require(outcome.files.first)
            #expect(file.lastPathComponent == name)
            #expect(pixelSize(file) == size, "\(tool)")
        }
    }

    @Test func rotationIsClockwise() throws {
        // Orange on the left half → after a clockwise turn, orange is on top.
        let context = ImageConverter.bitmapContext(width: 2, height: 1, alpha: true)!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        let rotated = try ImageTools.rotated(context.makeImage()!)
        let data = rotated.dataProvider!.data! as Data
        // Row 0 of the bitmap is the top row.
        #expect(data[0] > 200) // top pixel red
        #expect(data[rotated.bytesPerRow] < 50) // bottom pixel clear
    }

    @Test func liveTextReadsAnImage() async throws {
        let fixtures = try Fixtures(); defer { fixtures.remove() }
        let outcome = try await Executor.run(.tool(.extractText), inputs: [try fixtures.textImage("Hello Cutie")], context: fixtures.context)
        let text = try String(contentsOf: try #require(outcome.files.first), encoding: .utf8)
        #expect(text.contains("Hello"))
    }

    @Test func combineImagesIntoOnePDF() async throws {
        let fixtures = try Fixtures(); defer { fixtures.remove() }
        let inputs = [try fixtures.png("a.png"), try fixtures.png("b.png")]
        let outcome = try await Executor.run(.tool(.combineToPDF), inputs: inputs, context: fixtures.context)
        let pdf = try #require(outcome.files.first)
        #expect(pdf.lastPathComponent == "Combined.pdf")
        #expect(PDFDocument(url: pdf)?.pageCount == 2)
    }

    // MARK: Audio & video

    @Test func audioWithoutFFmpeg() async throws {
        let fixtures = try Fixtures(); defer { fixtures.remove() }
        let input = try fixtures.wav()
        for format in [Format.m4a, .flac, .aiff] {
            let output = try await convert(input, to: format, fixtures.context)
            let duration = try await AVURLAsset(url: output).load(.duration).seconds
            #expect(abs(duration - 1) < 0.1, "\(format)")
        }
    }

    @Test func audioWithFFmpeg() async throws {
        let fixtures = try Fixtures(); defer { fixtures.remove() }
        let context = fixtures.fullContext
        guard context.toolbox.ffmpeg != nil else { return }
        let input = try fixtures.wav()
        for format in [Format.mp3, .ogg, .opus, .wma, .flac] {
            let output = try await convert(input, to: format, context)
            #expect((try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) > 1000, "\(format)")
        }
        let louder = try await Executor.run(.tool(.normalizeAudio), inputs: [input], context: context)
        #expect(louder.files.first?.lastPathComponent == "tone even.wav")
    }

    @Test func videoConversionsAndTools() async throws {
        let fixtures = try Fixtures(); defer { fixtures.remove() }
        let context = fixtures.fullContext
        guard let ffmpeg = context.toolbox.ffmpeg else { return }
        let clip = try await fixtures.mp4(ffmpeg)

        let mov = try await convert(clip, to: .mov, context)
        #expect(try await AVURLAsset(url: mov).load(.duration).seconds > 1.5)
        _ = try await convert(clip, to: .webm, context)
        _ = try await convert(clip, to: .mkv, context)
        _ = try await convert(clip, to: .mp3, context)
        let gif = try await convert(clip, to: .gif, context)
        #expect(pixelSize(gif) != nil)

        // Native GIF path (no ffmpeg).
        let nativeGIF = try await convert(clip, to: .gif, fixtures.context)
        #expect(pixelSize(nativeGIF)?.width == 320)

        let muted = try #require(try await Executor.run(.tool(.muteVideo), inputs: [clip], context: context).files.first)
        #expect(try await AVURLAsset(url: muted).loadTracks(withMediaType: .audio).isEmpty)

        let rotated = try #require(try await Executor.run(.tool(.rotateVideo), inputs: [clip], context: context).files.first)
        let track = try #require(try await AVURLAsset(url: rotated).loadTracks(withMediaType: .video).first)
        let (transform, size) = try await track.load(.preferredTransform, .naturalSize)
        let shown = CGRect(origin: .zero, size: size).applying(transform)
        #expect(abs(shown.width) == 240 && abs(shown.height) == 320)
        #expect(shown.minX == 0 && shown.minY == 0)

        let snapshot = try #require(try await Executor.run(.tool(.snapshot), inputs: [clip], context: context).files.first)
        #expect(pixelSize(snapshot) == CGSize(width: 320, height: 240))

        let audio = try #require(try await Executor.run(.tool(.extractAudio), inputs: [clip], context: context).files.first)
        #expect(audio.pathExtension == "m4a")

        let small = try await Executor.run(.tool(.compressVideo), inputs: [clip], context: context)
        #expect(small.files.first?.lastPathComponent == "clip compressed.mp4")
        #expect(small.message?.contains("→") == true)
    }

    // MARK: Documents

    @Test func markdownToEverything() async throws {
        let fixtures = try Fixtures(); defer { fixtures.remove() }
        let input = try fixtures.text("notes.md", Fixtures.markdown)
        for format in [Format.docx, .pdf, .html, .epub, .txt, .rtf, .odt] {
            let output = try await convert(input, to: format, fixtures.context)
            #expect((try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) > 40, "\(format)")
        }
        let html = try String(contentsOf: fixtures.url("notes.html"), encoding: .utf8)
        #expect(html.contains("<h1>Trip Notes</h1>"))
        #expect(html.contains("<strong>sunscreen</strong>"))
        #expect(html.contains("<li>"))

        let docx = fixtures.url("notes.docx")
        let back = try NSAttributedString(url: docx, options: [:], documentAttributes: nil)
        #expect(back.string.contains("sunscreen"))

        let pdf = try #require(PDFDocument(url: fixtures.url("notes.pdf")))
        #expect(pdf.string?.contains("Trip Notes") == true)
    }

    @Test func wordDocumentBackToMarkdown() async throws {
        let fixtures = try Fixtures(); defer { fixtures.remove() }
        let docx = try await convert(try fixtures.text("notes.md", Fixtures.markdown), to: .docx, fixtures.context)
        try FileManager.default.removeItem(at: fixtures.url("notes.md"))
        let markdown = try String(contentsOf: try await convert(docx, to: .md, fixtures.context), encoding: .utf8)
        #expect(markdown.contains("# Trip Notes"))
        #expect(markdown.contains("**sunscreen**"))
        #expect(markdown.contains("- Tickets"))
        // Cocoa's DOCX writer drops hyperlinks, so links can't survive this round trip.
    }

    @Test func epubRoundTrip() async throws {
        let fixtures = try Fixtures(); defer { fixtures.remove() }
        let epub = try await convert(try fixtures.text("notes.md", Fixtures.markdown), to: .epub, fixtures.context)
        let text = try String(contentsOf: try await convert(epub, to: .txt, fixtures.context), encoding: .utf8)
        #expect(text.contains("sunscreen"))
        // mimetype must be the first entry, stored (EPUB rule).
        let listing = try await Shell.run(URL(fileURLWithPath: "/usr/bin/unzip"), ["-v", epub.path])
        let firstEntry = listing.split(separator: "\n").dropFirst(3).first ?? ""
        #expect(firstEntry.contains("Stored") && firstEntry.contains("mimetype"))
    }

    @Test func textClippingOpens() async throws {
        let fixtures = try Fixtures(); defer { fixtures.remove() }
        let clipping = fixtures.url("snippet.textClipping")
        let plist: [String: Any] = ["UTI-Data": ["public.utf8-plain-text": "clipped words"]]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0).write(to: clipping)
        let text = try String(contentsOf: try await convert(clipping, to: .txt, fixtures.context), encoding: .utf8)
        #expect(text.contains("clipped words"))
    }

    @Test func wordCount() async throws {
        let fixtures = try Fixtures(); defer { fixtures.remove() }
        let input = try fixtures.text("short.txt", "one two three four")
        let outcome = try await Executor.run(.tool(.wordCount), inputs: [input], context: fixtures.context)
        #expect(outcome.message?.hasPrefix("4 words") == true)
    }

    // MARK: PDF

    @Test func pdfTools() async throws {
        let fixtures = try Fixtures(); defer { fixtures.remove() }
        let input = try fixtures.pdf()
        let pages = try #require(PDFDocument(url: input)).pageCount
        #expect(pages >= 3)

        let split = try #require(try await Executor.run(.tool(.splitPDF), inputs: [input], context: fixtures.context).files.first)
        #expect(try FileManager.default.contentsOfDirectory(atPath: split.path).count == pages)

        let rotated = try #require(try await Executor.run(.tool(.rotatePDF), inputs: [input], context: fixtures.context).files.first)
        #expect(PDFDocument(url: rotated)?.page(at: 0)?.rotation == 90)

        let merged = try #require(try await Executor.run(.tool(.mergePDFs), inputs: [input, rotated], context: fixtures.context).files.first)
        #expect(PDFDocument(url: merged)?.pageCount == pages * 2)

        _ = try #require(try await Executor.run(.tool(.compressPDF), inputs: [input], context: fixtures.context).files.first)

        // A rotated page renders landscape, not cropped.
        let image = try PDFConverter.render(try #require(PDFDocument(url: rotated)?.page(at: 0)), dpi: 72)
        #expect(image.width == 792 && image.height == 612)
    }

    @Test func pdfConversions() async throws {
        let fixtures = try Fixtures(); defer { fixtures.remove() }
        let input = try fixtures.pdf()
        let pages = try #require(PDFDocument(url: input)).pageCount

        let images = try await convert(input, to: .png, fixtures.context)
        #expect(images.lastPathComponent == "report (PNG)")
        let first = try #require(try FileManager.default.contentsOfDirectory(at: images, includingPropertiesForKeys: nil).sorted { $0.path < $1.path }.first)
        #expect(pixelSize(first) == CGSize(width: 2550, height: 3300)) // Letter at 300 DPI
        #expect(try FileManager.default.contentsOfDirectory(atPath: images.path).count == pages)

        let text = try String(contentsOf: try await convert(input, to: .txt, fixtures.context), encoding: .utf8)
        #expect(text.contains("Page 2 of the report."))

        let docx = try await convert(input, to: .docx, fixtures.context)
        #expect(try NSAttributedString(url: docx, options: [:], documentAttributes: nil).string.contains("Page 3"))

        let pptx = try await convert(input, to: .pptx, fixtures.context)
        let listing = try await Shell.run(URL(fileURLWithPath: "/usr/bin/unzip"), ["-l", pptx.path])
        #expect(listing.contains("[Content_Types].xml"))
        #expect(listing.contains("ppt/slides/slide\(pages).xml"))
        // Quick Look (Office's own importer) must be able to draw it.
        let thumbnails = try fixtures.folder.appending(path: "ql").create()
        try await Shell.run(URL(fileURLWithPath: "/usr/bin/qlmanage"), ["-t", "-s", "256", "-o", thumbnails.path, pptx.path])
        #expect(try FileManager.default.contentsOfDirectory(atPath: thumbnails.path).count == 1)
    }

    // MARK: Spreadsheets

    @Test func spreadsheetRoundTrips() async throws {
        let fixtures = try Fixtures(); defer { fixtures.remove() }
        let rows = [["Name", "Amount", "Note"], ["Snacks", "12.5", "said \"yum\""], ["Zip", "02134", "line one\nline two"]]
        let csv = try fixtures.text("money.csv", CSV.write(rows, separator: ","))
        #expect(CSV.parse(try String(contentsOf: csv, encoding: .utf8), separator: ",") == rows)

        let xlsx = try await convert(csv, to: .xlsx, fixtures.context)
        let ods = try await convert(xlsx, to: .ods, fixtures.context)
        try FileManager.default.removeItem(at: csv)
        let back = try await convert(ods, to: .csv, fixtures.context)
        #expect(CSV.parse(try String(contentsOf: back, encoding: .utf8), separator: ",") == rows)

        let tsv = try await convert(xlsx, to: .tsv, fixtures.context)
        #expect(try String(contentsOf: tsv, encoding: .utf8).hasPrefix("Name\tAmount\tNote"))

        let pdf = try await convert(xlsx, to: .pdf, fixtures.context)
        #expect(PDFDocument(url: pdf)?.string?.contains("Snacks") == true)

        // ZIP code stays text, amount is a number.
        let book = try await XLSX.read(xlsx, scratch: try Scratch())
        #expect(book.sheets[0].rows[2][1] == "02134")
    }

    @Test func columnNames() {
        #expect(Spreadsheet.columnName(0) == "A")
        #expect(Spreadsheet.columnName(25) == "Z")
        #expect(Spreadsheet.columnName(26) == "AA")
        #expect(Spreadsheet.columnIndex(ofCell: "AB12") == 27)
    }

    // MARK: Subtitles

    @Test func subtitlesRoundTrip() async throws {
        let fixtures = try Fixtures(); defer { fixtures.remove() }
        let srt = try fixtures.text("talk.srt", "1\n00:00:01,000 --> 00:00:02,500\nHello <i>there</i>\n\n2\n00:01:02,040 --> 00:01:03,000\nBye\n")
        let vtt = try await convert(srt, to: .vtt, fixtures.context)
        let vttText = try String(contentsOf: vtt, encoding: .utf8)
        #expect(vttText.hasPrefix("WEBVTT"))
        #expect(vttText.contains("00:01:02.040 --> 00:01:03.000"))
        try FileManager.default.removeItem(at: srt)
        let back = try await convert(vtt, to: .srt, fixtures.context)
        #expect(Subtitles.parse(try String(contentsOf: back, encoding: .utf8)).count == 2)
        let text = try String(contentsOf: try await convert(vtt, to: .txt, fixtures.context), encoding: .utf8)
        #expect(text == "Hello there\nBye\n")
        #expect(Subtitles.milliseconds("02:03.456") == 123_456)
    }

    // MARK: Archives & any file

    @Test func archives() async throws {
        let fixtures = try Fixtures(); defer { fixtures.remove() }
        let folder = try fixtures.folder.appending(path: "Trip").create()
        try "a".write(to: folder.appending(path: "a.txt"), atomically: true, encoding: .utf8)
        try "b".write(to: folder.appending(path: "b [draft].txt"), atomically: true, encoding: .utf8)

        let zip = try await convert(folder, to: .zip, fixtures.context)
        #expect(zip.lastPathComponent == "Trip.zip")
        let tar = try await convert(zip, to: .tar, fixtures.context)
        #expect(tar.lastPathComponent == "Trip.tar")
        let tgz = try await convert(folder, to: .gzip, fixtures.context)
        #expect(tgz.lastPathComponent == "Trip.tar.gz")

        try FileManager.default.removeItem(at: folder)
        let extracted = try #require(try await Executor.run(.tool(.extract), inputs: [tgz], context: fixtures.context).files.first)
        #expect(extracted.lastPathComponent == "Trip")
        #expect(FileManager.default.fileExists(atPath: extracted.appending(path: "b [draft].txt").path))

        let lone = try fixtures.text("notes.txt", "hello")
        let gz = try await convert(lone, to: .gzip, fixtures.context)
        #expect(gz.lastPathComponent == "notes.txt.gz")

        let many = try await Executor.run(.tool(.zip), inputs: [lone, extracted], context: fixtures.context)
        #expect(many.files.first?.lastPathComponent == "Archive.zip")
    }

    @Test func checksum() async throws {
        let fixtures = try Fixtures(); defer { fixtures.remove() }
        let outcome = try await Executor.run(.tool(.checksum), inputs: [try fixtures.text("abc.txt", "abc")], context: fixtures.context)
        #expect(outcome.copied == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}

extension URL {
    func create() throws -> URL {
        try FileManager.default.createDirectory(at: self, withIntermediateDirectories: true)
        return self
    }
}
