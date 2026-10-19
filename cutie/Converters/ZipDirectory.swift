import Foundation

/// What a ZIP's central directory says before anything is extracted: whether
/// entries are encrypted, whether it's one part of a split archive, and how
/// big it gets unpacked. (bsdtar would otherwise stop with "Error exit delayed".)
nonisolated struct ZipDirectory: Equatable {
    var entries = 0
    var encrypted = false
    /// Split across several files (`.z01`, `.z02`… then `.zip`).
    var spanned = false
    var unpackedSize: Int64 = 0

    /// Nil when the file isn't a ZIP or its directory can't be found.
    init?(_ url: URL) {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
        self.init(data)
    }

    init?(_ data: Data) {
        guard data.count >= 22, let end = Self.lastSignature(0x0605_4B50, in: data) else { return nil }
        let disk = Int(Self.uint16(data, end + 4))
        let directoryDisk = Int(Self.uint16(data, end + 6))
        var count = Int(Self.uint16(data, end + 10))
        var offset = Int(Self.uint32(data, end + 16))
        spanned = disk != 0 || directoryDisk != 0
        // ZIP64: the real numbers are in a second end record, found through a locator.
        if count == 0xFFFF || offset == 0xFFFF_FFFF, end >= 20, Self.uint32(data, end - 20) == 0x0706_4B50 {
            let record = Int(Self.uint64(data, end - 20 + 8))
            guard record + 56 <= data.count, Self.uint32(data, record) == 0x0606_4B50 else { return nil }
            count = Int(Self.uint64(data, record + 32))
            offset = Int(Self.uint64(data, record + 48))
        }
        guard offset < data.count else {
            // A split archive's directory lives in the last part, pointing into earlier ones.
            if spanned { return }
            return nil
        }
        var index = offset
        while entries < count, index + 46 <= data.count, Self.uint32(data, index) == 0x0201_4B50 {
            let flags = Self.uint16(data, index + 8)
            var size = Int64(Self.uint32(data, index + 24))
            let nameLength = Int(Self.uint16(data, index + 28))
            let extraLength = Int(Self.uint16(data, index + 30))
            let commentLength = Int(Self.uint16(data, index + 32))
            if flags & 1 != 0 { encrypted = true }
            if size == 0xFFFF_FFFF {
                size = Self.zip64Size(data, extra: index + 46 + nameLength, length: extraLength) ?? size
            }
            unpackedSize += size
            entries += 1
            index += 46 + nameLength + extraLength + commentLength
        }
    }

    /// The uncompressed size in an entry's ZIP64 extra field (id 0x0001).
    private static func zip64Size(_ data: Data, extra start: Int, length: Int) -> Int64? {
        var index = start
        while index + 4 <= min(start + length, data.count) {
            let id = uint16(data, index), size = Int(uint16(data, index + 2))
            if id == 0x0001, size >= 8, index + 12 <= data.count { return Int64(uint64(data, index + 4)) }
            index += 4 + size
        }
        return nil
    }

    /// The end record sits in the last 64 KB + 22 bytes (after an optional comment).
    private static func lastSignature(_ signature: UInt32, in data: Data) -> Int? {
        let lowest = max(0, data.count - 22 - 65_535)
        var index = data.count - 22
        while index >= lowest {
            if uint32(data, index) == signature { return index }
            index -= 1
        }
        return nil
    }

    private static func uint16(_ data: Data, _ offset: Int) -> UInt16 {
        let base = data.startIndex + offset
        return UInt16(data[base]) | UInt16(data[base + 1]) << 8
    }

    private static func uint32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(uint16(data, offset)) | UInt32(uint16(data, offset + 2)) << 16
    }

    private static func uint64(_ data: Data, _ offset: Int) -> UInt64 {
        UInt64(uint32(data, offset)) | UInt64(uint32(data, offset + 4)) << 32
    }
}
