import AppKit
import CoreText
import PDFKit
import Quartz

/// PDF pages as images (300 DPI), as PowerPoint slides, and the PDF tools.
nonisolated enum PDFConverter {
    static func open(_ url: URL) throws -> PDFDocument {
        guard let document = PDFDocument(url: url) else { throw CutieError("Couldn't open this PDF.") }
        if document.isLocked { throw CutieError("This PDF is locked with a password.") }
        return document
    }

    /// One page drawn at `dpi` (capped at 10,000 px a side), rotation applied,
    /// on white. Only what's inside the crop box shows, as in every PDF viewer
    /// (printers' bleed and crop marks stay out).
    static func render(_ page: PDFPage, dpi: Double = 300) throws -> CGImage {
        let (image, _) = try renderWithScale(page, dpi: dpi)
        return image
    }

    private static func renderWithScale(_ page: PDFPage, dpi: Double) throws -> (CGImage, Double) {
        let bounds = page.bounds(for: .cropBox)
        let quarterTurns = ((page.rotation % 360) + 360) % 360 / 90
        let size = quarterTurns % 2 == 0 ? bounds.size : CGSize(width: bounds.height, height: bounds.width)
        let scale = min(dpi / 72, 10_000 / max(size.width, size.height, 1))
        let width = max(1, Int(size.width * scale)), height = max(1, Int(size.height * scale))
        guard let context = ImageConverter.bitmapContext(width: width, height: height, alpha: false) else {
            throw CutieError("Couldn't draw this page.")
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .cropBox, to: context)
        guard let image = context.makeImage() else { throw CutieError("Couldn't draw this page.") }
        return (image, scale)
    }

    /// Every page as `format` (JPG/PNG), written in `work`: one page → "name.png",
    /// more → a folder "name (PNG)" of numbered pages. Returns what it wrote.
    static func images(_ input: URL, as format: Format, in work: URL, context: JobContext) throws -> URL {
        let document = try open(input)
        let base = Output.baseName(of: input)
        let dpi = CGSize(width: 300, height: 300)
        if document.pageCount == 1, let page = document.page(at: 0) {
            let output = work.appending(path: "\(base).\(format.fileExtension)")
            try ImageConverter.write(try render(page), as: format, to: output, quality: context.imageQuality, dpi: dpi)
            return output
        }
        let output = work.appending(path: "\(base) (\(format.title))", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let digits = String(document.pageCount).count
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else { continue }
            let number = String(format: "%0\(digits)d", index + 1)
            let file = output.appending(path: "\(base) \(number).\(format.fileExtension)")
            try ImageConverter.write(try render(page), as: format, to: file, quality: context.imageQuality, dpi: dpi)
            context.progress(Double(index + 1) / Double(document.pageCount))
        }
        return output
    }

    /// A page's own text, or Live Text's reading of it when it has none (a scan).
    static func text(of page: PDFPage) async throws -> String {
        if let text = page.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
        return (try? await ImageTools.recognizedText(try render(page))) ?? ""
    }

    // MARK: - Tools

    /// Images re-compressed for screens (150 DPI, good JPEG quality). Uses
    /// Ghostscript when it's installed (what most PDF compressors use),
    /// otherwise macOS's own PDF filter. Bookmarks, links and the title stay.
    static func compress(_ input: URL, to output: URL, toolbox: Toolbox) async throws {
        let document = try open(input)
        if let ghostscript = toolbox.ghostscript {
            try await Shell.run(ghostscript, [
                "-q", "-dSAFER", "-dBATCH", "-dNOPAUSE", "-sDEVICE=pdfwrite", "-dCompatibilityLevel=1.7",
                "-dPDFSETTINGS=/ebook", "-dDetectDuplicateImages=true", "-sOutputFile=\(output.path)", input.path,
            ])
        } else {
            let settings: [String: Any] = [
                "Compression Quality": 0.75, "ImageCompression": "ImageJPEGCompress",
                "ImageScaleSettings": ["ImageResolution": 150, "ImageScaleInterpolate": true, "ImageSizeMax": 3000, "ImageSizeMin": 0],
            ]
            let filter = QuartzFilter(properties: [
                "Name": "Cutie", "FilterType": 1, "Domains": ["Applications": true],
                "FilterData": ["ColorSettings": ["ImageSettings": settings]],
            ])
            guard let filter, document.write(to: output, withOptions: [PDFDocumentWriteOption(rawValue: "QuartzFilter"): filter]) else {
                throw CutieError("Couldn't compress this PDF.")
            }
            // The filter drops bookmarks; put them back.
            if document.outlineRoot != nil {
                let result = rebuilt(try open(output))
                result.outlineRoot = copiedOutline(document.outlineRoot, from: document) { result.page(at: $0) }
                guard result.write(to: output) else { throw CutieError("Couldn't compress this PDF.") }
            }
        }
        let before = fileSize(input), after = fileSize(output)
        if after == 0 || Double(after) > Double(before) * 0.98 {
            throw CutieError("This PDF is already as small as it gets.")
        }
    }

    /// Each page as its own PDF in the folder `output`, with the document's title and author.
    static func split(_ input: URL, into output: URL, context: JobContext) throws {
        let document = try open(input)
        guard document.pageCount > 1 else { throw CutieError("This PDF has only one page.") }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let base = Output.baseName(of: input)
        let digits = String(document.pageCount).count
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: index)?.copy() as? PDFPage else { continue }
            let single = PDFDocument()
            single.insert(page, at: 0)
            single.documentAttributes = document.documentAttributes
            let number = String(format: "%0\(digits)d", index + 1)
            guard single.write(to: output.appending(path: "\(base) \(number).pdf")) else {
                throw CutieError("Couldn't save page \(index + 1).")
            }
            context.progress(Double(index + 1) / Double(document.pageCount))
        }
    }

    /// All pages of all inputs, in the order dropped. Each file gets a
    /// bookmark holding its own bookmarks; the first file's title and author carry over.
    static func merge(_ inputs: [URL], to output: URL) throws {
        let merged = PDFDocument()
        let root = PDFOutline()
        for input in inputs {
            let document = try open(input)
            if merged.pageCount == 0 { merged.documentAttributes = document.documentAttributes }
            let start = merged.pageCount
            for index in 0..<document.pageCount {
                guard let page = document.page(at: index)?.copy() as? PDFPage else { continue }
                merged.insert(page, at: merged.pageCount)
            }
            guard let first = merged.page(at: start) else { continue }
            let item = copiedOutline(document.outlineRoot, from: document) { merged.page(at: start + $0) } ?? PDFOutline()
            item.label = Output.baseName(of: input)
            item.destination = PDFDestination(page: first, at: CGPoint(x: 0, y: first.bounds(for: .cropBox).maxY))
            root.insertChild(item, at: root.numberOfChildren)
        }
        merged.outlineRoot = root
        guard merged.write(to: output) else { throw CutieError("Couldn't save the merged PDF.") }
    }

    /// Every page a quarter turn clockwise.
    static func rotate(_ input: URL, to output: URL) throws {
        let document = try open(input)
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            page.rotation = (page.rotation + 90) % 360
        }
        guard document.write(to: output) else { throw CutieError("Couldn't save the rotated PDF.") }
    }

    /// Adds an invisible text layer (Live Text's reading) to every page that
    /// has no text, so a scanned PDF can be searched, selected and copied.
    /// The pages themselves are copied untouched.
    static func makeSearchable(_ input: URL, to output: URL, context: JobContext) async throws {
        let document = try open(input)
        guard let source = CGPDFDocument(input as CFURL) else { throw CutieError("Couldn't open this PDF.") }
        guard let pdf = CGContext(output as CFURL, mediaBox: nil, nil) else { throw CutieError("Couldn't create the PDF.") }
        var readPages = 0
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: index), let original = source.page(at: index + 1) else { continue }
            var info: [CFString: Any] = [:]
            for (key, box) in [(kCGPDFContextMediaBox, CGPDFBox.mediaBox), (kCGPDFContextCropBox, .cropBox),
                               (kCGPDFContextBleedBox, .bleedBox), (kCGPDFContextTrimBox, .trimBox), (kCGPDFContextArtBox, .artBox)] {
                var rect = original.getBoxRect(box)
                info[key] = Data(bytes: &rect, count: MemoryLayout<CGRect>.size) as CFData
            }
            pdf.beginPDFPage(info as CFDictionary)
            pdf.drawPDFPage(original)
            if (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let lines = try await textLines(on: page)
                drawInvisible(lines, in: pdf)
                if !lines.isEmpty { readPages += 1 }
            }
            pdf.endPDFPage()
            context.progress(Double(index + 1) / Double(document.pageCount))
        }
        pdf.closePDF()
        guard readPages > 0 else { throw CutieError("This PDF is already searchable (or has no text to read).") }

        // Drawing copies only what's printed: put back rotation, links, notes, bookmarks and the title.
        let result = rebuilt(try open(output))
        for index in 0..<min(result.pageCount, document.pageCount) {
            guard let page = result.page(at: index), let old = document.page(at: index) else { continue }
            page.rotation = old.rotation
            for annotation in old.annotations {
                guard let copy = annotation.copy() as? PDFAnnotation else { continue }
                if let destination = annotation.destination, let target = destination.page.map(document.index(for:)),
                   let mapped = result.page(at: target) {
                    copy.destination = PDFDestination(page: mapped, at: destination.point)
                }
                page.addAnnotation(copy)
            }
        }
        result.outlineRoot = copiedOutline(document.outlineRoot, from: document) { result.page(at: $0) }
        result.documentAttributes = document.documentAttributes
        guard result.write(to: output) else { throw CutieError("Couldn't save the searchable PDF.") }
    }

    /// Live Text's lines on a page, each as four corners in the page's own
    /// (unrotated) coordinates: bottom left, bottom right, top right, top left.
    private static func textLines(on page: PDFPage) async throws -> [(text: String, corners: [CGPoint])] {
        let (image, scale) = try renderWithScale(page, dpi: 300)
        let size = CGSize(width: image.width, height: image.height)
        // Rendering mapped page space through the page's transform (rotation) and then `scale`.
        let toPage = page.transform(for: .cropBox).inverted()
        return try await ImageTools.recognizedLines(image).map { line in
            (line.text, line.corners.map { corner in
                CGPoint(x: corner.x * size.width / scale, y: corner.y * size.height / scale).applying(toPage)
            })
        }
    }

    private static func drawInvisible(_ lines: [(text: String, corners: [CGPoint])], in pdf: CGContext) {
        for line in lines where line.corners.count == 4 && !line.text.isEmpty {
            let (bottomLeft, bottomRight, topLeft) = (line.corners[0], line.corners[1], line.corners[3])
            let width = hypot(bottomRight.x - bottomLeft.x, bottomRight.y - bottomLeft.y)
            let height = hypot(topLeft.x - bottomLeft.x, topLeft.y - bottomLeft.y)
            guard width > 1, height > 1 else { continue }
            let font = CTFontCreateWithName("Helvetica" as CFString, height / 1.2, nil)
            let attributed = NSAttributedString(string: line.text, attributes: [.font: font])
            let ctLine = CTLineCreateWithAttributedString(attributed)
            let natural = CTLineGetTypographicBounds(ctLine, nil, nil, nil)
            guard natural > 0 else { continue }
            pdf.saveGState()
            pdf.setTextDrawingMode(.invisible)
            pdf.translateBy(x: bottomLeft.x, y: bottomLeft.y)
            pdf.rotate(by: atan2(bottomRight.y - bottomLeft.y, bottomRight.x - bottomLeft.x))
            pdf.scaleBy(x: width / natural, y: 1)
            pdf.textMatrix = .identity
            pdf.textPosition = CGPoint(x: 0, y: CTFontGetDescent(font))
            CTLineDraw(ctLine, pdf)
            pdf.restoreGState()
        }
    }

    // MARK: - Helpers

    /// The same pages in a new document. PDFKit (macOS 27) only saves an
    /// outline set on a document it built itself; one opened from a file
    /// writes without it. So bookmarks are always added to a rebuilt document.
    static func rebuilt(_ document: PDFDocument) -> PDFDocument {
        let fresh = PDFDocument()
        for index in 0..<document.pageCount {
            if let page = document.page(at: index)?.copy() as? PDFPage { fresh.insert(page, at: fresh.pageCount) }
        }
        fresh.documentAttributes = document.documentAttributes
        return fresh
    }

    /// A copy of `outline`'s items pointing at pages of another document
    /// (`page(index)` maps the old page index to the new page).
    static func copiedOutline(_ outline: PDFOutline?, from document: PDFDocument, page: (Int) -> PDFPage?) -> PDFOutline? {
        guard let outline else { return nil }
        let copy = PDFOutline()
        copy.label = outline.label
        copy.isOpen = outline.isOpen
        let destination = outline.destination ?? (outline.action as? PDFActionGoTo)?.destination
        if let destination, let old = destination.page, let mapped = page(document.index(for: old)) {
            copy.destination = PDFDestination(page: mapped, at: destination.point)
        } else if let action = outline.action, !(action is PDFActionGoTo) {
            copy.action = action
        }
        for index in 0..<outline.numberOfChildren {
            if let child = copiedOutline(outline.child(at: index), from: document, page: page) {
                copy.insertChild(child, at: copy.numberOfChildren)
            }
        }
        return copy
    }

    static func fileSize(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }
}
