import Foundation

/// The Actions wheel: works on any file or folder, never converts anything.
nonisolated enum FileAction: String, CaseIterable, Sendable, Hashable {
    case airDrop, float, copy, move, copyPath, terminal

    var title: String {
        switch self {
        case .airDrop: "AirDrop"
        case .float: "Float"
        case .copy: "Copy"
        case .move: "Move"
        case .copyPath: "Copy Path"
        case .terminal: "Terminal"
        }
    }

    var symbol: String {
        switch self {
        case .airDrop: "dot.radiowaves.up.forward"
        case .float: "pin"
        case .copy: "doc.on.clipboard"
        case .move: "folder"
        case .copyPath: "link"
        case .terminal: "terminal"
        }
    }
}
