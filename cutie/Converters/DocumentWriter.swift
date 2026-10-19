import AppKit

/// Writes an attributed string as any document format Cutie offers.
@MainActor
enum DocumentWriter {
    /// `html` is the document's own HTML when it has one (Markdown), which beats
    /// re-exporting; `baseURL` is where its relative pictures are.
    static func write(_ text: NSAttributedString, html: String? = nil, baseURL: URL? = nil, as format: Format, to url: URL,
                      title: String, context: JobContext, scratch: Scratch) async throws {
        let range = NSRange(location: 0, length: text.length)
        switch format {
        case .docx, .rtf, .odt:
            let type: NSAttributedString.DocumentType = format == .docx ? .officeOpenXML : format == .rtf ? .rtf : .openDocument
            let data = try text.data(from: range, documentAttributes: pageAttributes.merging([.documentType: type, .title: title]) { $1 })
            try data.write(to: url)
        case .txt:
            try Data(text.string.replacingOccurrences(of: "\u{0C}", with: "\n\n").utf8).write(to: url)
        case .md:
            try Data(Markdown.markdown(from: text).utf8).write(to: url)
        case .html:
            try Data((html ?? xhtmlPage(from: text, title: title)).utf8).write(to: url)
        case .pdf:
            try await PDFRenderer.renderInBackground(text, to: url, title: title)
        case .epub:
            try await EPUB.write(title: title, xhtml: html ?? xhtmlPage(from: text, title: title), to: url,
                                 baseURL: html == nil ? nil : baseURL, scratch: scratch)
        case .pages:
            let docx = scratch.file(UUID().uuidString + ".docx")
            try text.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
                .write(to: docx)
            try await IWork.export(docx, with: .pages, to: .pages, at: url, toolbox: context.toolbox)
        default:
            throw CutieError("Can't write \(format.title) documents.")
        }
    }

    /// The region's paper (A4 or Letter) with one-inch margins, as Word and Pages default to.
    static var pageAttributes: [NSAttributedString.DocumentAttributeKey: Any] {
        [.paperSize: NSValue(size: PDFRenderer.paperSize), .leftMargin: 72.0, .rightMargin: 72.0, .topMargin: 72.0, .bottomMargin: 72.0]
    }

    /// A clean XHTML page from an attributed string (Cocoa's HTML, tidied, with its styles kept).
    static func xhtmlPage(from text: NSAttributedString, title: String) -> String {
        let range = NSRange(location: 0, length: text.length)
        guard let data = try? text.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.html]),
              let cocoa = String(data: data, encoding: .utf8) else {
            return HTML.page(title: title, body: "<pre>" + HTML.escape(text.string) + "</pre>")
        }
        // Cocoa writes point sizes with a px unit ("font: 12.0px"), which browsers show
        // a quarter smaller; they're points, so say so.
        let html = HTML.rewritingCSSLengths(in: cocoa) { value, _ in HTML.cssNumber(value) + "pt" }
        let (body, style) = HTML.xhtmlBody(fromHTML: html)
        return HTML.page(title: title, body: body, extraStyle: style)
    }
}
