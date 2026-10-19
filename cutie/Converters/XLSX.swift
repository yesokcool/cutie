import Foundation

/// Excel workbooks, read and written directly (they're zipped XML).
nonisolated enum XLSX {
    private static let main = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
    private static let relationshipsNS = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"

    static func read(_ url: URL, scratch: Scratch) async throws -> Workbook {
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

        var shared: [String] = []
        if let strings = try? XMLDocument(contentsOf: xl.appending(path: "sharedStrings.xml")) {
            for item in try strings.nodes(forXPath: "//*[local-name()='si']") {
                shared.append((item as? XMLElement).map(text(of:)) ?? "")
            }
        }

        var sheets: [Workbook.Sheet] = []
        for node in try workbook.nodes(forXPath: "//*[local-name()='sheet']") {
            guard let element = node as? XMLElement,
                  let name = element.attribute(forName: "name")?.stringValue,
                  let id = element.attribute(forLocalName: "id", uri: relationshipsNS)?.stringValue,
                  let target = targets[id] else { continue }
            let path = target.hasPrefix("/") ? folder.appending(path: String(target.dropFirst())) : xl.appending(path: target)
            guard let sheet = try? XMLDocument(contentsOf: path) else { continue }
            sheets.append(.init(name: name, rows: try rows(of: sheet, shared: shared)))
        }
        guard !sheets.isEmpty else { throw CutieError("This workbook has no sheets.") }
        return Workbook(sheets: sheets)
    }

    private static func rows(of sheet: XMLDocument, shared: [String]) throws -> [[String]] {
        var rows: [[String]] = []
        for rowNode in try sheet.nodes(forXPath: "//*[local-name()='sheetData']/*[local-name()='row']") {
            guard let row = rowNode as? XMLElement else { continue }
            let number = row.attribute(forName: "r")?.stringValue.flatMap(Int.init) ?? rows.count + 1
            while rows.count < number - 1 { rows.append([]) }
            var cells: [String] = []
            for cellNode in row.children ?? [] {
                guard let cell = cellNode as? XMLElement, cell.localName == "c" else { continue }
                let column = cell.attribute(forName: "r")?.stringValue.map(Spreadsheet.columnIndex(ofCell:)) ?? cells.count
                while cells.count < column { cells.append("") }
                cells.append(value(of: cell, shared: shared))
            }
            rows.append(cells)
        }
        return rows
    }

    private static func value(of cell: XMLElement, shared: [String]) -> String {
        let type = cell.attribute(forName: "t")?.stringValue ?? "n"
        let raw = cell.elements(forLocalName: "v", uri: main).first?.stringValue ?? ""
        switch type {
        case "s": return Int(raw).flatMap { shared.indices.contains($0) ? shared[$0] : nil } ?? ""
        case "inlineStr":
            return cell.elements(forLocalName: "is", uri: main).first.map(text(of:)) ?? ""
        case "b": return raw == "1" ? "TRUE" : "FALSE"
        default: return raw
        }
    }

    /// The text of a string item: its `t` runs, minus phonetic guides (`rPh`).
    /// Walked by hand: a relative XPath (`.//t`) on these nodes matched every
    /// later `t` in the sheet, gluing following cells onto the last one in a row.
    private static func text(of element: XMLElement) -> String {
        var result = ""
        for child in element.children ?? [] {
            guard let child = child as? XMLElement else { continue }
            switch child.localName {
            case "t": result += child.stringValue ?? ""
            case "rPh": continue
            default: result += text(of: child)
            }
        }
        return result
    }

    static func write(_ book: Workbook, to output: URL, scratch: Scratch) async throws {
        let root = try scratch.folder("xlsx-" + UUID().uuidString)
        for folder in ["_rels", "xl/_rels", "xl/worksheets"] {
            try FileManager.default.createDirectory(at: root.appending(path: folder), withIntermediateDirectories: true)
        }
        func put(_ path: String, _ text: String) throws { try Data(text.utf8).write(to: root.appending(path: path)) }

        let names = uniqueSheetNames(book.sheets.map(\.name))
        var overrides = "", sheetList = "", relations = ""
        for (index, sheet) in book.sheets.enumerated() {
            let number = index + 1
            overrides += #"<Override PartName="/xl/worksheets/sheet\#(number).xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>"#
            sheetList += #"<sheet name="\#(XMLText.escape(names[index]))" sheetId="\#(number)" r:id="rId\#(number)"/>"#
            relations += #"<Relationship Id="rId\#(number)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet\#(number).xml"/>"#
            try put("xl/worksheets/sheet\(number).xml", worksheet(sheet.rows))
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
        try put("xl/styles.xml", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <styleSheet xmlns="\(main)"><fonts count="1"><font><sz val="12"/><name val="Calibri"/></font></fonts><fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills><borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/></cellXfs><cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles></styleSheet>
        """)
        try await ArchiveConverter.zipContents(of: root, to: output)
    }

    private static func worksheet(_ rows: [[String]]) -> String {
        var xml = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><worksheet xmlns="\#(main)"><sheetData>"#
        for (rowIndex, row) in rows.enumerated() where !row.allSatisfy(\.isEmpty) {
            xml += #"<row r="\#(rowIndex + 1)">"#
            for (columnIndex, value) in row.enumerated() where !value.isEmpty {
                let reference = Spreadsheet.columnName(columnIndex) + String(rowIndex + 1)
                if XMLText.isPlainNumber(value) {
                    xml += #"<c r="\#(reference)"><v>\#(value)</v></c>"#
                } else {
                    xml += #"<c r="\#(reference)" t="inlineStr"><is><t xml:space="preserve">\#(XMLText.escape(value))</t></is></c>"#
                }
            }
            xml += "</row>"
        }
        return xml + "</sheetData></worksheet>"
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
