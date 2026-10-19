import AppKit

/// The wheel's event surface. It is the drop target (the drag in progress
/// lands here), turns the pointer's position into a highlighted slice, and in
/// keyboard mode takes arrows, Return, Escape, clicks and modifier taps.
/// SwiftUI only draws: every event stops at this view.
final class WheelDropView: NSView {
    var geometry = WheelGeometry(count: 0) {
        didSet { needsDisplay = true }
    }
    var onHover: (Int?) -> Void = { _ in }
    var onDrop: ([URL]) -> Bool = { _ in false }
    var onChoose: () -> Void = {}
    var onStep: (Int) -> Void = { _ in }
    var onCancel: () -> Void = {}
    var onModifierPressed: (NSEvent.ModifierFlags) -> Void = { _ in }
    private var lastFlags: NSEvent.ModifierFlags = []

    init(content: NSView) {
        super.init(frame: .zero)
        registerForDraggedTypes([.fileURL])
        content.autoresizingMask = [.width, .height]
        addSubview(content)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    /// Liquid Glass is composited by the window server, so the panel's own
    /// pixels stay see-through under it, and macOS hands a drag (or click) over
    /// see-through pixels to the window below: only the labels caught the file.
    /// A barely-there fill over the whole wheel and switcher makes all of it a target.
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.02).setFill()
        let side = geometry.wheelSide
        NSBezierPath(ovalIn: NSRect(x: bounds.midX - side / 2, y: bounds.maxY - side, width: side, height: side)).fill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: bounds.width, height: WheelGeometry.footerHeight)).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    /// The ring's center: the wheel's square sits at the top, the switcher below.
    var wheelCenter: CGPoint {
        CGPoint(x: bounds.midX, y: bounds.maxY - geometry.wheelSide / 2)
    }

    func slice(at point: NSPoint) -> Int? {
        guard point.y >= bounds.maxY - geometry.wheelSide else { return nil } // the switcher
        return geometry.index(at: CGVector(dx: point.x - wheelCenter.x, dy: point.y - wheelCenter.y))
    }

    // MARK: Drag destination

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let index = slice(at: convert(sender.draggingLocation, from: nil))
        onHover(index)
        return index == nil ? [] : operation(for: sender.draggingSourceOperationMask)
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        onHover(nil)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        onHover(slice(at: convert(sender.draggingLocation, from: nil)))
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return !urls.isEmpty && onDrop(urls)
    }

    /// Never answer "move": the source (Finder) must leave its files alone.
    /// ⌘ during a drag limits the source to "generic", ⌃ to "link"; both are fine.
    private func operation(for mask: NSDragOperation) -> NSDragOperation {
        for candidate in [NSDragOperation.copy, .generic, .link] where mask.contains(candidate) {
            return candidate
        }
        return .copy
    }

    // MARK: Keyboard mode

    override func mouseMoved(with event: NSEvent) {
        guard window?.isKeyWindow == true else { return }
        if let index = slice(at: convert(event.locationInWindow, from: nil)) { onHover(index) }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let index = slice(at: point) {
            onHover(index)
            onChoose()
        } else if hypot(point.x - wheelCenter.x, point.y - wheelCenter.y) < geometry.innerRadius {
            onCancel()
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123, 126: onStep(-1)          // ← ↑
        case 124, 125: onStep(1)           // → ↓
        case 36, 76, 49: onChoose()        // Return, Enter, Space
        case 53: onCancel()                // Escape
        default: super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) { onCancel() }

    override func flagsChanged(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.shift, .command, .control, .option])
        let pressed = flags.subtracting(lastFlags)
        lastFlags = flags
        if !pressed.isEmpty { onModifierPressed(pressed) }
    }
}
