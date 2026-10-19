import Foundation

/// Every identifier comes from the running bundle, so the Dev build
/// (bundle id + ".dev", "Cutie Dev") never collides with the real one.
nonisolated enum AppIdentity {
    static var bundleID: String { Bundle.main.bundleIdentifier ?? "com.example.cutie" }

    static var isDev: Bool { bundleID.hasSuffix(".dev") }

    static var displayName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Cutie"
    }

    /// The app is also the unit tests' host; it must stay quiet there (no
    /// drag watching, no welcome window).
    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }
}
