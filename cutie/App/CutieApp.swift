import SwiftUI

@main
struct CutieApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarMenu(core: CutieCore.shared)
        } label: {
            Image(nsImage: Self.menuBarIcon)
                .accessibilityLabel(AppIdentity.displayName)
        }

        Settings {
            SettingsView(core: CutieCore.shared)
        }

        Window("Welcome to Cutie", id: WelcomeView.windowID) {
            WelcomeView()
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .defaultLaunchBehavior(Self.showsWelcome ? .presented : .suppressed)
    }

    /// The orange, as a template so the menu bar tints it.
    static let menuBarIcon: NSImage = {
        let image = NSImage(named: "MenuBarIcon")?.copy() as? NSImage ?? NSImage()
        image.size = NSSize(width: 17, height: 17)
        image.isTemplate = true
        return image
    }()

    static var showsWelcome: Bool {
        !AppIdentity.isRunningTests && !UserDefaults.standard.bool(forKey: Preferences.Key.hasSeenWelcome)
    }
}
