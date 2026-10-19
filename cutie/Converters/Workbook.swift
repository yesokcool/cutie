import Foundation

/// A workbook reduced to what converts cleanly between formats: named sheets
/// of text cells. Numbers stay numbers in XLSX/ODS; styling and formulas'
/// expressions don't survive (their last values do).
nonisolated struct Workbook: Equatable, Sendable {
    struct Sheet: Equatable, Sendable {
        var name: String
        var rows: [[String]]
    }

    var sheets: [Sheet]
}
