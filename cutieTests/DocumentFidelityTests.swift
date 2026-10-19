import AppKit
import PDFKit
import Testing
@testable import cutie

/// Documents keep their structure and their print size: headings stay
/// headings, tables stay tables, footnotes, links and pictures survive, text
/// stays 12 pt and pages are the region's paper. The helper tests (pandoc,
/// LibreOffice) run only on a Mac that has them.
@Suite(.serialized)
struct DocumentFidelityTests {
    static let report = """
    # Field Report

    Intro paragraph with a [link](https://example.com/report) and a note.[^1]

    ## Results

    | Item | Count | Price |
    |:-----|:-----:|------:|
    | Apples | 3 | 1.50 |
    | Pears | 12 | 0.75 |

    ![Chart](chart.png)

    - First point
    - Second point

    [^1]: The footnote text lives here.
    """

    func reportMarkdown(_ fixtures: Fixtures) throws -> URL {
        _ = try fixtures.png("chart.png")
        return try fixtures.text("report.md", Self.report)
    }

    func context(_ toolbox: Toolbox) -> JobContext {
        JobContext(toolbox: toolbox, output: Output(location: .nextToOriginal), imageQuality: 0.85)
    }

    func convert(_ input: URL, to format: Format, _ toolbox: Toolbox) async throws -> URL {
        let outcome = try await Executor.run(.convert(format), inputs: [input], context: context(toolbox))
        #expect(outcome.failures.isEmpty)
        return try #require(outcome.files.first)
    }

    /// One file from inside a zip package (DOCX, ODT, EPUB, XLSX).
    func part(_ path: String, of package: URL) async throws -> String {
        try await Shell.run(URL(fileURLWithPath: "/usr/bin/unzip"), ["-p", package.path, path])
    }

    func listing(_ package: URL) async throws -> String {
        try await Shell.run(URL(fileURLWithPath: "/usr/bin/unzip"), ["-l", package.path])
    }

    static let detected = Toolbox.detect()

    // MARK: Without helpers

    @Test func markdownBodyIsTwelvePoint() async throws {
        let fixtures = try Fixtures(); defer { fixtures.remove() }
        let docx = try await convert(try reportMarkdown(fixtures), to: .docx, .none)
        let text = try NSAttributedString(url: docx, options: [:], documentAttributes: nil)
        #expect(Markdown.typicalFontSize(text) == 12)
    }

    @Test func htmlPrintSizesRoundTrip() async throws {
        let fixtures = try Fixtures(); defer { fixtures.remove() }
        let html = try fixtures.text("page.html", """
        <html><head><style>body { font-size: 12pt }</style></head>
        <body><p>Body text</p><p style="font-size: 24px">Big text</p></body></html>
        """)
        let docx = try await convert(html, to: .docx, .none)
        let text = try NSAttributedString(url: docx, options: [:], documentAttributes: nil)
        let string = text.string as NSString
        let body = text.attribute(.font, at: string.range(of: "Body").location, effectiveRange: nil) as? NSFont
        let big = text.attribute(.font, at: string.range(of: "Big").location, effectiveRange: nil) as? NSFont
        #expect(body?.pointSize == 12)
        #expect(big?.pointSize == 18) // 24 CSS px are 18 pt

        // And back out: 12 pt text is written as 12pt, not 12px (which browsers show smaller).
        try FileManager.default.removeItem(at: html)
        let page = try String(contentsOf: try await convert(docx, to: .html, .none), encoding: .utf8)
        #expect(page.contains("12pt"))
        #expect(!page.contains("12.0px") && !page.contains("12px"))
    }

    @Test func markdownHTMLKeepsRelativePicturesAndTableHeaders() async throws {
        let fixtures = try Fixtures(); defer { fixtures.remove() }
        let input = try reportMarkdown(fixtures)
        let html = try String(contentsOf: try await convert(input, to: .html, .none), encoding: .utf8)
        #expect(html.contains(#"src="chart.png""#))
        #expect(!html.contains("file://"))
        #expect(html.contains("<th>Item</th>"))
        #expect(html.contains(#"<td style="text-align: right">1.50</td>"#))
        #expect(html.contains(#"<th style="text-align: center">Count</th>"#))

        let epub = try await convert(input, to: .epub, .none)
        #expect(try await listing(epub).contains("OEBPS/images/1.png"))
    }

