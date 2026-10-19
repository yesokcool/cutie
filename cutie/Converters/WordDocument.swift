import Foundation

/// A Word document as Cutie builds it from a PDF: pages (sections) of
/// paragraphs, tables and pictures, with heading styles and real lists.
/// `write` turns it into a .docx (WordprocessingML, zipped by hand like
/// Cutie's XLSX and PPTX).
nonisolated struct WordDocument {
    struct TextStyle: Hashable {
        var family: String?
        var size: Double
        var bold = false
        var italic = false
        /// RRGGBB, nil for black.
        var color: String?
    }

    struct Run: Equatable {
        var text: String
        var style: TextStyle
        var link: URL?
        var field: Field?
    }

    enum Field: Equatable {
        case page, pageCount
    }

    enum Alignment: String {
        case left, center, right, both
    }

    enum ListKind: Int, CaseIterable {
        case bullet = 1, decimal, lowerLetter, upperLetter, lowerRoman
    }

    struct ListItem {
        var kind: ListKind
        var level: Int
        /// One `w:num` per list, so numbered lists restart where the PDF did.
        var list: Int
        var start: Int
    }

    struct Paragraph {
        var runs: [Run]
        /// 1–4.
        var heading: Int?
        var list: ListItem?
        var alignment = Alignment.left
        /// Points.
        var leftIndent = 0.0
        var firstLineIndent = 0.0
        /// Only after a table or picture (between paragraphs, the space goes after).
        var spaceBefore = 0.0
        var spaceAfter = 0.0
        /// Line spacing as a multiple of single, when the PDF's lines were spaced unusually.
        var lineSpacing: Double?
        /// A right-aligned tab stop with a dot leader at this position (points from the
        /// left margin): table-of-contents lines. The text holds a tab where the dots were.
        var rightTab: Double?

        var text: String { runs.map(\.text).joined() }
    }

    struct Picture {
        var data: Data
        /// "jpeg" or "png".
        var type: String
        /// Points.
        var size: CGSize
        var alignment = Alignment.left
        var leftIndent = 0.0
    }

    struct Cell {
        var paragraphs: [Paragraph]
        var columnSpan = 1
        /// Part of a cell merged downwards: `.start` on the top cell, `.continued` below it.
        var verticalMerge: VerticalMerge?
    }

    enum VerticalMerge {
        case start, continued
    }

    struct Table {
        /// Points.
        var columnWidths: [Double]
        var rows: [[Cell]]
        var bordered: Bool
        var leftIndent = 0.0
    }

    enum Block {
        case paragraph(Paragraph)
        case table(Table)
        case picture(Picture)
    }

    struct Margins {
        var top = 72.0, left = 72.0, bottom = 72.0, right = 72.0
    }

    struct Page {
        /// Points, as the page is shown (rotation applied).
        var size: CGSize
        var margins = Margins()
        var blocks: [Block] = []
    }

    var pages: [Page] = []
    var header: Paragraph?
    var footer: Paragraph?
    var title: String?
    var author: String?
    /// The body text's font and size, which become the Normal style.
    var body = TextStyle(family: nil, size: 11)
    /// Each heading level's look (index 0 is Heading 1).
    var headings: [TextStyle] = []

    // MARK: - Writing

    func write(to output: URL, scratch: Scratch) async throws {
        let root = try scratch.folder("docx-" + UUID().uuidString)
        for folder in ["_rels", "docProps", "word/_rels", "word/media"] {
            try FileManager.default.createDirectory(at: root.appending(path: folder), withIntermediateDirectories: true)
        }
        func put(_ path: String, _ text: String) throws { try Data(text.utf8).write(to: root.appending(path: path)) }

        var writer = BodyWriter(document: self)
        let body = writer.body()
        let headerXML = header.map { writer.paragraph($0) } ?? "<w:p/>"
        let footerXML = footer.map { writer.paragraph($0) } ?? "<w:p/>"
        for (index, picture) in writer.pictures.enumerated() {
            try picture.data.write(to: root.appending(path: "word/media/image\(index + 1).\(picture.type)"))
        }

        var relations = [
            ("rId1", "styles", "styles.xml", false),
            ("rId2", "numbering", "numbering.xml", false),
            ("rId3", "settings", "settings.xml", false),
            ("rId4", "header", "header1.xml", false),
            ("rId5", "footer", "footer1.xml", false),
        ]
        for (index, picture) in writer.pictures.enumerated() {
            relations.append((writer.pictureIDs[index], "image", "media/image\(index + 1).\(picture.type)", false))
        }
        for (url, id) in writer.links.sorted(by: { $0.value < $1.value }) {
            relations.append((id, "hyperlink", url.absoluteString, true))
        }

        try put("[Content_Types].xml", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
        <Default Extension="xml" ContentType="application/xml"/>\
        <Default Extension="png" ContentType="image/png"/>\
        <Default Extension="jpeg" ContentType="image/jpeg"/>\
        <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>\
        <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>\
        <Override PartName="/word/numbering.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml"/>\
        <Override PartName="/word/settings.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.settings+xml"/>\
        <Override PartName="/word/header1.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.header+xml"/>\
        <Override PartName="/word/footer1.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.footer+xml"/>\
        <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>\
        </Types>
        """)
        try put("_rels/.rels", Self.relationships([
            ("rId1", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument", "word/document.xml", false),
            ("rId2", "http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties", "docProps/core.xml", false),
        ]))
        try put("word/_rels/document.xml.rels", Self.relationships(relations.map { id, type, target, external in
            (id, "http://schemas.openxmlformats.org/officeDocument/2006/relationships/\(type)", target, external)
        }))
        try put("word/document.xml", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document \(Self.namespaces)><w:body>\(body)</w:body></w:document>
        """)
        try put("word/header1.xml", #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:hdr \#(Self.namespaces)>\#(headerXML)</w:hdr>"#)
        try put("word/footer1.xml", #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:ftr \#(Self.namespaces)>\#(footerXML)</w:ftr>"#)
        try put("word/styles.xml", styles())
        try put("word/numbering.xml", Self.numbering(lists: writer.lists))
        try put("word/settings.xml", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:settings xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:defaultTabStop w:val="720"/>\
        <w:compat><w:compatSetting w:name="compatibilityMode" w:uri="http://schemas.microsoft.com/office/word" w:val="15"/></w:compat></w:settings>
        """)
        try put("docProps/core.xml", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" \
        xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" \
        xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">\
        <dc:title>\(XMLText.escape(title ?? ""))</dc:title><dc:creator>\(XMLText.escape(author ?? ""))</dc:creator></cp:coreProperties>
        """)
        try await ArchiveConverter.zipContents(of: root, to: output)
    }

    /// Writes the body, collecting the pictures, links and lists it refers to.
    private struct BodyWriter {
        let document: WordDocument
        var pictures: [Picture] = []
        var pictureIDs: [String] = []
        var links: [URL: String] = [:]
        /// List id → its kinds by level and its start, for numbering.xml.
        var lists: [Int: ListNumbering] = [:]
        private var nextID = 100

        init(document: WordDocument) { self.document = document }

        mutating func body() -> String {
            var xml = ""
            for (index, page) in document.pages.enumerated() {
                let last = index == document.pages.count - 1
                var blocks: [String] = []
                for block in page.blocks {
                    switch block {
                    case .paragraph(let item): blocks.append(paragraph(item))
                    case .table(let item): blocks.append(table(item))
                    case .picture(let item): blocks.append(picture(item))
                    }
                }
                let section = sectionProperties(page)
                if last {
                    xml += blocks.joined() + section
                } else {
                    // A section ends with the paragraph holding its properties: the page break.
                    if case .paragraph(let item)? = page.blocks.last {
                        blocks[blocks.count - 1] = paragraph(item, section: section)
                    } else {
                        blocks.append("<w:p><w:pPr>\(section)</w:pPr></w:p>")
                    }
                    xml += blocks.joined()
                }
            }
            return xml.isEmpty ? "<w:p/>" + sectionProperties(Page(size: CGSize(width: 612, height: 792))) : xml
        }

        func sectionProperties(_ page: Page) -> String {
            let width = twips(page.size.width), height = twips(page.size.height)
            let orient = width > height ? #" w:orient="landscape""# : ""
            let m = page.margins
            return """
            <w:sectPr><w:headerReference w:type="default" r:id="rId4"/><w:footerReference w:type="default" r:id="rId5"/>\
            <w:pgSz w:w="\(width)" w:h="\(height)"\(orient)/>\
            <w:pgMar w:top="\(twips(m.top))" w:right="\(twips(m.right))" w:bottom="\(twips(m.bottom))" w:left="\(twips(m.left))" \
            w:header="\(twips(min(36, m.top / 2)))" w:footer="\(twips(min(36, m.bottom / 2)))" w:gutter="0"/></w:sectPr>
            """
        }

        mutating func paragraph(_ paragraph: Paragraph, section: String = "") -> String {
            var properties = ""
            if let heading = paragraph.heading { properties += #"<w:pStyle w:val="Heading\#(heading)"/>"# }
            if let list = paragraph.list {
                if paragraph.heading == nil { properties += #"<w:pStyle w:val="ListParagraph"/>"# }
                properties += #"<w:numPr><w:ilvl w:val="\#(list.level)"/><w:numId w:val="\#(list.list)"/></w:numPr>"#
                var numbering = lists[list.list] ?? ListNumbering(start: list.start)
                if numbering.kinds[list.level] == nil { numbering.kinds[list.level] = list.kind }
                lists[list.list] = numbering
            }
            if let tab = paragraph.rightTab {
                properties += #"<w:tabs><w:tab w:val="right" w:leader="dot" w:pos="\#(twips(tab))"/></w:tabs>"#
            }
            var spacing = ""
            if paragraph.spaceBefore > 0 { spacing += #" w:before="\#(twips(paragraph.spaceBefore))""# }
            if paragraph.heading == nil || paragraph.spaceAfter > 0 { spacing += #" w:after="\#(twips(paragraph.spaceAfter))""# }
            if let line = paragraph.lineSpacing { spacing += #" w:line="\#(Int((line * 240).rounded()))" w:lineRule="auto""# }
            if !spacing.isEmpty { properties += "<w:spacing\(spacing)/>" }
            if paragraph.list == nil, paragraph.leftIndent > 1 || abs(paragraph.firstLineIndent) > 1 {
                var indent = #" w:left="\#(twips(paragraph.leftIndent))""#
                if paragraph.firstLineIndent > 1 { indent += #" w:firstLine="\#(twips(paragraph.firstLineIndent))""# }
                if paragraph.firstLineIndent < -1 { indent += #" w:hanging="\#(twips(-paragraph.firstLineIndent))""# }
                properties += "<w:ind\(indent)/>"
            }
            if paragraph.alignment != .left { properties += #"<w:jc w:val="\#(paragraph.alignment.rawValue)"/>"# }
            let style = paragraph.heading.map { document.headings.indices.contains($0 - 1) ? document.headings[$0 - 1] : document.body } ?? document.body
            // The paragraph mark's look is the list number's look: match the text.
            if paragraph.list != nil, let first = paragraph.runs.first {
                let mark = run(WordDocument.Run(text: "", style: first.style), base: style)
                if let start = mark.range(of: "<w:rPr>"), let end = mark.range(of: "</w:rPr>") {
                    properties += String(mark[start.lowerBound..<end.upperBound])
                }
            }
            properties += section
            return "<w:p>" + (properties.isEmpty ? "" : "<w:pPr>\(properties)</w:pPr>") + runs(paragraph.runs, base: style) + "</w:p>"
        }

        mutating func runs(_ runs: [Run], base: TextStyle) -> String {
            var xml = ""
            var index = 0
            while index < runs.count {
                if let url = runs[index].link {
                    var group = ""
                    while index < runs.count, runs[index].link == url {
                        group += run(runs[index], base: base)
                        index += 1
                    }
                    xml += #"<w:hyperlink r:id="\#(linkID(url))">\#(group)</w:hyperlink>"#
                } else {
                    xml += run(runs[index], base: base)
                    index += 1
                }
            }
            return xml
        }

        mutating func linkID(_ url: URL) -> String {
            if let id = links[url] { return id }
            let id = "rIdL\(links.count + 1)"
            links[url] = id
            return id
        }

        func run(_ run: Run, base: TextStyle) -> String {
            var properties = ""
            let style = run.style
            if let family = style.family, family != base.family {
                let name = XMLText.escape(family)
                properties += #"<w:rFonts w:ascii="\#(name)" w:hAnsi="\#(name)" w:cs="\#(name)"/>"#
            }
            if style.bold != base.bold { properties += style.bold ? "<w:b/>" : #"<w:b w:val="0"/>"# }
            if style.italic != base.italic { properties += style.italic ? "<w:i/>" : #"<w:i w:val="0"/>"# }
            if let color = style.color, color != base.color { properties += #"<w:color w:val="\#(color)"/>"# }
            let half = Int((style.size * 2).rounded())
            if half != Int((base.size * 2).rounded()), half > 0 { properties += #"<w:sz w:val="\#(half)"/><w:szCs w:val="\#(half)"/>"# }
            let rPr = properties.isEmpty ? "" : "<w:rPr>\(properties)</w:rPr>"
            if let field = run.field {
                let instruction = field == .page ? " PAGE " : " NUMPAGES "
                return #"<w:r>\#(rPr)<w:fldChar w:fldCharType="begin"/></w:r><w:r>\#(rPr)<w:instrText xml:space="preserve">\#(instruction)</w:instrText></w:r>"#
                    + #"<w:r>\#(rPr)<w:fldChar w:fldCharType="separate"/></w:r><w:r>\#(rPr)<w:t>\#(XMLText.escape(run.text))</w:t></w:r>"#
                    + #"<w:r>\#(rPr)<w:fldChar w:fldCharType="end"/></w:r>"#
            }
            // Line breaks and tabs are elements of their own.
            var content = ""
            var text = ""
            func flush() {
                if !text.isEmpty { content += #"<w:t xml:space="preserve">\#(XMLText.escape(text))</w:t>"#; text = "" }
            }
            for character in run.text {
                switch character {
                case "\n": flush(); content += "<w:br/>"
                case "\t": flush(); content += "<w:tab/>"
                default: text.append(character)
                }
            }
            flush()
            return "<w:r>\(rPr)\(content)</w:r>"
        }

        mutating func table(_ table: Table) -> String {
            let total = table.columnWidths.reduce(0, +)
            var properties = #"<w:tblW w:w="\#(twips(total))" w:type="dxa"/>"#
            if table.leftIndent > 1 { properties += #"<w:tblInd w:w="\#(twips(table.leftIndent))" w:type="dxa"/>"# }
            if table.bordered {
                let edge = { (name: String) in #"<w:\#(name) w:val="single" w:sz="4" w:space="0" w:color="000000"/>"# }
                properties += "<w:tblBorders>" + ["top", "left", "bottom", "right", "insideH", "insideV"].map(edge).joined() + "</w:tblBorders>"
            }
            properties += #"<w:tblLayout w:type="fixed"/><w:tblCellMar><w:left w:w="72" w:type="dxa"/><w:right w:w="72" w:type="dxa"/></w:tblCellMar>"#
            var xml = "<w:tbl><w:tblPr>\(properties)</w:tblPr><w:tblGrid>"
            xml += table.columnWidths.map { #"<w:gridCol w:w="\#(twips($0))"/>"# }.joined() + "</w:tblGrid>"
            for row in table.rows {
                xml += "<w:tr>"
                var column = 0
                for cell in row {
                    let span = max(1, cell.columnSpan)
                    let width = table.columnWidths[min(column, table.columnWidths.count - 1)..<min(column + span, table.columnWidths.count)].reduce(0, +)
                    var cellProperties = #"<w:tcW w:w="\#(twips(width))" w:type="dxa"/>"#
                    if span > 1 { cellProperties += #"<w:gridSpan w:val="\#(span)"/>"# }
                    switch cell.verticalMerge {
                    case .start: cellProperties += #"<w:vMerge w:val="restart"/>"#
                    case .continued: cellProperties += "<w:vMerge/>"
                    case nil: break
                    }
                    let paragraphs = cell.verticalMerge == .continued || cell.paragraphs.isEmpty
                        ? "<w:p/>" : cell.paragraphs.map { paragraph($0) }.joined()
                    xml += "<w:tc><w:tcPr>\(cellProperties)</w:tcPr>\(paragraphs)</w:tc>"
                    column += span
                }
                xml += "</w:tr>"
            }
            return xml + "</w:tbl>"
        }

        mutating func picture(_ picture: Picture) -> String {
            pictures.append(picture)
            let id = "rIdP\(pictures.count)"
            pictureIDs.append(id)
            nextID += 1
            let width = Int(picture.size.width * 12_700), height = Int(picture.size.height * 12_700)
            var properties = ""
            if picture.leftIndent > 1 { properties += #"<w:ind w:left="\#(twips(picture.leftIndent))"/>"# }
            if picture.alignment != .left { properties += #"<w:jc w:val="\#(picture.alignment.rawValue)"/>"# }
            return """
            <w:p>\(properties.isEmpty ? "" : "<w:pPr>\(properties)</w:pPr>")<w:r><w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0">\
            <wp:extent cx="\(width)" cy="\(height)"/><wp:docPr id="\(nextID)" name="Picture \(pictures.count)"/>\
            <a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">\
            <pic:pic><pic:nvPicPr><pic:cNvPr id="\(nextID)" name="image\(pictures.count).\(picture.type)"/><pic:cNvPicPr/></pic:nvPicPr>\
            <pic:blipFill><a:blip r:embed="\(id)"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>\
            <pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(width)" cy="\(height)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr>\
            </pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>
            """
        }
    }

    // MARK: - Parts

    private func styles() -> String {
        func runProperties(_ style: TextStyle, against base: TextStyle? = nil) -> String {
            var xml = ""
            if let family = style.family, family != base?.family {
                let name = XMLText.escape(family)
                xml += #"<w:rFonts w:ascii="\#(name)" w:hAnsi="\#(name)" w:eastAsia="\#(name)" w:cs="\#(name)"/>"#
            }
            if style.bold { xml += "<w:b/><w:bCs/>" }
            if style.italic { xml += "<w:i/><w:iCs/>" }
            if let color = style.color { xml += #"<w:color w:val="\#(color)"/>"# }
            let half = Int((style.size * 2).rounded())
            xml += #"<w:sz w:val="\#(half)"/><w:szCs w:val="\#(half)"/>"#
            return xml
        }
        var xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">\
        <w:docDefaults><w:rPrDefault><w:rPr>\(runProperties(body))<w:lang w:val="en-US"/></w:rPr></w:rPrDefault>\
        <w:pPrDefault><w:pPr><w:spacing w:after="0" w:line="240" w:lineRule="auto"/></w:pPr></w:pPrDefault></w:docDefaults>\
        <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/>\
        <w:rPr>\(runProperties(body))</w:rPr></w:style>
        """
        for level in 1...4 {
            let style = headings.indices.contains(level - 1) ? headings[level - 1] : TextStyle(family: body.family, size: body.size, bold: true)
            xml += """
            <w:style w:type="paragraph" w:styleId="Heading\(level)"><w:name w:val="heading \(level)"/>\
            <w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:uiPriority w:val="9"/><w:qFormat/>\
            <w:pPr><w:keepNext/><w:keepLines/><w:spacing w:before="\(level == 1 ? 240 : 160)" w:after="80"/>\
            <w:outlineLvl w:val="\(level - 1)"/></w:pPr><w:rPr>\(runProperties(style, against: body))</w:rPr></w:style>
            """
        }
        xml += """
        <w:style w:type="paragraph" w:styleId="ListParagraph"><w:name w:val="List Paragraph"/><w:basedOn w:val="Normal"/>\
        <w:uiPriority w:val="34"/><w:qFormat/></w:style>\
        <w:style w:type="table" w:default="1" w:styleId="TableNormal"><w:name w:val="Normal Table"/><w:uiPriority w:val="99"/>\
        <w:semiHidden/><w:tblPr><w:tblInd w:w="0" w:type="dxa"/><w:tblCellMar><w:top w:w="0" w:type="dxa"/>\
        <w:left w:w="108" w:type="dxa"/><w:bottom w:w="0" w:type="dxa"/><w:right w:w="108" w:type="dxa"/></w:tblCellMar></w:tblPr></w:style>\
        </w:styles>
        """
        return xml
    }

    /// How one list numbers its levels: the kind seen first at each level.
    struct ListNumbering {
        var start: Int
        var kinds: [Int: ListKind] = [:]
        var kind: ListKind { kinds[0] ?? kinds.min { $0.key < $1.key }?.value ?? .bullet }
    }

    /// A level's number format and text. A list nests in its kind's usual
    /// pattern (1. → a. → i.); `own` uses the kind's own format at that level.
    private static func levelFormat(_ kind: ListKind, level: Int, own: Bool) -> (format: String, text: String) {
        let step = own ? 0 : level % 3
        return switch kind {
        case .bullet: ("bullet", ["•", "◦", "▪"][level % 3])
        case .decimal: (["decimal", "lowerLetter", "lowerRoman"][step], "%\(level + 1).")
        case .lowerLetter: (["lowerLetter", "lowerRoman", "decimal"][step], "%\(level + 1).")
        case .upperLetter: (["upperLetter", "decimal", "lowerLetter"][step], "%\(level + 1).")
        case .lowerRoman: (["lowerRoman", "lowerLetter", "decimal"][step], "%\(level + 1).")
        }
    }

    private static func abstractNum(_ id: Int, _ format: (Int) -> (format: String, text: String)) -> String {
        var xml = #"<w:abstractNum w:abstractNumId="\#(id)"><w:multiLevelType w:val="hybridMultilevel"/>"#
        for level in 0..<9 {
            let (numFmt, text) = format(level)
            let left = 720 + level * 360
            xml += #"<w:lvl w:ilvl="\#(level)"><w:start w:val="1"/><w:numFmt w:val="\#(numFmt)"/><w:lvlText w:val="\#(XMLText.escape(text))"/>"#
            xml += #"<w:lvlJc w:val="left"/><w:pPr><w:ind w:left="\#(left)" w:hanging="360"/></w:pPr></w:lvl>"#
        }
        return xml + "</w:abstractNum>"
    }

    private static func numbering(lists: [Int: ListNumbering]) -> String {
        var xml = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:numbering xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">"#
        for kind in ListKind.allCases {
            xml += abstractNum(kind.rawValue) { levelFormat(kind, level: $0, own: false) }
        }
        // A list whose nested items are another kind ("•" under "1.") gets its
        // own definition, so each level shows the marker the PDF had.
        var abstractIDs: [Int: Int] = [:]
        for (id, list) in lists.sorted(by: { $0.key < $1.key }) {
            let mixed = list.kinds.contains { level, kind in
                levelFormat(kind, level: level, own: true) != levelFormat(list.kind, level: level, own: false)
            }
            guard mixed else { continue }
            let abstractID = 100 + id
            abstractIDs[id] = abstractID
            xml += abstractNum(abstractID) { level in
                list.kinds[level].map { levelFormat($0, level: level, own: true) } ?? levelFormat(list.kind, level: level, own: false)
            }
        }
        for (id, list) in lists.sorted(by: { $0.key < $1.key }) {
            xml += #"<w:num w:numId="\#(id)"><w:abstractNumId w:val="\#(abstractIDs[id] ?? list.kind.rawValue)"/>"#
            xml += #"<w:lvlOverride w:ilvl="0"><w:startOverride w:val="\#(max(1, list.start))"/></w:lvlOverride></w:num>"#
        }
        return xml + "</w:numbering>"
    }

    private static let namespaces = [
        #"xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main""#,
        #"xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships""#,
        #"xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing""#,
        #"xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main""#,
        #"xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture""#,
    ].joined(separator: " ")

    private static func relationships(_ items: [(id: String, type: String, target: String, external: Bool)]) -> String {
        let rows = items.map { item in
            let mode = item.external ? #" TargetMode="External""# : ""
            return #"<Relationship Id="\#(item.id)" Type="\#(item.type)" Target="\#(XMLText.escape(item.target))"\#(mode)/>"#
        }.joined()
        return #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\#(rows)</Relationships>"#
    }
}

/// Points → twentieths of a point, Word's unit for sizes and spacing.
private nonisolated func twips(_ points: Double) -> Int {
    Int((points * 20).rounded())
}
