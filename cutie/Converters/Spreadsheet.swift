import Foundation

/// Reads any spreadsheet into a `Workbook` and writes one out as any format Cutie offers.
nonisolated enum Spreadsheet {
    static func read(_ url: URL, scratch: Scratch, toolbox: Toolbox, locale: Locale = .current) async throws -> Workbook {
        let name = Output.baseName(of: url)
        switch FileKind.fileExtension(of: url) {
        case "csv":
            let text = try DocumentReader.readText(url)
            let separator = CSV.separator(of: text)
            let rows = CSV.parse(CSV.droppingDeclaration(text), separator: separator)
            let decimalComma = CSV.usesDecimalComma(rows, separator: separator, locale: locale)
            return Workbook(sheets: [.init(name: name, text: rows, decimalComma: decimalComma)])
        case "tsv":
            let rows = CSV.parse(try DocumentReader.readText(url), separator: "\t")
            let decimalComma = CSV.usesDecimalComma(rows, separator: "\t", locale: locale)
            return Workbook(sheets: [.init(name: name, text: rows, decimalComma: decimalComma)])
        case "xlsx":
            return try await XLSX.read(url, scratch: scratch, locale: locale)
        case "ods":
            return try await ODS.read(url, scratch: scratch)
        case "xls", "numbers":
            let xlsx = scratch.file(UUID().uuidString + ".xlsx")
            if let soffice = toolbox.soffice, url.pathExtension.lowercased() == "xls" {
                try await LibreOffice.convert(url, to: .xlsx, at: xlsx, soffice: soffice, scratch: scratch)
            } else {
                try await IWork.export(url, with: .numbers, to: .xlsx, at: xlsx, toolbox: toolbox)
            }
            return try await XLSX.read(xlsx, scratch: scratch, locale: locale)
        case let ext:
            throw CutieError("Can't open .\(ext) spreadsheets.")
        }
    }

    /// Writes `book`. CSV/TSV hold one sheet, so a multi-sheet workbook becomes a
    /// folder of them; returns whether `output` is a folder.
    @discardableResult
    static func write(_ book: Workbook, as format: Format, to output: URL, title: String, scratch: Scratch, toolbox: Toolbox) async throws -> Bool {
        switch format {
        case .csv, .tsv:
            if book.sheets.count == 1 {
                try delimited(book.sheets[0], as: format).write(to: output)
                return false
            }
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            for sheet in book.sheets {
                let file = output.appending(path: "\(title) - \(safeFileName(sheet.name)).\(format.fileExtension)")
                try delimited(sheet, as: format).write(to: file)
            }
            return true
        case .xlsx:
            try await XLSX.write(book, to: output, scratch: scratch)
        case .ods:
            try await ODS.write(book, to: output, scratch: scratch)
        case .pdf:
            let html = HTML.page(title: title, body: book.sheets.map(tableHTML).joined(separator: "\n"))
            let columns = book.sheets.map { $0.rows.map(\.count).max() ?? 0 }.max() ?? 0
            try await renderPDF(html, to: output, title: title, landscape: columns > 6)
        case .numbers:
            let xlsx = scratch.file(UUID().uuidString + ".xlsx")
            try await XLSX.write(book, to: xlsx, scratch: scratch)
            try await IWork.export(xlsx, with: .numbers, to: .numbers, at: output, toolbox: toolbox)
        default:
            throw CutieError("Can't write \(format.title) spreadsheets.")
        }
        return false
    }

    @MainActor
    private static func renderPDF(_ html: String, to output: URL, title: String, landscape: Bool) async throws {
        let text = try DocumentReader.fromHTML(html, baseURL: nil)
        try await PDFRenderer.renderInBackground(text, to: output, title: title, landscape: landscape)
    }

    /// A sheet as CSV or TSV, each cell as it shows. CSV is what Excel itself
    /// writes: CRLF line ends (RFC 4180), and a UTF-8 byte-order mark when the
    /// text isn't plain ASCII, because Excel reads a CSV without one in the
    /// Mac's or PC's old 8-bit encoding (é turns into Ã©). ASCII-only files
    /// stay mark-free for scripts. TSV is plain UTF-8 with LF.
    static func delimited(_ sheet: Workbook.Sheet, as format: Format) -> Data {
        guard format == .csv else { return Data(CSV.write(sheet.textRows, separator: "\t").utf8) }
        let text = CSV.write(sheet.textRows, separator: ",", lineEnding: "\r\n")
        let mark: [UInt8] = text.utf8.contains { $0 >= 0x80 } ? [0xEF, 0xBB, 0xBF] : []
        return Data(mark) + Data(text.utf8)
    }

    /// A sheet as an HTML table (for PDF): merged ranges span, numbers align right.
    static func tableHTML(_ sheet: Workbook.Sheet) -> String {
        var spans: [[Int]: Workbook.Merge] = [:]
        var covered = Set<[Int]>()
        for merge in sheet.merges {
            spans[[merge.firstRow, merge.firstColumn]] = merge
            for row in merge.firstRow...merge.lastRow {
                for column in merge.firstColumn...merge.lastColumn where [row, column] != [merge.firstRow, merge.firstColumn] {
                    covered.insert([row, column])
                }
            }
        }
        let rows = sheet.rows.enumerated().map { rowIndex, row in
            "<tr>" + row.enumerated().map { columnIndex, cell -> String in
                if covered.contains([rowIndex, columnIndex]) { return "" }
                var attributes = ""
                if let merge = spans[[rowIndex, columnIndex]] {
                    attributes += #" rowspan="\#(merge.lastRow - merge.firstRow + 1)" colspan="\#(merge.lastColumn - merge.firstColumn + 1)""#
                }
                if cell.value != nil && cell.kind != .bool { attributes += #" style="text-align: right""# }
                return "<td\(attributes)>\(HTML.escape(cell.text))</td>"
            }.joined() + "</tr>"
        }.joined(separator: "\n")
        return "<h3>\(HTML.escape(sheet.name))</h3>\n<table>\n\(rows)\n</table>"
    }

    static func safeFileName(_ name: String) -> String {
        name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    }

    /// Spreadsheet column letters: 0 → A, 25 → Z, 26 → AA.
    static func columnName(_ index: Int) -> String {
        var index = index + 1
        var name = ""
        while index > 0 {
            let remainder = (index - 1) % 26
            name = String(UnicodeScalar(65 + remainder)!) + name
            index = (index - 1) / 26
        }
        return name
    }

    /// "AB12" → 27.
    static func columnIndex(ofCell reference: String) -> Int {
        var index = 0
        for scalar in reference.unicodeScalars {
            guard (65...90).contains(scalar.value) else { break }
            index = index * 26 + Int(scalar.value) - 64
        }
        return max(0, index - 1)
    }
}