    @Test func pagesAreTheRegionsPaper() async throws {
        let fixtures = try Fixtures(); defer { fixtures.remove() }
        let input = try reportMarkdown(fixtures)
        let paper = PDFRenderer.paperSize

        let pdf = try #require(PDFDocument(url: try await convert(input, to: .pdf, .none)))
        let bounds = try #require(pdf.page(at: 0)).bounds(for: .mediaBox)
        #expect(abs(bounds.width - paper.width) < 1 && abs(bounds.height - paper.height) < 1)

        let docx = try await convert(input, to: .docx, .none)
        let xml = try await part("word/document.xml", of: docx)
        let width = try #require(xml.firstMatch(of: /<w:pgSz w:w="(\d+)"/).flatMap { Int($0.output.1) })
        #expect(abs(width - Int(paper.width * 20)) <= 2) // twentieths of a point
    }

    @Test func oversizedPicturesDontCutTheDocumentShort() throws {
        let fixtures = try Fixtures(); defer { fixtures.remove() }
        let tall = NSImage(size: CGSize(width: 800, height: 4000))
        let attachment = NSTextAttachment()
        attachment.image = tall
        let text = NSMutableAttributedString(string: "Before the picture\n", attributes: [.font: NSFont.systemFont(ofSize: 12)])
        text.append(NSAttributedString(attachment: attachment))
        text.append(NSAttributedString(string: "\nAfter the picture", attributes: [.font: NSFont.systemFont(ofSize: 12)]))
        let url = fixtures.url("tall.pdf")
        try PDFRenderer.render(text, to: url, title: "Tall")
        #expect(PDFDocument(url: url)?.string?.contains("After the picture") == true)
    }

    @Test func cssLengthsAreRewrittenOnlyInStyles() {
        let html = #"<style>p { margin: 16px }</style><p style="font-size: 12pt">Use 12px gaps</p>"#
        let rewritten = HTML.rewritingCSSLengths(in: html) { value, unit in "\(Int(value))\(unit == "pt" ? "A" : "B")" }
        #expect(rewritten == #"<style>p { margin: 16B }</style><p style="font-size: 12A">Use 12px gaps</p>"#)
    }

    // MARK: pandoc

