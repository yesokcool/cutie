import SwiftUI

/// First launch (and Menu ▸ How Cutie Works): the whole app in three steps.
struct WelcomeView: View {
    static let windowID = "welcome"
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var sample = WheelModel.sample

    var body: some View {
        let convert = Preferences.key(for: .convert)
        let tools = Preferences.key(for: .tools)
        let actions = Preferences.key(for: .actions)

        VStack(spacing: 24) {
            WheelView(model: sample)
                .scaleEffect(0.78)
                .frame(width: sample.geometry.panelSize.width * 0.78,
                       height: sample.geometry.panelSize.height * 0.78)
                .allowsHitTesting(false)

            VStack(alignment: .leading, spacing: 14) {
                WelcomeStep(number: 1, text: "Drag any file — from Finder, the Desktop, anywhere.")
                WelcomeStep(number: 2, text: "While it's still in your hand, tap \(convert.glyph) for Convert, \(tools.glyph) for Tools or \(actions.glyph) for Actions.")
                WelcomeStep(number: 3, text: "Drop it on a slice. The result lands next to the original, which stays as it was.")
            }

            Text("No drag handy? Select files in Finder and press \(FinderHotKey.display). Cutie lives in the menu bar.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button {
                UserDefaults.standard.set(true, forKey: Preferences.Key.hasSeenWelcome)
                dismissWindow(id: Self.windowID)
            } label: {
                Text("Start").frame(minWidth: 120)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 36)
        .padding(.bottom, 32)
        .frame(width: 480)
        .background(.background)
    }
}
