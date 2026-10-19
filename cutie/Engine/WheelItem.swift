import Foundation

/// One slice of a wheel.
nonisolated struct WheelItem: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case convert(Format)
        case tool(Tool)
        case action(FileAction)
    }

    let kind: Kind

    var id: String {
        switch kind {
        case .convert(let format): "convert." + format.rawValue
        case .tool(let tool): "tool." + tool.rawValue
        case .action(let action): "action." + action.rawValue
        }
    }

    var title: String {
        switch kind {
        case .convert(let format): format.title
        case .tool(let tool): tool.title
        case .action(let action): action.title
        }
    }

    var symbol: String {
        switch kind {
        case .convert(let format): format.symbol
        case .tool(let tool): tool.symbol
        case .action(let action): action.symbol
        }
    }

    static func convert(_ format: Format) -> WheelItem { WheelItem(kind: .convert(format)) }
    static func tool(_ tool: Tool) -> WheelItem { WheelItem(kind: .tool(tool)) }
    static func action(_ action: FileAction) -> WheelItem { WheelItem(kind: .action(action)) }
}
