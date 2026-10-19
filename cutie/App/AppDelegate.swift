import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !AppIdentity.isRunningTests else { return }
        CutieCore.shared.start()
    }
}
