import AppKit
import SwiftUI
import Testing
@testable import cutie

/// Renders the UI to PNGs for a look without opening anything on screen.
/// Run with CUTIE_SNAPSHOTS=<folder>; skipped otherwise.
@Suite(.serialized)
struct SnapshotTests {
    let folder = ProcessInfo.processInfo.environment["CUTIE_SNAPSHOTS"].map { URL(fileURLWithPath: $0) }

    func render<V: View>(_ view: V, _ name: String, dark: Bool = false, size: CGSize? = nil) throws {
        guard let folder else { return }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let content = view
            .environment(\.isSnapshot, true)
            .environment(\.colorScheme, dark ? .dark : .light)
            .padding(24)
            .background(dark ? Color(white: 0.16) : Color(white: 0.93))
        // A real (never shown) window so AppKit-backed controls draw too.
        let hosting = NSHostingView(rootView: content)
        hosting.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let fitting = size ?? hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: fitting)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        let rep = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])?.write(to: folder.appending(path: "\(name)\(dark ? "-dark" : "").png"))
    }

    @Test func wheels() throws {
        for dark in [false, true] {
            try render(WheelView(model: .sample), "wheel-convert", dark: dark)
        }
        let tools = WheelModel.sample
        tools.wheel = .tools
        tools.items = Catalog.tools(for: [URL(fileURLWithPath: "/tmp/a.jpg"), URL(fileURLWithPath: "/tmp/b.jpg")], toolbox: .none).map(WheelItem.tool)
        tools.highlighted = 6
        try render(WheelView(model: tools), "wheel-tools")
        let actions = WheelModel.sample
        actions.wheel = .actions
        actions.items = FileAction.allCases.map(WheelItem.action)
        actions.highlighted = nil
        try render(WheelView(model: actions), "wheel-actions", dark: true)
        let video = WheelModel.sample
        video.items = Catalog.conversions(for: [URL(fileURLWithPath: "/tmp/a.mov")], toolbox: Toolbox(ffmpeg: URL(fileURLWithPath: "/x"))).map(WheelItem.convert)
        video.highlighted = 3
        try render(WheelView(model: video), "wheel-video")
    }

    @Test func pills() throws {
        let running = JobModel(title: "Converting to PNG", symbol: "photo")
        running.state = .running(0.42)
        let done = JobModel(title: "Converting to PNG", symbol: "photo")
        done.state = .done(JobOutcome(files: [URL(fileURLWithPath: "/tmp/holiday photo.png")]))
        let compressed = JobModel(title: "Compressing", symbol: "photo")
        compressed.state = .done(JobOutcome(files: [URL(fileURLWithPath: "/tmp/clip compressed.mp4")], message: "48.2 MB → 11.9 MB (−75%)"))
        let failed = JobModel(title: "Converting to MP3", symbol: "waveform")
        failed.state = .failed("This file has no sound.")
        let copied = JobModel(title: "Checking", symbol: "checkmark.seal")
        copied.state = .done(JobOutcome(message: "SHA-256 copied", copied: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"))
        for dark in [false, true] {
            try render(VStack(spacing: 12) {
                ForEach([running, done, compressed, failed, copied]) { JobPillView(job: $0, onClose: {}) }
            }, "pills", dark: dark)
        }
    }

    @Test func float() throws {
        try render(HStack(spacing: 16) {
            FloatView(model: FloatModel(files: [URL(fileURLWithPath: "/tmp/notes.pdf")]), onClose: {})
            FloatView(model: FloatModel(files: [URL(fileURLWithPath: "/tmp/a.png"), URL(fileURLWithPath: "/tmp/b.mov")]), onClose: {})
        }, "float")
    }

    @Test func settingsAndWelcome() throws {
        for dark in [false, true] {
            try render(SettingsView(core: CutieCore.shared), "settings", dark: dark, size: CGSize(width: 588, height: 900))
            try render(WelcomeView(), "welcome", dark: dark, size: CGSize(width: 528, height: 820))
        }
    }
}
