import Foundation

/// Excel workbooks, read and written directly (they're zipped XML).
///
/// Reading streams each sheet with `XMLParser` (a whole-document tree of a
/// 14 MB workbook took 3.9 GB) and shows every cell the way Excel does: its
/// number format applied (dates, percentages, currency, decimals), the 1904
/// date system respected, formulas' last values, merged ranges kept.
nonisolated enum XLSX {
    private static let main = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
    private static let relationshipsNS = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"

    static func read(_ url: URL, scratch: Scratch, locale: Locale = .current) async throws -> Workbook {
        let folder = try scratch.folder("xlsx-" + UUID().uuidString)
        try await ArchiveConverter.unzip(url, into: folder)
        let xl = folder.appending(path: "xl")

        let workbook = try XMLDocument(contentsOf: xl.appending(path: "workbook.xml"))
        let rels = try XMLDocument(contentsOf: xl.appending(path: "_rels/workbook.xml.rels"))
        var targets: [String: String] = [:]
        for node in try rels.nodes(forXPath: "//*[local-name()='Relationship']") {
            guard let element = node as? XMLElement,
                  let id = element.attribute(forName: "Id")?.stringValue,
                  let target = element.attribute(forName: "Target")?.stringValue else { continue }
            targets[id] = target
        }
        let properties = try workbook.nodes(forXPath: "//*[local-name()='workbookPr']").first as? XMLElement
        let date1904 = ["1", "true"].contains(properties?.attribute(forName: "date1904")?.stringValue ?? "")

        let styles = Styles(try? XMLDocument(contentsOf: xl.appending(path: "styles.xml")), locale: locale)
        let shared = try SharedStrings.read(xl.appending(path: "sharedStrings.xml"))

        var sheets: [Workbook.Sheet] = []
        for node in try workbook.nodes(forXPath: "//*[local-name()='sheet']") {
            try Task.checkCancellation()
            guard let element = node as? XMLElement,
                  let name = element.attribute(forName: "name")?.stringValue,
                  let id = element.attribute(forLocalName: "id", uri: relationshipsNS)?.stringValue,
                  let target = targets[id], target.contains("worksheets/") else { continue }
            let path = target.hasPrefix("/") ? folder.appending(path: String(target.dropFirst())) : xl.appending(path: target)
            guard FileManager.default.fileExists(atPath: path.path) else { continue }
            let reader = SheetReader(shared: shared, styles: styles, date1904: date1904, locale: locale)
            sheets.append(try reader.read(path, name: name))
        }
        guard !sheets.isEmpty else { throw CutieError("This workbook has no sheets.") }
        return Workbook(sheets: sheets)
    }

    /// Excel escapes characters XML can't hold as `_xHHHH_` ("_x000D_" is a carriage return).
    static func unescape(_ text: String) -> String {
        guard text.contains("_x") else { return text }
        return text.replacing(/_x([0-9A-Fa-f]{4})_/) { match in
            UInt32(match.output.1, radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) } ?? String(match.output.0)
        }
    }

    // MARK: - Styles

    /// Which number format each cell style (`s`) uses.
    nonisolated struct Styles {
        var formats: [NumberFormat] = []

        init(_ document: XMLDocument?, locale: Locale) {
            guard let document else { return }
            var custom: [Int: String] = [:]
            for node in (try? document.nodes(forXPath: "//*[local-name()='numFmts']/*[local-name()='numFmt']")) ?? [] {
                guard let element = node as? XMLElement,
                      let id = element.attribute(forName: "numFmtId")?.stringValue.flatMap(Int.init),
                      let code = element.attribute(forName: "formatCode")?.stringValue else { continue }
                custom[id] = code
            }
            for node in (try? document.nodes(forXPath: "//*[local-name()='cellXfs']/*[local-name()='xf']")) ?? [] {
                let id = (node as? XMLElement)?.attribute(forName: "numFmtId")?.stringValue.flatMap(Int.init) ?? 0
                formats.append(NumberFormat(id: id, custom: custom, locale: locale))
            }
        }

        func format(_ index: Int) -> NumberFormat {
            formats.indices.contains(index) ? formats[index] : NumberFormat(code: "General")
        }
    }

    // MARK: - Shared strings

    /// The workbook's string table, streamed: each `si`'s text runs, without phonetic guides.
    private nonisolated final class SharedStrings: NSObject, XMLParserDelegate {
        var strings: [String] = []
        private var current = ""
        private var inText = false, inPhonetic = false

        static func read(_ url: URL) throws -> [String] {
            guard FileManager.default.fileExists(atPath: url.path), let stream = InputStream(url: url) else { return [] }
            let reader = SharedStrings()
            let parser = XMLParser(stream: stream)
            parser.shouldProcessNamespaces = true
            parser.delegate = reader
            guard parser.parse() else { throw CutieError("This workbook's text table is damaged.") }
            return reader.strings
        }

        func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            switch element {
            case "si": current = ""
            case "t": inText = true
            case "rPh": inPhonetic = true
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inText && !inPhonetic { current += string }
        }

        func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
            switch element {
            case "si": strings.append(XLSX.unescape(current))
            case "t": inText = false
            case "rPh": inPhonetic = false
            default: break
            }
        }
    }

    // MARK: - Sheets

    /// One worksheet, streamed row by row.
    private nonisolated final class SheetReader: NSObject, XMLParserDelegate {
        let shared: [String]
        let styles: Styles
        let date1904: Bool
        let locale: Locale

        private var rows: [[Workbook.Cell]] = []
        private var merges: [Workbook.Merge] = []
        private var row: [Workbook.Cell] = []
        private var rowNumber = 0
        private var reference: String?, type = "n", style = 0
        private var value = "", inline = ""
        private var inValue = false, inInline = false, inText = false, inPhonetic = false

        init(shared: [String], styles: Styles, date1904: Bool, locale: Locale) {
            self.shared = shared
            self.styles = styles
            self.date1904 = date1904
            self.locale = locale
        }

        func read(_ url: URL, name: String) throws -> Workbook.Sheet {
            guard let stream = InputStream(url: url) else { throw CutieError("Couldn't open the sheet “\(name)”.") }
            let parser = XMLParser(stream: stream)
            parser.shouldProcessNamespaces = true
            parser.delegate = self
            guard parser.parse() else { throw CutieError("The sheet “\(name)” is damaged.") }
            while rows.last?.isEmpty == true { rows.removeLast() }
            return Workbook.Sheet(name: name, rows: rows, merges: merges)
        }

        func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            switch element {
            case "row":
                rowNumber = attributes["r"].flatMap(Int.init) ?? rowNumber + 1
                row = []
            case "c":
                reference = attributes["r"]
                type = attributes["t"] ?? "n"
                style = attributes["s"].flatMap(Int.init) ?? 0
                value = ""
                inline = ""
            case "v": inValue = true
            case "is": inInline = true
            case "t": inText = true
            case "rPh": inPhonetic = true
            case "mergeCell":
                if let range = attributes["ref"], let merge = XLSX.merge(range) { merges.append(merge) }
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inValue { value += string } else if inInline && inText && !inPhonetic { inline += string }
        }

        func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
            switch element {
            case "v": inValue = false
            case "is": inInline = false
            case "t": inText = false
            case "rPh": inPhonetic = false
            case "c":
                let column = reference.map(Spreadsheet.columnIndex(ofCell:)) ?? row.count
                let cell = makeCell()
                guard !cell.isEmpty else { return }
                while row.count < column { row.append(.empty) }
                if row.count == column { row.append(cell) } else if column < row.count { row[column] = cell }
            case "row":
                while rows.count < rowNumber - 1 { rows.append([]) }
                if rows.count == rowNumber - 1 { rows.append(row) } else if rowNumber - 1 < rows.count { rows[rowNumber - 1] = row }
            default: break
            }
        }

        private func makeCell() -> Workbook.Cell {
            switch type {
            case "s":
                return Int(value).flatMap { shared.indices.contains($0) ? Workbook.Cell(text: shared[$0]) : nil } ?? .empty
            case "inlineStr":
                return Workbook.Cell(text: XLSX.unescape(inline))
            case "str", "e":
                return Workbook.Cell(text: XLSX.unescape(value))
            case "b":
                let on = value == "1" || value.lowercased() == "true"
                return Workbook.Cell(text: on ? "TRUE" : "FALSE", value: on ? 1 : 0, kind: .bool)
            case "d":
                guard let date = SpreadsheetDate.parseISO(String(value.prefix(19))) else { return Workbook.Cell(text: value) }
                let format = styles.format(style)
                let code = [.date, .dateTime, .time].contains(format.kind) ? format.code : (date.hasTime ? "yyyy-mm-dd hh:mm:ss" : "yyyy-mm-dd")
                return Workbook.Cell(text: NumberFormat(code: code).format(date.serial, locale: locale), value: date.serial,
                                     kind: date.hasTime ? .dateTime : .date, formatCode: code)
            default:
                guard !value.isEmpty, var number = Double(value) else { return .empty }
                let format = styles.format(style)
                let kind = format.kind
                if kind == .text { return Workbook.Cell(text: SpreadsheetNumber.general(number)) }
                if date1904, [.date, .dateTime].contains(kind) { number += SpreadsheetDate.offset1904 }
                return Workbook.Cell(text: format.format(number, locale: locale), value: number, kind: kind,
                                     formatCode: format.isGeneral ? nil : format.code)
            }
        }
    }

    /// "B2:D4" → rows 1…3, columns 1…3.
    static func merge(_ range: String) -> Workbook.Merge? {
        let ends = range.split(separator: ":").map(String.init)
        guard ends.count == 2, let first = cellPosition(ends[0]), let last = cellPosition(ends[1]) else { return nil }
        return Workbook.Merge(firstRow: first.row, firstColumn: first.column, lastRow: last.row, lastColumn: last.column)
    }

    private static func cellPosition(_ reference: String) -> (row: Int, column: Int)? {
        let digits = reference.drop { !$0.isNumber }
        guard let row = Int(digits), row > 0 else { return nil }
        return (row - 1, Spreadsheet.columnIndex(ofCell: reference))
    }

    // MARK: - Writing

    static func write(_ book: Workbook, to output: URL, scratch: Scratch) async throws {
        let root = try scratch.folder("xlsx-" + UUID().uuidString)
        for folder in ["_rels", "xl/_rels", "xl/worksheets"] {
            try FileManager.default.createDirectory(at: root.appending(path: folder), withIntermediateDirectories: true)
        }
        func put(_ path: String, _ text: String) throws { try Data(text.utf8).write(to: root.appending(path: path)) }

        var styles = StyleTable()
        let names = uniqueSheetNames(book.sheets.map(\.name))
        var overrides = "", sheetList = "", relations = ""
        for (index, sheet) in book.sheets.enumerated() {
            try Task.checkCancellation()
            let number = index + 1
            overrides += #"<Override PartName="/xl/worksheets/sheet\#(number).xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>"#
            sheetList += #"<sheet name="\#(XMLText.escape(names[index]))" sheetId="\#(number)" r:id="rId\#(number)"/>"#
            relations += #"<Relationship Id="rId\#(number)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet\#(number).xml"/>"#
            try put("xl/worksheets/sheet\(number).xml", worksheet(sheet, styles: &styles))
        }
        let stylesID = "rId\(book.sheets.count + 1)"
        relations += #"<Relationship Id="\#(stylesID)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>"#

        try put("[Content_Types].xml", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>\(overrides)</Types>
        """)
        try put("_rels/.rels", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>
        """)
        try put("xl/workbook.xml", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="\(main)" xmlns:r="\(relationshipsNS)"><sheets>\(sheetList)</sheets></workbook>
        """)
        try put("xl/_rels/workbook.xml.rels", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\(relations)</Relationships>
        """)
        try put("xl/styles.xml", styles.xml)
        try await ArchiveConverter.zipContents(of: root, to: output)
    }

    /// The number formats used, each with its cell style (`s` index).
    nonisolated struct StyleTable {
        private(set) var codes: [String] = []

        /// Excel's own ids for common codes; custom ones start at 164.
        static let builtIn: [String: Int] = [
            "0": 1, "0.00": 2, "#,##0": 3, "#,##0.00": 4, "0%": 9, "0.00%": 10, "0.00E+00": 11,
            "h:mm": 20, "h:mm:ss": 21, "@": 49,
        ]

        /// The style index for `code` (0 is General).
        mutating func style(for code: String?) -> Int {
            guard let code, code.caseInsensitiveCompare("General") != .orderedSame else { return 0 }
            if let index = codes.firstIndex(of: code) { return index + 1 }
            codes.append(code)
            return codes.count
        }

        var xml: String {
            var custom = "", xfs = #"<xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>"#
            var next = 164
            for code in codes {
                let id: Int
                if let builtIn = Self.builtIn[code] {
                    id = builtIn
                } else {
                    id = next
                    next += 1
                    custom += #"<numFmt numFmtId="\#(id)" formatCode="\#(XMLText.escape(code))"/>"#
                }
                xfs += #"<xf numFmtId="\#(id)" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>"#
            }
            let numFmts = custom.isEmpty ? "" : #"<numFmts count="\#(next - 164)">\#(custom)</numFmts>"#
            return """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <styleSheet xmlns="\(XLSX.main)">\(numFmts)<fonts count="1"><font><sz val="12"/><name val="Calibri"/></font></fonts><fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills><borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="\(codes.count + 1)">\(xfs)</cellXfs><cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles></styleSheet>
            """
        }
    }

    /// The Excel format code a cell is written with.
    static func formatCode(for cell: Workbook.Cell) -> String? {
        if let code = cell.formatCode { return code }
        switch cell.kind {
        case .date: return "yyyy-mm-dd"
        case .dateTime: return "yyyy-mm-dd hh:mm:ss"
        case .time: return "hh:mm:ss"
        case .percent: return "0.00%"
        case .currency(let symbol): return "\"\(symbol)\"#,##0.00"
        case .text, .number, .bool: return nil
        }
    }

    private static func worksheet(_ sheet: Workbook.Sheet, styles: inout StyleTable) -> String {
        var xml = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><worksheet xmlns="\#(main)"><sheetData>"#
        for (rowIndex, row) in sheet.rows.enumerated() where !row.allSatisfy(\.isEmpty) {
            xml += #"<row r="\#(rowIndex + 1)">"#
            for (columnIndex, cell) in row.enumerated() where !cell.isEmpty {
                let reference = Spreadsheet.columnName(columnIndex) + String(rowIndex + 1)
                switch (cell.kind, cell.value) {
                case (.bool, let value?):
                    xml += #"<c r="\#(reference)" t="b"><v>\#(value != 0 ? 1 : 0)</v></c>"#
                case (.text, _), (_, nil):
                    xml += #"<c r="\#(reference)" t="inlineStr"><is><t xml:space="preserve">\#(XMLText.escape(cell.text))</t></is></c>"#
                case (_, let value?):
                    let style = styles.style(for: formatCode(for: cell))
                    let styleAttribute = style == 0 ? "" : #" s="\#(style)""#
                    xml += #"<c r="\#(reference)"\#(styleAttribute)><v>\#(SpreadsheetNumber.exact(value))</v></c>"#
                }
            }
            xml += "</row>"
        }
        xml += "</sheetData>"
        if !sheet.merges.isEmpty {
            xml += #"<mergeCells count="\#(sheet.merges.count)">"#
            for merge in sheet.merges {
                let from = Spreadsheet.columnName(merge.firstColumn) + String(merge.firstRow + 1)
                let to = Spreadsheet.columnName(merge.lastColumn) + String(merge.lastRow + 1)
                xml += #"<mergeCell ref="\#(from):\#(to)"/>"#
            }
            xml += "</mergeCells>"
        }
        return xml + "</worksheet>"
    }

    /// Excel's rules: 31 characters, none of []:*?/\, unique.
    static func uniqueSheetNames(_ names: [String]) -> [String] {
        var used = Set<String>()
        return names.enumerated().map { index, name in
            var clean = String(name.filter { !"[]:*?/\\".contains($0) }.prefix(31))
            if clean.isEmpty { clean = "Sheet\(index + 1)" }
            var candidate = clean
            var number = 2
            while used.contains(candidate.lowercased()) {
                candidate = String(clean.prefix(28)) + " \(number)"
                number += 1
            }
            used.insert(candidate.lowercased())
            return candidate
        }
    }
}
