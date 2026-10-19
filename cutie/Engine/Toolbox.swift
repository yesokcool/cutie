import AppKit

/// The helpers this Mac has. Everything Cutie can do natively works without
/// them; each one only unlocks more formats. Detected at launch and whenever
/// Settings opens (so `brew install ffmpeg` shows up without a relaunch).
nonisolated struct Toolbox: Sendable, Equatable {
    var ffmpeg: URL?
    var ffprobe: URL?
    var cwebp: URL?
    var pages: URL?
    var keynote: URL?
    var numbers: URL?

    static let none = Toolbox()

    static let searchPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"]

    static func detect() -> Toolbox {
        func tool(_ name: String) -> URL? {
            for directory in searchPaths {
                let path = directory + "/" + name
                if FileManager.default.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
            }
            return nil
        }
        func app(_ bundleID: String) -> URL? {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        }
        return Toolbox(
            ffmpeg: tool("ffmpeg"),
            ffprobe: tool("ffprobe"),
            cwebp: tool("cwebp"),
            pages: app("com.apple.iWork.Pages"),
            keynote: app("com.apple.iWork.Keynote"),
            numbers: app("com.apple.iWork.Numbers")
        )
    }
}
