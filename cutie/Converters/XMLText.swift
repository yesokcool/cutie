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
}
