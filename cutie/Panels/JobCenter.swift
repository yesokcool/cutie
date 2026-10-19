import AppKit
import SwiftUI

/// Runs jobs and shows each as a pill where it was dropped. Finished pills
/// fade after a few seconds (never while the pointer is on them); failures
/// stay longer so the reason can be read.
final class JobCenter {
    var toolbox: () -> Toolbox = { .none }

    private var panels: [UUID: NSPanel] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]

    /// Runs `work` off the main thread with a pill at `point`.
    func run(title: String, symbol: String, at point: NSPoint,
             work: @escaping @Sendable (JobContext) async throws -> JobOutcome) {
        let job = JobModel(title: title, symbol: symbol)
        present(job, at: point)
        let progress: @Sendable (Double) -> Void = { value in
            Task { @MainActor in
                if case .running = job.state { job.state = .running(value) }
            }
        }
        let context = JobContext.current(toolbox: toolbox(), progress: progress)
        tasks[job.id] = Task {
            do {
                let outcome = try await work(context)
                if let copied = outcome.copied {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(copied, forType: .string)
                }
                finish(job, .done(outcome), after: 6)
            } catch is CancellationError {
                close(job)
            } catch {
                finish(job, .failed(error.localizedDescription), after: 15)
            }
        }
    }

    /// A short confirmation ("Path copied") that needs no work.
    func show(_ message: String, symbol: String, at point: NSPoint) {
        let job = JobModel(title: message, symbol: symbol)
        job.state = .done(JobOutcome(message: message))
        present(job, at: point)
        scheduleClose(job, after: 2.5)
    }

    func close(_ job: JobModel) {
        tasks.removeValue(forKey: job.id)?.cancel()
        panels.removeValue(forKey: job.id)?.orderOut(nil)
    }

    private func finish(_ job: JobModel, _ state: JobModel.State, after delay: Double) {
        guard panels[job.id] != nil else { return }
        job.state = state
        tasks.removeValue(forKey: job.id)
        scheduleClose(job, after: delay)
    }

    private func scheduleClose(_ job: JobModel, after delay: Double) {
        Task {
            try? await Task.sleep(for: .seconds(delay))
            while job.hovering { try? await Task.sleep(for: .milliseconds(500)) }
            close(job)
        }
    }

    // MARK: Panel

    private func present(_ job: JobModel, at point: NSPoint) {
        let size = NSSize(width: JobPillView.width, height: JobPillView.height)
        let hosting = NSHostingView(rootView: JobPillView(job: job, onClose: { [weak self] in self?.close(job) }))
        hosting.sizingOptions = []
        let surface = FileDragView(content: hosting)
        surface.files = { job.files }
        surface.onClick = {
            if !job.files.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(job.files) }
        }
        surface.onHover = { job.hovering = $0 }
        surface.onDragEnded = { [weak self] _ in
            // Dragged out with a move (same disk): the result isn't here any more.
            if job.files.contains(where: { !FileManager.default.fileExists(atPath: $0.path) }) { self?.close(job) }
        }
        surface.passThrough = { [NSRect(x: size.width - JobPillView.closeSide, y: 0, width: JobPillView.closeSide, height: size.height)] }

        let panel = WheelPanel()
        panel.level = .floating
        panel.contentView = surface
        panel.setFrame(frame(for: size, near: point), display: true)
        panel.orderFrontRegardless()
        panels[job.id] = panel
    }

    /// Centered on `point`, below any pill already there, kept on screen.
    private func frame(for size: NSSize, near point: NSPoint) -> NSRect {
        var frame = NSRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height)
        let others = panels.values.map(\.frame)
        while others.contains(where: { $0.intersects(frame) }) { frame.origin.y -= size.height + 8 }
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) ?? NSScreen.main {
            let visible = screen.visibleFrame.insetBy(dx: 8, dy: 8)
            frame.origin.x = min(max(frame.origin.x, visible.minX), visible.maxX - size.width)
            frame.origin.y = min(max(frame.origin.y, visible.minY), visible.maxY - size.height)
        }
        return frame
    }
}
