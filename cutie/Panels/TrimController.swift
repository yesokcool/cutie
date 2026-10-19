import AVKit

/// Trim: QuickTime's own trimming bar on the file. Trim saves a copy of the
/// chosen range (streams copied, not re-encoded) beside the original.
final class TrimController: NSObject, NSWindowDelegate {
    var onTrim: (URL, CMTimeRange, NSPoint) -> Void = { _, _, _ in }
    private var windows: [NSWindow] = []

    func open(_ url: URL, at point: NSPoint) {
        let player = AVPlayer(url: url)
        let playerView = AVPlayerView()
        playerView.player = player
        playerView.controlsStyle = .inline
        playerView.showsFullScreenToggleButton = false

        let isAudio = FileKind.of(url) == .audio
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: isAudio ? 140 : 460),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "Trim \(url.lastPathComponent)"
        window.contentView = playerView
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        windows.append(window)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)

        Task {
            // Trimming can only begin once the item is ready to play.
            for _ in 0..<100 where player.currentItem?.status != .readyToPlay {
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard playerView.canBeginTrimming else { window.close(); return }
            let result = await playerView.beginTrimming()
            let item = player.currentItem
            window.close()
            guard result == .okButton, let item else { return }
            let start = item.reversePlaybackEndTime.isValid ? item.reversePlaybackEndTime : .zero
            let end = item.forwardPlaybackEndTime.isValid ? item.forwardPlaybackEndTime : item.duration
            self.onTrim(url, CMTimeRange(start: start, end: end), point)
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        (window.contentView as? AVPlayerView)?.player?.pause()
        windows.removeAll { $0 === window }
    }
}
