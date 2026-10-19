import Foundation

/// Where finished files go. Every job writes into its own scratch folder first
/// and only moves complete files out, so a failed or cancelled job never leaves
/// half a file next to the original. Originals are never touched.
nonisolated struct Output: Sendable {
    var location: SaveLocation

    static var downloads: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Downloads")
    }

    /// The folder for outputs made from `input`: beside it, or Downloads when
    /// that's the setting or the original's folder is read-only (a disk image).
    func directory(for input: URL) -> URL {
        guard location == .nextToOriginal else { return Self.downloads }
        let parent = input.deletingLastPathComponent()
        return FileManager.default.isWritableFile(atPath: parent.path) ? parent : Self.downloads
    }

    /// Moves a finished file or folder from scratch to its final, unused name.
    /// On the same disk that's a rename. Across disks the copy goes to a
    /// hidden name first and is renamed only once complete, so an interrupted
    /// copy never shows up as a result. Never overwrites: if another job takes
    /// the name first, the next free one is used.
    func place(_ file: URL, named filename: String, beside input: URL) throws -> URL {
        let directory = directory(for: input)
        let manager = FileManager.default
        var source = file
        if !Self.sameVolume(file, directory) {
            let staging = directory.appending(path: ".cutie-\(UUID().uuidString)")
            do {
                try manager.copyItem(at: file, to: staging)
            } catch {
                try? manager.removeItem(at: staging)
                throw error
            }
            source = staging
        }
        defer { if source != file { try? manager.removeItem(at: source) } }
        for _ in 0..<100 {
            let target = Self.unique(filename, in: directory)
            do {
                try manager.moveItem(at: source, to: target)
                return target
            } catch CocoaError.fileWriteFileExists {
                continue
            }
        }
        throw CutieError("Couldn't find a free name for \(filename).")
    }

    static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        let key = URLResourceKey.volumeIdentifierKey
        guard let first = try? a.resourceValues(forKeys: [key]).volumeIdentifier as? NSObject,
              let second = try? b.resourceValues(forKeys: [key]).volumeIdentifier as? NSObject else { return false }
        return first.isEqual(second)
    }

    /// Fails early, in plain words, when a job that needs `bytes` (known
    /// ahead, like an archive's unpacked size) won't fit on `directory`'s disk.
    static func requireSpace(_ bytes: Int64, at directory: URL) throws {
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey, .volumeLocalizedNameKey]
        guard bytes > 0, let values = try? directory.resourceValues(forKeys: keys) else { return }
        // "Important usage" counts purgeable space on the startup disk; other disks only report plain free space.
        let important = values.volumeAvailableCapacityForImportantUsage ?? 0
        let free = important > 0 ? important : Int64(values.volumeAvailableCapacity ?? 0)
        guard free > 0, free < bytes else { return }
        let style = ByteCountFormatStyle(style: .file)
        let disk = values.volumeLocalizedName.map { "“\($0)”" } ?? "this disk"
        throw CutieError("Not enough space on \(disk): this needs about \(bytes.formatted(style)) and \(free.formatted(style)) is free.")
    }

    /// The bytes `urls` take up, folders included.
    static func size(of urls: [URL]) -> Int64 {
        var total: Int64 = 0
        for url in urls {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .totalFileAllocatedSizeKey, .fileSizeKey])
            if values?.isDirectory == true {
                let items = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
                while let item = items?.nextObject() as? URL {
                    let value = try? item.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
                    total += Int64(value?.totalFileAllocatedSize ?? value?.fileSize ?? 0)
                }
            } else {
                total += Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
            }
        }
        return total
    }

    /// "photo.png", then "photo 2.png", "photo 3.png"… like Finder.
    static func unique(_ filename: String, in directory: URL) -> URL {
        let (base, ext) = split(filename)
        var candidate = directory.appending(path: filename)
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let name = ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)"
            candidate = directory.appending(path: name)
            number += 1
        }
        return candidate
    }

    /// Splits "a.tar.gz" into ("a", "tar.gz") and "photo.png" into ("photo", "png").
    static func split(_ filename: String) -> (base: String, ext: String) {
        let lower = filename.lowercased()
        for compound in ["tar.gz", "tar.bz2", "tar.xz"] where lower.hasSuffix("." + compound) {
            return (String(filename.dropLast(compound.count + 1)), String(filename.suffix(compound.count)))
        }
        let url = URL(fileURLWithPath: filename)
        let ext = url.pathExtension
        return ext.isEmpty ? (filename, "") : (url.deletingPathExtension().lastPathComponent, ext)
    }

    /// The input's name without its extension ("holiday.tar.gz" → "holiday").
    static func baseName(of url: URL) -> String {
        split(url.lastPathComponent).base
    }
}
