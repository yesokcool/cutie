import ServiceManagement
import SwiftUI

/// A helper app or tool: what it adds, and whether this Mac has it.
struct HelperRow: View {
    let name: String
    let unlocks: String
    let found: Bool
    var install: String?
    @State private var copied = false

    var body: some View {
        LabeledContent {
            if found {
                Label("Installed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.tint)
            } else if let install {
                Button(copied ? "Copied" : "Copy “\(install)”") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(install, forType: .string)
                    copied = true
                }
            } else {
                Text("Not installed").foregroundStyle(.secondary)
            }
        } label: {
            Text(name)
            Text(unlocks)
        }
    }
}
