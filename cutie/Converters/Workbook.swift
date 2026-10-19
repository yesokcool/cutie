import Foundation

/// A workbook reduced to what converts cleanly between formats: named sheets
/// of typed cells, each with the text it shows (what CSV, TSV and PDF get)
/// and its value and kind (what XLSX and ODS get). Merged ranges carry over;
/// styling and formulas' expressions don't (their last values do).
nonisolated struct Workbook: Equatable, Sendable {
    struct Sheet: Equatable, Sendable {
        var name: String
        var rows: [[Cell]]
        var merges: [Merge] = []

        init(name: String, rows: [[Cell]], merges: [Merge] = []) {
            self.name = name
            self.rows = rows
            self.merges = merges
        }

        /// A sheet of text read from CSV/TSV: numbers, dates, percentages,
        /// currency and TRUE/FALSE become typed cells.
        init(name: String, text rows: [[String]], decimalComma: Bool = false) {
            self.init(name: name, rows: rows.map { $0.map { Cell.inferred(from: $0, decimalComma: decimalComma) } })
        }

        var textRows: [[String]] { rows.map { $0.map(\.text) } }
    }

    /// A block of cells shown as one; the value lives in the top-left cell.
    struct Merge: Equatable, Sendable {
        var firstRow: Int, firstColumn: Int, lastRow: Int, lastColumn: Int
    }

    struct Cell: Equatable, Sendable, ExpressibleByStringLiteral {
        enum Kind: Equatable, Sendable {
            case text, number, percent, date, time, dateTime, bool
            /// The currency symbol shown, e.g. "$" or "€".
            case currency(String)
        }

        /// What the cell shows.
        var text: String
        /// The number behind it; dates and times as spreadsheet serials (days
        /// since 1899-12-30), booleans as 1/0. Nil for text.
        var value: Double?
        var kind: Kind
        /// Excel's number format code, when known.
        var formatCode: String?

        init(text: String, value: Double? = nil, kind: Kind = .text, formatCode: String? = nil) {
            self.text = text
            self.value = value
            self.kind = value == nil ? .text : kind
            self.formatCode = formatCode
        }

        init(stringLiteral text: String) { self.init(text: text) }

        static let empty = Cell(text: "")

        var isEmpty: Bool { text.isEmpty && value == nil }
    }

    var sheets: [Sheet]
}

// MARK: - Reading typed values out of text

nonisolated extension Workbook.Cell {
    /// What Excel would make of `text` typed into a cell (or opened from a
    /// CSV): plain numbers (not ZIP codes with leading zeros or IDs over 15
    /// digits), percentages, $ € £ ¥ amounts, ISO dates and date-times,
    /// TRUE/FALSE. `decimalComma` reads "12,50" as 12.5 (semicolon CSVs).
    static func inferred(from text: String, decimalComma: Bool = false) -> Self {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return Self(text: text) }
        if let number = SpreadsheetNumber.parse(trimmed, decimalComma: decimalComma) {
            return Self(text: text, value: number.value, kind: number.kind, formatCode: number.formatCode)
        }
        switch trimmed.uppercased() {
        case "TRUE": return Self(text: "TRUE", value: 1, kind: .bool)
        case "FALSE": return Self(text: "FALSE", value: 0, kind: .bool)
        default: break
        }
        if let date = SpreadsheetDate.parseISO(trimmed) {
            let code = date.hasTime ? "yyyy-mm-dd hh:mm:ss" : "yyyy-mm-dd"
            return Self(text: text, value: date.serial, kind: date.hasTime ? .dateTime : .date, formatCode: code)
        }
        return Self(text: text)
    }
}

/// Numbers as people type them into spreadsheets.
nonisolated enum SpreadsheetNumber {
    struct Parsed { var value: Double; var kind: Workbook.Cell.Kind; var formatCode: String? }

    static func parse(_ text: String, decimalComma: Bool) -> Parsed? {
        var body = text
        var negative = false
        if body.hasPrefix("(") && body.hasSuffix(")") {
            negative = true
            body = String(body.dropFirst().dropLast())
        }
        if body.hasPrefix("-") { negative.toggle(); body.removeFirst() }
        var symbol: String?
        for candidate in ["$", "€", "£", "¥"] {
            if body.hasPrefix(candidate) {
                symbol = candidate
                body = String(body.dropFirst()).trimmingCharacters(in: .whitespaces)
            } else if body.hasSuffix(candidate) {
                symbol = candidate
                body = String(body.dropLast()).trimmingCharacters(in: .whitespaces)
            }
            if symbol != nil { break }
        }
        if symbol != nil, body.hasPrefix("-") { negative.toggle(); body.removeFirst() }
        var percent = false
        if symbol == nil, body.hasSuffix("%") {
            percent = true
            body = String(body.dropLast()).trimmingCharacters(in: .whitespaces)
        }
        let (group, decimal): (Character, Character) = decimalComma ? (".", ",") : (",", ".")
        let grouped = body.contains(group)
        guard let normalized = plainDigits(body, group: group, decimal: decimal) else { return nil }
        // Leading zeros (ZIP codes, phone numbers) and long digit runs (IDs, card numbers) stay text.
        let integerPart = normalized.split(separator: ".", omittingEmptySubsequences: false).first ?? ""
        let isPlain = symbol == nil && !percent && !grouped
        if isPlain {
            if integerPart.count > 1 && integerPart.hasPrefix("0") { return nil }
            if !normalized.contains(".") && !normalized.lowercased().contains("e") && integerPart.count > 15 { return nil }
        }
        guard var value = Double(normalized), value.isFinite else { return nil }
        if negative { value = -value }
        let decimals = normalized.split(separator: ".").dropFirst().first.map { $0.prefix { $0.isNumber }.count } ?? 0
        let digits = decimals > 0 ? "0." + String(repeating: "0", count: decimals) : "0"
        if let symbol {
            let code = symbol == "$" || symbol == "£" || symbol == "¥" ? "\(symbol)#,##\(digits)" : "#,##\(digits) \(symbol)"
            return Parsed(value: value, kind: .currency(symbol), formatCode: code)
        }
        if percent { return Parsed(value: value / 100, kind: .percent, formatCode: digits + "%") }
        return Parsed(value: value, kind: .number, formatCode: grouped ? "#,##" + digits : nil)
    }

    /// "1,234.50" → "1234.50"; nil unless it's digits with well-placed groups.
    private static func plainDigits(_ text: String, group: Character, decimal: Character) -> String? {
        let pattern = "^([0-9]{1,3}(\\\(group)[0-9]{3})+|[0-9]+)(\\\(decimal)[0-9]+)?([eE][-+]?[0-9]+)?$"
        guard text.range(of: pattern, options: .regularExpression) != nil else { return nil }
        return String(text.filter { $0 != group }.map { $0 == decimal ? "." : $0 })
    }

    /// Up to 15 significant digits, the most a spreadsheet keeps
    /// (0.1 + 0.2 shows as 0.3, not 0.30000000000000004).
    static func general(_ value: Double) -> String {
        guard value.isFinite else { return "#NUM!" }
        if value == 0 { return "0" }
        let magnitude = abs(value)
        if magnitude >= 1e15 || magnitude < 1e-9 {
            return String(format: "%.14E", value).replacingOccurrences(of: #"\.?0+E"#, with: "E", options: .regularExpression)
        }
        var text = String(format: "%.15g", value)
        if text.contains("e") { text = String(format: "%.15f", value) }
        if text.contains(".") {
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
        }
        return text
    }

    /// A value as written into a file: the shortest text that reads back as the same double.
    static func exact(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
        return "\(value)"
    }
}
