import AppKit
import PDFKit

/// Opens any text document as an attributed string. Main actor because
/// HTML import runs on WebKit, which must be on the main thread.
@MainActor
enum DocumentReader {
    static func read(_ url: URL, context: JobContext, scratch: Scratch) async throws -> NSAttributedString {
        let ext = FileKind.fileExtension(of: url)
        switch ext {
        case "md", "markdown":
            let text = try readText(url)
            let folder = url.deletingLastPathComponent()
            return try fromHTML(Markdown.htmlPage(from: text, title: Output.baseName(of: url), baseURL: folder), baseURL: folder)
        case "txt", "text":
            return plain(try readText(url))
        case "html", "htm":
            return try fromHTML(try readText(url), baseURL: url.deletingLastPathComponent())
        case "docx", "doc", "rtf", "rtfd", "odt", "webarchive":
            return try NSAttributedString(url: url, options: [.documentType: documentType(for: ext)], documentAttributes: nil)
        case "textclipping":
            return try textClipping(url)
        case "epub":
            let book = try await EPUB.read(url, scratch: scratch)
            return try fromHTML(book.html, baseURL: book.folder)
        case "pdf":
            return try await pdfText(url)
        case "pages":
            let docx = scratch.file(UUID().uuidString + ".docx")
            try await IWork.export(url, with: .pages, to: .docx, at: docx, toolbox: context.toolbox)
            return try NSAttributedString(url: docx, options: [.documentType: NSAttributedString.DocumentType.officeOpenXML], documentAttributes: nil)
        default:
            throw CutieError("Can't open .\(ext) documents.")
        }
    }

    static func documentType(for ext: String) -> NSAttributedString.DocumentType {
        switch ext {
        case "html", "htm": .html
        case "docx": .officeOpenXML
        case "doc": .docFormat
        case "rtf": .rtf
        case "rtfd": .rtfd
        case "odt": .openDocument
        case "webarchive": .webArchive
        default: .plain
        }
    }

    /// Cocoa's HTML import takes a CSS pixel for a point (and its default text
    /// is 12): a page's `font-size: 12pt` (16 px) came out as 16 pt. CSS lengths
    /// are rewritten first so print sizes survive: pt stay pt, px become ¾ pt.
    static func fromHTML(_ html: String, baseURL: URL?) throws -> NSAttributedString {
        let html = HTML.rewritingCSSLengths(in: html) { value, unit in
            HTML.cssNumber(unit == "pt" ? value : value * 0.75) + "px"
        }
        var options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue,
        ]
        if let baseURL { options[.baseURL] = baseURL }
        return try NSAttributedString(data: Data(html.utf8), options: options, documentAttributes: nil)
    }

    static func plain(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.black])
    }

    /// Any plain-text file, whatever its encoding (see `TextDecoding`).
    nonisolated static func readText(_ url: URL) throws -> String {
        try TextDecoding.read(url)
    }

    /// A Finder text clipping: a property list holding the text as RTF and/or plain text.
    static func textClipping(_ url: URL) throws -> NSAttributedString {
        let data = try Data(contentsOf: url)
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let items = plist["UTI-Data"] as? [String: Any] else {
            throw CutieError("Couldn't read this clipping.")
        }
        if let rtf = items["public.rtf"] as? Data,
           let text = try? NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) {
            return text
        }
        for key in ["public.utf8-plain-text", "public.utf16-plain-text", "public.plain-text"] {
            if let text = items[key] as? String { return plain(text) }
            if let data = items[key] as? Data, let text = String(data: data, encoding: key.contains("16") ? .utf16 : .utf8) {
                return plain(text)
            }
        }
        throw CutieError("This clipping has no text.")
    }

    /// Every page's text, pages separated by page breaks. Pages without text
    /// (scans, photos of pages) are read with Live Text, one by one, so a PDF
    /// mixing typed and scanned pages loses nothing.
    static func pdfText(_ url: URL) async throws -> NSAttributedString {
        let document = try PDFConverter.open(url)
        let result = NSMutableAttributedString()
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else { continue }
            if result.length > 0 { result.append(NSAttributedString(string: "\u{0C}")) }
            if let text = page.attributedString, !text.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.append(text)
            } else {
                result.append(plain(try await PDFConverter.text(of: page)))
            }
        }
        guard !result.string.trimmingCharacters(in: .whitespacesAndNewlines.union(["\u{0C}"])).isEmpty else {
            throw CutieError("This PDF has no text.")
        }
        return result
    }
}
