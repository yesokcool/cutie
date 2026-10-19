import Foundation

/// ZIP, TAR and GZIP through macOS's own bsdtar (libarchive), which also
/// reads RAR and 7z. Office files and EPUBs are zipped here too.
nonisolated enum ArchiveConverter {
    /// Archives `items` (files or folders) into one file. Items keep their names at the archive's root.
    static func archive(_ items: [URL], as format: Format, to output: URL) async throws {
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
    static func extract(_ archive: URL, into folder: URL) async throws {
        let ext = FileKind.fileExtension(of: archive)
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
        try await Shell.run(Shell.tar, ["-xf", archive.path, "-C", folder.path])
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
