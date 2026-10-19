import Foundation

/// OpenDocument spreadsheets (LibreOffice), read and written directly.
/// Cells keep their type (number, percentage, currency, date, time,
/// boolean, text), what they show, and merged ranges.
nonisolated enum ODS {
    private static let office = "urn:oasis:names:tc:opendocument:xmlns:office:1.0"
    private static let table = "urn:oasis:names:tc:opendocument:xmlns:table:1.0"

    static func read(_ url: URL, scratch: Scratch) async throws -> Workbook {
        let folder = try scratch.folder("ods-" + UUID().uuidString)
        try await ArchiveConverter.unzip(url, into: folder)
        guard let stream = InputStream(url: folder.appending(path: "content.xml")) else {
            throw CutieError("This spreadsheet has no content.")
        }
        let reader = Reader()
        let parser = XMLParser(stream: stream)
        parser.shouldProcessNamespaces = true
        parser.delegate = reader
        guard parser.parse() else { throw CutieError("This spreadsheet is damaged.") }
        guard !reader.sheets.isEmpty else { throw CutieError("This spreadsheet has no sheets.") }
        return Workbook(sheets: reader.sheets)
    }

    // MARK: - Reading

    /// content.xml, streamed. Repeated rows and cells are expanded, except runs
    /// of empty ones, which only materialize when something follows them
    /// (files pad sheets to a million rows).
    private nonisolated final class Reader: NSObject, XMLParserDelegate {
        var sheets: [Workbook.Sheet] = []

        private var name = ""
        private var rows: [[Workbook.Cell]] = []
        private var merges: [Workbook.Merge] = []
        private var pendingEmptyRows = 0
        private var rowRepeats = 1
        private var cells: [Workbook.Cell] = []
        private var pendingEmptyCells = 0
        private var rowSpans: [(column: Int, rows: Int, columns: Int)] = []

        private var cellAttributes: [String: String] = [:]
        private var paragraphs: [String] = []
        private var paragraph = ""
        private var paragraphDepth = 0
        private var annotationDepth = 0

        /// Attribute names without their namespace prefix ("office:value" → "value").
        private func local(_ attributes: [String: String]) -> [String: String] {
            var result: [String: String] = [:]
            for (key, value) in attributes {
                let name = key.split(separator: ":").last.map(String.init) ?? key
                if result[name] == nil || key.hasPrefix("office:") || key.hasPrefix("table:") { result[name] = value }
            }
            return result
        }

        func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            if annotationDepth > 0 {
                if element == "annotation" { annotationDepth += 1 }
                return
            }
            switch element {
            case "table" where namespaceURI == ODS.table:
                name = local(attributes)["name"] ?? "Sheet\(sheets.count + 1)"
                rows = []
                merges = []
                pendingEmptyRows = 0
            case "table-row":
                rowRepeats = Int(local(attributes)["number-rows-repeated"] ?? "1") ?? 1
                cells = []
                pendingEmptyCells = 0
                rowSpans = []
            case "table-cell", "covered-table-cell":
                cellAttributes = local(attributes)
                paragraphs = []
            case "p", "h":
                paragraphDepth += 1
                paragraph = ""
            case "s" where paragraphDepth > 0:
                paragraph += String(repeating: " ", count: Int(local(attributes)["c"] ?? "1") ?? 1)
            case "tab" where paragraphDepth > 0:
                paragraph += "\t"
            case "line-break" where paragraphDepth > 0:
                paragraph += "\n"
            case "annotation":
                annotationDepth = 1
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if paragraphDepth > 0 && annotationDepth == 0 { paragraph += string }
        }

        func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
            if annotationDepth > 0 {
                if element == "annotation" { annotationDepth -= 1 }
                return
            }
            switch element {
            case "p", "h":
                paragraphDepth -= 1
                if paragraphDepth == 0 { paragraphs.append(paragraph) }
            case "table-cell", "covered-table-cell":
                let count = Int(cellAttributes["number-columns-repeated"] ?? "1") ?? 1
                let cell = element == "table-cell" ? makeCell() : .empty
                if cell.isEmpty { pendingEmptyCells += count; return }
                cells += Array(repeating: .empty, count: pendingEmptyCells)
                pendingEmptyCells = 0
                let spanRows = Int(cellAttributes["number-rows-spanned"] ?? "1") ?? 1
                let spanColumns = Int(cellAttributes["number-columns-spanned"] ?? "1") ?? 1
                if spanRows > 1 || spanColumns > 1 { rowSpans.append((cells.count, spanRows, spanColumns)) }
                cells += Array(repeating: cell, count: min(count, 1000))
            case "table-row":
                if cells.isEmpty { pendingEmptyRows += rowRepeats; return }
                rows += Array(repeating: [], count: min(pendingEmptyRows, 10_000))
                pendingEmptyRows = 0
                for span in rowSpans {
                    merges.append(Workbook.Merge(firstRow: rows.count, firstColumn: span.column,
                                                 lastRow: rows.count + span.rows - 1, lastColumn: span.column + span.columns - 1))
                }
                rows += Array(repeating: cells, count: min(rowRepeats, 10_000))
            case "table" where namespaceURI == ODS.table:
                sheets.append(Workbook.Sheet(name: name, rows: rows, merges: merges))
            default: break
            }
        }

        private func makeCell() -> Workbook.Cell {
            let shown = paragraphs.joined(separator: "\n")
            let type = cellAttributes["value-type"]
            let number = cellAttributes["value"].flatMap(Double.init)
            switch type {
            case "float", "percentage", "currency":
                guard let number else { return Workbook.Cell(text: shown) }
                guard number.isFinite else { return Workbook.Cell(text: "#NUM!") }
                let text = shown.isEmpty ? SpreadsheetNumber.general(number) : shown
                let shape = ODS.shape(of: shown, matching: number)
                switch type {
                case "percentage":
                    return Workbook.Cell(text: text, value: number, kind: .percent, formatCode: shape?.formatCode ?? "0%")
                case "currency":
                    let symbol = cellAttributes["currency"].flatMap(ODS.symbol(forCurrency:)) ?? {
                        if case .currency(let symbol)? = shape?.kind { return symbol }
                        return cellAttributes["currency"] ?? "$"
                    }()
                    let code = shape?.formatCode ?? "\"\(symbol)\"#,##0.00"
                    return Workbook.Cell(text: text, value: number, kind: .currency(symbol), formatCode: code)
                default:
                    return Workbook.Cell(text: text, value: number, kind: .number, formatCode: shape?.formatCode)
                }
            case "date":
                guard let raw = cellAttributes["date-value"], let date = SpreadsheetDate.parseISO(String(raw.prefix(19))) else {
                    return Workbook.Cell(text: shown)
                }
                let code = date.hasTime ? "yyyy-mm-dd hh:mm:ss" : "yyyy-mm-dd"
                return Workbook.Cell(text: shown.isEmpty ? NumberFormat(code: code).format(date.serial) : shown,
                                     value: date.serial, kind: date.hasTime ? .dateTime : .date, formatCode: code)
            case "time":
                guard let raw = cellAttributes["time-value"], let time = SpreadsheetDate.parseDuration(raw) else {
                    return Workbook.Cell(text: shown)
                }
                return Workbook.Cell(text: shown.isEmpty ? NumberFormat(code: "hh:mm:ss").format(time) : shown,
                                     value: time, kind: .time, formatCode: "hh:mm:ss")
            case "boolean":
                let on = cellAttributes["boolean-value"] == "true"
                return Workbook.Cell(text: on ? "TRUE" : "FALSE", value: on ? 1 : 0, kind: .bool)
            default:
                return Workbook.Cell(text: cellAttributes["string-value"] ?? shown)
            }
        }
    }

    /// How a cell's shown text formats its value ("1,500" for 1.5 in German is
    /// three decimals; "1,500" for 1500 in English is grouping). The text is
    /// read both ways and only the reading that gives back the stored value
    /// (allowing for the rounding the text shows) counts.
    static func shape(of shown: String, matching value: Double) -> SpreadsheetNumber.Parsed? {
        let trimmed = shown.trimmingCharacters(in: .whitespaces)
        for decimalComma in [false, true] {
            guard let parsed = SpreadsheetNumber.parse(trimmed, decimalComma: decimalComma) else { continue }
            let mark: Character = decimalComma ? "," : "."
            let places = trimmed.split(separator: mark).dropFirst().first.map { $0.prefix(while: \.isNumber).count } ?? 0
            let scale = parsed.kind == .percent ? 0.01 : 1
            let tolerance = max(abs(value) * 1e-9, 0.5 * pow(10, -Double(places)) * scale)
            if abs(parsed.value - value) <= tolerance { return parsed }
        }
        return nil
    }

    static let currencies: [String: String] = [
        "USD": "$", "EUR": "€", "GBP": "£", "JPY": "¥", "CNY": "¥", "INR": "₹", "KRW": "₩", "RUB": "₽",
        "BRL": "R$", "CHF": "CHF", "PLN": "zł", "CZK": "Kč", "SEK": "kr", "NOK": "kr", "DKK": "kr",
        "CAD": "$", "AUD": "$",
    ]

    static func symbol(forCurrency code: String) -> String? { currencies[code.uppercased()] }

    /// The ISO code for a symbol, when it's unambiguous enough to write.
    static func currencyCode(for symbol: String) -> String? {
        ["$": "USD", "€": "EUR", "£": "GBP", "¥": "JPY", "₹": "INR", "₩": "KRW", "₽": "RUB", "R$": "BRL",
         "CHF": "CHF", "zł": "PLN", "Kč": "CZK"][symbol]
    }

    // MARK: - Writing

    static func write(_ book: Workbook, to output: URL, scratch: Scratch) async throws {
        let root = try scratch.folder("ods-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appending(path: "META-INF"), withIntermediateDirectories: true)
        try Data("application/vnd.oasis.opendocument.spreadsheet".utf8).write(to: root.appending(path: "mimetype"))
        try Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <manifest:manifest xmlns:manifest="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0" manifest:version="1.2">
         <manifest:file-entry manifest:full-path="/" manifest:version="1.2" manifest:media-type="application/vnd.oasis.opendocument.spreadsheet"/>
         <manifest:file-entry manifest:full-path="content.xml" manifest:media-type="text/xml"/>
        </manifest:manifest>
        """.utf8).write(to: root.appending(path: "META-INF/manifest.xml"))

        var styles = DataStyles()
        var tables = ""
        for sheet in book.sheets {
            try Task.checkCancellation()
            tables += table(sheet, styles: &styles)
        }
        try Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <office:document-content xmlns:office="\(office)" xmlns:table="\(table)" xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" xmlns:style="urn:oasis:names:tc:opendocument:xmlns:style:1.0" xmlns:number="urn:oasis:names:tc:opendocument:xmlns:datastyle:1.0" xmlns:fo="urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0" office:version="1.2"><office:automatic-styles>\(styles.xml)</office:automatic-styles><office:body><office:spreadsheet>\(tables)</office:spreadsheet></office:body></office:document-content>
        """.utf8).write(to: root.appending(path: "content.xml"))

        try await ArchiveConverter.zipContents(of: root, to: output, storedFirst: "mimetype")
    }

    private static func table(_ sheet: Workbook.Sheet, styles: inout DataStyles) -> String {
        var spans: [Int: [Int: (rows: Int, columns: Int)]] = [:]
        var covered = Set<[Int]>()
        var lastColumn = sheet.rows.map(\.count).max() ?? 0
        var lastRow = sheet.rows.count
        for merge in sheet.merges {
            spans[merge.firstRow, default: [:]][merge.firstColumn] = (merge.lastRow - merge.firstRow + 1, merge.lastColumn - merge.firstColumn + 1)
            for row in merge.firstRow...merge.lastRow {
                for column in merge.firstColumn...merge.lastColumn where row != merge.firstRow || column != merge.firstColumn {
                    covered.insert([row, column])
                }
            }
            lastColumn = max(lastColumn, merge.lastColumn + 1)
            lastRow = max(lastRow, merge.lastRow + 1)
        }

        let coveredRows = Set(covered.map { $0[0] })

        var xml = #"<table:table table:name="\#(XMLText.escape(sheet.name))">"#
        xml += #"<table:table-column table:number-columns-repeated="\#(max(1, lastColumn))"/>"#
        for rowIndex in 0..<lastRow {
            let row = rowIndex < sheet.rows.count ? sheet.rows[rowIndex] : []
            let width = max(row.count, coveredRows.contains(rowIndex) || spans[rowIndex] != nil ? lastColumn : 0)
            xml += "<table:table-row>"
            if width == 0 { xml += "<table:table-cell/>" }
            for columnIndex in 0..<width {
                if covered.contains([rowIndex, columnIndex]) {
                    xml += "<table:covered-table-cell/>"
                    continue
                }
                let cell = columnIndex < row.count ? row[columnIndex] : .empty
                xml += cellXML(cell, span: spans[rowIndex]?[columnIndex], styles: &styles)
            }
            xml += "</table:table-row>"
        }
        return xml + "</table:table>"
    }

    private static func cellXML(_ cell: Workbook.Cell, span: (rows: Int, columns: Int)?, styles: inout DataStyles) -> String {
        var attributes = ""
        if let span {
            attributes += #" table:number-rows-spanned="\#(span.rows)" table:number-columns-spanned="\#(span.columns)""#
        }
        if cell.isEmpty { return "<table:table-cell\(attributes)/>" }
        if let style = styles.cellStyle(for: cell) { attributes += #" table:style-name="\#(style)""# }
        if let value = cell.value {
            switch cell.kind {
            case .number:
                attributes += #" office:value-type="float" office:value="\#(SpreadsheetNumber.exact(value))""#
            case .percent:
                attributes += #" office:value-type="percentage" office:value="\#(SpreadsheetNumber.exact(value))""#
            case .currency(let symbol):
                let code = currencyCode(for: symbol).map { #" office:currency="\#($0)""# } ?? ""
                attributes += #" office:value-type="currency"\#(code) office:value="\#(SpreadsheetNumber.exact(value))""#
            case .date:
                attributes += #" office:value-type="date" office:date-value="\#(SpreadsheetDate.iso(value, time: false))""#
            case .dateTime:
                attributes += #" office:value-type="date" office:date-value="\#(SpreadsheetDate.iso(value, time: true))""#
            case .time:
                attributes += #" office:value-type="time" office:time-value="\#(SpreadsheetDate.isoDuration(value))""#
            case .bool:
                attributes += #" office:value-type="boolean" office:boolean-value="\#(value != 0)""#
            case .text:
                attributes += #" office:value-type="string""#
            }
        } else {
            attributes += #" office:value-type="string""#
        }
        let paragraphs = cell.text.components(separatedBy: "\n").map { "<text:p>\(paragraph($0))</text:p>" }.joined()
        return "<table:table-cell\(attributes)>\(paragraphs)</table:table-cell>"
    }

    /// A line as ODF text: runs of spaces and leading spaces need `text:s`, tabs `text:tab`.
    private static func paragraph(_ line: String) -> String {
        var result = "", spaces = 0, atStart = true
        func flush() {
            guard spaces > 0 else { return }
            if atStart { result += #"<text:s text:c="\#(spaces)"/>"# } else {
                result += " "
                if spaces > 1 { result += #"<text:s text:c="\#(spaces - 1)"/>"# }
            }
            spaces = 0
        }
        for character in line {
            switch character {
            case " ": spaces += 1
            case "\t": flush(); result += "<text:tab/>"; atStart = false
            default:
                flush()
                result += XMLText.escape(String(character))
                atStart = false
            }
        }
        if spaces > 0 { atStart = true; flush() }
        return result
    }

    /// Number styles (how a number, date or amount shows) and the cell styles that use them.
    private nonisolated struct DataStyles {
        private var names: [String: String] = [:]
        private(set) var xml = ""

        mutating func cellStyle(for cell: Workbook.Cell) -> String? {
            guard cell.value != nil else { return nil }
            let format = NumberFormat(code: XLSX.formatCode(for: cell) ?? "General")
            let shape = format.shape
            let key: String
            let body: String
            func number(_ decimals: Int, _ grouped: Bool) -> String {
                #"<number:number number:decimal-places="\#(decimals)" number:min-decimal-places="\#(decimals)" number:min-integer-digits="1"\#(grouped ? #" number:grouping="true""# : "")/>"#
            }
            func text(_ text: String) -> String { "<number:text>\(XMLText.escape(text))</number:text>" }
            let long = #" number:style="long""#
            switch cell.kind {
            case .date:
                key = "date"
                body = "<number:date-style style:name=\"%@\"><number:year\(long)/>\(text("-"))<number:month\(long)/>\(text("-"))<number:day\(long)/></number:date-style>"
            case .dateTime:
                key = "datetime"
                body = "<number:date-style style:name=\"%@\"><number:year\(long)/>\(text("-"))<number:month\(long)/>\(text("-"))<number:day\(long)/>\(text(" "))<number:hours\(long)/>\(text(":"))<number:minutes\(long)/>\(text(":"))<number:seconds\(long)/></number:date-style>"
            case .time:
                key = "time"
                body = "<number:time-style style:name=\"%@\"><number:hours\(long)/>\(text(":"))<number:minutes\(long)/>\(text(":"))<number:seconds\(long)/></number:time-style>"
            case .bool:
                key = "bool"
                body = "<number:boolean-style style:name=\"%@\"><number:boolean/></number:boolean-style>"
            case .percent:
                key = "percent\(shape.decimals)"
                body = "<number:percentage-style style:name=\"%@\">\(number(shape.decimals, false))\(text("%"))</number:percentage-style>"
            case .currency(let symbol):
                key = "currency\(symbol)\(shape.decimals)\(shape.symbolFirst)"
                let sign = "<number:currency-symbol>\(XMLText.escape(symbol))</number:currency-symbol>"
                let digits = number(shape.decimals, true)
                body = "<number:currency-style style:name=\"%@\">" + (shape.symbolFirst ? sign + digits : digits + text(" ") + sign) + "</number:currency-style>"
            case .number:
                guard cell.formatCode != nil else { return nil }
                key = "number\(shape.decimals)\(shape.grouped)"
                body = "<number:number-style style:name=\"%@\">\(number(shape.decimals, shape.grouped))</number:number-style>"
            case .text:
                return nil
            }
            if let name = names[key] { return name }
            let index = names.count + 1
            let dataName = "N\(index)", cellName = "ce\(index)"
            xml += body.replacingOccurrences(of: "%@", with: dataName)
            xml += #"<style:style style:name="\#(cellName)" style:family="table-cell" style:data-style-name="\#(dataName)"/>"#
            names[key] = cellName
            return cellName
        }
    }
}
