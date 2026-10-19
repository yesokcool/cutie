import Foundation

/// OpenDocument spreadsheets (LibreOffice), read and written directly.
nonisolated enum ODS {
    private static let office = "urn:oasis:names:tc:opendocument:xmlns:office:1.0"
    private static let table = "urn:oasis:names:tc:opendocument:xmlns:table:1.0"

    static func read(_ url: URL, scratch: Scratch) async throws -> Workbook {
        let folder = try scratch.folder("ods-" + UUID().uuidString)
        try await ArchiveConverter.unzip(url, into: folder)
        let content = try XMLDocument(contentsOf: folder.appending(path: "content.xml"))

        var sheets: [Workbook.Sheet] = []
        for node in try content.nodes(forXPath: "//*[local-name()='spreadsheet']/*[local-name()='table']") {
            guard let element = node as? XMLElement else { continue }
            let name = element.attribute(forLocalName: "name", uri: table)?.stringValue ?? "Sheet\(sheets.count + 1)"
            sheets.append(.init(name: name, rows: rows(of: element)))
        }
        guard !sheets.isEmpty else { throw CutieError("This spreadsheet has no sheets.") }
        return Workbook(sheets: sheets)
    }

    /// Rows with repeats expanded — except runs of empty rows/cells, which only
    /// materialize when something follows them (files pad sheets to a million rows).
    private static func rows(of sheet: XMLElement) -> [[String]] {
        var rows: [[String]] = []
        var pendingEmptyRows = 0
        for row in tableRows(in: sheet) {
            let repeats = Int(row.attribute(forLocalName: "number-rows-repeated", uri: table)?.stringValue ?? "1") ?? 1
            var cells: [String] = []
            var pendingEmptyCells = 0
            for cellNode in row.children ?? [] {
                guard let cell = cellNode as? XMLElement,
                      cell.localName == "table-cell" || cell.localName == "covered-table-cell" else { continue }
                let count = Int(cell.attribute(forLocalName: "number-columns-repeated", uri: table)?.stringValue ?? "1") ?? 1
                let value = self.value(of: cell)
                if value.isEmpty { pendingEmptyCells += count; continue }
                cells += Array(repeating: "", count: pendingEmptyCells)
                pendingEmptyCells = 0
                cells += Array(repeating: value, count: min(count, 1000))
            }
            if cells.isEmpty { pendingEmptyRows += repeats; continue }
            rows += Array(repeating: [], count: min(pendingEmptyRows, 10_000))
            pendingEmptyRows = 0
            rows += Array(repeating: cells, count: min(repeats, 10_000))
        }
        return rows
    }

    /// Rows in order, looking inside row groups and header rows. Walked by hand
    /// (see `XLSX.text(of:)`: relative XPath reached past the element).
    private static func tableRows(in element: XMLElement) -> [XMLElement] {
        var rows: [XMLElement] = []
        for child in element.children ?? [] {
            guard let child = child as? XMLElement else { continue }
            switch child.localName {
            case "table-row": rows.append(child)
            case "table-row-group", "table-header-rows", "table-rows": rows += tableRows(in: child)
            default: continue
            }
        }
        return rows
    }

    private static func value(of cell: XMLElement) -> String {
        let type = cell.attribute(forLocalName: "value-type", uri: office)?.stringValue
        if ["float", "percentage", "currency"].contains(type),
           let value = cell.attribute(forLocalName: "value", uri: office)?.stringValue {
            return value
        }
        let paragraphs = (cell.children ?? []).compactMap { node -> String? in
            guard let element = node as? XMLElement, element.localName == "p" else { return nil }
            return element.stringValue
        }
        return paragraphs.joined(separator: "\n")
    }

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

        var tables = ""
        for sheet in book.sheets {
            tables += #"<table:table table:name="\#(XMLText.escape(sheet.name))">"#
            let columns = max(1, sheet.rows.map(\.count).max() ?? 1)
            tables += #"<table:table-column table:number-columns-repeated="\#(columns)"/>"#
            for row in sheet.rows {
                tables += "<table:table-row>"
                if row.isEmpty { tables += "<table:table-cell/>" }
                for value in row {
                    if value.isEmpty {
                        tables += "<table:table-cell/>"
                    } else if XMLText.isPlainNumber(value) {
                        tables += #"<table:table-cell office:value-type="float" office:value="\#(value)"><text:p>\#(value)</text:p></table:table-cell>"#
                    } else {
                        let paragraphs = value.components(separatedBy: "\n").map { "<text:p>\(XMLText.escape($0))</text:p>" }.joined()
                        tables += #"<table:table-cell office:value-type="string">\#(paragraphs)</table:table-cell>"#
                    }
                }
                tables += "</table:table-row>"
            }
            tables += "</table:table>"
        }
        try Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <office:document-content xmlns:office="\(office)" xmlns:table="\(table)" xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" office:version="1.2"><office:body><office:spreadsheet>\(tables)</office:spreadsheet></office:body></office:document-content>
        """.utf8).write(to: root.appending(path: "content.xml"))

        try await ArchiveConverter.zipContents(of: root, to: output, storedFirst: "mimetype")
    }
}
