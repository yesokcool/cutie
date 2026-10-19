import AppKit
import PDFKit

/// PDF → Word that rebuilds the document instead of dumping its text:
/// paragraphs reflowed, headings as heading styles, bulleted and numbered
/// lists, tables as tables, pictures and charts in place, fonts, sizes and
/// colours from the PDF, page size and margins per page, running headers and
/// page numbers moved to the header and footer. Scanned pages are read with
/// Live Text. Also PDF → Excel: every table found, one sheet each.
nonisolated enum PDFToWord {
    static func write(from input: URL, to output: URL, context: JobContext, scratch: Scratch) async throws {
        let (document, layouts) = try await read(input, context: context)
        try await build(layouts, from: document).write(to: output, scratch: scratch)
    }

    static func writeTables(from input: URL, to output: URL, context: JobContext, scratch: Scratch) async throws {
        let (_, layouts) = try await read(input, context: context)
        var sheets: [Workbook.Sheet] = []
        for (pageIndex, layout) in layouts.enumerated() {
            for (tableIndex, table) in layout.tables.enumerated() {
                let rows = table.cells.map { row in
                    // Typed as Excel would type them: "2,400.50" is a number shown with its grouping.
                    row.map { cell in cell.covered ? "" : cell.lines.map(\.text).joined(separator: " ") }
                }
                let suffix = layout.tables.count > 1 ? " (\(tableIndex + 1))" : ""
                sheets.append(.init(name: "Page \(pageIndex + 1)\(suffix)", text: rows))
            }
        }
        guard !sheets.isEmpty else { throw CutieError("No tables found in this PDF.") }
        try await XLSX.write(Workbook(sheets: sheets), to: output, scratch: scratch)
    }

    private static func read(_ input: URL, context: JobContext) async throws -> (PDFDocument, [PDFPageLayout]) {
        let document = try PDFConverter.open(input)
        guard let pdf = CGPDFDocument(input as CFURL) else { throw CutieError("Couldn't open this PDF.") }
        var layouts: [PDFPageLayout] = []
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: index), let cgPage = pdf.page(at: index + 1) else { continue }
            layouts.append(try await PDFPageLayout.read(page, cgPage: cgPage))
            context.progress(Double(index + 1) / Double(document.pageCount) * 0.9)
        }
        return (document, layouts)
    }

    // MARK: - Building the document

    typealias Line = PDFPageLayout.Line
    typealias Glyph = PDFPageLayout.Glyph

    static func build(_ layouts: [PDFPageLayout], from source: PDFDocument) -> WordDocument {
        var layouts = layouts
        var word = WordDocument()
        word.title = source.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String
        word.author = source.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String
        (word.header, word.footer) = moveMarginals(&layouts)

        // The body text's look: the most common font and size.
        var counts: [WordDocument.TextStyle: Int] = [:]
        for layout in layouts {
            for line in layout.lines {
                for glyph in line.glyphs where !glyph.isSpace {
                    counts[WordDocument.TextStyle(family: glyph.style.family, size: glyph.style.size), default: 0] += 1
                }
            }
        }
        word.body = counts.max { $0.value < $1.value }?.key ?? WordDocument.TextStyle(family: "Helvetica Neue", size: 11)
        if word.body.family == nil { word.body.family = "Helvetica Neue" }

        var drafts: [[Draft]] = []
        var listCounter = 0
        for layout in layouts {
            drafts.append(paragraphs(layout.lines, body: word.body, lists: &listCounter))
        }
        let levels = headingLevels(drafts.flatMap { $0 }, body: word.body)
        word.headings = levels.styles

        for (index, layout) in layouts.enumerated() {
            word.pages.append(page(layout, drafts: drafts[index], body: word.body, headings: levels.level))
        }
        return word
    }

    // MARK: Paragraphs

    /// A paragraph before it's styled: its lines, and list information.
    struct Draft {
        var lines: [Line]
        var list: WordDocument.ListItem?
        /// Where the text starts after a list marker.
        var textStart: Double?
        /// Indices of lines that follow a deliberate line break (an address, a short label line).
        var breaks: Set<Int> = []
        /// A list item's first line as printed, marker included.
        var markedLine: Line?

        var frame: CGRect { lines.reduce(CGRect.null) { $0.union($1.frame) } }
        var size: Double {
            var sizes: [Double: Int] = [:]
            for line in lines { for glyph in line.glyphs where !glyph.isSpace { sizes[glyph.style.size, default: 0] += 1 } }
            return sizes.max { $0.value < $1.value }?.key ?? lines.first?.size ?? 11
        }
        var allBold: Bool {
            let solid = lines.flatMap(\.glyphs).filter { !$0.isSpace }
            return !solid.isEmpty && solid.allSatisfy(\.style.bold)
        }
        var text: String { lines.map(\.text).joined(separator: " ") }
    }

    private static func paragraphs(_ lines: [Line], body: WordDocument.TextStyle, lists: inout Int) -> [Draft] {
        var drafts: [Draft] = []
        // The list being continued: its kind, id, marker position and next number.
        var open: (kind: WordDocument.ListKind, id: Int, x: Double, next: Int)?
        for line in lines {
            var line = line
            let printed = line
            // A big, short numbered line is a heading ("1. Introduction"), not a list item.
            let headingLike = line.size >= body.size * 1.15 && line.frame.width < columnWidth(of: line, in: lines) * 0.6
            let marker = headingLike ? nil : listMarker(line)
            if var current = drafts.last, marker == nil {
                // "A. The software…" wrapping back under its letter is a labelled paragraph, not a list.
                if current.list != nil, current.lines.count == 1, let marked = current.markedLine,
                   abs(line.frame.minX - marked.frame.minX) < line.size * 0.6,
                   abs(line.frame.minX - (current.textStart ?? 0)) > line.size * 0.6 {
                    current = Draft(lines: [marked])
                    drafts[drafts.count - 1] = current
                    open = nil
                }
                switch continuation(of: current, with: line, in: lines) {
                case .sameParagraph:
                    drafts[drafts.count - 1].lines.append(line)
                    continue
                case .lineBreak:
                    drafts[drafts.count - 1].breaks.insert(current.lines.count)
                    drafts[drafts.count - 1].lines.append(line)
                    continue
                case .newParagraph:
                    break
                }
            }
            guard let marker else {
                open = nil
                drafts.append(Draft(lines: [line]))
                continue
            }
            line.glyphs.removeFirst(marker.glyphCount)
            while line.glyphs.first?.isSpace == true { line.glyphs.removeFirst() }
            line = Line(glyphs: line.glyphs)
            let indent = max(body.size * 1.5, 12)
            let item: WordDocument.ListItem
            if let list = open, marker.x > list.x + body.size * 0.75 {
                // Nested under the open list.
                let level = max(1, min(8, Int(((marker.x - list.x) / indent).rounded())))
                item = WordDocument.ListItem(kind: marker.kind, level: level, list: list.id, start: 1)
            } else if let list = open, list.kind == marker.kind, abs(marker.x - list.x) <= body.size * 0.75,
                      marker.number == nil || marker.number == list.next {
                item = WordDocument.ListItem(kind: list.kind, level: 0, list: list.id, start: 1)
                open?.next = (marker.number ?? list.next) + 1
            } else {
                lists += 1
                open = (marker.kind, lists, marker.x, (marker.number ?? 1) + 1)
                item = WordDocument.ListItem(kind: marker.kind, level: 0, list: lists, start: marker.number ?? 1)
            }
            drafts.append(Draft(lines: [line], list: item, textStart: line.frame.minX, markedLine: printed))
        }
        return drafts
    }

    enum Continuation {
        case sameParagraph, lineBreak, newParagraph
    }

    /// Whether `line` carries on the paragraph `draft` (the same block of text),
    /// and if so whether the line before it ended early on purpose.
    private static func continuation(of draft: Draft, with line: Line, in lines: [Line]) -> Continuation {
        guard let previous = draft.lines.last else { return .newParagraph }
        let size = max(previous.size, line.size)
        if abs(previous.size - line.size) > 0.75 { return .newParagraph }
        let previousBold = previous.glyphs.filter { !$0.isSpace }.allSatisfy(\.style.bold)
        let lineBold = line.glyphs.filter { !$0.isSpace }.allSatisfy(\.style.bold)
        if previousBold != lineBold { return .newParagraph }
        // Below the previous line, without a blank line between.
        let pitch = previous.frame.minY - line.frame.minY
        if pitch <= size * 0.5 || pitch > size * 1.75 { return .newParagraph }
        if draft.lines.count >= 2 {
            let earlier = draft.lines[draft.lines.count - 2]
            let usual = earlier.frame.minY - previous.frame.minY
            if pitch > usual * 1.3 + 1 { return .newParagraph }
        }
        // Same left edge (or the text edge of a list item, or after a first-line indent).
        let left = draft.lines.count >= 2 ? draft.lines[1].frame.minX : (draft.textStart ?? draft.lines[0].frame.minX)
        let x = line.frame.minX
        if draft.lines.count == 1, draft.list == nil, x < draft.lines[0].frame.minX - size * 0.5, x > draft.lines[0].frame.minX - size * 4 {
            // A first-line indent.
        } else if abs(x - left) > size * 1.2 {
            return .newParagraph
        }
        // The previous line stopped short although the next word would have fit: a deliberate break.
        let right = columnRight(of: previous, in: lines)
        let firstWord = line.glyphs.prefix { !$0.isSpace }.reduce(CGRect.null) { $0.union($1.frame) }
        if !firstWord.isNull, previous.frame.maxX + size * 0.3 + firstWord.width < right - 0.5 {
            if let last = previous.text.trimmingCharacters(in: .whitespaces).last, ".!?:;\"”’)".contains(last) {
                return .newParagraph
            }
            return .lineBreak
        }
        return .sameParagraph
    }

    /// How wide the column `line` sits in is.
    private static func columnWidth(of line: Line, in lines: [Line]) -> Double {
        columnRight(of: line, in: lines) - Double(line.frame.minX)
    }

    /// The right edge of the column `line` sits in: the furthest any line starting near it reaches.
    private static func columnRight(of line: Line, in lines: [Line]) -> Double {
        lines.filter { abs($0.frame.minX - line.frame.minX) < line.size * 3 && $0.frame.intersects(CGRect(x: line.frame.minX, y: 0, width: 1, height: 1e6)) }
            .map { Double($0.frame.maxX) }.max() ?? Double(line.frame.maxX)
    }

    struct Marker {
        var kind: WordDocument.ListKind
        var number: Int?
        var glyphCount: Int
        var x: Double
    }

    /// A bullet or a number at the start of a line: "• ", "– ", "1. ", "a) ", "iv. ".
    static func listMarker(_ line: Line) -> Marker? {
        let text = line.text
        guard let first = line.glyphs.first else { return nil }
        let bullets = "•◦▪▫●○■□‣⁃∙·–—−‒-*➢►▶◆◇❖→✓✔"
        if let character = text.first, bullets.contains(character) || character.unicodeScalars.first.map({ (0xE000...0xF8FF).contains($0.value) }) == true {
            let rest = text.dropFirst()
            guard let next = rest.first, next == " " || next == "\t" || next == "\u{00A0}",
                  rest.drop(while: { $0.isWhitespace }).first != nil else { return nil }
            if character == "-" || character == "*", line.glyphs.count < 3 { return nil }
            return Marker(kind: .bullet, number: nil, glyphCount: 1, x: first.frame.minX)
        }
        let patterns: [(String, WordDocument.ListKind)] = [
            (#"^\(?(\d{1,3})[.)]\s+\S"#, .decimal),
            (#"^\(?([ivxlc]{1,5})[.)]\s+\S"#, .lowerRoman),
            (#"^\(?([a-z])[.)]\s+\S"#, .lowerLetter),
            (#"^\(?([A-Z])[.)]\s+\S"#, .upperLetter),
        ]
        for (pattern, kind) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let tokenRange = Range(match.range(at: 1), in: text) else { continue }
            let token = String(text[tokenRange])
            let number: Int? = switch kind {
            case .decimal: Int(token)
            case .lowerLetter, .upperLetter: Int(token.lowercased().unicodeScalars.first!.value) - 96
            case .lowerRoman: roman(token)
            case .bullet: nil
            }
            guard let number else { continue }
            // Marker = everything up to the first space.
            let markerLength = text.prefix { !$0.isWhitespace }.count
            return Marker(kind: kind, number: number, glyphCount: min(markerLength, line.glyphs.count - 1), x: first.frame.minX)
        }
        return nil
    }

    private static func roman(_ text: String) -> Int? {
        let values: [Character: Int] = ["i": 1, "v": 5, "x": 10, "l": 50, "c": 100]
        var total = 0, previous = 0
        for character in text.reversed() {
            guard let value = values[character] else { return nil }
            total += value < previous ? -value : value
            previous = max(previous, value)
        }
        return total > 0 ? total : nil
    }

    // MARK: Headings

    /// Paragraph sizes bigger than the body (or bold body-size lines on their
    /// own) become heading levels, biggest first.
    private static func headingLevels(_ drafts: [Draft], body: WordDocument.TextStyle) -> (styles: [WordDocument.TextStyle], level: (Draft) -> Int?) {
        func isCandidate(_ draft: Draft) -> Bool {
            guard draft.list == nil, draft.lines.count <= 3 else { return false }
            let text = draft.text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, text.count <= 200, text.contains(where: \.isLetter) else { return false }
            if draft.size >= body.size * 1.15 { return true }
            return draft.allBold && draft.lines.count == 1 && text.count <= 100 && draft.size >= body.size - 0.5
                && !(text.hasSuffix(".") && text.count > 60)
        }
        // Rank: bigger first; bold body-size headings last.
        func rank(_ draft: Draft) -> Double { draft.size >= body.size * 1.15 ? draft.size : body.size + 0.01 }
        let ranks = Set(drafts.filter(isCandidate).map { (rank($0) * 2).rounded() / 2 }).sorted(by: >)
        var styles: [WordDocument.TextStyle] = []
        for value in ranks.prefix(4) {
            let example = drafts.first { isCandidate($0) && (rank($0) * 2).rounded() / 2 == value }!
            let glyph = example.lines.flatMap(\.glyphs).first { !$0.isSpace }?.style ?? body
            styles.append(WordDocument.TextStyle(family: glyph.family, size: example.size, bold: example.allBold,
                                                 italic: glyph.italic, color: glyph.color))
        }
        let level: (Draft) -> Int? = { draft in
            guard isCandidate(draft), let index = ranks.firstIndex(of: (rank(draft) * 2).rounded() / 2) else { return nil }
            return min(index + 1, 4)
        }
        return (styles, level)
    }

    // MARK: Pages

    private static func page(_ layout: PDFPageLayout, drafts: [Draft], body: WordDocument.TextStyle,
                             headings: (Draft) -> Int?) -> WordDocument.Page {
        let size = layout.size
        let content = (drafts.map(\.frame) + layout.pictures.map(\.frame) + layout.tables.map(\.frame)).reduce(CGRect.null) { $0.union($1) }
        var margins = WordDocument.Margins()
        if !content.isNull {
            func clamp(_ value: Double) -> Double { min(144, max(18, value)) }
            margins.left = clamp(content.minX)
            margins.right = clamp(size.width - content.maxX)
            if margins.right > margins.left * 1.5 { margins.right = margins.left }
            margins.top = clamp(size.height - content.maxY)
            margins.bottom = clamp(content.minY)
            if margins.bottom > margins.top * 1.5 { margins.bottom = margins.top }
        }
        let textWidth = size.width - margins.left - margins.right
        let columnLeft = drafts.map { Double($0.frame.minX) }.min() ?? margins.left
        let pageRight = drafts.map { Double($0.frame.maxX) }.max() ?? Double(size.width - margins.right)

        var flow: [(frame: CGRect, block: WordDocument.Block, isText: Bool)] = []
        let allLines = drafts.flatMap(\.lines)
        for draft in drafts {
            let right = draft.lines.count >= 2 ? columnRight(of: draft.lines[0], in: allLines) : pageRight
            var paragraph = makeParagraph(draft, body: body, columnLeft: columnLeft, columnRight: right,
                                          pageWidth: size.width, marginLeft: margins.left, textWidth: textWidth,
                                          lineStarts: allLines.map { Double($0.frame.minX) })
            paragraph.heading = headings(draft)
            flow.append((draft.frame, .paragraph(paragraph), true))
        }

        var placed: [(frame: CGRect, block: WordDocument.Block)] = []
        for table in layout.tables {
            placed.append((table.frame, .table(makeTable(table, body: body, indent: max(0, table.frame.minX - margins.left)))))
        }
        for item in layout.pictures {
            var picture = item.picture
            if picture.size.width > textWidth {
                picture.size = CGSize(width: textWidth, height: picture.size.height * textWidth / picture.size.width)
            }
            if abs(item.frame.midX - size.width / 2) < 12, picture.size.width < textWidth * 0.95 {
                picture.alignment = .center
            } else {
                picture.leftIndent = max(0, min(item.frame.minX - margins.left, textWidth - picture.size.width))
            }
            placed.append((item.frame, .picture(picture)))
        }
        // Tables and pictures go before the first text below them (preferring text in the same column).
        for item in placed.sorted(by: { $0.frame.maxY > $1.frame.maxY }) {
            let below = { (entry: (frame: CGRect, block: WordDocument.Block, isText: Bool)) in
                entry.isText && entry.frame.maxY < item.frame.maxY - 1
            }
            let sameColumn = flow.firstIndex { below($0) && $0.frame.maxX > item.frame.minX && $0.frame.minX < item.frame.maxX }
            let index = sameColumn ?? flow.firstIndex(where: below) ?? flow.count
            flow.insert((item.frame, item.block, false), at: index)
        }
        // Space after each paragraph: the gap down to whatever comes next; after a
        // table or picture, the gap goes before the paragraph that follows it.
        for index in flow.indices {
            guard case .paragraph(var paragraph) = flow[index].block else { continue }
            let size = paragraph.runs.first?.style.size ?? body.size
            if index + 1 < flow.count, flow[index + 1].frame.maxY < flow[index].frame.minY {
                paragraph.spaceAfter = min(48, max(0, (flow[index].frame.minY - flow[index + 1].frame.maxY - size * 0.25).rounded()))
            }
            if index > 0, !flow[index - 1].isText, flow[index].frame.maxY < flow[index - 1].frame.minY {
                paragraph.spaceBefore = min(48, max(0, (flow[index - 1].frame.minY - flow[index].frame.maxY - size * 0.25).rounded()))
            }
            flow[index].block = .paragraph(paragraph)
        }
        return WordDocument.Page(size: size, margins: margins, blocks: flow.map(\.block))
    }

    private static func makeParagraph(_ draft: Draft, body: WordDocument.TextStyle, columnLeft: Double, columnRight: Double,
                                      pageWidth: Double, marginLeft: Double, textWidth: Double, lineStarts: [Double]) -> WordDocument.Paragraph {
        var glyphs = reflowed(draft.lines, breaks: draft.breaks)
        var rightTab: Double?
        if let leader = withTabLeader(glyphs) {
            glyphs = leader
            rightTab = textWidth
        }
        var paragraph = WordDocument.Paragraph(runs: runs(glyphs))
        paragraph.rightTab = rightTab
        paragraph.list = draft.list
        let size = draft.size
        let lines = draft.lines
        let center = pageWidth / 2
        // Centred: every line's middle on the page's middle, and not starting where other lines start.
        let sharedStart = lines.contains { line in lineStarts.filter { abs($0 - line.frame.minX) < 1.5 }.count > 1 + (lines.count > 1 ? lines.count - 1 : 0) }
        let centered = draft.list == nil && !sharedStart && lines.allSatisfy { abs($0.frame.midX - center) < max(3, size * 0.3) }
            && draft.frame.minX > columnLeft + size * 2
        let rightAligned = draft.list == nil && !sharedStart && lines.allSatisfy { abs($0.frame.maxX - columnRight) < size * 0.6 }
            && draft.frame.minX > columnLeft + size * 3
        // Justified text ends every line but the last exactly at the column's edge.
        let justified = lines.count >= 2 && lines.dropLast().allSatisfy { abs($0.frame.maxX - columnRight) < 1.0 }
            && (lines.last.map { $0.frame.maxX < columnRight - size } ?? false)
        if centered {
            paragraph.alignment = .center
        } else if rightAligned {
            paragraph.alignment = .right
        } else {
            if justified { paragraph.alignment = .both }
            let rest = lines.count >= 2 ? lines[1].frame.minX : lines[0].frame.minX
            paragraph.leftIndent = max(0, rest - marginLeft)
            paragraph.firstLineIndent = lines[0].frame.minX - rest
        }
        if lines.count >= 2 {
            let pitches = zip(lines, lines.dropFirst()).map { $0.frame.minY - $1.frame.minY }
            let pitch = pitches.reduce(0, +) / Double(pitches.count)
            let multiple = pitch / (size * 1.17)
            if multiple < 0.9 || multiple > 1.2 { paragraph.lineSpacing = min(3, max(0.8, (multiple * 20).rounded() / 20)) }
        }
        return paragraph
    }

    /// The lines of a paragraph as one run of text: joined with spaces, words
    /// hyphenated across a line break put back together.
    static func reflowed(_ lines: [Line], breaks: Set<Int> = []) -> [Glyph] {
        var glyphs: [Glyph] = []
        for (index, line) in lines.enumerated() {
            var incoming = line.glyphs
            if let last = glyphs.last {
                if breaks.contains(index) {
                    while glyphs.last?.isSpace == true { glyphs.removeLast() }
                    glyphs.append(Glyph(text: "\n", frame: .null, style: last.style, link: nil))
                } else if last.text == "\u{00AD}" {
                    glyphs.removeLast()
                } else if last.text == "-", glyphs.dropLast().last?.text.last?.isLetter == true,
                          incoming.first?.text.first?.isLowercase == true {
                    glyphs.removeLast()
                } else if !last.isSpace {
                    glyphs.append(Glyph(text: " ", frame: .null, style: last.style, link: last.link))
                }
            }
            while incoming.first?.isSpace == true, glyphs.last?.isSpace == true { incoming.removeFirst() }
            glyphs += incoming
        }
        return glyphs.filter { $0.text != "\u{00AD}" }
    }

    /// A table-of-contents line ("Introduction ........ 4"): the dots become a
    /// tab, which the paragraph turns into a right-aligned dot leader.
    static func withTabLeader(_ glyphs: [Glyph]) -> [Glyph]? {
        let leaders: Set<String> = [".", "·", "…", "_"]
        var index = glyphs.count - 1
        // Back over the page number (and spaces) at the end.
        while index >= 0, glyphs[index].isSpace { index -= 1 }
        let numberEnd = index
        while index >= 0, glyphs[index].text.allSatisfy({ $0.isNumber || $0.isLetter && $0.isLowercase && "ivxlc".contains($0) }), !glyphs[index].isSpace { index -= 1 }
        guard index < numberEnd else { return nil }
        let numberStart = index + 1
        var dots = 0
        while index >= 0, leaders.contains(glyphs[index].text) || glyphs[index].isSpace {
            if !glyphs[index].isSpace { dots += glyphs[index].text == "…" ? 3 : 1 }
            index -= 1
        }
        guard dots >= 4, index >= 0 else { return nil }
        let tab = Glyph(text: "\t", frame: .null, style: glyphs[index].style, link: nil)
        return Array(glyphs[...index]) + [tab] + Array(glyphs[numberStart...numberEnd])
    }

    /// Glyphs → runs of one style and link. Spaces join the run they're in.
    static func runs(_ glyphs: [Glyph]) -> [WordDocument.Run] {
        var runs: [WordDocument.Run] = []
        for glyph in glyphs {
            if var last = runs.last, glyph.link == last.link, glyph.isSpace || glyph.style == last.style {
                last.text += glyph.text
                runs[runs.count - 1] = last
            } else {
                runs.append(WordDocument.Run(text: glyph.text, style: glyph.style, link: glyph.link))
            }
        }
        return runs
    }

    private static func makeTable(_ table: PDFPageLayout.PlacedTable, body: WordDocument.TextStyle, indent: Double) -> WordDocument.Table {
        let widths = zip(table.columnEdges, table.columnEdges.dropFirst()).map { max(12, $1 - $0) }
        var rows: [[WordDocument.Cell]] = []
        for (r, row) in table.cells.enumerated() {
            var cells: [WordDocument.Cell] = []
            var c = 0
            while c < row.count {
                let cell = row[c]
                if let owner = cell.owner {
                    let ownerCell = table.cells[owner.row][owner.column]
                    if owner.row < r, owner.column == c {
                        cells.append(WordDocument.Cell(paragraphs: [], columnSpan: ownerCell.columnSpan, verticalMerge: .continued))
                        c += max(1, ownerCell.columnSpan)
                    } else {
                        c += 1
                    }
                    continue
                }
                var paragraph = WordDocument.Paragraph(runs: runs(reflowed(cell.lines)))
                if paragraph.runs.isEmpty { paragraph.runs = [] }
                cells.append(WordDocument.Cell(paragraphs: paragraph.runs.isEmpty ? [] : [paragraph], columnSpan: cell.columnSpan,
                                               verticalMerge: cell.rowSpan > 1 ? .start : nil))
                c += max(1, cell.columnSpan)
            }
            rows.append(cells)
        }
        return WordDocument.Table(columnWidths: widths, rows: rows, bordered: table.bordered, leftIndent: indent)
    }

    // MARK: Headers and footers

    /// Page numbers and text repeated at the top or bottom of the pages leave
    /// the body and become the document's header and footer.
    private static func moveMarginals(_ layouts: inout [PDFPageLayout]) -> (WordDocument.Paragraph?, WordDocument.Paragraph?) {
        struct Candidate { var page: Int; var line: Int; var key: String; var top: Bool }
        var candidates: [Candidate] = []
        for (pageIndex, layout) in layouts.enumerated() {
            for (lineIndex, line) in layout.lines.enumerated() {
                let top = line.frame.minY > layout.size.height * 0.91
                let bottom = line.frame.maxY < layout.size.height * 0.09
                guard top || bottom else { continue }
                let key = line.text.lowercased().replacingOccurrences(of: #"\d+"#, with: "#", options: .regularExpression)
                    .trimmingCharacters(in: .whitespaces)
                candidates.append(Candidate(page: pageIndex, line: lineIndex, key: key, top: top))
            }
        }
        let pageNumber = #"^(page\s*)?#(\s*(of|/)\s*#)?$|^[-–—]\s*#\s*[-–—]$"#
        let needed = max(2, (layouts.count + 1) / 2)
        var header: WordDocument.Paragraph?, footer: WordDocument.Paragraph?
        var remove: [Int: Set<Int>] = [:]
        for candidate in candidates {
            let isNumber = candidate.key.range(of: pageNumber, options: .regularExpression) != nil
            let repeats = candidates.filter { $0.key == candidate.key && $0.top == candidate.top }.count
            guard isNumber || (layouts.count >= 2 && repeats >= needed) else { continue }
            remove[candidate.page, default: []].insert(candidate.line)
            let layout = layouts[candidate.page]
            let line = layout.lines[candidate.line]
            var paragraph = WordDocument.Paragraph(runs: isNumber ? numberRuns(line) : runs(line.glyphs))
            let center = layout.size.width / 2
            paragraph.alignment = abs(line.frame.midX - center) < 20 ? .center : (line.frame.midX > center ? .right : .left)
            if candidate.top { header = header ?? paragraph } else { footer = footer ?? paragraph }
        }
        for (page, lines) in remove {
            layouts[page].lines = layouts[page].lines.enumerated().filter { !lines.contains($0.offset) }.map(\.element)
        }
        return (header, footer)
    }

    /// "Page 3 of 10" → "Page {PAGE} of {NUMPAGES}".
    private static func numberRuns(_ line: Line) -> [WordDocument.Run] {
        let style = line.glyphs.first { !$0.isSpace }?.style ?? WordDocument.TextStyle(family: nil, size: 10)
        var runs: [WordDocument.Run] = []
        var numbers = 0
        var text = ""
        var digits = ""
        func flushDigits() {
            guard !digits.isEmpty else { return }
            if !text.isEmpty { runs.append(.init(text: text, style: style)); text = "" }
            runs.append(.init(text: digits, style: style, field: numbers == 0 ? .page : .pageCount))
            numbers += 1
            digits = ""
        }
        for character in line.text {
            if character.isNumber { digits.append(character) } else { flushDigits(); text.append(character) }
        }
        flushDigits()
        if !text.isEmpty { runs.append(.init(text: text, style: style)) }
        return runs
    }
}
