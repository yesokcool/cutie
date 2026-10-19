import AppKit
import PDFKit
import Testing
@testable import cutie

/// PDF → Word rebuilds the document: headings, reflowed paragraphs, styles,
/// lists, tables, pictures, sections, header and footer. PDF → Excel finds tables.
@Suite(.serialized)
struct PDFToWordTests {
    /// Two pages: a bold system-font title, a paragraph drawn as three lines,
    /// red italic words, a ruled 3×3 table, bullets, a photo and page numbers;
    /// then a smaller heading, a paragraph and a numbered list.
    @MainActor
    func reportPDF(_ fixtures: Fixtures) throws -> URL {
        let url = fixtures.url("report.pdf")
        var media = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try #require(CGContext(url as CFURL, mediaBox: &media, nil))
        let body = try #require(NSFont(name: "Helvetica", size: 11))
        func draw(_ text: String, _ x: CGFloat, _ y: CGFloat, _ font: NSFont, _ color: NSColor = .black) {
            (text as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: [.font: font, .foregroundColor: color])
        }

        context.beginPDFPage(nil)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        draw("Quarterly Report", 72, 700, NSFont.boldSystemFont(ofSize: 24))
        let lines = ["This is the first line of a paragraph that wraps across",
                     "several lines in the original PDF, and should be joined",
                     "back into one paragraph when converted to Word."]
        for (index, line) in lines.enumerated() { draw(line, 72, 660 - CGFloat(index) * 14, body) }
        draw("Red words", 72, 610, try #require(NSFont(name: "Helvetica-Oblique", size: 11)), .red)
        context.setStrokeColor(NSColor.black.cgColor)
        context.setLineWidth(1)
        let (left, bottom, width, height): (CGFloat, CGFloat, CGFloat, CGFloat) = (72, 450, 120, 24)
        for row in 0...3 {
            context.move(to: CGPoint(x: left, y: bottom + CGFloat(row) * height))
            context.addLine(to: CGPoint(x: left + 3 * width, y: bottom + CGFloat(row) * height))
        }
        for column in 0...3 {
            context.move(to: CGPoint(x: left + CGFloat(column) * width, y: bottom))
            context.addLine(to: CGPoint(x: left + CGFloat(column) * width, y: bottom + 3 * height))
        }
        context.strokePath()
        for (row, cells) in [["Item", "Qty", "Price"], ["Apples", "3", "1.20"], ["Pears", "5", "2,400.50"]].enumerated() {
            for (column, text) in cells.enumerated() {
                draw(text, left + CGFloat(column) * width + 6, bottom + CGFloat(2 - row) * height + 7, body)
            }
        }
        draw("• First bullet item", 72, 400, body)
        draw("• Second bullet item", 72, 384, body)
        let photo = try #require(CGImageSourceCreateWithURL(fixtures.noisePhoto("photo.jpg", width: 400, height: 300) as CFURL, nil)
            .flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        context.draw(photo, in: CGRect(x: 72, y: 150, width: 200, height: 150))
        draw("1", 303, 40, body)
        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage()

        context.beginPDFPage(nil)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        draw("Second Section", 72, 700, try #require(NSFont(name: "Helvetica-Bold", size: 18)))
        draw("A short closing paragraph.", 72, 670, body)
        draw("1. Alpha", 72, 640, body)
        draw("2. Beta", 72, 624, body)
        draw("2", 303, 40, body)
        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage()
        context.closePDF()

        let document = try #require(PDFDocument(url: url))
        document.documentAttributes = [PDFDocumentAttribute.titleAttribute: "Quarterly Report"]
        document.write(to: url)
        return url
    }

    struct Package {
        let folder: URL
        func xml(_ path: String) throws -> String { try String(contentsOf: folder.appending(path: path), encoding: .utf8) }

        /// Each body paragraph's text and its XML.
        func paragraphs() throws -> [(text: String, xml: String)] {
            let document = try XMLDocument(contentsOf: folder.appending(path: "word/document.xml"))
            return try document.nodes(forXPath: "//*[local-name()='body']/*[local-name()='p']").map { node in
                (Package.text(of: node), node.xmlString)
            }
        }

        /// Rows of cell texts of every table.
        func tableRows() throws -> [[String]] {
            let document = try XMLDocument(contentsOf: folder.appending(path: "word/document.xml"))
            return try document.nodes(forXPath: "//*[local-name()='tr']").map { row in
                (row.children ?? []).filter { $0.localName == "tc" }.map(Package.text(of:))
            }
        }

        /// The `w:t` text under a node, walked by hand (relative XPath on a node leaks into its later siblings).
        static func text(of node: XMLNode) -> String {
            if node.localName == "t" { return node.stringValue ?? "" }
            return (node.children ?? []).map(text(of:)).joined()
        }
    }

    func unpack(_ docx: URL, _ fixtures: Fixtures) async throws -> Package {
        let folder = try fixtures.folder.appending(path: "unpacked-" + UUID().uuidString).create()
        try await ArchiveConverter.unzip(docx, into: folder)
        return Package(folder: folder)
    }

    func convert(_ input: URL, to format: Format, _ fixtures: Fixtures) async throws -> URL {
        let outcome = try await Executor.run(.convert(format), inputs: [input], context: fixtures.context)
        return try #require(outcome.files.first)
    }

    @Test func rebuildsTheDocument() async throws {
        let fixtures = try Fixtures(); defer { fixtures.remove() }
        let docx = try await convert(try reportPDF(fixtures), to: .docx, fixtures)
        let package = try await unpack(docx, fixtures)
        let paragraphs = try package.paragraphs()
        let document = try package.xml("word/document.xml")

        // Headings as heading styles, biggest first; the bold system font is seen as bold.
        let title = try #require(paragraphs.first { $0.text == "Quarterly Report" })
        #expect(title.xml.contains(#"w:val="Heading1""#))
        let second = try #require(paragraphs.first { $0.text == "Second Section" })
        #expect(second.xml.contains(#"w:val="Heading2""#))
        #expect(try package.xml("word/styles.xml").contains("<w:b/>"))

        // The three drawn lines are one paragraph again.
        #expect(paragraphs.contains { $0.text == "This is the first line of a paragraph that wraps across several lines in the original PDF, and should be joined back into one paragraph when converted to Word." }, "\(paragraphs.map(\.text))")

        // Colour and italic carried over.
        let red = try #require(paragraphs.first { $0.text == "Red words" })
        #expect(red.xml.contains("<w:i"))
        #expect(red.xml.contains(#"<w:color w:val="FF0000""#))

        // A real table: three rows, the cells' text in the right cells.
        #expect(document.components(separatedBy: "<w:tbl>").count == 2)
        #expect(document.components(separatedBy: "<w:tr>").count == 4)
        #expect(document.contains("tblBorders"))
        let rows = try package.tableRows()
        #expect(rows == [["Item", "Qty", "Price"], ["Apples", "3", "1.20"], ["Pears", "5", "2,400.50"]])
        #expect(!paragraphs.contains { $0.text.contains("Apples") })

        // Lists: bullets and numbers, markers turned into real numbering.
        let bullets = paragraphs.filter { $0.text.hasSuffix("bullet item") }
        #expect(bullets.count == 2)
        #expect(bullets.allSatisfy { $0.xml.contains("<w:numPr>") && !$0.text.contains("•") })
        let numbered = paragraphs.filter { ["Alpha", "Beta"].contains($0.text) }
        #expect(numbered.count == 2)
        let numbering = try package.xml("word/numbering.xml")
        #expect(numbering.contains(#"w:val="bullet""#) && numbering.contains(#"w:val="decimal""#))

        // The photo, as the JPEG it was in the PDF.
        let media = try FileManager.default.contentsOfDirectory(atPath: package.folder.appending(path: "word/media").path)
        #expect(media.contains { $0.hasSuffix(".jpeg") })
        #expect(document.contains("<wp:inline"))

        // One section per page (Letter), page numbers in the footer as a field.
        #expect(document.components(separatedBy: "<w:sectPr>").count == 3)
        #expect(document.contains(#"<w:pgSz w:w="12240" w:h="15840"/>"#))
        #expect(try package.xml("word/footer1.xml").contains("PAGE"))
        #expect(!paragraphs.contains { $0.text == "1" || $0.text == "2" })
        #expect(try package.xml("docProps/core.xml").contains("Quarterly Report"))

        // Other apps open it: Cocoa's Word reader, and Quick Look draws it.
        let text = try NSAttributedString(url: docx, options: [:], documentAttributes: nil).string
        #expect(text.contains("Quarterly Report") && text.contains("Apples") && text.contains("Second Section"))
        let thumbnails = try fixtures.folder.appending(path: "ql").create()
        try await Shell.run(URL(fileURLWithPath: "/usr/bin/qlmanage"), ["-t", "-s", "256", "-o", thumbnails.path, docx.path])
        #expect(try FileManager.default.contentsOfDirectory(atPath: thumbnails.path).count == 1)
    }

    @Test func chartsBecomePictures() async throws {
        let fixtures = try Fixtures(); defer { fixtures.remove() }
        let url = fixtures.url("chart.pdf")
        var media = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try #require(CGContext(url as CFURL, mediaBox: &media, nil))
        context.beginPDFPage(nil)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        ("Sales by region" as NSString).draw(at: CGPoint(x: 72, y: 700), withAttributes: [.font: NSFont(name: "Helvetica", size: 11)!])
        // A pie of four slices and a bar chart with axis labels.
        for (index, color) in [NSColor.red, .blue, .green, .orange].enumerated() {
            context.setFillColor(color.cgColor)
            context.move(to: CGPoint(x: 200, y: 500))
            context.addArc(center: CGPoint(x: 200, y: 500), radius: 80, startAngle: Double(index) * .pi / 2, endAngle: Double(index + 1) * .pi / 2, clockwise: false)
            context.fillPath()
            context.fill(CGRect(x: 340 + index * 40, y: 420, width: 28, height: 40 + index * 30))
            ("Q\(index + 1)" as NSString).draw(at: CGPoint(x: 344 + index * 40, y: 404), withAttributes: [.font: NSFont(name: "Helvetica", size: 8)!])
        }
        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage()
        context.closePDF()

        let package = try await unpack(try await convert(url, to: .docx, fixtures), fixtures)
        let pictures = try FileManager.default.contentsOfDirectory(atPath: package.folder.appending(path: "word/media").path)
        #expect(pictures.contains { $0.hasSuffix(".png") })
        let paragraphs = try package.paragraphs()
        #expect(paragraphs.contains { $0.text == "Sales by region" })
        #expect(!paragraphs.contains { $0.text.contains("Q3") })
    }

    @Test func scannedPagesAreRead() async throws {
        let fixtures = try Fixtures(); defer { fixtures.remove() }
        let docx = try await convert(try fixtures.scannedPDF(typedFirst: false), to: .docx, fixtures)
        let paragraphs = try await unpack(docx, fixtures).paragraphs()
        #expect(paragraphs.contains { $0.text.contains("Scanned page 1 says hello") })
        #expect(paragraphs.contains { $0.text.contains("Scanned page 2 says hello") })
    }

    @Test func tablesToExcel() async throws {
        let fixtures = try Fixtures(); defer { fixtures.remove() }
        let xlsx = try await convert(try reportPDF(fixtures), to: .xlsx, fixtures)
        let book = try await XLSX.read(xlsx, scratch: try Scratch())
        #expect(book.sheets.count == 1)
        #expect(book.sheets[0].rows == [["Item", "Qty", "Price"], ["Apples", "3", "1.20"], ["Pears", "5", "2400.50"]], "\(book.sheets[0].rows)")

        await #expect(throws: (any Error).self) {
            _ = try await Executor.run(.convert(.xlsx), inputs: [try fixtures.scannedPDF("plain.pdf")], context: fixtures.context)
        }
    }

    @Test func listMarkers() {
        func line(_ text: String) -> PDFPageLayout.Line {
            PDFPageLayout.Line(glyphs: text.map { PDFPageLayout.Glyph(text: String($0), frame: CGRect(x: 0, y: 0, width: 5, height: 10),
                                                                         style: .init(family: nil, size: 10)) })
        }
        #expect(PDFToWord.listMarker(line("• Apples"))?.kind == .bullet)
        #expect(PDFToWord.listMarker(line("3. Pears"))?.number == 3)
        #expect(PDFToWord.listMarker(line("b) Plums"))?.kind == .lowerLetter)
        #expect(PDFToWord.listMarker(line("iv. Figs"))?.number == 4)
        #expect(PDFToWord.listMarker(line("2024 was a year")) == nil)
        #expect(PDFToWord.listMarker(line("-5 degrees")) == nil)
        #expect(PDFToWord.spreadsheetValue("1,234.50") == "1234.50")
        #expect(PDFToWord.spreadsheetValue("02134") == "02134")
    }
}
