import AppKit

/// Writes an attributed string as any document format Cutie offers.
@MainActor
enum DocumentWriter {
    /// `html` is the document's own HTML when it has one (Markdown), which beats re-exporting.
    static func write(_ text: NSAttributedString, html: String? = nil, as format: Format, to url: URL,
                      title: String, context: JobContext, scratch: Scratch) async throws {
        let range = NSRange(location: 0, length: text.length)
        switch format {
        case .docx, .rtf, .odt:
            let type: NSAttributedString.DocumentType = format == .docx ? .officeOpenXML : format == .rtf ? .rtf : .openDocument
            let data = try text.data(from: range, documentAttributes: [.documentType: type, .title: title])
            try data.write(to: url)
        case .txt:
            try Data(text.string.replacingOccurrences(of: "\u{0C}", with: "\n\n").utf8).write(to: url)
        case .md:
            try Data(Markdown.markdown(from: text).utf8).write(to: url)
        case .html:
            try Data((html ?? xhtmlPage(from: text, title: title)).utf8).write(to: url)
        case .pdf:
            try PDFRenderer.render(text, to: url, title: title)
        case .epub:
            try await EPUB.write(title: title, xhtml: html ?? xhtmlPage(from: text, title: title), to: url, scratch: scratch)
        case .pages:
            let docx = scratch.file(UUID().uuidString + ".docx")
            try text.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
                .write(to: docx)
            try await IWork.export(docx, with: .pages, to: .pages, at: url, toolbox: context.toolbox)
        default:
            throw CutieError("Can't write \(format.title) documents.")
        }
    }

    /// A clean XHTML page from an attributed string (Cocoa's HTML, tidied, with its styles kept).
    static func xhtmlPage(from text: NSAttributedString, title: String) -> String {
        let range = NSRange(location: 0, length: text.length)
        guard let data = try? text.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.html]),
              let html = String(data: data, encoding: .utf8) else {
            return HTML.page(title: title, body: "<pre>" + HTML.escape(text.string) + "</pre>")
        }
        let (body, style) = HTML.xhtmlBody(fromHTML: html)
        return HTML.page(title: title, body: body, extraStyle: style)
    }
}
