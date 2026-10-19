import Foundation

/// What a finished job hands back to the result pill.
nonisolated struct JobOutcome: Sendable, Equatable {
    var files: [URL] = []
    /// A line to show instead of (or under) the files: "1,204 words", "2.1 MB → 640 KB".
    var message: String?
    /// Text the pill copied to the clipboard (checksums), so it can say so.
    var copied: String?
    var failures: [String] = []
}
