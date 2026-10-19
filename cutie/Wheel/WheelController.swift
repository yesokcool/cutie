import AppKit
import SwiftUI

/// Opens, switches and closes the wheel, and hands the chosen slice on.
final class WheelController {
    let model = WheelModel()
    /// A slice was chosen: what, for which files, and where on screen (the wheel's center).
    var onChoose: (WheelItem, [URL], NSPoint) -> Void = { _, _, _ in }
    var toolbox: () -> Toolbox = { .none }

    private var panel: WheelPanel?
    private var dropView: WheelDropView?
    /// The wheel's center on screen; it stays put while switching wheels.
    private var anchor: NSPoint = .zero
    /// In keyboard mode Cutie takes focus; this app gets it back when the wheel closes.
    private var previousApp: NSRunningApplication?
    private var resignObserver: NSObjectProtocol?

    var isOpen: Bool { panel?.isVisible == true }

    func open(_ wheel: Wheel, inputs: [URL], at point: NSPoint, keyboard: Bool) {
        model.inputs = inputs
        model.keyboard = keyboard
        model.keys = Dictionary(uniqueKeysWithValues: Wheel.allCases.map { ($0, Preferences.key(for: $0)) })
        anchor = point
        let panel = makePanel()
        panel.allowsKey = keyboard
        show(wheel)
        model.appeared = false
        panel.orderFrontRegardless()
        if keyboard {
            let frontmost = NSWorkspace.shared.frontmostApplication
            previousApp = frontmost == .current ? nil : frontmost
            NSApp.activate()
            panel.makeKey()
            panel.makeFirstResponder(dropView)
        }
        DispatchQueue.main.async { self.model.appeared = true }
    }

    /// Another wheel's key: switch. The open wheel's own key again: close (a way to cancel mid-drag).
    func pressed(_ wheel: Wheel) {
        if wheel == model.wheel { close() } else { show(wheel) }
    }

    func close() {
        guard let panel, panel.isVisible else { return }
        model.highlighted = nil
        model.appeared = false
        panel.orderOut(nil)
        if model.keyboard, let previousApp {
            previousApp.activate()
        }
        previousApp = nil
    }

    private func show(_ wheel: Wheel) {
        model.wheel = wheel
        model.items = Catalog.items(for: model.inputs, wheel: wheel, toolbox: toolbox())
        model.highlighted = model.keyboard && !model.items.isEmpty ? 0 : nil
        layout()
    }

    private func choose() {
        guard let item = model.highlightedItem else { return }
        let inputs = model.inputs
        close()
        onChoose(item, inputs, anchor)
    }

    // MARK: Panel

    private func makePanel() -> WheelPanel {
        if let panel { return panel }
        let hosting = NSHostingView(rootView: WheelView(model: model))
        hosting.sizingOptions = []
        let dropView = WheelDropView(content: hosting)
        dropView.onHover = { [weak self] index in self?.model.highlighted = index }
        dropView.onDrop = { [weak self] urls in
            guard let self, self.model.highlightedItem != nil else { return false }
            self.model.inputs = urls
            DispatchQueue.main.async { self.choose() }
            return true
        }
        dropView.onChoose = { [weak self] in self?.choose() }
        dropView.onCancel = { [weak self] in self?.close() }
        dropView.onStep = { [weak self] step in
            guard let self, !self.model.items.isEmpty else { return }
            let count = self.model.items.count
            self.model.highlighted = ((self.model.highlighted ?? -step) + step + count) % count
        }
        dropView.onModifierPressed = { [weak self] flags in
            if let wheel = Preferences.wheel(forPressed: flags) { self?.show(wheel) }
        }
        let panel = WheelPanel()
        panel.contentView = dropView
        // Keyboard mode: clicking anywhere else dismisses the wheel.
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.model.keyboard else { return }
                self.close()
            }
        }
        self.panel = panel
        self.dropView = dropView
        return panel
    }

    /// Sizes the panel for the current slice count with the ring centered on
    /// `anchor`, nudged to stay on screen.
    private func layout() {
        guard let panel, let dropView else { return }
        let geometry = model.geometry
        dropView.geometry = geometry
        let size = geometry.panelSize
        let half = geometry.wheelSide / 2
        var origin = NSPoint(x: anchor.x - size.width / 2, y: anchor.y - (size.height - half))
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(anchor, $0.frame, false) }) ?? NSScreen.main {
            let visible = screen.visibleFrame
            origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
            origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        }
        anchor = NSPoint(x: origin.x + size.width / 2, y: origin.y + size.height - half)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }
}
