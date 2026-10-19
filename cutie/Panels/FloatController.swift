import AppKit
import Observation
import SwiftUI

final class FloatController {
    private var panels: [ObjectIdentifier: NSPanel] = [:]

    static let size = NSSize(width: 170, height: 150)

    func show(_ files: [URL], at point: NSPoint) {
        let model = FloatModel(files: files)
        let panel = WheelPanel()
        panel.level = .floating
        let key = ObjectIdentifier(panel)

        let hosting = NSHostingView(rootView: FloatView(model: model) { [weak self] in self?.close(key) })
        hosting.sizingOptions = []
        let surface = FileDragView(content: hosting)
        surface.files = { model.files }
        surface.onClick = { NSWorkspace.shared.activateFileViewerSelecting(model.files) }
        surface.onFilesDropped = { urls in
            model.files += urls.filter { !model.files.contains($0) }
        }
        surface.onDragEnded = { [weak self] _ in
            // Moved away (Finder moves on the same disk): forget what's gone.
            model.files.removeAll { !FileManager.default.fileExists(atPath: $0.path) }
            if model.files.isEmpty { self?.close(key) }
        }
        surface.passThrough = { [NSRect(x: 0, y: Self.size.height - 40, width: 40, height: 40)] }

        panel.contentView = surface
        var frame = NSRect(x: point.x - Self.size.width / 2, y: point.y - Self.size.height / 2, width: Self.size.width, height: Self.size.height)
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) ?? NSScreen.main {
            let visible = screen.visibleFrame.insetBy(dx: 8, dy: 8)
            frame.origin.x = min(max(frame.origin.x, visible.minX), visible.maxX - frame.width)
            frame.origin.y = min(max(frame.origin.y, visible.minY), visible.maxY - frame.height)
        }
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        panels[key] = panel
    }

    private func close(_ key: ObjectIdentifier) {
        panels.removeValue(forKey: key)?.orderOut(nil)
    }
}
