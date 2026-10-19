import AppKit

/// The Actions wheel. These touch the clipboard, windows and other apps, so
/// they run on the main thread right away.
final class ActionRunner {
    let jobs: JobCenter
    let floats: FloatController

    init(jobs: JobCenter, floats: FloatController) {
        self.jobs = jobs
        self.floats = floats
    }

    func perform(_ action: FileAction, on files: [URL], at point: NSPoint) {
        switch action {
        case .airDrop:
            guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: files) else {
                jobs.show("AirDrop isn't available", symbol: action.symbol, at: point)
                return
            }
            NSApp.activate()
            service.perform(withItems: files)
        case .float:
            floats.show(files, at: point)
        case .copy:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects(files as [NSURL])
            jobs.show(files.count == 1 ? "Copied — paste it anywhere" : "Copied \(files.count) files", symbol: action.symbol, at: point)
        case .copyPath:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(files.map(\.path).joined(separator: "\n"), forType: .string)
            jobs.show(files.count == 1 ? "Path copied" : "\(files.count) paths copied", symbol: action.symbol, at: point)
        case .move:
            move(files, at: point)
        case .terminal:
            openTerminal(at: files[0])
        }
    }

    private func move(_ files: [URL], at point: NSPoint) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Move Here"
        panel.message = files.count == 1 ? "Move \(files[0].lastPathComponent) to…" : "Move \(files.count) items to…"
        if let last = UserDefaults.standard.url(forKey: Preferences.Key.lastMoveFolder) { panel.directoryURL = last }
        NSApp.activate()
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        UserDefaults.standard.set(folder, forKey: Preferences.Key.lastMoveFolder)

        var moved = 0
        var problem: String?
        for file in files where file.deletingLastPathComponent().standardizedFileURL != folder.standardizedFileURL {
            do {
                try FileManager.default.moveItem(at: file, to: Output.unique(file.lastPathComponent, in: folder))
                moved += 1
            } catch {
                problem = problem ?? error.localizedDescription
            }
        }
        if let problem {
            jobs.show(problem, symbol: "exclamationmark.triangle", at: point)
        } else {
            jobs.show("Moved \(moved == 1 ? "1 item" : "\(moved) items") to \(folder.lastPathComponent)", symbol: "folder", at: point)
        }
    }

    /// A Terminal window in the folder (or the file's folder).
    private func openTerminal(at item: URL) {
        var isFolder: ObjCBool = false
        FileManager.default.fileExists(atPath: item.path, isDirectory: &isFolder)
        let folder = isFolder.boolValue ? item : item.deletingLastPathComponent()
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        NSWorkspace.shared.open([folder], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }
}
