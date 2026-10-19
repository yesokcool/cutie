import AppKit

/// Pages, Keynote and Numbers, driven by AppleScript (through `osascript`, so
/// the main thread never waits). Only offered when the app is installed; the
/// first use asks for permission to control it. Apps Cutie had to launch are
/// quit again afterwards.
nonisolated enum IWork {
    enum App: String, Sendable {
        case pages = "Pages", keynote = "Keynote", numbers = "Numbers"

        var bundleID: String {
            switch self {
            case .pages: "com.apple.iWork.Pages"
            case .keynote: "com.apple.iWork.Keynote"
            case .numbers: "com.apple.iWork.Numbers"
            }
        }
    }

    /// Opens `input` in `app` and saves or exports it as `format` at `output`.
    /// Keynote's JPG/PNG export writes a folder of slide images at `output`.
    static func export(_ input: URL, with app: App, to format: Format, at output: URL, toolbox: Toolbox) async throws {
        let installed = switch app {
        case .pages: toolbox.pages
        case .keynote: toolbox.keynote
        case .numbers: toolbox.numbers
        }
        guard installed != nil else { throw CutieError("This needs \(app.rawValue).") }
        guard let command = exportCommand(app: app, format: format) else {
            throw CutieError("\(app.rawValue) can't make \(format.title) files.")
        }
        let wasRunning = await MainActor.run {
            !NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).isEmpty
        }
        let script = """
        on run argv
            set inputFile to POSIX file (item 1 of argv)
            set outputFile to POSIX file (item 2 of argv)
            tell application "\(app.rawValue)"
                set theDocument to open inputFile
                try
                    \(command)
                on error message
                    close theDocument saving no
                    error message
                end try
                close theDocument saving no
                if (item 3 of argv) is "quit" then quit
            end tell
        end run
        """
        do {
            try await Shell.run(Shell.osascript, ["-e", script, input.path, output.path, wasRunning ? "stay" : "quit"])
        } catch let failure as Shell.Failure where failure.output.contains("-1743") {
            throw CutieError("Cutie isn't allowed to control \(app.rawValue). Turn it on in System Settings ▸ Privacy & Security ▸ Automation.")
        }
        guard FileManager.default.fileExists(atPath: output.path) else {
            throw CutieError("\(app.rawValue) didn't save the file.")
        }
    }

    /// The AppleScript line that writes `format` (`theDocument` → `outputFile`).
    static func exportCommand(app: App, format: Format) -> String? {
        switch (app, format) {
        case (.pages, .pages), (.keynote, .key), (.numbers, .numbers):
            "save theDocument in outputFile"
        case (_, .pdf):
            "export theDocument to outputFile as PDF"
        case (.pages, .docx):
            "export theDocument to outputFile as Microsoft Word"
        case (.pages, .epub):
            "export theDocument to outputFile as EPUB"
        case (.pages, .txt):
            "export theDocument to outputFile as unformatted text"
        case (.pages, .rtf):
            "export theDocument to outputFile as formatted text"
        case (.keynote, .pptx):
            "export theDocument to outputFile as Microsoft PowerPoint"
        case (.keynote, .png):
            "export theDocument to outputFile as slide images with properties {image format:PNG}"
        case (.keynote, .jpg):
            "export theDocument to outputFile as slide images with properties {image format:JPEG}"
        case (.numbers, .xlsx):
            "export theDocument to outputFile as Microsoft Excel"
        case (.numbers, .csv):
            "export theDocument to outputFile as CSV"
        default:
            nil
        }
    }
}
