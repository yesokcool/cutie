import SwiftUI

/// The menu under the orange in the menu bar.
struct MenuBarMenu: View {
    @Bindable var core: CutieCore
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Convert Files…") { core.chooseFiles() }
            .keyboardShortcut("o")
        Button("Convert Finder Selection") { core.convertFinderSelection() }
            .keyboardShortcut("c", modifiers: [.control, .option])
        Divider()
        Toggle("Pause Cutie", isOn: $core.paused)
        Divider()
        Button("How Cutie Works") {
            NSApp.activate()
            openWindow(id: WelcomeView.windowID)
        }
        Button("Settings…") {
            NSApp.activate()
            openSettings()
        }
        .keyboardShortcut(",")
        Divider()
        Button("Quit \(AppIdentity.displayName)") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
