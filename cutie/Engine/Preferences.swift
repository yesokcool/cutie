import AppKit

/// Every persisted setting. All of them are plain UserDefaults values (the
/// app's only persisted surface); Settings binds to the same keys with
/// @AppStorage. Never rename a key: that silently resets the setting.
nonisolated enum Preferences {
    enum Key {
        static let convertKey = "convertKey"
        static let toolsKey = "toolsKey"
        static let actionsKey = "actionsKey"
        static let saveLocation = "saveLocation"
        static let imageQuality = "imageQuality"
        static let paused = "paused"
        static let hasSeenWelcome = "hasSeenWelcome"
        static let lastMoveFolder = "lastMoveFolder"
        static let finderShortcut = "finderShortcut"
    }

    static let defaultKeys: [Wheel: TriggerKey] = [.convert: .shift, .tools: .command, .actions: .control]

    static func key(for wheel: Wheel, in defaults: UserDefaults = .standard) -> TriggerKey {
        let name = switch wheel {
        case .convert: Key.convertKey
        case .tools: Key.toolsKey
        case .actions: Key.actionsKey
        }
        return defaults.string(forKey: name).flatMap(TriggerKey.init(rawValue:)) ?? defaultKeys[wheel]!
    }

    static func storageKey(for wheel: Wheel) -> String {
        switch wheel {
        case .convert: Key.convertKey
        case .tools: Key.toolsKey
        case .actions: Key.actionsKey
        }
    }

    /// The wheel a newly pressed modifier opens, if exactly one wheel's key was pressed.
    static func wheel(forPressed flags: NSEvent.ModifierFlags, in defaults: UserDefaults = .standard) -> Wheel? {
        Wheel.allCases.first { wheel in
            guard let flag = key(for: wheel, in: defaults).flag else { return false }
            return flags.contains(flag)
        }
    }

    static func saveLocation(in defaults: UserDefaults = .standard) -> SaveLocation {
        defaults.string(forKey: Key.saveLocation).flatMap(SaveLocation.init(rawValue:)) ?? .nextToOriginal
    }

    /// JPEG/HEIC/AVIF quality, 0.5–1.
    static func imageQuality(in defaults: UserDefaults = .standard) -> Double {
        let value = defaults.object(forKey: Key.imageQuality) as? Double ?? 0.85
        return min(max(value, 0.5), 1)
    }
}
