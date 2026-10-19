import Foundation

/// Turns the bytes of a plain-text file (CSV, TSV, TXT, SRT, VTT, ASS,
/// Markdown) into text, whatever encoding it was saved in: a byte-order mark
/// wins, then UTF-16 without a mark, then UTF-8, then the legacy encodings
/// Excel, Notepad and old Macs write (Windows-1252, Windows-1250, Mac Roman),
/// picked by which one reads as the most plausible text.
nonisolated enum TextDecoding {
    static func read(_ url: URL) throws -> String {
        try decode(Data(contentsOf: url))
    }

    static func decode(_ data: Data) throws -> String {
        let bytes = [UInt8](data.prefix(4))
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            if let text = String(data: data.dropFirst(3), encoding: .utf8) { return text }
        }
        if bytes.starts(with: [0xFF, 0xFE, 0x00, 0x00]), let text = String(data: data.dropFirst(4), encoding: .utf32LittleEndian) {
            return text
        }
        if bytes.starts(with: [0xFF, 0xFE]), let text = String(data: data.dropFirst(2), encoding: .utf16LittleEndian) {
            return text
        }
        if bytes.starts(with: [0xFE, 0xFF]), let text = String(data: data.dropFirst(2), encoding: .utf16BigEndian) {
            return text
        }
        // UTF-16 first: its zero bytes are valid (but wrong) UTF-8.
        if let encoding = unmarkedUTF16(data), let text = String(data: data, encoding: encoding) { return text }
        if let text = String(data: data, encoding: .utf8) { return text }

        let candidates: [String.Encoding] = [.windowsCP1252, .windowsCP1250, .macOSRoman]
        var best: (text: String, score: Int)?
        for encoding in candidates {
            guard let text = String(data: data, encoding: encoding) else { continue }
            let score = plausibility(text)
            if best == nil || score > best!.score { best = (text, score) }
        }
        guard let best else { throw CutieError("Couldn't read this file's text encoding.") }
        return best.text
    }

    /// UTF-16 saved without a byte-order mark: mostly-ASCII text leaves every
    /// other byte zero.
    static func unmarkedUTF16(_ data: Data) -> String.Encoding? {
        let sample = [UInt8](data.prefix(4096))
        guard sample.count >= 4, sample.count % 2 == 0 else { return nil }
        let pairs = sample.count / 2
        var evenZeros = 0, oddZeros = 0
        for index in stride(from: 0, to: sample.count - 1, by: 2) {
            if sample[index] == 0 { evenZeros += 1 }
            if sample[index + 1] == 0 { oddZeros += 1 }
        }
        if oddZeros > pairs * 6 / 10 && evenZeros < pairs / 10 { return .utf16LittleEndian }
        if evenZeros > pairs * 6 / 10 && oddZeros < pairs / 10 { return .utf16BigEndian }
        return nil
    }

    /// How much a reading looks like real text. Accented lowercase letters count
    /// for it; stray symbols, control characters and capitals in the middle of a
    /// word count against it. A Polish "ą" read as Windows-1252 becomes "¹", a
    /// French "é" read as Mac Roman becomes "È" inside "cafÈ".
    static func plausibility(_ text: String) -> Int {
        let usualSymbols = Set("€£¥©®°±·–—‘’‚“”„†•…‰‹›«»¿¡×÷½¼¾µ¢§¶")
        var score = 0
        var previous: Character = " "
        for character in text {
            defer { previous = character }
            guard !character.isASCII else { continue }
            if character.isLetter {
                if character.isUppercase {
                    score += previous.isLetter && previous.isLowercase ? -3 : 1
                } else {
                    score += 2
                }
            } else if !(usualSymbols.contains(character) || character.isWhitespace) {
                score -= 3
            }
        }
        return score
    }
}