    @Test func pandocKeepsWordStructure() async throws {
        guard let pandoc = Self.detected.pandoc else { return }
        let fixtures = try Fixtures(); defer { fixtures.remove() }
        let toolbox = Toolbox(pandoc: pandoc)
        let input = try reportMarkdown(fixtures)

        let docx = try await convert(input, to: .docx, toolbox)
        let xml = try await part("word/document.xml", of: docx)
        #expect(xml.contains(#"w:val="Heading1""#))
        #expect(xml.contains(#"w:val="Heading2""#))
        #expect(xml.contains("<w:tbl>"))
        #expect(xml.contains("<w:hyperlink"))
        #expect(try await part("word/footnotes.xml", of: docx).contains("The footnote text lives here."))
        #expect(try await listing(docx).contains("word/media/"))

        // Back to Markdown: pictures come along in a media folder.
        try FileManager.default.removeItem(at: input)
        let folder = try await convert(docx, to: .md, toolbox)
        #expect(folder.lastPathComponent == "report (Markdown)")
        let markdown = try String(contentsOf: folder.appending(path: "report.md"), encoding: .utf8)
        #expect(markdown.contains("# Field Report"))
        #expect(markdown.contains("## Results"))
        #expect(markdown.contains("| Apples"))
        #expect(markdown.contains("[^1]"))
        #expect(markdown.contains("(https://example.com/report)"))
        #expect(markdown.contains("](media/"))
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "media").path))
    }

    @Test func pandocMakesSelfContainedHTMLAndEPUB() async throws {
        guard let pandoc = Self.detected.pandoc else { return }
        let fixtures = try Fixtures(); defer { fixtures.remove() }
        let toolbox = Toolbox(pandoc: pandoc)
        let input = try reportMarkdown(fixtures)

        let html = try String(contentsOf: try await convert(input, to: .html, toolbox), encoding: .utf8)
        #expect(html.contains("<h1"))
        #expect(html.contains("<table"))
        #expect(html.contains("<th"))
        #expect(html.contains("data:image/png;base64"))
        #expect(html.contains("The footnote text lives here."))

        let epub = try await convert(input, to: .epub, toolbox)
        let files = try await listing(epub)
        #expect(files.contains(".png"))
        #expect(files.contains("mimetype"))

        let odt = try await convert(input, to: .odt, toolbox)
        let content = try await part("content.xml", of: odt)
        #expect(content.contains("<text:h"))
        #expect(content.contains("<table:table "))
    }

    // MARK: LibreOffice

    @Test func libreOfficeLaysOutWordFiles() async throws {
        guard let soffice = Self.detected.soffice else { return }
        let fixtures = try Fixtures(); defer { fixtures.remove() }
        let docx = try await convert(try reportMarkdown(fixtures), to: .docx, .none)
        let pdfURL = try await convert(docx, to: .pdf, Toolbox(soffice: soffice))
        let pdf = try #require(PDFDocument(url: pdfURL))
        #expect(pdf.pageCount >= 1)
        #expect(pdf.string?.contains("Field Report") == true)
        #expect(pdf.string?.contains("Apples") == true)
        let bounds = try #require(pdf.page(at: 0)).bounds(for: .mediaBox)
        let paper = PDFRenderer.paperSize
        #expect(abs(bounds.width - paper.width) < 2 && abs(bounds.height - paper.height) < 2)

        let odt = try await convert(docx, to: .odt, Toolbox(soffice: soffice))
        #expect(try await part("content.xml", of: odt).contains("Apples"))
    }

    /// A hand-made workbook: a formula (2 × 3) and a merged cell.
    func formulaWorkbook(_ fixtures: Fixtures) async throws -> URL {
        let root = try fixtures.folder.appending(path: "book").create()
        let parts: [String: String] = [
            "[Content_Types].xml": """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
            <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
            <Default Extension="xml" ContentType="application/xml"/>
            <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
            <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
            </Types>
            """,
            "_rels/.rels": """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
            <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
            </Relationships>
            """,
            "xl/workbook.xml": """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
            <sheets><sheet name="Totals" sheetId="1" r:id="rId1"/></sheets>
            </workbook>
            """,
            "xl/_rels/workbook.xml.rels": """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
            <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
            </Relationships>
            """,
            "xl/worksheets/sheet1.xml": """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
            <sheetData>
            <row r="1"><c r="A1"><v>2</v></c><c r="B1"><v>3</v></c><c r="C1"><f>A1*B1</f><v>6</v></c></row>
            <row r="3"><c r="A3" t="inlineStr"><is><t>Merged heading</t></is></c></row>
            </sheetData>
            <mergeCells count="1"><mergeCell ref="A3:B3"/></mergeCells>
            </worksheet>
            """,
        ]
        for (path, xml) in parts {
            let file = root.appending(path: path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try xml.write(to: file, atomically: true, encoding: .utf8)
        }
        let xlsx = fixtures.url("totals.xlsx")
        try await ArchiveConverter.zipContents(of: root, to: xlsx)
        return xlsx
    }

    @Test func libreOfficeKeepsFormulasAndMergedCells() async throws {
        guard let soffice = Self.detected.soffice else { return }
        let fixtures = try Fixtures(); defer { fixtures.remove() }
        let toolbox = Toolbox(soffice: soffice)
        let xlsx = try await formulaWorkbook(fixtures)

        let ods = try await convert(xlsx, to: .ods, toolbox)
        let content = try await part("content.xml", of: ods)
        #expect(content.contains(#"table:formula="of:=[.A1]*[.B1]""#))
        #expect(content.contains(#"table:number-columns-spanned="2""#))

        let pdf = try #require(PDFDocument(url: try await convert(xlsx, to: .pdf, toolbox)))
        #expect(pdf.string?.contains("Merged heading") == true)
        #expect(pdf.string?.contains("6") == true)
    }

    @Test func libreOfficeOpensSlidesWithoutKeynote() async throws {
        guard let soffice = Self.detected.soffice else { return }
        let fixtures = try Fixtures(); defer { fixtures.remove() }
        let toolbox = Toolbox(soffice: soffice)
        #expect(Catalog.conversions(for: [fixtures.url("a.pptx")], toolbox: toolbox) == [.pdf, .jpg, .png])
        #expect(Catalog.conversions(for: [fixtures.url("a.key")], toolbox: toolbox).isEmpty)
        #expect(!Catalog.conversions(for: [fixtures.url("a.xls")], toolbox: toolbox).isEmpty)

        let report = try await fixtures.pdf()
        let pages = try #require(PDFDocument(url: report)).pageCount
        let pptx = try await convert(report, to: .pptx, .none)
        try FileManager.default.removeItem(at: report)
        let slides = try #require(PDFDocument(url: try await convert(pptx, to: .pdf, toolbox)))
        #expect(slides.pageCount == pages)
        let pictures = try await convert(pptx, to: .png, toolbox)
        #expect(try FileManager.default.contentsOfDirectory(atPath: pictures.path).count == pages)
    }
}
