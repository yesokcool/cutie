import Foundation

/// The three wheels. Each opens from its own modifier key (Settings ▸ Keys).
nonisolated enum Wheel: String, CaseIterable, Sendable, Hashable {
    case convert, tools, actions

    var title: String {
        switch self {
        case .convert: "Convert"
        case .tools: "Tools"
        case .actions: "Actions"
        }
    }
}
