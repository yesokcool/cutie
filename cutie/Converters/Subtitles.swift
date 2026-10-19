import Foundation

/// SRT ⇄ WebVTT, and either to plain text (the lines only).
nonisolated enum Subtitles {
    struct Cue: Equatable, Sendable {
        var start: Int // milliseconds
        var end: Int
        var text: String
    }

    static func parse(_ source: String) -> [Cue] {
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var cues: [Cue] = []
        for block in normalized.components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[timingIndex].components(separatedBy: "-->")
            guard parts.count == 2,
                  let start = milliseconds(parts[0]),
                  let end = milliseconds(parts[1].split(separator: " ", omittingEmptySubsequences: true).first.map(String.init) ?? "") else { continue }
            let text = lines[(timingIndex + 1)...].joined(separator: "\n")
            cues.append(Cue(start: start, end: end, text: text))
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

    static func srt(_ cues: [Cue]) -> String {
        cues.enumerated().map { index, cue in
            "\(index + 1)\n\(stamp(cue.start, separator: ",")) --> \(stamp(cue.end, separator: ","))\n\(cue.text)\n"
        }.joined(separator: "\n")
    }

    static func vtt(_ cues: [Cue]) -> String {
        "WEBVTT\n\n" + cues.map { cue in
            "\(stamp(cue.start, separator: ".")) --> \(stamp(cue.end, separator: "."))\n\(cue.text)\n"
        }.joined(separator: "\n")
    }

    /// The spoken lines, tags stripped, repeats (rolling captions) removed.
    static func text(_ cues: [Cue]) -> String {
        var lines: [String] = []
        for cue in cues {
            let clean = cue.text.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
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
        default: Subtitles.text(cues)
        }
        try Data(text.utf8).write(to: output)
    }
}
