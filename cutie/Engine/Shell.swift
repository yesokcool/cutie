import Foundation
import Synchronization

/// Runs a command-line tool (ffmpeg, bsdtar, zip, osascript) without blocking,
/// and kills it if the job is cancelled.
nonisolated enum Shell {
    struct Failure: LocalizedError {
        let tool: String
        let status: Int32
        let output: String

        var errorDescription: String? {
            let detail = output.split(separator: "\n").last.map(String.init) ?? ""
            return detail.isEmpty ? "\(tool) stopped (\(status))." : detail
        }
    }

    /// Returns stdout. `onLine` sees stdout line by line as it arrives (ffmpeg progress).
    /// With `stdoutFile`, stdout goes to that file instead.
    @discardableResult
    static func run(
        _ executable: URL,
        _ arguments: [String],
        in directory: URL? = nil,
        stdoutFile: URL? = nil,
        onLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let directory { process.currentDirectoryURL = directory }
        process.standardInput = FileHandle.nullDevice

        let output = Mutex(Data())
        let errors = Mutex(Data())
        let pending = Mutex("")
        let outPipe = Pipe()
        let errPipe = Pipe()
        var outFile: FileHandle?

        if let stdoutFile {
            FileManager.default.createFile(atPath: stdoutFile.path, contents: nil)
            outFile = try FileHandle(forWritingTo: stdoutFile)
            process.standardOutput = outFile
        } else {
            process.standardOutput = outPipe
            outPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                output.withLock { $0.append(data) }
                if let onLine, let text = String(data: data, encoding: .utf8) {
                    let lines: [String] = pending.withLock { buffer in
                        buffer += text
                        var parts = buffer.components(separatedBy: "\n")
                        buffer = parts.removeLast()
                        return parts
                    }
                    lines.forEach(onLine)
                }
            }
        }
        process.standardError = errPipe
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            errors.withLock { $0.append(data) }
        }

        let box = ProcessBox(process)
        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
                process.terminationHandler = { finished in
                    continuation.resume(returning: finished.terminationStatus)
                }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            box.terminate()
        }

        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        if stdoutFile == nil {
            let rest = outPipe.fileHandleForReading.readDataToEndOfFile()
            output.withLock { $0.append(rest) }
        }
        let restErrors = errPipe.fileHandleForReading.readDataToEndOfFile()
        errors.withLock { $0.append(restErrors) }
        try? outFile?.close()

        try Task.checkCancellation()
        let stdout = output.withLock { String(decoding: $0, as: UTF8.self) }
        guard status == 0 else {
            let stderr = errors.withLock { String(decoding: $0, as: UTF8.self) }
            throw Failure(tool: executable.lastPathComponent, status: status,
                          output: stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return stdout
    }

    static let tar = URL(fileURLWithPath: "/usr/bin/tar")
    static let zip = URL(fileURLWithPath: "/usr/bin/zip")
    static let ditto = URL(fileURLWithPath: "/usr/bin/ditto")
    static let gzip = URL(fileURLWithPath: "/usr/bin/gzip")
    static let osascript = URL(fileURLWithPath: "/usr/bin/osascript")
}

/// Lets the cancellation handler (which may run on any thread) reach the process.
private nonisolated final class ProcessBox: @unchecked Sendable {
    private let process: Process
    init(_ process: Process) { self.process = process }
    func terminate() { if process.isRunning { process.terminate() } }
}
