import Foundation

/// Everything a running conversion or tool needs.
nonisolated struct JobContext: Sendable {
    var toolbox: Toolbox
    var output: Output
    var imageQuality: Double
    /// 0…1 for the current file.
    var progress: @Sendable (Double) -> Void = { _ in }

    static func current(toolbox: Toolbox, progress: @escaping @Sendable (Double) -> Void = { _ in }) -> JobContext {
        JobContext(
            toolbox: toolbox,
            output: Output(location: Preferences.saveLocation()),
            imageQuality: Preferences.imageQuality(),
            progress: progress
        )
    }
}
