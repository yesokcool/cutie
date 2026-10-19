import Foundation

/// RFC 4180 CSV (quoted fields, doubled quotes, newlines inside quotes).
nonisolated enum CSV {
    static func parse(_ text: String, separator: Character) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var iterator = text.makeIterator()
        var pending: Character? = nil
        while let character = pending ?? iterator.next() {
            pending = nil
            if quoted {
                if character == "\"" {
                    if let next = iterator.next() {
                        if next == "\"" { field.append("\"") } else { quoted = false; pending = next }
                    } else {
                        quoted = false
                    }
                } else {
                    field.append(character)
                }
            } else if character == "\"" && field.isEmpty {
                quoted = true
            } else if character == separator {
                row.append(field); field = ""
            } else if character == "\n" || character == "\r\n" || character == "\r" {
                row.append(field); field = ""
                rows.append(row); row = []
            } else {
                field.append(character)
            }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }

    static func write(_ rows: [[String]], separator: Character, lineEnding: String = "\n") -> String {
        rows.map { row in
            row.map { field in
                let needsQuotes = field.contains(separator) || field.contains("\"") || field.contains("\n") || field.contains("\r")
                    || field.first == " " || field.last == " "
                return needsQuotes ? "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : field
            }.joined(separator: String(separator))
        }.joined(separator: lineEnding) + lineEnding
    }

    /// The separator a CSV file uses: comma, semicolon (European Excel), tab or
    /// pipe, whichever splits the first lines into the same number of fields
    /// most consistently. Quoted text doesn't count. Excel's "sep=;" first line wins.
    static func separator(of text: String) -> Character {
        if let declared = declaredSeparator(text) { return declared }
        let candidates: [Character] = [",", ";", "\t", "|"]
        var counts: [Character: [Int]] = [:]
        var current: [Character: Int] = [:]
        var quoted = false, lines = 0
        for character in text {
            if character == "\"" { quoted.toggle(); continue }
            if quoted { continue }
            if character == "\n" || character == "\r\n" || character == "\r" {
                for candidate in candidates { counts[candidate, default: []].append(current[candidate] ?? 0) }
                current = [:]
                lines += 1
                if lines >= 50 { break }
            } else if candidates.contains(character) {
                current[character, default: 0] += 1
            }
        }
        if !current.isEmpty || lines == 0 {
            for candidate in candidates { counts[candidate, default: []].append(current[candidate] ?? 0) }
        }
        var best: (separator: Character, score: Int) = (",", 0)
        for candidate in candidates {
            let perLine = counts[candidate] ?? []
            let used = perLine.filter { $0 > 0 }
            guard let mode = Dictionary(grouping: used, by: { $0 }).max(by: { $0.value.count < $1.value.count })?.key else { continue }
            // Lines agreeing on the field count, weighted a little by how many fields that is.
            let score = perLine.filter { $0 == mode }.count * 100 + min(mode, 50)
            if score > best.score { best = (candidate, score) }
        }
        return best.separator
    }

    static func declaredSeparator(_ text: String) -> Character? {
        let firstLine = text.prefix { $0 != "\n" && $0 != "\r\n" && $0 != "\r" }
        guard firstLine.lowercased().hasPrefix("sep="), firstLine.count == 5 else { return nil }
        return firstLine.last
    }

    /// The text without a leading "sep=;" line.
    static func droppingDeclaration(_ text: String) -> String {
        guard declaredSeparator(text) != nil else { return text }
        return String(text.drop { $0 != "\n" && $0 != "\r\n" && $0 != "\r" }.dropFirst())
    }
}
