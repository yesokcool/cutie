import AppKit

/// Hosts SwiftUI content and makes the whole surface a drag source for files
/// (a finished result, a Float), plus a click action. SwiftUI keeps the clicks
/// that land in `passThrough` (the close button).
final class FileDragView: NSView, NSDraggingSource {
    var files: () -> [URL] = { [] }
    var onClick: () -> Void = {}
    var onDragEnded: (NSDragOperation) -> Void = { _ in }
    var onHover: (Bool) -> Void = { _ in }
    /// Rects (in this view's coordinates, y up) where clicks go to the SwiftUI content.
    var passThrough: () -> [NSRect] = { [] }
    /// Files dropped onto this view (Float collects them). Nil = not a drop target.
    var onFilesDropped: (([URL]) -> Void)? {
        didSet { onFilesDropped == nil ? unregisterDraggedTypes() : registerForDraggedTypes([.fileURL]) }
    }

    private let content: NSView
    private var mouseDownEvent: NSEvent?

    init(content: NSView) {
        self.content = content
        super.init(frame: .zero)
        content.autoresizingMask = [.width, .height]
        addSubview(content)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard frame.contains(point) else { return nil }
        let local = convert(point, from: superview)
        if passThrough().contains(where: { $0.contains(local) }) {
            return content.hitTest(convert(local, to: content.superview)) ?? content
        }
        return self
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onHover(true) }
    override func mouseExited(with event: NSEvent) { onHover(false) }

    override func mouseDown(with event: NSEvent) { mouseDownEvent = event }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownEvent else { return }
        let distance = hypot(event.locationInWindow.x - start.locationInWindow.x, event.locationInWindow.y - start.locationInWindow.y)
        guard distance > 3 else { return }
        mouseDownEvent = nil
        let urls = files()
        guard !urls.isEmpty else { return }
        let items = urls.enumerated().map { index, url in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            let point = convert(start.locationInWindow, from: nil)
            item.setDraggingFrame(NSRect(x: point.x - 24 + CGFloat(index * 4), y: point.y - 24 - CGFloat(index * 4), width: 48, height: 48), contents: icon)
            return item
        }
        beginDraggingSession(with: items, event: start, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        if mouseDownEvent != nil { onClick() }
        mouseDownEvent = nil
    }

    // MARK: NSDraggingSource

    /// Like dragging from Finder: Finder moves on the same disk and copies across disks.
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .move, .generic, .link] : [.copy, .generic]
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        onDragEnded(operation)
    }

    // MARK: Drop target

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        (sender.draggingSource as? FileDragView) === self ? [] : .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty, let onFilesDropped else { return false }
        onFilesDropped(urls)
        return true
    }
}
