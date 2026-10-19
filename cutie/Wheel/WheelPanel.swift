import AppKit

/// A borderless, see-through panel that floats above everything (full-screen
/// apps included) without activating Cutie, so the drag in progress keeps going.
/// It takes key focus only in keyboard mode.
final class WheelPanel: NSPanel {
    var allowsKey = false

    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovable = false
        acceptsMouseMovedEvents = true
        animationBehavior = .none
    }
}
