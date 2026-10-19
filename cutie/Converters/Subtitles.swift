import Foundation

/// SRT ⇄ WebVTT ⇄ ASS/SSA, and any of them to plain text (the lines only).
///
/// Cues are kept in one neutral form: SRT-style markup (`<i>`, `<b>`, `<u>`,
/// `<font color="…">`), real characters instead of entities, and a numpad
/// position (ASS's `\an`: 2 bottom centre, 8 top centre). Each format's own
/// styling is translated in and out of that, so italics, colours and
/// top-of-screen cues survive every conversion. Timing is kept to the
/// millisecond (ASS stores centiseconds, so it rounds to those).
nonisolated enum Subtitles {
    struct Cue: Equatable, Sendable {
        var start: Int // milliseconds
        var end: Int
        var text: String
        /// Numpad position: 1–3 bottom, 4–6 middle, 7–9 top (left, centre, right).
        var position = 2
    }

    enum Syntax { case srt, vtt, ass }

    static func syntax(of source: String) -> Syntax {
        let start = source.drop { $0 == "\u{FEFF}" || $0.isWhitespace }
        if start.hasPrefix("WEBVTT") { return .vtt }
        if source.contains("[Script Info]") || source.contains("[Events]") { return .ass }
        return .srt
    }

    static func parse(_ source: String) -> [Cue] {
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        switch syntax(of: normalized) {
        case .ass: return parseASS(normalized)
        case .vtt: return parseTimedBlocks(normalized, vtt: true)
        case .srt: return parseTimedBlocks(normalized, vtt: false)
        }
    }

    // MARK: - SRT and VTT

    private static func parseTimedBlocks(_ source: String, vtt: Bool) -> [Cue] {
        var cues: [Cue] = []
        var classColors: [String: String] = [:]
        for block in source.components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            if vtt, lines.first?.hasPrefix("STYLE") == true {
                classColors.merge(styleColors(lines.dropFirst().joined(separator: "\n"))) { $1 }
                continue
            }
            guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[timingIndex].components(separatedBy: "-->")
            guard parts.count == 2 else { continue }
            let after = parts[1].split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard let start = milliseconds(parts[0]), let end = milliseconds(after.first ?? "") else { continue }
            let raw = lines[(timingIndex + 1)...].joined(separator: "\n")
            if vtt {
                let (text, position) = fromVTT(raw, settings: Array(after.dropFirst()), classColors: classColors)
                cues.append(Cue(start: start, end: end, text: text, position: position))
            } else {
                let (text, position) = fromSRT(raw)
                cues.append(Cue(start: start, end: end, text: text, position: position))
            }
        }
        return cues
    }

    /// "01:02:03,456", "02:03.456" (VTT may omit hours) → ms.
    static func milliseconds(_ stamp: String) -> Int? {
        let clean = stamp.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let pieces = clean.split(separator: ":").map(String.init)
        guard (2...3).contains(pieces.count) else { return nil }
        let secondsParts = pieces.last!.split(separator: ".").map(String.init)
        guard let seconds = Int(secondsParts[0]) else { return nil }
        let millis = secondsParts.count > 1 ? Int(secondsParts[1].padding(toLength: 3, withPad: "0", startingAt: 0).prefix(3)) ?? 0 : 0
        guard let minutes = Int(pieces[pieces.count - 2]) else { return nil }
        let hours = pieces.count == 3 ? Int(pieces[0]) ?? 0 : 0
        return ((hours * 60 + minutes) * 60 + seconds) * 1000 + millis
    }

    static func stamp(_ ms: Int, separator: Character) -> String {
        let hours = ms / 3_600_000, minutes = ms / 60_000 % 60, seconds = ms / 1000 % 60, millis = ms % 1000
        return String(format: "%02d:%02d:%02d%@%03d", hours, minutes, seconds, String(separator), millis)
    }

    /// SRT text: its tags are already the neutral ones; `{\an8}` and the ASS
    /// overrides some SRT files carry ({\i1}, {\c&H…&}) are translated.
    static func fromSRT(_ raw: String) -> (String, Int) {
        var position = 2
        var text = translateOverrides(raw, position: &position, style: .plain, keepPlainBraces: true)
        text = decodeEntities(text)
        return (text, position)
    }

    /// VTT text: voice, language and class spans become plain text (or a
    /// colour), karaoke timestamps go, ruby keeps its base, entities decode,
    /// and the line/align settings become a position.
    static func fromVTT(_ raw: String, settings: [String], classColors: [String: String]) -> (String, Int) {
        var output = ""
        var stack: [String] = []
        var inRubyText = false
        var index = raw.startIndex
        while index < raw.endIndex {
            if raw[index] == "<", let close = raw[index...].firstIndex(of: ">") {
                let tag = String(raw[raw.index(after: index)..<close])
                index = raw.index(after: close)
                if tag.first?.isNumber == true { continue } // <00:00:01.000> karaoke timing
                let closing = tag.hasPrefix("/")
                let name = (closing ? String(tag.dropFirst()) : tag).split(whereSeparator: { $0 == " " || $0 == "." }).first.map(String.init) ?? ""
                if closing {
                    if name == "rt" { inRubyText = false; continue }
                    if let open = stack.lastIndex(where: { $0 == name || ($0 == "font" && name == "c") }) {
                        let entry = stack.remove(at: open)
                        if entry == "font" { output += "</font>" } else if ["i", "b", "u"].contains(entry) { output += "</\(entry)>" }
                    }
                    continue
                }
                switch name {
                case "i", "b", "u":
                    output += "<\(name)>"
                    stack.append(name)
                case "c":
                    let classes = tag.split(separator: ".").dropFirst().map(String.init)
                    if let color = classes.lazy.compactMap({ classColors[$0] ?? vttPalette[$0] }).first {
                        output += #"<font color="\#(color)">"#
                        stack.append("font")
                    } else {
                        stack.append("c")
                    }
                case "rt":
                    inRubyText = true
                default:
                    stack.append(name) // v, lang, ruby: their text stays, the tag goes
                }
                continue
            }
            if !inRubyText { output.append(raw[index]) }
            index = raw.index(after: index)
        }
        for entry in stack.reversed() where ["i", "b", "u", "font"].contains(entry) { output += "</\(entry)>" }
        return (decodeEntities(output), position(fromVTT: settings))
    }

    /// VTT's built-in colour classes.
    static let vttPalette: [String: String] = [
        "white": "#FFFFFF", "lime": "#00FF00", "cyan": "#00FFFF", "red": "#FF0000",
        "yellow": "#FFFF00", "magenta": "#FF00FF", "blue": "#0000FF", "black": "#000000",
    ]

    /// `::cue(.name) { color: #ff0000 }` rules from a STYLE block.
    private static func styleColors(_ css: String) -> [String: String] {
        var colors: [String: String] = [:]
        for match in css.matches(of: /::cue\(\.([A-Za-z0-9_-]+)\)\s*\{[^}]*?color:\s*([^;}\s]+)/) {
            if let hex = hexColor(String(match.output.2)) { colors[String(match.output.1)] = hex }
        }
        return colors
    }

    private static func position(fromVTT settings: [String]) -> Int {
        var row = 0 // 0 bottom, 1 middle, 2 top
        var column = 1 // 0 left, 1 centre, 2 right
        for setting in settings {
            let pair = setting.split(separator: ":", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { continue }
            let value = pair[1].split(separator: ",").first.map(String.init) ?? pair[1]
            switch pair[0] {
            case "line":
                if value.hasSuffix("%"), let percent = Double(value.dropLast()) {
                    row = percent < 34 ? 2 : (percent < 67 ? 1 : 0)
                } else if let line = Int(value) {
                    row = line >= 0 ? 2 : 0
                }
            case "align":
                column = ["left", "start"].contains(value) ? 0 : (["right", "end"].contains(value) ? 2 : 1)
            default: continue
            }
        }
        return row * 3 + column + 1
    }

    static func srt(_ cues: [Cue]) -> String {
        cues.enumerated().map { index, cue in
            let prefix = cue.position == 2 ? "" : "{\\an\(cue.position)}"
            return "\(index + 1)\n\(stamp(cue.start, separator: ",")) --> \(stamp(cue.end, separator: ","))\n\(prefix)\(cue.text)\n"
        }.joined(separator: "\n")
    }

    static func vtt(_ cues: [Cue]) -> String {
        var classes: [String: String] = [:] // hex → class
        let bodies = cues.map { cue in
            let settings: String = switch cue.position {
            case 7: " line:0 align:left"
            case 8: " line:0"
            case 9: " line:0 align:right"
            case 4: " line:50%,center align:left"
            case 5: " line:50%,center"
            case 6: " line:50%,center align:right"
            case 1: " align:left"
            case 3: " align:right"
            default: ""
            }
            let text = toVTTMarkup(cue.text, classes: &classes)
            return "\(stamp(cue.start, separator: ".")) --> \(stamp(cue.end, separator: "."))\(settings)\n\(text)\n"
        }
        var header = "WEBVTT\n\n"
        let custom = classes.filter { name in !vttPalette.keys.contains(name.value) }.sorted { $0.value < $1.value }
        if !custom.isEmpty {
            header += "STYLE\n" + custom.map { "::cue(.\($0.value)) { color: \($0.key); }" }.joined(separator: "\n") + "\n\n"
        }
        return header + bodies.joined(separator: "\n")
    }

    /// Neutral markup → VTT: escaped text, `<c.class>` for colours.
    private static func toVTTMarkup(_ text: String, classes: inout [String: String]) -> String {
        var output = ""
        for piece in markupPieces(text) {
            switch piece {
            case .text(let text):
                output += text.replacingOccurrences(of: "&", with: "&amp;")
                    .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            case .open(let tag, let color):
                if tag == "font" {
                    let hex = color.flatMap(hexColor) ?? "#FFFFFF"
                    let name = vttPalette.first { $0.value == hex }?.key ?? "c_" + hex.dropFirst().lowercased()
                    classes[hex] = name
                    output += "<c.\(name)>"
                } else {
                    output += "<\(tag)>"
                }
            case .close(let tag):
                output += tag == "font" ? "</c>" : "</\(tag)>"
            }
        }
        return output
    }

    // MARK: - ASS / SSA

    private struct ASSStyle {
        var bold = false, italic = false, underline = false
        var color: String?
        var position = 2
        static let plain = ASSStyle()
    }

    private static func parseASS(_ source: String) -> [Cue] {
        var section = ""
        var styleFields: [String] = [], eventFields: [String] = []
        var styles: [String: ASSStyle] = [:]
        var legacyAlignment = false
        var cues: [Cue] = []
        for line in source.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                section = trimmed.lowercased()
                legacyAlignment = legacyAlignment || section == "[v4 styles]"
                continue
            }
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = trimmed[..<colon].trimmingCharacters(in: .whitespaces)
            let value = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            switch (section, key) {
            case (_, "Format") where section.contains("styles"):
                styleFields = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            case (_, "Style") where section.contains("styles"):
                let values = split(value, into: styleFields.count)
                func field(_ name: String) -> String? { styleFields.firstIndex(of: name).flatMap { values.indices.contains($0) ? values[$0] : nil } }
                var style = ASSStyle()
                style.bold = (field("bold").flatMap(Int.init) ?? 0) != 0
                style.italic = (field("italic").flatMap(Int.init) ?? 0) != 0
                style.underline = (field("underline").flatMap(Int.init) ?? 0) != 0
                style.color = field("primarycolour").flatMap(assColor).flatMap { $0 == "#FFFFFF" ? nil : $0 }
                if let alignment = field("alignment").flatMap(Int.init) {
                    style.position = legacyAlignment ? numpad(fromLegacy: alignment) : alignment
                }
                styles[field("name") ?? "Default"] = style
            case ("[events]", "Format"):
                eventFields = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            case ("[events]", "Dialogue"):
                if eventFields.isEmpty {
                    eventFields = ["layer", "start", "end", "style", "name", "marginl", "marginr", "marginv", "effect", "text"]
                }
                let values = split(value, into: eventFields.count)
                func field(_ name: String) -> String? { eventFields.firstIndex(of: name).flatMap { values.indices.contains($0) ? values[$0] : nil } }
                guard let start = field("start").flatMap(milliseconds), let end = field("end").flatMap(milliseconds) else { continue }
                let style = styles[field("style")?.replacingOccurrences(of: "*", with: "") ?? "Default"] ?? styles["Default"] ?? .plain
                var position = style.position
                let raw = (field("text") ?? "").replacingOccurrences(of: "\\N", with: "\n")
                    .replacingOccurrences(of: "\\n", with: " ").replacingOccurrences(of: "\\h", with: "\u{00A0}")
                let text = translateOverrides(raw, position: &position, style: style)
                cues.append(Cue(start: start, end: end, text: text, position: position))
            default:
                continue
            }
        }
        // ASS lists events in any order; SRT and VTT need them by start time (stable for ties).
        return cues.enumerated().sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }.map(\.element)
    }

    /// Splits "a,b,c,text, with commas" into `count` fields; the last keeps its commas.
    private static func split(_ value: String, into count: Int) -> [String] {
        value.split(separator: ",", maxSplits: max(0, count - 1), omittingEmptySubsequences: false)
            .enumerated().map { index, part in index == count - 1 ? String(part) : part.trimmingCharacters(in: .whitespaces) }
    }

    /// SSA's old alignment numbers (1–3 bottom, 5–7 top, 9–11 middle) → numpad.
    private static func numpad(fromLegacy alignment: Int) -> Int {
        switch alignment {
        case 5...7: alignment + 2
        case 9...11: alignment - 5
        case 1...3: alignment
        default: 2
        }
    }

    /// ASS override blocks ({\i1}, {\b0}, {\c&H0000FF&}, {\an8}, {\r}) → neutral
    /// tags, on top of the line's style; drawings ({\p1}…{\p0}) and other
    /// overrides drop out. Used for SRT too, where some files carry them.
    private static func translateOverrides(_ raw: String, position: inout Int, style: ASSStyle, keepPlainBraces: Bool = false) -> String {
        var output = ""
        var open: [(tag: String, color: String?)] = [] // i, b, u, font
        func openTag(_ entry: (tag: String, color: String?)) {
            output += entry.tag == "font" ? #"<font color="\#(entry.color ?? "#FFFFFF")">"# : "<\(entry.tag)>"
            open.append(entry)
        }
        func setOpen(_ tag: String, _ on: Bool, color: String? = nil) {
            if let index = open.lastIndex(where: { $0.tag == tag }) {
                // Close down to it, then reopen what was inside it (tags must nest).
                let inner = Array(open[(index + 1)...])
                for entry in open[index...].reversed() { output += "</\(entry.tag)>" }
                open.removeSubrange(index...)
                inner.forEach(openTag)
            }
            if on { openTag((tag, color)) }
        }
        if style.bold { setOpen("b", true) }
        if style.italic { setOpen("i", true) }
        if style.underline { setOpen("u", true) }
        if let color = style.color { setOpen("font", true, color: color) }

        var drawing = false
        var index = raw.startIndex
        while index < raw.endIndex {
            if raw[index] == "{", let close = raw[index...].firstIndex(of: "}") {
                let block = String(raw[raw.index(after: index)..<close])
                guard block.hasPrefix("\\") else {
                    // An ASS comment; in SRT, just text in braces.
                    if keepPlainBraces { output += "{" + block + "}" }
                    index = raw.index(after: close)
                    continue
                }
                index = raw.index(after: close)
                for override in block.split(separator: "\\").map(String.init) where !override.isEmpty {
                    if let match = override.firstMatch(of: /^an([1-9])$/) {
                        position = Int(match.output.1)!
                    } else if let match = override.firstMatch(of: /^a([0-9]{1,2})$/) {
                        position = numpad(fromLegacy: Int(match.output.1)!)
                    } else if let match = override.firstMatch(of: /^([ibu])([0-9]+)$/) {
                        let weight = Int(match.output.2)!
                        setOpen(String(match.output.1), match.output.1 == "b" ? (weight == 1 || weight >= 600) : weight != 0)
                    } else if let match = override.firstMatch(of: /^1?c(&H[0-9A-Fa-f]+&?)?$/) {
                        if let color = match.output.1.flatMap({ assColor(String($0)) }) {
                            setOpen("font", true, color: color)
                        } else {
                            setOpen("font", style.color != nil, color: style.color)
                        }
                    } else if override == "r" || (override.hasPrefix("r") && !override.hasPrefix("rnd")) {
                        for entry in open.reversed() { output += "</\(entry.tag)>" }
                        open = []
                    } else if let match = override.firstMatch(of: /^p([0-9]+)$/) {
                        drawing = Int(match.output.1)! > 0
                    }
                }
                continue
            }
            if !drawing { output.append(raw[index]) }
            index = raw.index(after: index)
        }
        for entry in open.reversed() { output += "</\(entry.tag)>" }
        // Opening and immediately closing (a style tag around nothing) leaves no trace.
        return output.replacingOccurrences(of: #"<(i|b|u)></\1>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"<font color="[^"]*"></font>"#, with: "", options: .regularExpression)
    }

    static func ass(_ cues: [Cue]) -> String {
        var lines = [
            "[Script Info]", "ScriptType: v4.00+", "PlayResX: 384", "PlayResY: 288", "WrapStyle: 0",
            "ScaledBorderAndShadow: yes", "",
            "[V4+ Styles]",
            "Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding",
            "Style: Default,Arial,20,&H00FFFFFF,&H000000FF,&H00000000,&H64000000,0,0,0,0,100,100,0,0,1,1,1,2,10,10,10,1",
            "",
            "[Events]",
            "Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text",
        ]
        for cue in cues {
            var text = cue.position == 2 ? "" : "{\\an\(cue.position)}"
            for piece in markupPieces(cue.text) {
                switch piece {
                case .text(let plain): text += plain.replacingOccurrences(of: "\n", with: "\\N")
                case .open("font", let color): text += "{\\c\(assColor(fromHex: color.flatMap(hexColor) ?? "#FFFFFF"))}"
                case .open(let tag, _): text += "{\\\(tag)1}"
                case .close("font"): text += "{\\c}"
                case .close(let tag): text += "{\\\(tag)0}"
                }
            }
            lines.append("Dialogue: 0,\(assStamp(cue.start)),\(assStamp(cue.end)),Default,,0,0,0,,\(text)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// h:mm:ss.cc, rounded to the centisecond ASS stores.
    static func assStamp(_ ms: Int) -> String {
        let centiseconds = (ms + 5) / 10
        return String(format: "%d:%02d:%02d.%02d", centiseconds / 360_000, centiseconds / 6000 % 60, centiseconds / 100 % 60, centiseconds % 100)
    }

    // MARK: - Colours and markup

    /// "&H00BBGGRR" / "&HBBGGRR&" (ASS keeps blue first) → "#RRGGBB".
    static func assColor(_ text: String) -> String? {
        let upper = text.uppercased().trimmingCharacters(in: .whitespaces)
        var hex: String
        if !upper.contains("H"), let decimal = Int(upper) {
            hex = String(format: "%06X", decimal) // SSA's decimal BGR
        } else {
            hex = upper.replacingOccurrences(of: "&", with: "").replacingOccurrences(of: "H", with: "")
            guard !hex.isEmpty, hex.allSatisfy(\.isHexDigit) else { return nil }
            if hex.count < 6 { hex = String(repeating: "0", count: 6 - hex.count) + hex }
        }
        let bgr = String(hex.suffix(6))
        let blue = bgr.prefix(2), green = bgr.dropFirst(2).prefix(2), red = bgr.suffix(2)
        return "#\(red)\(green)\(blue)"
    }

    static func assColor(fromHex hex: String) -> String {
        let digits = hex.dropFirst()
        return "&H\(digits.suffix(2))\(digits.dropFirst(2).prefix(2))\(digits.prefix(2))&"
    }

    /// "#f00", "#FF0000", "red", "rgb(255,0,0)" → "#FF0000".
    static func hexColor(_ text: String) -> String? {
        let lower = text.lowercased().trimmingCharacters(in: .whitespaces)
        if let named = vttPalette[lower] ?? ["green": "#008000", "purple": "#800080", "orange": "#FFA500", "gray": "#808080", "grey": "#808080"][lower] {
            return named
        }
        if lower.hasPrefix("#") {
            let digits = lower.dropFirst()
            if digits.count == 3 { return "#" + digits.map { "\($0)\($0)" }.joined().uppercased() }
            if digits.count == 6 || digits.count == 8 { return "#" + digits.prefix(6).uppercased() }
        }
        if let match = lower.firstMatch(of: /rgba?\((\d+),\s*(\d+),\s*(\d+)/) {
            return String(format: "#%02X%02X%02X", Int(match.output.1)!, Int(match.output.2)!, Int(match.output.3)!)
        }
        return nil
    }

    enum Piece: Equatable { case text(String), open(String, color: String?), close(String) }

    /// Neutral markup split into text and the four tags it knows.
    static func markupPieces(_ text: String) -> [Piece] {
        var pieces: [Piece] = []
        var plain = ""
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == "<", let close = text[index...].firstIndex(of: ">") {
                let tag = String(text[text.index(after: index)..<close])
                let lower = tag.lowercased()
                var piece: Piece?
                if ["i", "b", "u"].contains(lower) { piece = .open(lower, color: nil) }
                if ["/i", "/b", "/u", "/font"].contains(lower) { piece = .close(String(lower.dropFirst())) }
                if lower.hasPrefix("font") {
                    let color = tag.firstMatch(of: /color\s*=\s*"?([^"\s>]+)"?/).map { String($0.output.1) }
                    piece = .open("font", color: color)
                }
                if let piece {
                    if !plain.isEmpty { pieces.append(.text(plain)); plain = "" }
                    pieces.append(piece)
                    index = text.index(after: close)
                    continue
                }
            }
            plain.append(text[index])
            index = text.index(after: index)
        }
        if !plain.isEmpty { pieces.append(.text(plain)) }
        return pieces
    }

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let named = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}", "lrm": "\u{200E}", "rlm": "\u{200F}"]
        return text.replacing(/&(#x[0-9A-Fa-f]+|#[0-9]+|[A-Za-z]+);/) { match in
            let body = String(match.output.1)
            if body.hasPrefix("#x"), let value = UInt32(body.dropFirst(2), radix: 16), let scalar = Unicode.Scalar(value) { return String(Character(scalar)) }
            if body.hasPrefix("#"), let value = UInt32(body.dropFirst()), let scalar = Unicode.Scalar(value) { return String(Character(scalar)) }
            return named[body.lowercased()] ?? String(match.output.0)
        }
    }

    /// The spoken lines, markup stripped, repeats (rolling captions) removed.
    static func text(_ cues: [Cue]) -> String {
        var lines: [String] = []
        for cue in cues {
            let clean = markupPieces(cue.text).compactMap { if case .text(let text) = $0 { return text }; return nil }.joined()
            for line in clean.components(separatedBy: "\n") where !line.isEmpty && lines.last != line {
                lines.append(line)
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func convert(_ input: URL, to format: Format, at output: URL) throws {
        let cues = parse(try DocumentReader.readText(input))
        guard !cues.isEmpty else { throw CutieError("No subtitles found in this file.") }
        let text = switch format {
        case .srt: srt(cues)
        case .vtt: vtt(cues)
        case .ass: ass(cues)
        default: Subtitles.text(cues)
        }
        try Data(text.utf8).write(to: output)
    }
}
