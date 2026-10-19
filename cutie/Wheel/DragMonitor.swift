import AppKit
import os

/// Notices when you're dragging files anywhere on the Mac and tap a wheel's key.
///
/// How, without Accessibility permission: a global *mouse-down* monitor (mouse
/// monitors need no permission) starts a 60 Hz poll that lasts only while the
/// button is held. The poll watches the system drag pasteboard: when its change
/// count moves, a drag began, and if it carries file URLs those are the files.
/// Modifier keys are read from `NSEvent.modifierFlags` (also permission-free).
/// Only a key pressed *after* the drag started counts, so a ⌘-drag in Finder
/// doesn't pop a wheel.
///
/// Some pointing devices report the button as up for a moment in the middle of
/// a drag (pen tablets lifting slightly, mice whose own software re-posts
/// clicks), so a release only counts once it lasts.
final class DragMonitor {
    var isEnabled = true
    /// A wheel's key went down mid-drag.
    var onPress: (Wheel, [URL]) -> Void = { _, _ in }
    /// The mouse button came up after a file drag.
    var onDragEnded: () -> Void = {}

    private var monitors: [Any] = []
    private var timer: Timer?
    private var changeCount = 0
    private var files: [URL]?
    private var flags: NSEvent.ModifierFlags = []
    /// When the button was first seen up; nil while it's held.
    private var releasedAt: Date?

    static let watchedFlags: NSEvent.ModifierFlags = [.shift, .command, .control, .option]
    /// How long the button must stay up before a file drag counts as over.
    static let releaseGrace: TimeInterval = 0.15
    static let log = Logger(subsystem: AppIdentity.bundleID, category: "drag")

    func start() {
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] _ in
            self?.mouseWentDown()
        }) {
            monitors.append(global)
        }
        // Drags that start in Cutie's own panels (a result, a Float).
        if let local = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] event in
            self?.mouseWentDown()
            return event
        }) {
            monitors.append(local)
        }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        stopPolling()
    }

    private func mouseWentDown() {
        guard isEnabled else { return }
        changeCount = NSPasteboard(name: .drag).changeCount
        files = nil
        releasedAt = nil
        flags = Self.currentFlags
        stopPolling()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func poll() {
        if NSEvent.pressedMouseButtons & 1 == 0 {
            let now = Date()
            let since = releasedAt ?? now
            releasedAt = since
            // A plain click ends at once; a file drag only once the release lasts.
            if files != nil, now.timeIntervalSince(since) < Self.releaseGrace { return }
            stopPolling()
            if files != nil {
                Self.log.notice("Drag ended")
                onDragEnded()
            }
            files = nil
            return
        }
        if let since = releasedAt {
            Self.log.notice("Button up for \(Date().timeIntervalSince(since), format: .fixed(precision: 3)) s mid-drag, ignored")
            releasedAt = nil
        }
        let pasteboard = NSPasteboard(name: .drag)
        if files == nil, pasteboard.changeCount != changeCount {
            changeCount = pasteboard.changeCount
            let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            if !urls.isEmpty {
                files = urls
                flags = Self.currentFlags
                Self.log.notice("Drag of \(urls.count) file(s) started")
            }
        }
        guard let files else { return }
        let now = Self.currentFlags
        let pressed = now.subtracting(flags)
        flags = now
        if !pressed.isEmpty, let wheel = Preferences.wheel(forPressed: pressed) {
            Self.log.notice("Key for \(String(describing: wheel)) pressed (flags \(now.rawValue))")
            onPress(wheel, files)
        }
    }

    private func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    static var currentFlags: NSEvent.ModifierFlags {
        NSEvent.modifierFlags.intersection(watchedFlags)
    }
}
