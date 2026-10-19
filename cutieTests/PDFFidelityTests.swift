import AppKit
import ImageIO
import PDFKit
import Testing
@testable import cutie

/// PDFs keep what makes them PDFs: crop boxes, bookmarks, links, titles;
/// scans get read; compression actually compresses.
@Suite(.serialized)
struct PDFFidelityTests {
    func run(_ item: WheelItem, _ inputs: [URL], _ context: JobContext) async throws -> URL {
        let outcome = try await Executor.run(item, inputs: inputs, context: context)
        return try #require(outcome.files.first)
    }

    @Test func pagesRenderTheirCropBox() async throws {
        let fixtures = try Fixtures(); defer { fixtures.remove() }
        let folder = try await run(.convert(.png), [try fixtures.printPDF()], fixtures.context)
        let first = try #require(try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .sorted { $0.path < $1.path }.first)
        let source = try #require(CGImageSourceCreateWithURL(first as CFURL, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 2550)
        #expect(properties[kCGImagePropertyPixelHeight] as? Int == 3300)
        #expect(properties[kCGImagePropertyDPIWidth] as? Double == 300)
    }

    @Test func mergeKeepsBookmarksAndTitle() async throws {
        let fixtures = try Fixtures(); defer { fixtures.remove() }
        let inputs = [try fixtures.printPDF("first.pdf"), try fixtures.printPDF("second.pdf")]
        let merged = try #require(PDFDocument(url: try await run(.tool(.mergePDFs), inputs, fixtures.context)))
        #expect(merged.pageCount == 6)
        let root = try #require(merged.outlineRoot)
        #expect(root.numberOfChildren == 2)
        #expect(root.child(at: 0)?.label == "first")
        #expect(root.child(at: 1)?.label == "second")
        #expect(root.child(at: 1)?.numberOfChildren == 3)
        let chapter = try #require(root.child(at: 1)?.child(at: 2)?.destination?.page)
        #expect(merged.index(for: chapter) == 5)
        #expect(merged.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String == "Brochure")
    }

    @Test func splitKeepsTheTitle() async throws {
        let fixtures = try Fixtures(); defer { fixtures.remove() }
        let folder = try await run(.tool(.splitPDF), [try fixtures.printPDF()], fixtures.context)
        let pages = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        #expect(pages.count == 3)
        let firstPage = try #require(pages.first)
        let page = try #require(PDFDocument(url: firstPage))
        #expect(page.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String == "Test Author")
    }

    @Test func compressionShrinksPhotosAndKeepsStructure() async throws {
        let fixtures = try Fixtures(); defer { fixtures.remove() }
        let input = try fixtures.printPDF(photo: fixtures.noisePhoto())
        let output = try await run(.tool(.compressPDF), [input], fixtures.context)
        #expect(PDFConverter.fileSize(output) < PDFConverter.fileSize(input) * 3 / 4)
        let document = try #require(PDFDocument(url: output))
        #expect(document.outlineRoot?.numberOfChildren == 3)
        #expect(document.page(at: 0)?.annotations.contains { $0.url != nil } == true)

        // Nothing to squeeze: say so instead of handing back a copy.
        let plain = try fixtures.printPDF("plain.pdf")
        await #expect(throws: (any Error).self) {
            _ = try await Executor.run(.tool(.compressPDF), inputs: [plain], context: fixtures.context)
        }
    }

    @Test func ghostscriptCompression() async throws {
        let fixtures = try Fixtures(); defer { fixtures.remove() }
        let context = fixtures.fullContext
        guard context.toolbox.ghostscript != nil else { return }
        let input = try fixtures.printPDF(photo: fixtures.noisePhoto())
        let output = try await run(.tool(.compressPDF), [input], context)
        #expect(PDFConverter.fileSize(output) < PDFConverter.fileSize(input) / 2)
        let document = try #require(PDFDocument(url: output))
        #expect(document.pageCount == 3)
        #expect(document.outlineRoot?.numberOfChildren == 3)
        #expect(document.string?.contains("Chapter 2 heading") == true)
    }

    @Test func scannedPagesAreReadPageByPage() async throws {
        let fixtures = try Fixtures(); defer { fixtures.remove() }
        let text = try String(contentsOf: try await run(.convert(.txt), [try fixtures.scannedPDF()], fixtures.context), encoding: .utf8)
        #expect(text.contains("Typed first page"))
        #expect(text.contains("Scanned page 2"))
    }

    @Test func makeSearchableAddsAHiddenTextLayer() async throws {
        let fixtures = try Fixtures(); defer { fixtures.remove() }
        let input = try fixtures.scannedPDF(typedFirst: false)
        let output = try await run(.tool(.makeSearchable), [input], fixtures.context)
        #expect(output.lastPathComponent == "scan searchable.pdf")
        let document = try #require(PDFDocument(url: output))
        #expect(document.pageCount == 2)
        let page = try #require(document.page(at: 1))
        #expect(page.string?.contains("Scanned page 2") == true)
        // The hidden words sit where the picture shows them (top left area of the page).
        let hello = try #require(document.findString("hello", withOptions: .caseInsensitive).first { $0.pages.first == page })
        let bounds = hello.bounds(for: page)
        #expect(bounds.minY > 792 / 2)
        #expect(bounds.minX > 72 && bounds.maxX < 612)

        // A PDF that already has text has nothing to add.
        await #expect(throws: (any Error).self) {
            _ = try await Executor.run(.tool(.makeSearchable), inputs: [try fixtures.printPDF()], context: fixtures.context)
        }
    }

    @Test func makeSearchableHandlesTurnedPages() async throws {
        let fixtures = try Fixtures(); defer { fixtures.remove() }
        let input = try fixtures.scannedPDF("turned.pdf", typedFirst: false, turned: true)
        let document = try #require(PDFDocument(url: try await run(.tool(.makeSearchable), [input], fixtures.context)))
        let page = try #require(document.page(at: 0))
        #expect(page.rotation == 90)
        #expect(page.string?.contains("Scanned page 1") == true)
    }
}
