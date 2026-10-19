import AppKit

/// A modifier key that opens a wheel while you drag.
nonisolated enum TriggerKey: String, CaseIterable, Sendable, Hashable {
    case shift, command, control, option, off

    var flag: NSEvent.ModifierFlags? {
        switch self {
        case .shift: .shift
        case .command: .command
        case .control: .control
        case .option: .option
        case .off: nil
        }
    }

    var glyph: String {
        switch self {
        case .shift: "⇧"
        case .command: "⌘"
        case .control: "⌃"
        case .option: "⌥"
        case .off: ""
        }
    }

    var name: String {
        switch self {
        case .shift: "Shift"
        case .command: "Command"
        case .control: "Control"
        case .option: "Option"
        case .off: "Off"
        }
    }
}
