import AppKit
import PDFKit
import Testing
@testable import cutie

/// Regressions from the 2026-10-19 code review: list markers on scanned
/// pages, page numbers, nested list formats, CSV/TSV through LibreOffice,
/// pandoc's titles, XLS without Numbers, lenient-but-honest damage checks,
/// and figure grouping on path-heavy pages.
@Suite(.serialized)
struct DocumentReviewTests {
    static let detected = Toolbox.detect()

    func context(_ toolbox: Toolbox) -> JobContext {
        JobContext(toolbox: toolbox, output: Output(location: .nextToOriginal), imageQuality: 0.85)
    }

    func convert(_ input: URL, to format: Format, _ toolbox: Toolbox = .none) async throws -> URL {
        let outcome = try await Executor.run(.convert(format), inputs: [input], context: context(toolbox))
        #expect(outcome.failures.isEmpty, "\(outcome.failures)")
        return try #require(outcome.files.first)
    }

    func part(_ path: String, of package: URL) async throws -> String {
        try await Shell.run(URL(fileURLWithPath: "/usr/bin/unzip"), ["-p", package.path, path])
    }

    /// Draws pages of text lines: (text, x, y, size) per page.
    @MainActor
    func textPDF(_ fixtures: Fixtures, _ name: String, pages: [[(String, CGFloat, CGFloat, CGFloat)]]) throws -> URL {
        let url = fixtures.url(name)
        var media = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try #require(CGContext(url as CFURL, mediaBox: &media, nil))
        for lines in pages {
            context.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            for (text, x, y, size) in lines {
                (text as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: [.font: NSFont(name: "Helvetica", size: size)!])
            }
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }

    // MARK: PDF → Word

    @Test func scannedLineMarkersAreStrippedByCharacter() {
        // Live Text gives a scanned page's whole line as one glyph.
        func scanned(_ text: String) -> PDFPageLayout.Line {
            PDFPageLayout.Line(glyphs: [PDFPageLayout.Glyph(text: text, frame: CGRect(x: 72, y: 600, width: 200, height: 12),
                                                            style: .init(family: nil, size: 11))])
        }
        let bullet = scanned("• Apples")
        let bulletMarker = try? #require(PDFToWord.listMarker(bullet))
        #expect(bulletMarker?.kind == .bullet)
        #expect(PDFToWord.dropping(bulletMarker?.length ?? 0, from: bullet).text == "Apples")

        let numbered = scanned("1. Apples and pears")
        let numberMarker = try? #require(PDFToWord.listMarker(numbered))
        #expect(numberMarker?.number == 1)
        let rest = PDFToWord.dropping(numberMarker?.length ?? 0, from: numbered)
        #expect(rest.text == "Apples and pears")
        #expect(rest.frame.minX > 72)
    }

    @Test func aYearInALetterheadIsNotAPageNumber() async throws {
        let fixtures = try Fixtures(); defer { fixtures.remove() }
        let letter = try textPDF(fixtures, "letter.pdf", pages: [[
            ("2025", 290, 760, 11),
            ("Dear reader, this letter has a year in its letterhead.", 72, 650, 11),
        ]])
        let docx = try await convert(letter, to: .docx)
        #expect(try await part("word/document.xml", of: docx).contains(">2025<"))
        let margins = try await part("word/header1.xml", of: docx) + part("word/footer1.xml", of: docx)
        #expect(!margins.contains("PAGE"))
    }

    @Test func pageNumbersCountWithThePages() async throws {
        let fixtures = try Fixtures(); defer { fixtures.remove() }
        // Numbered from 7 (front matter elsewhere), and a year that repeats but doesn't count.
        let pages = (0..<3).map { page in
            [("Body text on page \(page + 1).", CGFloat(72), CGFloat(650), CGFloat(11)),
             ("\(page + 7)", 300, 30, 11),
             ("2025", 290, 765, 9)]
        }
        let docx = try await convert(try textPDF(fixtures, "book.pdf", pages: pages), to: .docx)
        let body = try await part("word/document.xml", of: docx)
        #expect(!body.contains(">7<") && !body.contains(">8<") && !body.contains(">9<"))
        #expect(try await part("word/footer1.xml", of: docx).contains("PAGE"))
        let header = try await part("word/header1.xml", of: docx)
        #expect(header.contains("2025"))
        #expect(!header.contains("PAGE"))
    }

    @Test func nestedBulletsUnderNumbersStayBullets() async throws {
        let fixtures = try Fixtures(); defer { fixtures.remove() }
        let pdf = try textPDF(fixtures, "steps.pdf", pages: [[
            ("1. First step", 72, 650, 11),
            ("• detail one", 96, 634, 11),
            ("• detail two", 96, 618, 11),
            ("2. Second step", 72, 602, 11),
        ]])
        let docx = try await convert(pdf, to: .docx)
        let document = try await part("word/document.xml", of: docx)
        let numbering = try await part("word/numbering.xml", of: docx)
        // The detail paragraph's list and level → its abstract definition → that level's format.
        let paragraph = try #require(document.components(separatedBy: "<w:p>").first { $0.contains("detail one") })
        let numID = try #require(paragraph.firstMatch(of: /w:numId w:val="(\d+)"/)?.1)
        let level = try #require(paragraph.firstMatch(of: /w:ilvl w:val="(\d+)"/)?.1)
        #expect(level != "0")
        let num = try #require(numbering.firstMatch(of: try Regex(#"<w:num w:numId="\#(numID)"><w:abstractNumId w:val="(\d+)"/>"#)))
        let abstractID = try #require(num.output[1].substring)
        let abstract = try #require(numbering.components(separatedBy: "<w:abstractNum ").first { $0.hasPrefix(#"w:abstractNumId="\#(abstractID)""#) })
        let levelXML = try #require(abstract.components(separatedBy: "<w:lvl ").first { $0.hasPrefix(#"w:ilvl="\#(level)""#) })
        #expect(levelXML.contains(#"<w:numFmt w:val="bullet"/>"#))
        // The numbered level keeps its numbers.
        let first = try #require(abstract.components(separatedBy: "<w:lvl ").first { $0.hasPrefix(#"w:ilvl="0""#) })
        #expect(first.contains(#"<w:numFmt w:val="decimal"/>"#))
    }

    // MARK: LibreOffice and pandoc

    /// Where `word` sits on the PDF's first page.
    func position(of word: String, in pdf: PDFDocument) throws -> CGRect {
        let page = try #require(pdf.page(at: 0))
        let found = try #require(pdf.findString(word, withOptions: []).first)
        return found.bounds(for: page)
    }

    @Test func csvAndTSVReachLibreOfficeAsColumns() async throws {
        guard let soffice = Self.detected.soffice else { return }
        let fixtures = try Fixtures(); defer { fixtures.remove() }
        let toolbox = Toolbox(soffice: soffice)
        for (name, text) in [("prices.csv", "Name;Qty;Price\napple;37;1,50\npear;12;0,75\n"),
                             ("prices.tsv", "Name\tQty\tPrice\napple\t37\t1.50\npear\t12\t0.75\n")] {
            let input = try fixtures.text(name, text)
            let pdf = try #require(PDFDocument(url: try await convert(input, to: .pdf, toolbox)))
            #expect(pdf.string?.contains("apple;") == false, "\(name)")
            let apple = try position(of: "apple", in: pdf)
            let quantity = try position(of: "37", in: pdf)
            // Its own column: well to the right, on the same row.
            #expect(quantity.minX - apple.maxX > 20, "\(name)")
            #expect(abs(quantity.midY - apple.midY) < 4, "\(name)")
            try FileManager.default.removeItem(at: input)
        }
    }

    @Test func pandocAddsNoTitleTheSourceDidntHave() async throws {
        guard let pandoc = Self.detected.pandoc else { return }
        let fixtures = try Fixtures(); defer { fixtures.remove() }
        let toolbox = Toolbox(pandoc: pandoc)
        let input = try fixtures.text("report.md", "# Findings\n\nSome text.\n")

        let docx = try await convert(input, to: .docx, toolbox)
        #expect(!(try await part("word/document.xml", of: docx)).contains(#"w:val="Title""#))

        let html = try String(contentsOf: try await convert(input, to: .html, toolbox), encoding: .utf8)
        #expect(!html.contains(#"class="title""#))
        #expect(html.contains("<title>report</title>"))

        let epub = try await convert(input, to: .epub, toolbox)
        let listing = try await Shell.run(URL(fileURLWithPath: "/usr/bin/unzip"), ["-l", epub.path])
        #expect(!listing.contains("title_page"))
        #expect(try await part("EPUB/content.opf", of: epub).contains(">report<"))
    }

    @Test func xlsOpensWithLibreOfficeAlone() async throws {
        guard let soffice = Self.detected.soffice else { return }
        let fixtures = try Fixtures(); defer { fixtures.remove() }
        let csv = try fixtures.text("ledger.csv", "Item,Amount\nRent,1200\nFood,340\n")
        let xlsx = try await convert(csv, to: .xlsx)
        let folder = try fixtures.folder.appending(path: "xls").create()
        let profile = try fixtures.folder.appending(path: "profile").create()
        try await Shell.run(soffice, ["-env:UserInstallation=\(profile.absoluteString)", "--headless", "--norestore",
                                      "--convert-to", "xls", "--outdir", folder.path, xlsx.path])
        let xls = folder.appending(path: "ledger.xls")
        #expect(FileManager.default.fileExists(atPath: xls.path))
        // LibreOffice but no Numbers: CSV and TSV still come out.
        let toolbox = Toolbox(soffice: soffice)
        for format in [Format.csv, .tsv] {
            let text = try String(contentsOf: try await convert(xls, to: format, toolbox), encoding: .utf8)
            #expect(text.contains("Rent"), "\(format)")
            #expect(text.contains("1200"), "\(format)")
        }
    }

    // MARK: Damage checks

    @Test func paddingBetweenJPEGSegmentsIsNotDamage() throws {
        let fixtures = try Fixtures(); defer { fixtures.remove() }
        var bytes = [UInt8](try Data(contentsOf: fixtures.cameraJPEG()))
        // After the first segment, a few zero bytes before the next marker.
        let length = Int(bytes[4]) << 8 | Int(bytes[5])
        bytes.insert(contentsOf: [0, 0, 0, 0], at: 4 + length)
        #expect(!FileIntegrity.isTruncated(Data(bytes)))
        #expect(FileIntegrity.isTruncated(Data(bytes.prefix(bytes.count / 2))))
    }

    @Test func aGIFWithoutItsTrailerIsWholeButAHalfGIFIsNot() throws {
        let fixtures = try Fixtures(); defer { fixtures.remove() }
        let gif = try Data(contentsOf: fixtures.animatedGIF())
        #expect(!FileIntegrity.isTruncated(gif))
        #expect(gif.last == 0x3B)
        #expect(!FileIntegrity.isTruncated(gif.dropLast()))
        #expect(FileIntegrity.isTruncated(gif.prefix(gif.count / 2)))
    }

    // MARK: Figure grouping

    /// The pairwise merge the grid replaces, as the reference.
    func naiveGroups(_ frames: [CGRect], margin: Double) -> [[Int]] {
        var clusters = frames.enumerated().map { (frame: $0.element, members: [$0.offset]) }
        var merged = true
        while merged {
            merged = false
            var index = 0
            while index < clusters.count {
                var other = index + 1
                while other < clusters.count {
                    if clusters[index].frame.insetBy(dx: -margin, dy: -margin).intersects(clusters[other].frame) {
                        clusters[index].frame = clusters[index].frame.union(clusters[other].frame)
                        clusters[index].members += clusters[other].members
                        clusters.remove(at: other)
                        merged = true
                    } else {
                        other += 1
                    }
                }
                index += 1
            }
        }
        return clusters.map { $0.members.sorted() }.sorted { $0[0] < $1[0] }
    }

    @Test func figureGroupingMatchesThePairwiseMergeAndScales() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<20 {
            let frames = (0..<150).map { _ in
                CGRect(x: Double.random(in: 0...600, using: &generator), y: Double.random(in: 0...800, using: &generator),
                       width: Double.random(in: 1...40, using: &generator), height: Double.random(in: 1...40, using: &generator))
            }
            #expect(PDFPageLayout.touchingGroups(frames, margin: 16) == naiveGroups(frames, margin: 16))
        }
        // A page of 20,000 tiny marks (a scatter plot) groups in well under a second.
        let marks = (0..<20_000).map { index in
            CGRect(x: Double(index % 200) * 3, y: Double(index / 200) * 8, width: 1, height: 1)
        }
        let start = Date()
        let groups = PDFPageLayout.touchingGroups(marks, margin: 16)
        #expect(Date().timeIntervalSince(start) < 1)
        #expect(groups.count == 1)
    }
}
