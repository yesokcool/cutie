import Foundation
import Synchronization

/// Spreadsheet dates: serial numbers counting days since 1899-12-30 (Excel's
/// 1900 system, fraction = time of day). Always computed in UTC so no time
/// zone or daylight-saving shift can move a date.
nonisolated enum SpreadsheetDate {
    /// Days between the 1900 and 1904 systems (old Mac Excel files use 1904).
    static let offset1904 = 1462.0

    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    struct Parts: Equatable {
        var year = 1899, month = 12, day = 30, hour = 0, minute = 0, second = 0
        var millisecond = 0, weekday = 7
    }

    /// Serial → calendar parts. Excel's phantom 29 Feb 1900 (serial 60) and the
    /// day shift before it are reproduced, so old serials read as Excel shows them.
    static func parts(_ serial: Double, roundToSecond: Bool = true) -> Parts {
        var days = serial.rounded(.down)
        var milliseconds = ((serial - days) * 86_400_000).rounded()
        if roundToSecond { milliseconds = (milliseconds / 1000).rounded() * 1000 }
        if milliseconds >= 86_400_000 { days += 1; milliseconds -= 86_400_000 }
        if days == 60 {
            return Parts(year: 1900, month: 2, day: 29, hour: Int(milliseconds) / 3_600_000,
                         minute: Int(milliseconds) / 60_000 % 60, second: Int(milliseconds) / 1000 % 60,
                         millisecond: Int(milliseconds) % 1000, weekday: 4)
        }
        if days < 60 { days += 1 }
        let date = Date(timeIntervalSince1970: (days - 25_569) * 86_400)
        let components = calendar.dateComponents([.year, .month, .day, .weekday], from: date)
        let ms = Int(milliseconds)
        return Parts(year: components.year!, month: components.month!, day: components.day!,
                     hour: ms / 3_600_000, minute: ms / 60_000 % 60, second: ms / 1000 % 60,
                     millisecond: ms % 1000, weekday: components.weekday!)
    }

    static func serial(year: Int, month: Int, day: Int, hour: Int = 0, minute: Int = 0, second: Double = 0) -> Double? {
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else { return nil }
        var days = (date.timeIntervalSince1970 / 86_400).rounded() + 25_569
        if days <= 60 { days -= 1 }
        return days + (Double(hour) * 3600 + Double(minute) * 60 + second) / 86_400
    }

    /// "2025-06-01", "2025-06-01 10:20:30", "2025-06-01T10:20" → serial.
    static func parseISO(_ text: String) -> (serial: Double, hasTime: Bool)? {
        let pattern = #"^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2})(?::(\d{2}(?:\.\d+)?))?)?$"#
        guard let match = text.firstMatch(of: try! Regex(pattern)) else { return nil }
        func part(_ index: Int) -> String? { match.output[index].substring.map(String.init) }
        guard let year = part(1).flatMap(Int.init), let month = part(2).flatMap(Int.init), let day = part(3).flatMap(Int.init),
              (1...12).contains(month), (1...31).contains(day) else { return nil }
        let hour = part(4).flatMap(Int.init) ?? 0, minute = part(5).flatMap(Int.init) ?? 0
        let second = part(6).flatMap(Double.init) ?? 0
        guard hour < 24, minute < 60, second < 60,
              let serial = serial(year: year, month: month, day: day, hour: hour, minute: minute, second: second),
              parts(serial.rounded(.down)).day == day else { return nil }
        return (serial, part(4) != nil)
    }

    /// ODS writes dates as "2025-06-01T10:20:30" and durations as "PT10H20M30S".
    static func iso(_ serial: Double, time: Bool) -> String {
        let p = parts(serial)
        let date = String(format: "%04d-%02d-%02d", p.year, p.month, p.day)
        return time ? date + String(format: "T%02d:%02d:%02d", p.hour, p.minute, p.second) : date
    }

    static func isoDuration(_ fraction: Double) -> String {
        let seconds = Int((fraction * 86_400).rounded())
        return String(format: "PT%02dH%02dM%02dS", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }

    static func parseDuration(_ text: String) -> Double? {
        guard let match = text.firstMatch(of: /^-?P(?:(\d+)D)?T?(?:(\d+)H)?(?:(\d+)M)?(?:([\d.]+)S)?$/) else { return nil }
        let days = Double(match.output.1 ?? "0") ?? 0, hours = Double(match.output.2 ?? "0") ?? 0
        let minutes = Double(match.output.3 ?? "0") ?? 0, seconds = Double(match.output.4 ?? "0") ?? 0
        return days + (hours * 3600 + minutes * 60 + seconds) / 86_400
    }
}

/// An Excel number format ("#,##0.00", "0.0%", "$#,##0.00;($#,##0.00)",
/// "d mmm yyyy", "[h]:mm:ss", "@"…) applied the way Excel shows a cell.
/// Separators come out as written in the code (comma groups, point decimals),
/// so CSV stays readable everywhere.
nonisolated struct NumberFormat: Equatable {
    let code: String
    /// The code taken apart once, so formatting a million cells doesn't re-read it each time.
    private let compiled: [Section]
    let kind: Workbook.Cell.Kind

    /// One `;`-separated part of a code.
    private struct Section: Equatable {
        var text: String
        var tokens: [Token]
        var kind: Workbook.Cell.Kind
        var isGeneral: Bool
        var condition: Condition?
    }

    private struct Condition: Equatable {
        var comparison: String
        var limit: Double

        func matches(_ value: Double) -> Bool {
            switch comparison {
            case "<": value < limit
            case ">": value > limit
            case "<=": value <= limit
            case ">=": value >= limit
            case "<>": value != limit
            default: value == limit
            }
        }
    }

    init(code: String) {
        self.code = code
        compiled = Self.sections(code).map { text in
            let tokens = Self.tokens(text)
            let condition = text.firstMatch(of: /\[(<=|>=|<>|<|>|=)(-?[0-9.]+)\]/).flatMap { match in
                Double(match.output.2).map { Condition(comparison: String(match.output.1), limit: $0) }
            }
            let plain = Self.stripped(tokens)
            let isGeneral = plain.isEmpty || plain.caseInsensitiveCompare("General") == .orderedSame
            return Section(text: text, tokens: tokens, kind: Self.kind(of: text, tokens: tokens), isGeneral: isGeneral, condition: condition)
        }
        kind = compiled.first?.kind ?? .number
    }

    /// Plain "General": the number as is.
    var isGeneral: Bool { compiled.allSatisfy(\.isGeneral) }

    /// Excel's built-in formats by id. 5–8, 14 and 22 depend on the reader's
    /// locale; they're resolved with `locale`.
    init(id: Int, custom: [Int: String], locale: Locale = .current) {
        self.init(code: custom[id] ?? Self.builtInCode(id, locale: locale))
    }

    static func builtInCode(_ id: Int, locale: Locale) -> String {
        let code: String
        switch id {
        case 1: code = "0"
        case 2: code = "0.00"
        case 3: code = "#,##0"
        case 4: code = "#,##0.00"
        case 5: code = Self.currencyCode(locale, decimals: 0, red: false)
        case 6: code = Self.currencyCode(locale, decimals: 0, red: true)
        case 7: code = Self.currencyCode(locale, decimals: 2, red: false)
        case 8: code = Self.currencyCode(locale, decimals: 2, red: true)
        case 9: code = "0%"
        case 10: code = "0.00%"
        case 11: code = "0.00E+00"
        case 12: code = "# ?/?"
        case 13: code = "# ??/??"
        case 14: code = Self.shortDateCode(locale)
        case 15: code = "d-mmm-yy"
        case 16: code = "d-mmm"
        case 17: code = "mmm-yy"
        case 18: code = "h:mm AM/PM"
        case 19: code = "h:mm:ss AM/PM"
        case 20: code = "h:mm"
        case 21: code = "h:mm:ss"
        case 22: code = Self.shortDateCode(locale) + " h:mm"
        case 37: code = "#,##0 ;(#,##0)"
        case 38: code = "#,##0 ;[Red](#,##0)"
        case 39: code = "#,##0.00;(#,##0.00)"
        case 40: code = "#,##0.00;[Red](#,##0.00)"
        case 41: code = #"_(* #,##0_);_(* \(#,##0\);_(* "-"_);_(@_)"#
        case 42: code = #"_("$"* #,##0_);_("$"* \(#,##0\);_("$"* "-"_);_(@_)"#
        case 43: code = #"_(* #,##0.00_);_(* \(#,##0.00\);_(* "-"??_);_(@_)"#
        case 44: code = #"_("$"* #,##0.00_);_("$"* \(#,##0.00\);_("$"* "-"??_);_(@_)"#
        case 45: code = "mm:ss"
        case 46: code = "[h]:mm:ss"
        case 47: code = "mm:ss.0"
        case 48: code = "##0.0E+0"
        case 49: code = "@"
        default: code = "General"
        }
        return code
    }

    /// The locale's numeric date with a four-digit year (6/1/2025, 01.06.2025, 01/06/2025).
    static func shortDateCode(_ locale: Locale) -> String {
        let pattern = DateFormatter.dateFormat(fromTemplate: "yyyyMMdd", options: 0, locale: locale) ?? "MM/dd/yyyy"
        var code = ""
        for character in pattern {
            switch character {
            case "M": code += "m"
            case "d": code += "d"
            case "y": code += "y"
            case "'": continue
            default: code.append(character)
            }
        }
        // Single m/d where the locale doesn't pad (US: 6/1/2025).
        if pattern.hasPrefix("MM/dd") && locale.region?.identifier == "US" { code = "m/d/yyyy" }
        return code
    }

    static func currencyCode(_ locale: Locale, decimals: Int, red: Bool) -> String {
        let symbol = locale.currencySymbol ?? "$"
        let digits = decimals > 0 ? "#,##0." + String(repeating: "0", count: decimals) : "#,##0"
        let positive = "\"\(symbol)\"\(digits)"
        return positive + ";" + (red ? "[Red]" : "") + "\\(\"\(symbol)\"\(digits)\\)"
    }

    // MARK: - What kind of value

    private static func kind(of section: String, tokens: [Token]) -> Workbook.Cell.Kind {
        let plain = stripped(tokens)
        if plain.isEmpty || plain.caseInsensitiveCompare("General") == .orderedSame { return .number }
        if plain == "@" { return .text }
        let lower = plain.lowercased()
        let hasDate = lower.contains("y") || lower.contains("d") || (lower.contains("m") && !lower.contains("h") && !lower.contains("s"))
        let hasTime = lower.contains("h") || lower.contains("s") || lower.contains("am/pm") || lower.contains("a/p")
        if hasDate && hasTime { return .dateTime }
        if hasDate { return .date }
        if hasTime { return .time }
        if tokens.contains(.percent) { return .percent }
        if let symbol = currencySymbol(section, tokens: tokens) { return .currency(symbol) }
        return .number
    }

    /// "$", "€" (from "[$€-407]"), "£"… when the code shows one.
    private static func currencySymbol(_ section: String, tokens: [Token]) -> String? {
        if let match = section.firstMatch(of: /\[\$([^\-\]]+)(?:-[0-9A-Fa-f]+)?\]/) { return String(match.output.1) }
        let literals = tokens.compactMap { if case .literal(let text) = $0 { return text }; return nil }.joined()
        for symbol in ["$", "€", "£", "¥", "₩", "₹", "₽", "CHF", "kr", "zł", "Kč", "R$"] where literals.contains(symbol) {
            return symbol
        }
        return nil
    }

    /// Decimal places, digit grouping and whether a currency symbol comes
    /// first, as an OpenDocument number style needs them.
    var shape: (decimals: Int, grouped: Bool, symbolFirst: Bool) {
        let tokens = compiled.first?.tokens ?? []
        let decimals = tokens.firstIndex(of: .decimalPoint).map { tokens[$0...].filter(\.isDigit).count } ?? 0
        let firstDigit = tokens.firstIndex(where: \.isDigit) ?? tokens.endIndex
        let symbolFirst = tokens[..<firstDigit].contains { token in
            if case .literal(let text) = token { return text.contains { !$0.isWhitespace && !"(-".contains($0) } }
            return false
        }
        return (decimals, tokens.contains(.groupComma), symbolFirst)
    }

    // MARK: - Formatting

    func format(_ value: Double, locale: Locale = .current) -> String {
        guard var section = compiled.first else { return SpreadsheetNumber.general(value) }
        var number = value
        var signHandled = false
        // Conditions like [<1000] pick a section; otherwise positive;negative;zero.
        if compiled.contains(where: { $0.condition != nil }) {
            section = compiled.first { $0.condition?.matches(value) ?? false } ?? compiled.last { $0.condition == nil } ?? section
            signHandled = value >= 0 || compiled.count > 1
            number = abs(value)
        } else if value < 0, compiled.count >= 2 {
            section = compiled[1]
            number = abs(value)
            signHandled = true
        } else if value == 0, compiled.count >= 3 {
            section = compiled[2]
        }
        let result: String
        if section.isGeneral {
            result = Self.literalWrap(section.text, around: SpreadsheetNumber.general(number))
        } else {
            switch section.kind {
            case .date, .time, .dateTime: result = Self.renderDate(number, tokens: section.tokens, locale: locale)
            case .text: result = SpreadsheetNumber.general(number)
            default: result = Self.renderNumber(number, tokens: section.tokens, signHandled: signHandled)
            }
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    /// Text in a format with a text section ("@", or a fourth section).
    func format(text: String) -> String {
        let sections = Self.sections(code)
        guard let section = sections.count >= 4 ? sections[3] : sections.first(where: { $0.contains("@") }) else { return text }
        var result = ""
        for token in Self.tokens(section) {
            switch token {
            case .literal(let literal): result += literal
            case .placeholder("@"): result += text
            default: continue
            }
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    /// "General" with literal text around it ("General \" units\"").
    private static func literalWrap(_ section: String, around text: String) -> String {
        guard let range = section.range(of: "General", options: .caseInsensitive) else { return text }
        let before = literalText(String(section[..<range.lowerBound]))
        let after = literalText(String(section[range.upperBound...]))
        return before + text + after
    }

    // MARK: Numbers

    private static func renderNumber(_ value: Double, tokens: [Token], signHandled: Bool) -> String {
        var scaled = value * pow(100, Double(tokens.filter { $0 == .percent }.count))
        // Commas right after the last digit placeholder divide by 1000 each.
        var trailingCommas = 0
        if let lastPlaceholder = tokens.lastIndex(where: \.isDigit) {
            var index = tokens.index(after: lastPlaceholder)
            while index < tokens.endIndex, tokens[index] == .groupComma { trailingCommas += 1; index += 1 }
        }
        scaled /= pow(1000, Double(trailingCommas))

        if let exponentIndex = tokens.firstIndex(where: \.isExponent) {
            return renderScientific(scaled, tokens: tokens, exponentIndex: exponentIndex, signHandled: signHandled)
        }
        if tokens.contains(.placeholder("/")) {
            return renderFraction(scaled, tokens: tokens, signHandled: signHandled)
        }

        let decimalIndex = tokens.firstIndex(of: .decimalPoint)
        let integerTokens = decimalIndex.map { Array(tokens[..<$0]) } ?? tokens
        let fractionTokens = decimalIndex.map { Array(tokens[tokens.index(after: $0)...]) } ?? []
        let fractionPlaces = fractionTokens.filter(\.isDigit).count
        let requiredFraction = fractionTokens.filter { $0 == .placeholder("0") || $0 == .placeholder("?") }.count

        let magnitude = abs(scaled)
        var digits = fixed(magnitude, places: fractionPlaces)
        var fractionDigits = ""
        if let point = digits.firstIndex(of: ".") {
            fractionDigits = String(digits[digits.index(after: point)...])
            digits = String(digits[..<point])
        }
        while fractionDigits.count > requiredFraction, fractionDigits.hasSuffix("0") { fractionDigits.removeLast() }
        let grouping = integerTokens.contains(.groupComma) && integerTokens.firstIndex(of: .groupComma).map { comma in
            integerTokens[..<comma].contains(where: \.isDigit) && integerTokens[comma...].contains(where: \.isDigit)
        } == true

        var integerText = fillInteger(digits == "0" ? "" : digits, tokens: integerTokens, grouping: grouping)
        let fractionText = fillFraction(fractionDigits, tokens: fractionTokens)
        if decimalIndex != nil { integerText += "." + fractionText }
        let isZero = (Double(digits) ?? 0) == 0 && fractionDigits.allSatisfy { $0 == "0" }
        let sign = scaled < 0 && !signHandled && !isZero ? "-" : ""
        return sign + integerText
    }

    /// `value` with exactly `places` decimals, rounded half away from zero on
    /// its 15 significant digits, as Excel does (3.25 → "3.3", 1.005 → "1.01").
    static func fixed(_ value: Double, places: Int) -> String {
        var decimal = Decimal(string: String(format: "%.15g", value)) ?? Decimal(value)
        var rounded = Decimal()
        NSDecimalRound(&rounded, &decimal, places, .plain)
        var text = NSDecimalNumber(decimal: rounded).stringValue
        guard places > 0 else { return text }
        if !text.contains(".") { text += "." }
        let have = text.count - text.distance(from: text.startIndex, to: text.firstIndex(of: ".")!) - 1
        return text + String(repeating: "0", count: max(0, places - have))
    }

    /// Fills the integer placeholders right to left, literals kept in place;
    /// digits beyond the placeholders go in front ("000-00-0000" phone/SSN codes work).
    private static func fillInteger(_ digits: String, tokens: [Token], grouping: Bool) -> String {
        var digits = Array(digits)
        if grouping, digits.count > 3 {
            var grouped: [Character] = []
            for (index, digit) in digits.enumerated() {
                if index > 0 && (digits.count - index) % 3 == 0 { grouped.append(",") }
                grouped.append(digit)
            }
            digits = grouped
        }
        var output: [String] = []
        var remaining = digits
        let lastDigitToken = tokens.lastIndex(where: \.isDigit)
        for (index, token) in tokens.enumerated().reversed() {
            switch token {
            case .placeholder(let symbol) where "0#?".contains(symbol):
                var piece = ""
                if let digit = remaining.popLast() {
                    piece = String(digit)
                    // Group commas ride along with the digit they precede.
                    while remaining.last == "," { piece = String(remaining.removeLast()) + piece }
                } else if symbol == "0" {
                    piece = "0"
                } else if symbol == "?" {
                    piece = " "
                }
                if index == tokens.firstIndex(where: \.isDigit), !remaining.isEmpty {
                    piece = String(remaining) + piece
                    remaining = []
                }
                output.append(piece)
            case .literal(let text):
                output.append(text)
            case .percent:
                output.append("%")
            case .groupComma:
                if let lastDigitToken, index > lastDigitToken { continue }
            default:
                continue
            }
        }
        if !remaining.isEmpty { output.append(String(remaining)) }
        return output.reversed().joined()
    }

    private static func fillFraction(_ digits: String, tokens: [Token]) -> String {
        var remaining = Array(digits)
        var output = ""
        for token in tokens {
            switch token {
            case .placeholder(let symbol) where "0#?".contains(symbol):
                if !remaining.isEmpty { output.append(remaining.removeFirst()) } else if symbol == "0" { output += "0" } else if symbol == "?" { output += " " }
            case .literal(let text):
                output += text
            case .percent:
                output += "%"
            default:
                continue
            }
        }
        return output
    }

    private static func renderScientific(_ value: Double, tokens: [Token], exponentIndex: Int, signHandled: Bool) -> String {
        let mantissaTokens = Array(tokens[..<exponentIndex])
        let fractionPlaces = mantissaTokens.firstIndex(of: .decimalPoint).map { point in
            mantissaTokens[point...].filter(\.isDigit).count
        } ?? 0
        let exponentDigits = max(1, tokens[tokens.index(after: exponentIndex)...].filter(\.isDigit).count)
        let integerPlaces = max(1, mantissaTokens.firstIndex(of: .decimalPoint).map { mantissaTokens[..<$0] }.map { $0.filter(\.isDigit).count } ?? mantissaTokens.filter(\.isDigit).count)
        var exponent = value == 0 ? 0 : Int(floor(log10(abs(value))))
        // Engineering-style codes ("##0.0E+0") keep the exponent a multiple of the integer places.
        if integerPlaces > 1 { exponent = Int(floor(Double(exponent) / Double(integerPlaces))) * integerPlaces }
        var mantissa = value / pow(10, Double(exponent))
        if abs(mantissa).rounded(toPlaces: fractionPlaces) >= pow(10, Double(integerPlaces)) {
            exponent += integerPlaces
            mantissa = value / pow(10, Double(exponent))
        }
        let sign = value < 0 && !signHandled ? "-" : ""
        let body = String(format: "%.\(fractionPlaces)f", abs(mantissa))
        let plus = tokens[exponentIndex] == .exponent("E+") || tokens[exponentIndex] == .exponent("e+")
        let exponentSign = exponent < 0 ? "-" : (plus ? "+" : "")
        let letter = tokens[exponentIndex].exponentLetter
        return sign + body + letter + exponentSign + String(format: "%0\(exponentDigits)d", abs(exponent))
    }

    private static func renderFraction(_ value: Double, tokens: [Token], signHandled: Bool) -> String {
        let slash = tokens.firstIndex(of: .placeholder("/"))!
        let denominatorTokens = tokens[tokens.index(after: slash)...]
        let fixed = denominatorTokens.compactMap { token -> Int? in
            if case .literal(let text) = token { return Int(text) }
            return nil
        }.first
        let places = max(1, denominatorTokens.filter(\.isDigit).count)
        let hasWhole = tokens[..<slash].contains(.literal(" "))
        let magnitude = abs(value)
        let whole = hasWhole ? magnitude.rounded(.down) : 0
        let part = magnitude - whole
        var best = (numerator: 0, denominator: 1)
        if let fixed {
            best = (Int((part * Double(fixed)).rounded()), fixed)
        } else {
            var bestError = Double.infinity
            for denominator in 1...Int(pow(10, Double(places)) - 1) {
                let numerator = Int((part * Double(denominator)).rounded())
                let error = abs(part - Double(numerator) / Double(denominator))
                if error < bestError - 1e-12 { bestError = error; best = (numerator, denominator) }
            }
        }
        let sign = value < 0 && !signHandled ? "-" : ""
        if best.numerator == 0 { return sign + (whole > 0 ? String(Int(whole)) : "0") }
        if best.numerator == best.denominator { return sign + String(Int(whole) + 1) }
        let fraction = "\(best.numerator)/\(best.denominator)"
        return sign + (whole > 0 ? "\(Int(whole)) \(fraction)" : fraction)
    }

    // MARK: Dates

    private static func renderDate(_ serial: Double, tokens: [Token], locale: Locale) -> String {
        let fractionDigits = tokens.compactMap { token -> Int? in
            if case .date(let text) = token, text.hasPrefix(".") { return text.count - 1 }
            return nil
        }.max() ?? 0
        let parts = SpreadsheetDate.parts(serial, roundToSecond: fractionDigits == 0)
        let twelveHour = tokens.contains { if case .date(let text) = $0 { return ["am/pm", "a/p"].contains(text.lowercased()) }; return false }
        let symbols = DateSymbols.of(locale)

        // "m"/"mm" mean minutes right after an hour or right before seconds.
        let dateTokens = tokens.enumerated().map { index, token -> Token in
            guard case .date(let text) = token, text.lowercased() == "m" || text.lowercased() == "mm" else { return token }
            let previous = tokens[..<index].last { if case .date = $0 { return true }; return false }
            let next = tokens[tokens.index(after: index)...].first { if case .date = $0 { return true }; return false }
            let afterHour = { if case .date(let t) = previous { return t.lowercased().hasPrefix("h") || t.lowercased().hasPrefix("[h") }; return false }()
            let beforeSecond = { if case .date(let t) = next { return t.lowercased().hasPrefix("s") || t.lowercased().hasPrefix("[s") }; return false }()
            return afterHour || beforeSecond ? .date(text.lowercased() == "m" ? "minute" : "minute2") : token
        }

        var result = ""
        for token in dateTokens {
            switch token {
            case .literal(let text): result += text
            case .date(let raw):
                let text = raw.lowercased()
                switch text {
                case "yyyy", "yyy": result += String(format: "%04d", parts.year)
                case "yy", "y": result += String(format: "%02d", parts.year % 100)
                case "m": result += String(parts.month)
                case "mm": result += String(format: "%02d", parts.month)
                case "mmm": result += symbols.shortMonthSymbols[parts.month - 1]
                case "mmmm": result += symbols.monthSymbols[parts.month - 1]
                case "mmmmm": result += String(symbols.monthSymbols[parts.month - 1].prefix(1))
                case "d": result += String(parts.day)
                case "dd": result += String(format: "%02d", parts.day)
                case "ddd": result += symbols.shortWeekdaySymbols[parts.weekday - 1]
                case "dddd": result += symbols.weekdaySymbols[parts.weekday - 1]
                case "h", "hh":
                    var hour = parts.hour
                    if twelveHour { hour = hour % 12 == 0 ? 12 : hour % 12 }
                    result += text == "hh" ? String(format: "%02d", hour) : String(hour)
                case "minute": result += String(parts.minute)
                case "minute2": result += String(format: "%02d", parts.minute)
                case "s": result += String(parts.second)
                case "ss": result += String(format: "%02d", parts.second)
                case "am/pm": result += parts.hour < 12 ? (raw == "am/pm" ? "am" : "AM") : (raw == "am/pm" ? "pm" : "PM")
                case "a/p": result += parts.hour < 12 ? (raw == "a/p" ? "a" : "A") : (raw == "a/p" ? "p" : "P")
                default:
                    if text.hasPrefix(".") {
                        let digits = text.count - 1
                        let fraction = Double(parts.millisecond) / 1000
                        result += "." + String(String(format: "%.\(digits)f", fraction).dropFirst(2))
                    } else if text.hasPrefix("[h") {
                        let hours = Int((serial * 86_400).rounded()) / 3600
                        result += String(format: "%0\(text.count - 2)d", hours)
                    } else if text.hasPrefix("[m") {
                        result += String(format: "%0\(text.count - 2)d", Int((serial * 1440).rounded()))
                    } else if text.hasPrefix("[s") {
                        result += String(format: "%0\(text.count - 2)d", Int((serial * 86_400).rounded()))
                    }
                }
            default: continue
            }
        }
        return result
    }

    // MARK: - Tokens

    enum Token: Equatable {
        case literal(String)
        /// An unquoted %: prints "%" and multiplies by 100.
        case percent
        /// 0 # ? / @ and similar.
        case placeholder(String)
        case decimalPoint
        case groupComma
        case exponent(String)
        /// y m d h s am/pm [h] .0 …
        case date(String)

        var isDigit: Bool { self == .placeholder("0") || self == .placeholder("#") || self == .placeholder("?") }
        var isExponent: Bool { if case .exponent = self { return true }; return false }
        var exponentLetter: String { if case .exponent(let text) = self { return String(text.prefix(1)) }; return "E" }
    }

    /// Splits a code into sections at semicolons outside quotes and brackets.
    static func sections(_ code: String) -> [String] {
        var sections: [String] = [], current = ""
        var inQuotes = false, inBrackets = false, escaped = false
        for character in code {
            if escaped { current.append(character); escaped = false; continue }
            switch character {
            case "\\": escaped = true; current.append(character)
            case "\"": inQuotes.toggle(); current.append(character)
            case "[" where !inQuotes: inBrackets = true; current.append(character)
            case "]" where !inQuotes: inBrackets = false; current.append(character)
            case ";" where !inQuotes && !inBrackets: sections.append(current); current = ""
            default: current.append(character)
            }
        }
        sections.append(current)
        return sections
    }

    /// The code without quoted text, escapes, padding, fills, colours and locale tags.
    static func stripped(_ tokens: [Token]) -> String {
        tokens.map { token -> String in
            switch token {
            case .literal: return ""
            case .placeholder(let text), .date(let text), .exponent(let text): return text
            case .decimalPoint: return "."
            case .groupComma: return ","
            case .percent: return "%"
            }
        }.joined()
    }

    static func literalText(_ section: String) -> String {
        tokens(section).compactMap { if case .literal(let text) = $0 { return text }; return nil }.joined()
    }

    static func tokens(_ section: String) -> [Token] {
        var tokens: [Token] = []
        let characters = Array(section)
        var index = 0
        func literal(_ text: String) {
            if case .literal(let previous) = tokens.last {
                tokens[tokens.count - 1] = .literal(previous + text)
            } else {
                tokens.append(.literal(text))
            }
        }
        let hasDateParts = section.replacingOccurrences(of: #""[^"]*""#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\[[^\]]*\]"#, with: "", options: .regularExpression)
            .lowercased().contains { "ymdhs".contains($0) }
        while index < characters.count {
            let character = characters[index]
            let lower = Character(character.lowercased())
            switch character {
            case "\"":
                var text = ""
                index += 1
                while index < characters.count, characters[index] != "\"" { text.append(characters[index]); index += 1 }
                literal(text)
            case "\\":
                index += 1
                if index < characters.count { literal(String(characters[index])) }
            case "_":
                index += 1
                literal(" ")
            case "*":
                index += 1 // fill character: nothing when there's no column width
            case "[":
                var inside = ""
                index += 1
                while index < characters.count, characters[index] != "]" { inside.append(characters[index]); index += 1 }
                let lowered = inside.lowercased()
                if inside.hasPrefix("$") {
                    let symbol = inside.dropFirst().split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
                    if !symbol.isEmpty { literal(symbol) }
                } else if lowered.first.map({ "hms".contains($0) }) == true, Set(lowered).isSubset(of: Set("hms")) {
                    tokens.append(.date("[" + lowered + "]"))
                }
                // Colours ([Red]) and conditions ([<100]) don't print.
            case "0", "#", "?":
                tokens.append(.placeholder(String(character)))
            case "@":
                tokens.append(.placeholder("@"))
            case "/" where !hasDateParts:
                tokens.append(.placeholder("/"))
            case ".":
                if hasDateParts, index + 1 < characters.count, characters[index + 1] == "0" {
                    var text = "."
                    while index + 1 < characters.count, characters[index + 1] == "0" { text.append("0"); index += 1 }
                    tokens.append(.date(text))
                } else if hasDateParts {
                    literal(".")
                } else {
                    tokens.append(.decimalPoint)
                }
            case ",":
                if hasDateParts { literal(",") } else { tokens.append(.groupComma) }
            case "E", "e":
                if !hasDateParts, index + 1 < characters.count, characters[index + 1] == "+" || characters[index + 1] == "-" {
                    tokens.append(.exponent(String(character) + String(characters[index + 1])))
                    index += 1
                } else {
                    literal(String(character))
                }
            case "%":
                tokens.append(.percent)
            default:
                if hasDateParts, "ymdhsa".contains(lower) {
                    let rest = String(characters[index...]).lowercased()
                    if rest.hasPrefix("am/pm") {
                        tokens.append(.date(String(characters[index..<index + 5])))
                        index += 4
                    } else if rest.hasPrefix("a/p") {
                        tokens.append(.date(String(characters[index..<index + 3])))
                        index += 2
                    } else if "ymdhs".contains(lower) {
                        var text = String(lower)
                        while index + 1 < characters.count, Character(characters[index + 1].lowercased()) == lower {
                            text.append(lower)
                            index += 1
                        }
                        tokens.append(.date(text))
                    } else {
                        literal(String(character))
                    }
                } else if section.lowercased() == "general" || String(characters[index...]).lowercased().hasPrefix("general") {
                    tokens.append(.placeholder("General"))
                    index += 6
                } else {
                    literal(String(character))
                }
            }
            index += 1
        }
        return tokens
    }
}

private nonisolated extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let factor = pow(10, Double(places))
        return (self * factor).rounded() / factor
    }
}

/// Month and weekday names per locale, made once (a DateFormatter per cell is slow).
nonisolated struct DateSymbols: Sendable {
    var monthSymbols: [String], shortMonthSymbols: [String], weekdaySymbols: [String], shortWeekdaySymbols: [String]

    private static let cache = Mutex<[String: DateSymbols]>([:])

    static func of(_ locale: Locale) -> DateSymbols {
        if let cached = cache.withLock({ $0[locale.identifier] }) { return cached }
        let formatter = DateFormatter()
        formatter.locale = locale
        let symbols = DateSymbols(monthSymbols: formatter.monthSymbols, shortMonthSymbols: formatter.shortMonthSymbols,
                                  weekdaySymbols: formatter.weekdaySymbols, shortWeekdaySymbols: formatter.shortWeekdaySymbols)
        cache.withLock { $0[locale.identifier] = symbols }
        return symbols
    }
}
