import AVFoundation
import AppKit
import Observation

/// The running app: watches drags, opens wheels, runs what's chosen.
@Observable
final class CutieCore {
    static let shared = CutieCore()

    private(set) var toolbox = Toolbox.none
    var paused = UserDefaults.standard.bool(forKey: Preferences.Key.paused) {
        didSet {
            UserDefaults.standard.set(paused, forKey: Preferences.Key.paused)
            monitor.isEnabled = !paused
            if paused { wheel.close() }
        }
    }
    var finderShortcut = UserDefaults.standard.object(forKey: Preferences.Key.finderShortcut) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(finderShortcut, forKey: Preferences.Key.finderShortcut)
            finderShortcut ? hotKey.register() : hotKey.unregister()
        }
    }

    @ObservationIgnored let monitor = DragMonitor()
    @ObservationIgnored let wheel = WheelController()
    @ObservationIgnored let jobs = JobCenter()
    @ObservationIgnored let floats = FloatController()
    @ObservationIgnored let trimmer = TrimController()
    @ObservationIgnored let hotKey = FinderHotKey()
    @ObservationIgnored private lazy var actions = ActionRunner(jobs: jobs, floats: floats)
    @ObservationIgnored private var started = false

    func start() {
        guard !started else { return }
        started = true
        refreshToolbox()
        wheel.toolbox = { [unowned self] in toolbox }
        jobs.toolbox = { [unowned self] in toolbox }
        wheel.onChoose = { [unowned self] item, files, point in run(item, on: files, at: point) }
        trimmer.onTrim = { [unowned self] url, range, point in trim(url, range: range, at: point) }

        monitor.isEnabled = !paused
        monitor.onPress = { [unowned self] wheelKind, files in
            if self.wheel.isOpen {
                self.wheel.pressed(wheelKind)
            } else {
                self.wheel.open(wheelKind, inputs: files, at: NSEvent.mouseLocation, keyboard: false)
            }
        }
        monitor.onDragEnded = { [unowned self] in
            // A drop on the wheel closes it itself; a drop anywhere else leaves it open.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                if self.wheel.isOpen && !self.wheel.model.keyboard { self.wheel.close() }
            }
        }
        monitor.start()

        hotKey.onPress = { [unowned self] in convertFinderSelection() }
        if finderShortcut { hotKey.register() }
    }

    func refreshToolbox() {
        toolbox = Toolbox.detect()
    }

    // MARK: Entry points besides dragging

    /// Menu ▸ Convert Files…: pick files, then the wheel opens under the pointer.
    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.prompt = "Choose"
        NSApp.activate()
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        wheel.open(.convert, inputs: panel.urls, at: NSEvent.mouseLocation, keyboard: true)
    }

    /// ⌃⌥C: the wheel for whatever is selected in Finder.
    func convertFinderSelection() {
        let point = NSEvent.mouseLocation
        Task {
            do {
                let files = try await FinderHotKey.finderSelection()
                guard !files.isEmpty else {
                    jobs.show("Select files in Finder first", symbol: "cursorarrow.click", at: point)
                    return
                }
                wheel.open(.convert, inputs: files, at: point, keyboard: true)
            } catch {
                jobs.show(error.localizedDescription, symbol: "exclamationmark.triangle", at: point)
            }
        }
    }

    // MARK: Running a slice

    func run(_ item: WheelItem, on files: [URL], at point: NSPoint) {
        switch item.kind {
        case .action(let action):
            actions.perform(action, on: files, at: point)
        case .tool(.trimMedia):
            if let file = files.first { trimmer.open(file, at: point) }
        case .convert(let format):
            jobs.run(title: "Converting to \(format.title)", symbol: format.symbol, at: point) { context in
                try await Executor.run(item, inputs: files, context: context)
            }
        case .tool(let tool):
            jobs.run(title: tool.progressTitle, symbol: tool.symbol, at: point) { context in
                try await Executor.run(item, inputs: files, context: context)
            }
        }
    }

    /// The Trim window's OK: save the chosen range beside the original.
    private func trim(_ url: URL, range: CMTimeRange, at point: NSPoint) {
        jobs.run(title: Tool.trimMedia.progressTitle, symbol: Tool.trimMedia.symbol, at: point) { context in
            let scratch = try Scratch()
            defer { scratch.remove() }
            let (_, ext) = MediaTools.fileType(for: url)
            let target = scratch.file("\(Output.baseName(of: url))\(Tool.trimMedia.suffix).\(ext)")
            try await MediaTools.trim(url, range: range, to: target, context: context)
            return JobOutcome(files: [try context.output.place(target, named: target.lastPathComponent, beside: url)])
        }
    }
}
