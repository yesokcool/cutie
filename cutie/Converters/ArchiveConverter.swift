import Foundation

/// ZIP, TAR and GZIP through macOS's own bsdtar (libarchive), which also
/// reads RAR and 7z; 7-Zip (when installed) for split archives and RAR/7z;
/// ditto (Archive Utility's engine) for ZIPs made on a Mac. Office files and
/// EPUBs are zipped here too.
nonisolated enum ArchiveConverter {
    /// Given to tools that would otherwise stop and ask for a password on a
    /// terminal, so an encrypted archive fails with a clear message instead.
    static let noPassword = "cutie-has-no-password"

    /// Archives `items` (files or folders) into one file. Items keep their names
    /// at the archive's root. ZIPs are cross-platform: UTF-8 names, permissions
    /// and symlinks kept, no `__MACOSX` folder (Finder's Compress adds one, and
    /// marks non-ASCII names in a way Windows reads as gibberish).
    static func archive(_ items: [URL], as format: Format, to output: URL) async throws {
        if format == .tar {
            try Output.requireSpace(Output.size(of: items), at: output.deletingLastPathComponent())
        }
        var arguments = ["--no-mac-metadata", "--exclude", ".DS_Store"]
        switch format {
        case .zip: arguments += ["--format", "zip", "-cf", output.path]
        case .tar: arguments += ["-cf", output.path]
        case .gzip: arguments += ["-czf", output.path]
        default: throw CutieError("Can't make \(format.title) archives.")
        }
        for item in items {
            arguments += ["-C", item.deletingLastPathComponent().path, item.lastPathComponent]
        }
        try await Shell.run(Shell.tar, arguments)
    }

    /// A single regular file → `name.gz` (gzip of the file itself, no tarball).
    static func gzipFile(_ input: URL, to output: URL) async throws {
        try await Shell.run(Shell.gzip, ["-c", "-9", input.path], stdoutFile: output)
    }

    /// Extracts into `folder`. Plain `.gz` files (not tarballs) are gunzipped.
    /// A downloaded archive's quarantine passes to what comes out of it, as
    /// with Archive Utility, so Gatekeeper still checks apps inside.
    static func extract(_ archive: URL, into folder: URL, toolbox: Toolbox = .none) async throws {
        try await unpack(archive, into: folder, toolbox: toolbox)
        propagateQuarantine(from: archive, to: folder)
    }

    private static func unpack(_ archive: URL, into folder: URL, toolbox: Toolbox) async throws {
        let ext = FileKind.fileExtension(of: archive)
        let zip = ext == "zip" ? ZipDirectory(archive) : nil
        if zip?.encrypted == true { throw CutieError("This archive is password-protected.") }
        if let zip { try Output.requireSpace(zip.unpackedSize, at: folder) }

        if isSplit(archive) || zip?.spanned == true {
            guard let sevenZip = toolbox.sevenZip else {
                throw CutieError("This is one part of a split archive. 7-Zip opens those (brew install sevenzip).")
            }
            return try await sevenZipExtract(archive, into: folder, with: sevenZip)
        }
        if ["rar", "7z"].contains(ext), let sevenZip = toolbox.sevenZip {
            return try await sevenZipExtract(archive, into: folder, with: sevenZip)
        }
        if zip != nil {
            // Archive Utility's engine: restores Finder tags and resource forks from `__MACOSX`.
            do {
                try await Shell.run(Shell.ditto, ["-x", "-k", archive.path, folder.path])
                return
            } catch {
                try clear(folder) // Methods ditto can't read (Deflate64, bzip2…) go to bsdtar.
            }
        }
        if ext == "gz" || ext == "bz2" || ext == "xz" {
            // A compressed single file unless it's really a tarball.
            let listing = try? await Shell.run(Shell.tar, ["-tf", archive.path])
            if listing == nil || listing!.isEmpty {
                let name = Output.baseName(of: archive)
                let tool = ext == "gz" ? Shell.gzip : URL(fileURLWithPath: ext == "bz2" ? "/usr/bin/bzip2" : "/usr/bin/xz")
                try await Shell.run(tool, ["-dc", archive.path], stdoutFile: folder.appending(path: name))
                return
            }
        }
        try await Shell.run(Shell.tar, ["--passphrase", noPassword, "-xf", archive.path, "-C", folder.path])
    }

    private static func sevenZipExtract(_ archive: URL, into folder: URL, with sevenZip: URL) async throws {
        try await Shell.run(sevenZip, ["x", "-y", "-bd", "-p" + noPassword, "-o" + folder.path, archive.path])
    }

    /// "name.7z.001", "name.zip.001", "name.part1.rar", or a RAR with "name.r00" beside it.
    static func isSplit(_ archive: URL) -> Bool {
        let name = archive.lastPathComponent.lowercased()
        if name.range(of: #"\.(7z|zip|rar)\.\d{3}$"#, options: .regularExpression) != nil { return true }
        if name.range(of: #"\.part\d+\.rar$"#, options: .regularExpression) != nil { return true }
        if name.hasSuffix(".rar") {
            let base = archive.deletingPathExtension()
            return FileManager.default.fileExists(atPath: base.appendingPathExtension("r00").path)
        }
        return false
    }

    private static func clear(_ folder: URL) throws {
        for item in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
            try FileManager.default.removeItem(at: item)
        }
    }

    static let quarantine = "com.apple.quarantine"

    /// Gives everything inside `folder` the quarantine `archive` has, if any.
    static func propagateQuarantine(from archive: URL, to folder: URL) {
        guard let value = extendedAttribute(quarantine, of: archive) else { return }
        let items = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil, options: [])
        while let item = items?.nextObject() as? URL {
            setExtendedAttribute(quarantine, value, on: item)
        }
    }

    /// Carries `source`'s quarantine onto `target` (an archive made from it).
    static func copyQuarantine(from source: URL, to target: URL) {
        if let value = extendedAttribute(quarantine, of: source) { setExtendedAttribute(quarantine, value, on: target) }
    }

    static func extendedAttribute(_ name: String, of url: URL) -> Data? {
        url.withUnsafeFileSystemRepresentation { path -> Data? in
            guard let path else { return nil }
            let length = getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
            guard length > 0 else { return nil }
            var data = Data(count: length)
            let read = data.withUnsafeMutableBytes { getxattr(path, name, $0.baseAddress, length, 0, XATTR_NOFOLLOW) }
            return read == length ? data : nil
        }
    }

    static func setExtendedAttribute(_ name: String, _ value: Data, on url: URL) {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return }
            _ = value.withUnsafeBytes { setxattr(path, name, $0.baseAddress, value.count, 0, XATTR_NOFOLLOW) }
        }
    }

    /// The meaningful top-level items an extraction produced (no `__MACOSX` resource-fork folders).
    static func topLevelItems(in folder: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { !["__MACOSX", ".DS_Store"].contains($0.lastPathComponent) }
    }

    /// Zips a folder's *contents* (Office files, ODS). `first`, if given, goes in first and uncompressed (EPUB/ODF `mimetype`).
    static func zipContents(of folder: URL, to output: URL, storedFirst first: String? = nil) async throws {
        if let first {
            try await Shell.run(Shell.zip, ["-X", "-0", "-q", output.path, first], in: folder)
        }
        let items = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0 != first && $0 != ".DS_Store" }
            .sorted()
        // -nw: names like "[Content_Types].xml" are literal, not wildcard patterns.
        try await Shell.run(Shell.zip, ["-X", "-9", "-r", "-q", "-nw", output.path] + items, in: folder)
    }

    /// Unzips into `folder` (Office files, EPUBs).
    static func unzip(_ file: URL, into folder: URL) async throws {
        try await Shell.run(Shell.ditto, ["-x", "-k", file.path, folder.path])
    }
}
