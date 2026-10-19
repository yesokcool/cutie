import SwiftUI
import UniformTypeIdentifiers

/// Finder's icon for a file, or the stacked icon for several.
struct FileIcon: View {
    let image: NSImage

    init(urls: [URL]) { image = Self.icon(for: urls) }

    /// An icon looked up once (the wheel redraws at every pointer move mid-drag;
    /// asking Finder for the icon each time made it lag).
    init(image: NSImage) { self.image = image }

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .accessibilityHidden(true)
    }

    static func icon(for urls: [URL]) -> NSImage {
        switch urls.count {
        case 0: NSWorkspace.shared.icon(for: .data)
        case 1 where !FileManager.default.fileExists(atPath: urls[0].path):
            NSWorkspace.shared.icon(for: UTType(filenameExtension: urls[0].pathExtension) ?? .data)
        case 1: NSWorkspace.shared.icon(forFile: urls[0].path)
        default: NSWorkspace.shared.icon(forFiles: urls.map(\.path)) ?? NSWorkspace.shared.icon(for: .data)
        }
    }
}
