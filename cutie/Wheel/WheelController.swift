import AppKit
import os
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
    /// When the current wheel appeared: a repeat of its key right after (a
    /// keyboard or driver bounce) mustn't close it straight away.
    private var shownAt = Date.distantPast
    static let log = Logger(subsystem: AppIdentity.bundleID, category: "wheel")

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
        guard wheel == model.wheel else { return show(wheel) }
        guard Date().timeIntervalSince(shownAt) > 0.35 else {
            Self.log.notice("Repeat of the open wheel's key ignored")
            return
        }
        close(because: "its key was tapped again")
    }

    func close(because reason: StaticString = "closed") {
        guard let panel, panel.isVisible else { return }
        Self.log.notice("Wheel closed: \(reason)")
        model.highlighted = nil
        model.appeared = false
        panel.orderOut(nil)
        if model.keyboard, let previousApp {
            previousApp.activate()
        }
        previousApp = nil
    }

    private func show(_ wheel: Wheel) {
        shownAt = Date()
        Self.log.notice("Wheel shown: \(String(describing: wheel))")
        model.wheel = wheel
        model.items = Catalog.items(for: model.inputs, wheel: wheel, toolbox: toolbox())
        model.highlighted = model.keyboard && !model.items.isEmpty ? 0 : nil
        layout()
    }

    private func choose() {
        guard let item = model.highlightedItem else { return }
        let inputs = model.inputs
        close(because: "a slice was chosen")
        onChoose(item, inputs, anchor)
    }

    // MARK: Panel

    private func makePanel() -> WheelPanel {
        if let panel { return panel }
        let hosting = NSHostingView(rootView: WheelView(model: model))
        hosting.sizingOptions = []
        let dropView = WheelDropView(content: hosting)
        // Called at every pointer move; Observation redraws on every set, so only set changes.
        dropView.onHover = { [weak self] index in
            guard let self, self.model.highlighted != index else { return }
            self.model.highlighted = index
        }
        dropView.onDrop = { [weak self] urls in
            guard let self, self.model.highlightedItem != nil else { return false }
            self.model.inputs = urls
            DispatchQueue.main.async { self.choose() }
            return true
        }
        dropView.onChoose = { [weak self] in self?.choose() }
        dropView.onCancel = { [weak self] in self?.close(because: "cancelled") }
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
                self.close(because: "another window took focus")
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
