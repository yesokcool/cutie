import Foundation
import Testing
@testable import cutie

/// Spreadsheets must read the way Excel shows them and keep their types:
/// dates are dates, 8.25% stays a percentage, $1,234.50 stays money,
/// 0.1 + 0.2 shows as 0.3, ZIP codes keep their leading zero.
@Suite(.serialized)
struct SpreadsheetFidelityTests {
    static let us = Locale(identifier: "en_US")

    /// An .xlsx built from raw sheet XML, as Excel writes it.
    func workbook(_ fixtures: Fixtures, name: String = "book.xlsx", sheets: [(name: String, xml: String)],
                  shared: [String] = [], numFmts: [(Int, String)] = [], xfs: [Int] = [0], date1904: Bool = false) async throws -> URL {
        let root = try fixtures.folder.appending(path: "build-\(UUID().uuidString)").create()
        for folder in ["_rels", "xl/_rels", "xl/worksheets"] {
            try root.appending(path: folder).create()
        }
        func put(_ path: String, _ text: String) throws { try Data(text.utf8).write(to: root.appending(path: path)) }
        let main = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
        var sheetList = "", relations = "", overrides = ""
        for (index, sheet) in sheets.enumerated() {
            let number = index + 1
            sheetList += #"<sheet name="\#(sheet.name)" sheetId="\#(number)" r:id="rId\#(number)"/>"#
            relations += #"<Relationship Id="rId\#(number)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet\#(number).xml"/>"#
            overrides += #"<Override PartName="/xl/worksheets/sheet\#(number).xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>"#
            try put("xl/worksheets/sheet\(number).xml", #"<?xml version="1.0" encoding="UTF-8"?><worksheet xmlns="\#(main)">\#(sheet.xml)</worksheet>"#)
        }
        relations += #"<Relationship Id="rIdS" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>"#
        relations += #"<Relationship Id="rIdT" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings" Target="sharedStrings.xml"/>"#
        try put("[Content_Types].xml", #"<?xml version="1.0" encoding="UTF-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/><Override PartName="/xl/sharedStrings.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"/>\#(overrides)</Types>"#)
        try put("_rels/.rels", #"<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>"#)
        let pr = date1904 ? #"<workbookPr date1904="1"/>"# : ""
        try put("xl/workbook.xml", #"<?xml version="1.0" encoding="UTF-8"?><workbook xmlns="\#(main)" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">\#(pr)<sheets>\#(sheetList)</sheets></workbook>"#)
        try put("xl/_rels/workbook.xml.rels", #"<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\#(relations)</Relationships>"#)
        let formats = numFmts.map { #"<numFmt numFmtId="\#($0.0)" formatCode="\#(XMLText.escape($0.1))"/>"# }.joined()
        let cellXfs = xfs.map { #"<xf numFmtId="\#($0)" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>"# }.joined()
        try put("xl/styles.xml", #"<?xml version="1.0" encoding="UTF-8"?><styleSheet xmlns="\#(main)"><numFmts count="\#(numFmts.count)">\#(formats)</numFmts><fonts count="1"><font/></fonts><fills count="1"><fill/></fills><borders count="1"><border/></borders><cellStyleXfs count="1"><xf/></cellStyleXfs><cellXfs count="\#(xfs.count)">\#(cellXfs)</cellXfs></styleSheet>"#)
        try put("xl/sharedStrings.xml", #"<?xml version="1.0" encoding="UTF-8"?><sst xmlns="\#(main)" count="\#(shared.count)">\#(shared.map { "<si>\($0)</si>" }.joined())</sst>"#)
        let url = fixtures.url(name)
        try await ArchiveConverter.zipContents(of: root, to: url)
        try FileManager.default.removeItem(at: root)
        return url
    }

    /// Styles: 1 date, 2 percent, 3 dollars, 4 grouped, 5 12-hour time,
    /// 6 accounting, 7 date-time, 8 text (@).
    static let numFmts: [(Int, String)] = [
        (164, "yyyy-mm-dd"), (165, "\"$\"#,##0.00"), (166, "#,##0.00"), (167, "h:mm:ss AM/PM"), (168, "yyyy-mm-dd hh:mm"),
    ]
    static let xfs = [0, 164, 10, 165, 166, 167, 44, 168, 49]

    static let shared = [
        "<t>Name</t>",
        #"<r><rPr><b/></rPr><t>Bold</t></r><r><t xml:space="preserve"> part</t></r><rPh sb="0" eb="1"><t>ふりがな</t></rPh>"#,
        "<t>02134</t>",
        "<t>Café</t>",
    ]

    static let dataSheet = """
    <sheetData>
    <row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c><c r="C1" t="s"><v>3</v></c></row>
    <row r="2"><c r="A2" s="1"><v>45809</v></c><c r="B2" s="2"><v>0.0825</v></c><c r="C2" s="3"><v>1234.5</v></c><c r="D2" s="4"><v>1234567.891</v></c><c r="E2" s="5"><v>0.4309027777777778</v></c><c r="F2" s="6"><v>-1234.5</v></c><c r="G2" s="7"><v>45809.43090277778</v></c></row>
    <row r="3"><c r="A3"><v>0.30000000000000004</v></c><c r="B3" t="s"><v>2</v></c><c r="C3" t="b"><v>1</v></c><c r="D3"><f>A3*2</f><v>0.6000000000000001</v></c><c r="E3" t="str"><f>"x"&amp;"y"</f><v>xy</v></c><c r="F3" t="e"><v>#DIV/0!</v></c><c r="G3" t="inlineStr"><is><t>inline</t></is></c><c r="H3" s="8"><v>5</v></c></row>
    <row r="5"><c r="A5" t="s"><v>0</v></c><c r="B5" s="1"/></row>
    </sheetData><mergeCells count="1"><mergeCell ref="A5:C5"/></mergeCells>
    """

    func dataWorkbook(_ fixtures: Fixtures, date1904: Bool = false) async throws -> URL {
        try await workbook(fixtures, sheets: [("Data", Self.dataSheet), ("Notes", #"<sheetData><row r="1"><c r="A1" t="inlineStr"><is><t>note</t></is></c></row></sheetData>"#)],
                           shared: Self.shared, numFmts: Self.numFmts, xfs: Self.xfs, date1904: date1904)
    }

    @Test func cellsReadAsExcelShowsThem() async throws {
        let fixtures = try Fixtures(); defer { fixtures.remove() }
        let book = try await Spreadsheet.read(try await dataWorkbook(fixtures), scratch: try Scratch(), toolbox: .none, locale: Self.us)
        #expect(book.sheets.map(\.name) == ["Data", "Notes"])
        let rows = book.sheets[0].textRows
        #expect(rows[0] == ["Name", "Bold part", "Café"])
        #expect(rows[1] == ["2025-06-01", "8.25%", "$1,234.50", "1,234,567.89", "10:20:30 AM", "$(1,234.50)", "2025-06-01 10:20"])
        #expect(rows[2] == ["0.3", "02134", "TRUE", "0.6", "xy", "#DIV/0!", "inline", "5"])
        #expect(rows[3].isEmpty)
        #expect(rows[4] == ["Name"])
        #expect(book.sheets[0].merges == [Workbook.Merge(firstRow: 4, firstColumn: 0, lastRow: 4, lastColumn: 2)])

        let cells = book.sheets[0].rows
        #expect(cells[1][0].kind == .date && cells[1][0].value == 45809)
        #expect(cells[1][1].kind == .percent && cells[1][1].value == 0.0825)
        #expect(cells[1][2].kind == .currency("$"))
        #expect(cells[1][4].kind == .time)
        #expect(cells[1][6].kind == .dateTime)
        #expect(cells[2][0].kind == .number && cells[2][0].value == 0.30000000000000004)
        #expect(cells[2][1] == "02134")
        #expect(cells[2][2].kind == .bool)
    }

    @Test func the1904DateSystem() async throws {
        let fixtures = try Fixtures(); defer { fixtures.remove() }
        let sheet = #"<sheetData><row r="1"><c r="A1" s="1"><v>44347</v></c></row></sheetData>"#
        let url = try await workbook(fixtures, sheets: [("Old Mac", sheet)], numFmts: Self.numFmts, xfs: Self.xfs, date1904: true)
        let book = try await Spreadsheet.read(url, scratch: try Scratch(), toolbox: .none, locale: Self.us)
        #expect(book.sheets[0].textRows[0][0] == "2025-06-01")
        #expect(book.sheets[0].rows[0][0].value == 45809)
    }

    @Test func excelToCSVShowsWhatExcelShows() async throws {
        let fixtures = try Fixtures(); defer { fixtures.remove() }
        let folder = try #require(try await Executor.run(.convert(.csv), inputs: [try await dataWorkbook(fixtures)], context: fixtures.context).files.first)
        let data = try Data(contentsOf: folder.appending(path: "book - Data.csv"))
        #expect(data.starts(with: [0xEF, 0xBB, 0xBF])) // "Café" isn't ASCII: Excel needs the mark
        let text = try TextDecoding.decode(data)
        #expect(text.contains("\r\n"))
        let rows = CSV.parse(text, separator: ",")
        #expect(rows[1] == ["2025-06-01", "8.25%", "$1,234.50", "1,234,567.89", "10:20:30 AM", "$(1,234.50)", "2025-06-01 10:20"])
        #expect(rows[2] == ["0.3", "02134", "TRUE", "0.6", "xy", "#DIV/0!", "inline", "5"])

        let notes = try Data(contentsOf: folder.appending(path: "book - Notes.csv"))
        #expect(!notes.starts(with: [0xEF, 0xBB, 0xBF])) // plain ASCII stays mark-free
    }

    @Test func typesSurviveODSAndBack() async throws {
        let fixtures = try Fixtures(); defer { fixtures.remove() }
        let ods = try await Executor.run(.convert(.ods), inputs: [try await dataWorkbook(fixtures)], context: fixtures.context).files.first!
        let book = try await ODS.read(ods, scratch: try Scratch())
        let cells = book.sheets[0].rows
        #expect(cells[1][0].kind == .date && cells[1][0].value == 45809)
        #expect(cells[1][1].kind == .percent && cells[1][1].value == 0.0825 && cells[1][1].text == "8.25%")
        #expect(cells[1][2].kind == .currency("$") && cells[1][2].value == 1234.5 && cells[1][2].text == "$1,234.50")
        #expect(cells[1][4].kind == .time && abs((cells[1][4].value ?? 0) - 0.4309027777777778) < 1e-9)
        #expect(cells[1][6].kind == .dateTime)
        #expect(cells[2][0].value == 0.30000000000000004 && cells[2][0].kind == .number)
        #expect(cells[2][1] == "02134")
        #expect(cells[2][2].kind == .bool && cells[2][2].value == 1)
        #expect(book.sheets[0].merges == [Workbook.Merge(firstRow: 4, firstColumn: 0, lastRow: 4, lastColumn: 2)])
        #expect(book.sheets.count == 2)

        try FileManager.default.removeItem(at: fixtures.url("book.xlsx"))
        let xlsx = try await Executor.run(.convert(.xlsx), inputs: [ods], context: fixtures.context).files.first!
        let again = try await Spreadsheet.read(xlsx, scratch: try Scratch(), toolbox: .none, locale: Self.us)
        let back = again.sheets[0].rows
        #expect(back[1][0].kind == .date && back[1][0].text == "2025-06-01")
        #expect(back[1][1].text == "8.25%")
        #expect(back[1][2].text == "$1,234.50")
        #expect(back[2][0].value == 0.30000000000000004)
        #expect(back[2][2].kind == .bool)
        #expect(again.sheets[0].merges.count == 1)
    }

    @Test func libreOfficeAgreesWithOurFiles() async throws {
        let soffice = URL(fileURLWithPath: "/Applications/LibreOffice.app/Contents/MacOS/soffice")
        guard FileManager.default.isExecutableFile(atPath: soffice.path) else { return }
        let fixtures = try Fixtures(); defer { fixtures.remove() }
        let csv = try fixtures.text("typed.csv", "When,Share,Cost,Zip,Done\n2025-06-01,8.25%,\"$1,234.50\",02134,TRUE\n")
        for format in [Format.xlsx, .ods] {
            let file = try #require(try await Executor.run(.convert(format), inputs: [csv], context: fixtures.context).files.first)
            let out = try fixtures.folder.appending(path: "lo-\(format.rawValue)").create()
            let profile = try fixtures.folder.appending(path: "lo-profile").create()
            try await Shell.run(soffice, ["-env:UserInstallation=\(profile.absoluteString)", "--headless", "--convert-to", "csv:Text - txt - csv (StarCalc):44,34,76,1,,1033,false,true,true",
                                          "--outdir", out.path, file.path])
            let text = try TextDecoding.read(out.appending(path: "typed.csv"))
            #expect(text.contains("2025-06-01"), "\(format)")
            #expect(text.contains("8.25%"), "\(format)")
            #expect(text.contains("$1,234.50"), "\(format): \(text)")
            #expect(text.contains("02134"), "\(format)")
        }
    }

    @Test func csvValuesAreTyped() async throws {
        let fixtures = try Fixtures(); defer { fixtures.remove() }
        let csv = try fixtures.text("mixed.csv", "When,Share,Cost,Zip,Done,Sum,Card\n2025-06-01,8.25%,\"$1,234.50\",02134,TRUE,0.30000000000000004,4111111111111111\n")
        let xlsx = try #require(try await Executor.run(.convert(.xlsx), inputs: [csv], context: fixtures.context).files.first)
        let row = try await Spreadsheet.read(xlsx, scratch: try Scratch(), toolbox: .none, locale: Self.us).sheets[0].rows[1]
        #expect(row[0].kind == .date && row[0].text == "2025-06-01")
        #expect(row[1].kind == .percent && row[1].value == 0.0825)
        #expect(row[2].kind == .currency("$") && row[2].text == "$1,234.50")
        #expect(row[3] == "02134")
        #expect(row[4].kind == .bool)
        #expect(row[5].value == 0.30000000000000004 && row[5].text == "0.3")
        #expect(row[6] == "4111111111111111")
    }

    @Test func semicolonCSVWithDecimalCommasAndOldEncoding() async throws {
        let fixtures = try Fixtures(); defer { fixtures.remove() }
        let text = "Name;Amount;Day\r\nCafé;12,50;2025-06-01\r\nThé;1.234,50;2025-06-02\r\n"
        let url = fixtures.url("prix.csv")
        try text.data(using: .windowsCP1252)!.write(to: url)
        let xlsx = try #require(try await Executor.run(.convert(.xlsx), inputs: [url], context: fixtures.context).files.first)
        let rows = try await Spreadsheet.read(xlsx, scratch: try Scratch(), toolbox: .none, locale: Self.us).sheets[0].rows
        #expect(rows[1][0] == "Café")
        #expect(rows[1][1].value == 12.5)
        #expect(rows[2][1].value == 1234.5)
        #expect(rows[2][2].kind == .date)
    }

    @Test func separatorDetection() {
        #expect(CSV.separator(of: "a,b,c\n1,2,3\n") == ",")
        #expect(CSV.separator(of: "a;b;c\n1,5;2,5;3\n") == ";")
        #expect(CSV.separator(of: "a\tb\tc\n1\t2\t3\n") == "\t")
        #expect(CSV.separator(of: "a|b|c\n1|2|3\n") == "|")
        #expect(CSV.separator(of: "\"x;y\",b\n\"1;2\",3\n") == ",")
        #expect(CSV.separator(of: "sep=;\na;b\n") == ";")
        #expect(CSV.droppingDeclaration("sep=;\na;b\n") == "a;b\n")
        #expect(CSV.separator(of: "only\none\n") == ",")
    }

    @Test func numberFormats() {
        func shows(_ code: String, _ value: Double) -> String { NumberFormat(code: code).format(value, locale: Self.us) }
        #expect(shows("General", 0.30000000000000004) == "0.3")
        #expect(shows("0.0", 3.25) == "3.3") // half away from zero, like Excel
        #expect(shows("#,##0.00;[Red](#,##0.00)", -5) == "(5.00)")
        #expect(shows("[$€-407]#,##0.00", 1234.5) == "€1,234.50")
        #expect(shows("0.00E+00", 12345) == "1.23E+04")
        #expect(shows("# ?/?", 1.5) == "1 1/2")
        #expect(shows("000-00-0000", 123456789) == "123-45-6789")
        #expect(shows("dddd, mmm d, yyyy", 45809) == "Sunday, Jun 1, 2025")
        #expect(shows("[h]:mm:ss", 1.5) == "36:00:00")
        #expect(shows("mm:ss.0", 0.000694444) == "01:00.0")
        #expect(NumberFormat(id: 14, custom: [:], locale: Self.us).format(45809, locale: Self.us) == "6/1/2025")
        #expect(NumberFormat(id: 14, custom: [:], locale: Locale(identifier: "de_DE")).format(45809) == "01.06.2025")
        #expect(SpreadsheetDate.parts(60).day == 29) // Excel's phantom 29 Feb 1900
        #expect(SpreadsheetDate.serial(year: 1900, month: 3, day: 1) == 61)
    }

    @Test func bigSheetsStream() async throws {
        let fixtures = try Fixtures(); defer { fixtures.remove() }
        let rows = (0..<40_000).map { index -> [Workbook.Cell] in
            [Workbook.Cell(text: "Row \(index)"), Workbook.Cell(text: "\(index)", value: Double(index), kind: .number),
             Workbook.Cell(text: "2025-06-01", value: 45809, kind: .date, formatCode: "yyyy-mm-dd")]
        }
        let url = fixtures.url("big.xlsx")
        try await XLSX.write(Workbook(sheets: [.init(name: "Big", rows: rows)]), to: url, scratch: try Scratch())
        let clock = ContinuousClock()
        let started = clock.now
        let book = try await XLSX.read(url, scratch: try Scratch(), locale: Self.us)
        #expect(clock.now - started < .seconds(20))
        #expect(book.sheets[0].rows.count == 40_000)
        #expect(book.sheets[0].textRows[39_999] == ["Row 39999", "39999", "2025-06-01"])
    }
}
