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
    func place(_ file: URL, named filename: String, beside input: URL) throws -> URL {
        let target = Self.unique(filename, in: directory(for: input))
        try FileManager.default.moveItem(at: file, to: target)
        return target
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
