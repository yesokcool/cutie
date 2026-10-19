import Foundation

/// A job's private scratch folder, removed when the job ends.
nonisolated struct Scratch: Sendable {
    let url: URL

    init() throws {
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
