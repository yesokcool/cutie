import Foundation

/// Reads any spreadsheet into a `Workbook` and writes one out as any format Cutie offers.
nonisolated enum Spreadsheet {
    static func read(_ url: URL, scratch: Scratch, toolbox: Toolbox) async throws -> Workbook {
        let name = Output.baseName(of: url)
        switch FileKind.fileExtension(of: url) {
        case "csv":
            return Workbook(sheets: [.init(name: name, rows: CSV.parse(try DocumentReader.readText(url), separator: ","))])
        case "tsv":
            return Workbook(sheets: [.init(name: name, rows: CSV.parse(try DocumentReader.readText(url), separator: "\t"))])
        case "xlsx":
            return try await XLSX.read(url, scratch: scratch)
        case "ods":
            return try await ODS.read(url, scratch: scratch)
        case "xls", "numbers":
            let xlsx = scratch.file(UUID().uuidString + ".xlsx")
            if let soffice = toolbox.soffice, url.pathExtension.lowercased() == "xls" {
                try await LibreOffice.convert(url, to: .xlsx, at: xlsx, soffice: soffice, scratch: scratch)
            } else {
                try await IWork.export(url, with: .numbers, to: .xlsx, at: xlsx, toolbox: toolbox)
            }
            return try await XLSX.read(xlsx, scratch: scratch)
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
            let separator: Character = format == .csv ? "," : "\t"
            if book.sheets.count == 1 {
                try Data(CSV.write(book.sheets[0].rows, separator: separator).utf8).write(to: output)
                return false
            }
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            for sheet in book.sheets {
                let file = output.appending(path: "\(title) - \(safeFileName(sheet.name)).\(format.fileExtension)")
                try Data(CSV.write(sheet.rows, separator: separator).utf8).write(to: file)
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

    static func tableHTML(_ sheet: Workbook.Sheet) -> String {
        let rows = sheet.rows.map { row in
            "<tr>" + row.map { "<td>\(HTML.escape($0))</td>" }.joined() + "</tr>"
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
