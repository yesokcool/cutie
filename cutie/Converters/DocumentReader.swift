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
        case "html", "htm", "docx", "doc", "rtf", "rtfd", "odt", "webarchive":
            return try NSAttributedString(url: url, options: [.documentType: documentType(for: ext)], documentAttributes: nil)
        case "textclipping":
            return try textClipping(url)
        case "epub":
            let book = try await EPUB.read(url, scratch: scratch)
            return try fromHTML(book.html, baseURL: book.folder)
        case "pdf":
            return try pdfText(url)
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

    static func fromHTML(_ html: String, baseURL: URL?) throws -> NSAttributedString {
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

    /// UTF-8 first, then whatever encoding Foundation detects.
    nonisolated static func readText(_ url: URL) throws -> String {
        if let text = try? String(contentsOf: url, encoding: .utf8) { return text }
        var encoding = String.Encoding.utf8
        return try String(contentsOf: url, usedEncoding: &encoding)
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

    /// Every page's text, pages separated by page breaks.
    static func pdfText(_ url: URL) throws -> NSAttributedString {
        guard let document = PDFDocument(url: url) else { throw CutieError("Couldn't open this PDF.") }
        if document.isLocked { throw CutieError("This PDF is locked with a password.") }
        let result = NSMutableAttributedString()
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index), let text = page.attributedString else { continue }
            if result.length > 0 { result.append(NSAttributedString(string: "\u{0C}")) }
            result.append(text)
        }
        if result.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // A scan: read the pages with Live Text instead.
            let text = try PDFConverter.recognizedText(document)
            return plain(text)
        }
        return result
    }
}
