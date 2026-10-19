import Foundation

/// Spots files that were cut off (an interrupted download or copy). ImageIO
/// decodes a truncated JPEG without complaint and fills the missing rows with
/// grey, so the container's own structure is checked instead.
nonisolated enum FileIntegrity {
    static func checkImage(_ url: URL) throws {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped), data.count >= 12 else { return }
        if isTruncated(data) {
            throw CutieError("This image is damaged or incomplete (it ends early).")
        }
    }

    static func isTruncated(_ data: Data) -> Bool {
        let bytes = [UInt8](data.prefix(12))
        if bytes.starts(with: [0xFF, 0xD8]) { return !jpegIsComplete(data) }
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return !pngIsComplete(data) }
        if bytes.starts(with: Array("GIF8".utf8)) { return !gifIsComplete(data) }
        if bytes.starts(with: Array("RIFF".utf8)) { return riffSize(data) > data.count }
        if bytes.starts(with: Array("BM".utf8)) { return Int(littleEndian32(data, at: 2)) > data.count }
        if Array(bytes[4..<8]) == Array("ftyp".utf8) { return !isoBoxesAreComplete(data) }
        return false
    }

    /// Walks the segments to the end-of-image marker. Thumbnails sit inside
    /// APP segments, so their own end markers are skipped by length.
    static func jpegIsComplete(_ data: Data) -> Bool {
        let base = data.startIndex
        var index = 2
        while index + 1 < data.count {
            guard data[base + index] == 0xFF else { return false }
            let marker = data[base + index + 1]
            switch marker {
            case 0xD9:
                return true
            case 0xFF:
                index += 1 // fill byte
            case 0x01, 0xD0...0xD7:
                index += 2
            default:
                guard index + 3 < data.count else { return false }
                let length = Int(data[base + index + 2]) << 8 | Int(data[base + index + 3])
                index += 2 + length
                if marker == 0xDA {
                    // Entropy-coded data runs to the next real marker (not a stuffed 0x00 or a restart).
                    while index + 1 < data.count {
                        if data[base + index] == 0xFF {
                            let next = data[base + index + 1]
                            if next != 0x00, !(0xD0...0xD7).contains(next) { break }
                        }
                        index += 1
                    }
                }
            }
        }
        return false
    }

    static func pngIsComplete(_ data: Data) -> Bool {
        var index = 8
        while index + 8 <= data.count {
            let length = Int(bigEndian32(data, at: index))
            let type = String(decoding: data[(data.startIndex + index + 4)..<(data.startIndex + index + 8)], as: UTF8.self)
            index += 12 + length
            if index > data.count { return false }
            if type == "IEND" { return true }
        }
        return false
    }

    /// A GIF ends with a 0x3B trailer; some writers pad a few bytes after it.
    static func gifIsComplete(_ data: Data) -> Bool {
        data.suffix(8).contains(0x3B)
    }

    static func riffSize(_ data: Data) -> Int {
        Int(littleEndian32(data, at: 4)) + 8
    }

    /// HEIC, AVIF, MP4 and MOV are ISO boxes; a box reaching past the end means it was cut off.
    static func isoBoxesAreComplete(_ data: Data) -> Bool {
        var index = 0
        while index + 8 <= data.count {
            var size = Int(bigEndian32(data, at: index))
            if size == 1 {
                guard index + 16 <= data.count else { return false }
                size = Int(bigEndian32(data, at: index + 8)) << 32 | Int(bigEndian32(data, at: index + 12))
            } else if size == 0 {
                return true // runs to the end of the file
            }
            guard size >= 8 else { return false }
            index += size
        }
        return index == data.count
    }

    private static func bigEndian32(_ data: Data, at offset: Int) -> UInt32 {
        let base = data.startIndex + offset
        return UInt32(data[base]) << 24 | UInt32(data[base + 1]) << 16 | UInt32(data[base + 2]) << 8 | UInt32(data[base + 3])
    }

    private static func littleEndian32(_ data: Data, at offset: Int) -> UInt32 {
        let base = data.startIndex + offset
        return UInt32(data[base]) | UInt32(data[base + 1]) << 8 | UInt32(data[base + 2]) << 16 | UInt32(data[base + 3]) << 24
    }
}
