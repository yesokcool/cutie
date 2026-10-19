import AppKit
import PDFKit
import Vision

/// PDF pages as images (300 DPI), as PowerPoint slides, and the PDF tools.
nonisolated enum PDFConverter {
    static func open(_ url: URL) throws -> PDFDocument {
        guard let document = PDFDocument(url: url) else { throw CutieError("Couldn't open this PDF.") }
        if document.isLocked { throw CutieError("This PDF is locked with a password.") }
        return document
    }

    /// One page drawn at `dpi` (capped at 10,000 px a side), rotation applied, on white.
    static func render(_ page: PDFPage, dpi: Double = 300) throws -> CGImage {
        let bounds = page.bounds(for: .mediaBox)
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
        page.draw(with: .mediaBox, to: context)
        guard let image = context.makeImage() else { throw CutieError("Couldn't draw this page.") }
        return image
    }

    /// Every page as `format` (JPG/PNG), written in `work`: one page → "name.png",
    /// more → a folder "name (PNG)" of numbered pages. Returns what it wrote.
    static func images(_ input: URL, as format: Format, in work: URL, context: JobContext) throws -> URL {
        let document = try open(input)
        let base = Output.baseName(of: input)
        if document.pageCount == 1, let page = document.page(at: 0) {
            let output = work.appending(path: "\(base).\(format.fileExtension)")
            try ImageConverter.write(try render(page), as: format, to: output, quality: context.imageQuality)
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
            try ImageConverter.write(try render(page), as: format, to: file, quality: context.imageQuality)
            context.progress(Double(index + 1) / Double(document.pageCount))
        }
        return output
    }

    /// Live Text over every page, for scans with no text layer.
    static func recognizedText(_ document: PDFDocument) throws -> String {
        var pages: [String] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            pages.append((try? ImageTools.recognizedText(try render(page, dpi: 200))) ?? "")
        }
        let text = pages.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw CutieError("This PDF has no text.") }
        return text
    }

    // MARK: - Tools

    /// Re-saves with images as JPEG, downsampled for screens.
    static func compress(_ input: URL, to output: URL) throws {
        let document = try open(input)
        let options: [PDFDocumentWriteOption: Any] = [.saveImagesAsJPEGOption: true, .optimizeImagesForScreenOption: true]
        guard document.write(to: output, withOptions: options) else { throw CutieError("Couldn't compress this PDF.") }
    }

    /// Each page as its own PDF in the folder `output`.
    static func split(_ input: URL, into output: URL, context: JobContext) throws {
        let document = try open(input)
        guard document.pageCount > 1 else { throw CutieError("This PDF has only one page.") }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let base = Output.baseName(of: input)
        let digits = String(document.pageCount).count
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index)?.copy() as? PDFPage else { continue }
            let single = PDFDocument()
            single.insert(page, at: 0)
            let number = String(format: "%0\(digits)d", index + 1)
            guard single.write(to: output.appending(path: "\(base) \(number).pdf")) else {
                throw CutieError("Couldn't save page \(index + 1).")
            }
            context.progress(Double(index + 1) / Double(document.pageCount))
        }
    }

    /// All pages of all inputs, in the order dropped.
    static func merge(_ inputs: [URL], to output: URL) throws {
        let merged = PDFDocument()
        for input in inputs {
            let document = try open(input)
            for index in 0..<document.pageCount {
                guard let page = document.page(at: index)?.copy() as? PDFPage else { continue }
                merged.insert(page, at: merged.pageCount)
            }
        }
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
}
