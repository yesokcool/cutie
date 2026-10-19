import Foundation

/// A job's private scratch folder, removed when the job ends.
nonisolated struct Scratch: Sendable {
    let url: URL

    /// With `near`, the folder sits on the same disk as that folder (macOS's
    /// hidden temporary items there), so a big job from an external drive
    /// doesn't need room on the startup disk, and placing the result is an
    /// instant rename instead of a copy. Falls back to the usual temp folder.
    init(near directory: URL? = nil) throws {
        if let directory,
           let nearby = try? FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                     appropriateFor: directory, create: true) {
            url = nearby
            return
        }
        url = FileManager.default.temporaryDirectory.appending(path: "Cutie-" + UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func file(_ name: String) -> URL { url.appending(path: name) }

    func folder(_ name: String) throws -> URL {
        let folder = url.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    func remove() { try? FileManager.default.removeItem(at: url) }
}
