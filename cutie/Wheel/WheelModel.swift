import AppKit
import Observation

/// What the open wheel shows. Owned by `WheelController`; drawn by `WheelView`.
@Observable
final class WheelModel {
    var wheel: Wheel = .convert
    var items: [WheelItem] = []
    var inputs: [URL] = [] {
        didSet { icon = FileIcon.icon(for: inputs) }
    }
    /// The inputs' Finder icon, looked up once per set of files.
    private(set) var icon = NSImage()
    var highlighted: Int?
    /// Opened from the keyboard (menu or hotkey) rather than mid-drag: arrows and clicks choose.
    var keyboard = false
    var appeared = false
    /// The keys shown in the switcher under the ring.
    var keys: [Wheel: TriggerKey] = Preferences.defaultKeys

    var geometry: WheelGeometry { WheelGeometry(count: items.count) }

    var highlightedItem: WheelItem? {
        highlighted.flatMap { items.indices.contains($0) ? items[$0] : nil }
    }

    /// "photo.heic" or "3 files".
    var inputSummary: String {
        inputs.count == 1 ? inputs[0].lastPathComponent : "\(inputs.count) files"
    }
}
