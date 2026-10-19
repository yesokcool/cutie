import SwiftUI

/// The pill a job lives in: progress while it runs, then the result — drag it
/// anywhere, click to show it in Finder.
struct JobPillView: View {
    let job: JobModel
    var onClose: () -> Void

    static let width: CGFloat = 320
    static let height: CGFloat = 64
    /// The close button's square at the trailing edge (FileDragView passes clicks there to SwiftUI).
    static let closeSide: CGFloat = 44

    var body: some View {
        HStack(spacing: 12) {
            leading
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(headline)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .accessibilityLabel(job.isFinished ? "Close" : "Cancel")
            .frame(width: Self.closeSide - 12)
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .frame(width: Self.width, height: Self.height)
        .cutieGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .animation(.snappy, value: job.state)
    }

    @ViewBuilder private var leading: some View {
        switch job.state {
        case .running(let progress):
            if let progress {
                ProgressView(value: progress)
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                    .tint(.accentColor)
            } else {
                ProgressView().controlSize(.small)
            }
        case .done(let outcome):
            if outcome.files.isEmpty {
                Image(systemName: outcome.copied != nil ? "doc.on.clipboard" : job.symbol)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.tint)
            } else {
                FileIcon(urls: outcome.files)
            }
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 20))
                .foregroundStyle(.orange)
        }
    }

    private var headline: String {
        switch job.state {
        case .running: return job.title + "…"
        case .done(let outcome):
            if outcome.files.count == 1 { return outcome.files[0].lastPathComponent }
            if outcome.files.count > 1 { return "\(outcome.files.count) files" }
            return outcome.message ?? job.title
        case .failed: return "Couldn't finish"
        }
    }

    private var detail: String {
        switch job.state {
        case .running(let progress):
            return progress.map { "\(Int(($0 * 100).rounded()))%" } ?? "Working on it"
        case .done(let outcome):
            var parts: [String] = []
            if !outcome.files.isEmpty, let message = outcome.message { parts.append(message) }
            if !outcome.failures.isEmpty { parts.append("\(outcome.failures.count) didn't work: \(outcome.failures[0])") }
            if !outcome.files.isEmpty && parts.isEmpty { parts.append("Drag it anywhere · click to show in Finder") }
            if outcome.files.isEmpty, let copied = outcome.copied {
                parts.append(copied.split(separator: "\n").count > 1 ? "\(copied.split(separator: "\n").count) lines" : String(copied.prefix(32)) + "…")
            }
            return parts.joined(separator: " · ")
        case .failed(let message):
            return message
        }
    }
}
