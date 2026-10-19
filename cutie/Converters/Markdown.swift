import AppKit

/// Markdown in and out. Reading uses Foundation's CommonMark parser
/// (`AttributedString(markdown:)`) and turns its block structure into HTML;
/// writing walks an attributed string's fonts, lists and links.
nonisolated enum Markdown {
    // MARK: - Markdown → HTML

    /// The `<body>` contents for a Markdown document.
    static func htmlBody(from markdown: String, baseURL: URL? = nil) -> String {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false, interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible)
        guard let document = try? AttributedString(markdown: markdown, options: options, baseURL: baseURL) else {
            return "<pre>" + HTML.escape(markdown) + "</pre>"
        }

        var html = ""
        var open: [PresentationIntent.IntentType] = []
        for run in document.runs {
            let path = Array((run.presentationIntent?.components ?? []).reversed())
            var shared = 0
            while shared < min(open.count, path.count), open[shared].identity == path[shared].identity { shared += 1 }
            for (index, block) in open.enumerated().dropFirst(shared).reversed() {
                html += closingTag(block.kind, in: open[..<index])
            }
            for (index, block) in path.enumerated().dropFirst(shared) {
                html += openingTag(block.kind, in: path[..<index])
            }
            open = path

            let text = String(document[run.range].characters)
            if path.last?.kind == .thematicBreak { continue }
            if case .codeBlock = path.first?.kind {
                html += HTML.escape(text)
                continue
            }
            html += inline(text, run: run)
        }
        for (index, block) in open.enumerated().reversed() { html += closingTag(block.kind, in: open[..<index]) }
        return html
    }

    /// A complete XHTML page (also what EPUB chapters use).
    static func htmlPage(from markdown: String, title: String, baseURL: URL? = nil) -> String {
        HTML.page(title: title, body: htmlBody(from: markdown, baseURL: baseURL))
    }

    private static func inline(_ text: String, run: AttributedString.Runs.Run) -> String {
        let intent = run.inlinePresentationIntent ?? []
        if intent.contains(.lineBreak) { return "<br/>" }
        if intent.contains(.softBreak) { return "\n" }
        if let image = run.imageURL {
            // As written ("photos/a.png"), so the page works wherever it's moved with its pictures.
            let source = image.baseURL == nil ? image.absoluteString : image.relativeString
            return "<img src=\"\(HTML.escape(source))\" alt=\"\(HTML.escape(text))\"/>"
        }
        var html = HTML.escape(text)
        if intent.contains(.code) { html = "<code>\(html)</code>" }
        if intent.contains(.emphasized) { html = "<em>\(html)</em>" }
        if intent.contains(.stronglyEmphasized) { html = "<strong>\(html)</strong>" }
        if intent.contains(.strikethrough) { html = "<del>\(html)</del>" }
        if let link = run.link { html = "<a href=\"\(HTML.escape(link.absoluteString))\">\(html)</a>" }
        return html
    }

    /// `outer` is the blocks this one sits in (outermost first), which decides
    /// whether a table cell is a header and how its column is aligned.
    private static func openingTag(_ kind: PresentationIntent.Kind, in outer: ArraySlice<PresentationIntent.IntentType>) -> String {
        switch kind {
        case .paragraph: "<p>"
        case .header(let level): "<h\(min(max(level, 1), 6))>"
        case .orderedList: "<ol>"
        case .unorderedList: "<ul>"
        case .listItem: "<li>"
        case .codeBlock: "<pre><code>"
        case .blockQuote: "<blockquote>"
        case .thematicBreak: "<hr/>"
        case .table: "<table>"
        case .tableHeaderRow, .tableRow: "<tr>"
        case .tableCell(let column): "<\(cellTag(in: outer))\(alignment(of: column, in: outer))>"
        @unknown default: ""
        }
    }

    private static func cellTag(in outer: ArraySlice<PresentationIntent.IntentType>) -> String {
        outer.contains { $0.kind == .tableHeaderRow } ? "th" : "td"
    }

    private static func alignment(of column: Int, in outer: ArraySlice<PresentationIntent.IntentType>) -> String {
        for block in outer.reversed() {
            guard case .table(let columns) = block.kind, columns.indices.contains(column) else { continue }
            switch columns[column].alignment {
            case .center: return " style=\"text-align: center\""
            case .right: return " style=\"text-align: right\""
            default: return ""
            }
        }
        return ""
    }

    private static func closingTag(_ kind: PresentationIntent.Kind, in outer: ArraySlice<PresentationIntent.IntentType>) -> String {
        switch kind {
        case .paragraph: "</p>\n"
        case .header(let level): "</h\(min(max(level, 1), 6))>\n"
        case .orderedList: "</ol>\n"
        case .unorderedList: "</ul>\n"
        case .listItem: "</li>\n"
        case .codeBlock: "</code></pre>\n"
        case .blockQuote: "</blockquote>\n"
        case .thematicBreak: "\n"
        case .table: "</table>\n"
        case .tableHeaderRow, .tableRow: "</tr>\n"
        case .tableCell: "</\(cellTag(in: outer))>"
        @unknown default: ""
        }
    }

    // MARK: - Attributed string → Markdown

    static func markdown(from text: NSAttributedString) -> String {
        let string = text.string as NSString
        let bodySize = typicalFontSize(text)
        var lines: [String] = []
        var inCode = false

        string.enumerateSubstrings(in: NSRange(location: 0, length: string.length), options: [.byParagraphs]) { _, range, _, _ in
            guard range.length > 0 else {
                if inCode { lines.append("```"); inCode = false }
                lines.append("")
                return
            }
            let paragraph = text.attributedSubstring(from: range)
            let style = paragraph.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
            let font = paragraph.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
            let monospaced = isMonospaced(paragraph)

            if monospaced {
                if !inCode { lines.append("```"); inCode = true }
                lines.append(paragraph.string)
                return
            }
            if inCode { lines.append("```"); inCode = false }

            if let lists = style?.textLists, let list = lists.last {
                let depth = String(repeating: "  ", count: max(0, lists.count - 1))
                let ordered = list.markerFormat.rawValue.contains("decimal")
                let content = inlineMarkdown(stripListMarker(paragraph))
                let marker = ordered ? "\(text.itemNumber(in: list, at: range.location)). " : "- "
                lines.append(depth + marker + content)
                return
            }
            // Word files come back with the bullet as plain text and no list attached.
            if let match = paragraph.string.firstMatch(of: /^(\t*)([•◦▪‣⁃–\-*]|\d+[.)])\t/) {
                let depth = String(repeating: "  ", count: max(0, match.1.count - 1))
                let marker = match.2.first?.isNumber == true ? "\(match.2.dropLast()). " : "- "
                let content = inlineMarkdown(paragraph.attributedSubstring(from: NSRange(location: match.0.utf16.count, length: paragraph.length - match.0.utf16.count)))
                lines.append(depth + marker + content)
                return
            }

            let content = inlineMarkdown(paragraph)
            if content.trimmingCharacters(in: .whitespaces).isEmpty { lines.append(""); return }
            let ratio = (font?.pointSize ?? bodySize) / max(bodySize, 1)
            let prefix = ratio >= 1.6 ? "# " : ratio >= 1.3 ? "## " : ratio >= 1.12 ? "### " : ""
            if !prefix.isEmpty {
                lines.append(prefix + paragraph.string.trimmingCharacters(in: .whitespaces))
            } else {
                lines.append(content)
            }
            lines.append("")
        }
        if inCode { lines.append("```") }

        // Collapse runs of blank lines, but keep list items together.
        var result: [String] = []
        for line in lines {
            if line.isEmpty, result.last?.isEmpty ?? true { continue }
            result.append(line)
        }
        return result.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    private static func inlineMarkdown(_ text: NSAttributedString) -> String {
        var markdown = ""
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, range, _ in
            var piece = escape((text.string as NSString).substring(with: range))
            guard !piece.trimmingCharacters(in: .whitespaces).isEmpty else { markdown += piece; return }
            let font = attributes[.font] as? NSFont
            let traits = font?.fontDescriptor.symbolicTraits ?? []
            // Keep surrounding spaces outside the markers (`** bold**` isn't bold in Markdown).
            let leading = String(piece.prefix { $0 == " " })
            let trailing = String(piece.reversed().prefix { $0 == " " })
            piece = piece.trimmingCharacters(in: .whitespaces)
            if traits.contains(.monoSpace) { piece = "`\(piece)`" } else {
                if traits.contains(.italic) { piece = "*\(piece)*" }
                if traits.contains(.bold) { piece = "**\(piece)**" }
            }
            if let strike = attributes[.strikethroughStyle] as? Int, strike != 0 { piece = "~~\(piece)~~" }
            if let link = attributes[.link] {
                let url = (link as? URL)?.absoluteString ?? (link as? String) ?? ""
                if !url.isEmpty { piece = "[\(piece)](\(url))" }
            }
            markdown += leading + piece + trailing
        }
        return markdown.replacingOccurrences(of: "\u{2028}", with: "  \n")
    }

    private static func escape(_ text: String) -> String {
        var escaped = ""
        for character in text {
            if "*_`[]\\".contains(character) { escaped.append("\\") }
            escaped.append(character)
        }
        return escaped
    }

    /// Imported lists carry their bullet as text ("\t•\tItem"); drop it.
    private static func stripListMarker(_ paragraph: NSAttributedString) -> NSAttributedString {
        let string = paragraph.string as NSString
        guard string.hasPrefix("\t") else { return paragraph }
        let second = string.range(of: "\t", options: [], range: NSRange(location: 1, length: string.length - 1))
        guard second.location != NSNotFound, second.location < 12 else { return paragraph }
        let start = second.location + 1
        return paragraph.attributedSubstring(from: NSRange(location: start, length: string.length - start))
    }

    private static func isMonospaced(_ paragraph: NSAttributedString) -> Bool {
        guard paragraph.length > 0 else { return false }
        var allMono = true
        paragraph.enumerateAttribute(.font, in: NSRange(location: 0, length: paragraph.length)) { value, _, stop in
            let font = value as? NSFont
            if !(font?.fontDescriptor.symbolicTraits.contains(.monoSpace) ?? false) { allMono = false; stop.pointee = true }
        }
        return allMono
    }

    /// The font size most of the text uses, so headings can be told apart.
    static func typicalFontSize(_ text: NSAttributedString) -> CGFloat {
        var counts: [CGFloat: Int] = [:]
        text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            let size = (value as? NSFont)?.pointSize ?? 12
            counts[size, default: 0] += range.length
        }
        return counts.max { $0.value < $1.value }?.key ?? 12
    }
}
