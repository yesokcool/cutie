import Foundation

/// XML text helpers for the spreadsheet writers.
nonisolated enum XMLText {
    /// Escapes markup and drops characters XML 1.0 can't hold.
    static func escape(_ text: String) -> String {
        var result = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "\t", "\n", "\r": result.unicodeScalars.append(scalar)
            default:
                if scalar.value >= 0x20 && !(0xFFFE...0xFFFF).contains(scalar.value) { result.unicodeScalars.append(scalar) }
            }
        }
        return result
    }

    /// A number that should stay a number: no leading zeros (ZIP codes stay text), ≤ 15 digits (IDs stay text).
    static func isPlainNumber(_ value: String) -> Bool {
        guard value.range(of: #"^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][-+]?[0-9]+)?$"#, options: .regularExpression) != nil else {
            return false
        }
        return value.filter(\.isNumber).count <= 15
    }
}
