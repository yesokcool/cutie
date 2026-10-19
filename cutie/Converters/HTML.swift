import AppKit

/// Small HTML helpers shared by the document writers.
nonisolated enum HTML {
    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Any HTML, tidied into well-formed XHTML: the `<body>` contents and the page's `<style>` text.
    static func xhtmlBody(fromHTML html: String) -> (body: String, style: String) {
        guard let document = try? XMLDocument(xmlString: html, options: [.documentTidyHTML]) else {
            return ("<pre>" + escape(html) + "</pre>", "")
        }
        let body = (try? document.nodes(forXPath: "//*[local-name()='body']"))?.first as? XMLElement
        let inner = body?.children?.map(\.xmlString).joined(separator: "\n") ?? ""
        let style = (try? document.nodes(forXPath: "//*[local-name()='style']"))?
            .compactMap(\.stringValue).joined(separator: "\n") ?? ""
        return (inner, style)
    }

    /// A small, readable XHTML page. EPUB chapters need XHTML, so every page Cutie writes is.
    static func page(title: String, body: String, extraStyle: String = "") -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml">
        <head>
        <meta charset="utf-8"/>
        <title>\(escape(title))</title>
        <style>
        body { font-family: -apple-system, "Helvetica Neue", sans-serif; font-size: 12pt; line-height: 1.5; max-width: 42em; margin: 2em auto; padding: 0 1em; }
        pre, code { font-family: Menlo, monospace; font-size: 10.5pt; }
        pre { background: #f4f4f4; padding: 0.8em; white-space: pre-wrap; }
        blockquote { margin-left: 0; padding-left: 1em; border-left: 3px solid #ccc; color: #555; }
        table { border-collapse: collapse; }
        td, th { border: 1px solid #ccc; padding: 0.3em 0.6em; }
        img { max-width: 100%; }
        \(extraStyle)
        </style>
        </head>
        <body>
        \(body)
        </body>
        </html>
        """
    }
}
