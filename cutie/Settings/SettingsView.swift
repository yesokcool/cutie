import ServiceManagement
import SwiftUI

/// Settings (⌘,): the wheels' keys, where results go, and which helpers this Mac has.
struct SettingsView: View {
    @Bindable var core: CutieCore

    @AppStorage(Preferences.Key.convertKey) private var convertKey = TriggerKey.shift
    @AppStorage(Preferences.Key.toolsKey) private var toolsKey = TriggerKey.command
    @AppStorage(Preferences.Key.actionsKey) private var actionsKey = TriggerKey.control
    @AppStorage(Preferences.Key.saveLocation) private var saveLocation = SaveLocation.nextToOriginal
    @AppStorage(Preferences.Key.imageQuality) private var imageQuality = 0.85
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                keyPicker("Convert", for: .convert)
                keyPicker("Tools", for: .tools)
                keyPicker("Actions", for: .actions)
            } header: {
                Text("Wheels")
            } footer: {
                Text("While dragging a file, tap a key to open its wheel; tap it again to close. Choosing a key another wheel uses swaps them.")
                    .foregroundStyle(.secondary)
            }

            Section("Results") {
                Picker("Save", selection: $saveLocation) {
                    ForEach(SaveLocation.allCases, id: \.self) { Text($0.name).tag($0) }
                }
                LabeledContent("JPG, HEIC and AVIF quality") {
                    HStack {
                        Slider(value: $imageQuality, in: 0.5...1, step: 0.05)
                            .frame(width: 160)
                        Text(imageQuality, format: .percent.precision(.fractionLength(0)))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                }
            }

            Section("General") {
                Toggle("\(FinderHotKey.display) opens the wheel for Finder's selection", isOn: $core.finderShortcut)
                Toggle("Open at login", isOn: $openAtLogin)
                    .onChange(of: openAtLogin) { _, enabled in setOpenAtLogin(enabled) }
                if let loginError {
                    Text(loginError).font(.callout).foregroundStyle(.orange)
                }
                Toggle("Pause Cutie", isOn: $core.paused)
            }

            if core.updater.isAvailable {
                Section {
                    Toggle("Check for updates automatically", isOn: Binding(
                        get: { core.updater.automaticChecks },
                        set: { core.updater.automaticChecks = $0 }
                    ))
                    LabeledContent("Version \(Self.version)") {
                        Button("Check Now") { core.updater.checkForUpdates() }
                    }
                } header: {
                    Text("Updates")
                } footer: {
                    Text("Off unless you turn it on. When on, Cutie asks GitHub once a day whether there's a newer version; nothing else leaves this Mac.")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                HelperRow(name: "ffmpeg", unlocks: "MP3, OGG, Opus, WMA, MKV, WebM, AVI and WMV",
                          found: core.toolbox.ffmpeg != nil, install: "brew install ffmpeg")
                HelperRow(name: "cwebp", unlocks: "WebP images, animated ones too",
                          found: core.toolbox.cwebp != nil, install: "brew install webp")
                HelperRow(name: "Ghostscript", unlocks: "Smaller compressed PDFs",
                          found: core.toolbox.ghostscript != nil, install: "brew install ghostscript")
                HelperRow(name: "7-Zip", unlocks: "Split archives, and RAR and 7z beyond what macOS opens",
                          found: core.toolbox.sevenZip != nil, install: "brew install sevenzip")
                HelperRow(name: "Pages", unlocks: "Pages documents", found: core.toolbox.pages != nil)
                HelperRow(name: "Keynote", unlocks: "Keynote and PowerPoint slides", found: core.toolbox.keynote != nil)
                HelperRow(name: "Numbers", unlocks: "Numbers and XLS spreadsheets", found: core.toolbox.numbers != nil)
                HelperRow(name: "LibreOffice", unlocks: "Word, Excel and PowerPoint with real layout and formulas",
                          found: core.toolbox.soffice != nil, install: "brew install --cask libreoffice")
                HelperRow(name: "pandoc", unlocks: "Headings, tables and footnotes in Word, Markdown and EPUB",
                          found: core.toolbox.pandoc != nil, install: "brew install pandoc")
            } header: {
                Text("Helpers")
            } footer: {
                Text("Everything else works on its own. Files never leave this Mac.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 540)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { core.refreshToolbox() }
    }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    private func keyPicker(_ title: String, for wheel: Wheel) -> some View {
        Picker(title, selection: binding(for: wheel)) {
            ForEach(TriggerKey.allCases, id: \.self) { key in
                Text(key == .off ? "Off" : "\(key.glyph)  \(key.name)").tag(key)
            }
        }
    }

    private func binding(for wheel: Wheel) -> Binding<TriggerKey> {
        Binding {
            switch wheel {
            case .convert: convertKey
            case .tools: toolsKey
            case .actions: actionsKey
            }
        } set: { newKey in
            let oldKey = binding(for: wheel).wrappedValue
            if newKey != .off {
                // Swap with whichever wheel had this key.
                if wheel != .convert, convertKey == newKey { convertKey = oldKey }
                if wheel != .tools, toolsKey == newKey { toolsKey = oldKey }
                if wheel != .actions, actionsKey == newKey { actionsKey = oldKey }
            }
            switch wheel {
            case .convert: convertKey = newKey
            case .tools: toolsKey = newKey
            case .actions: actionsKey = newKey
            }
        }
    }

    private func setOpenAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = error.localizedDescription
        }
    }
}
