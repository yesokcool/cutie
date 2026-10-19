import Foundation
import Synchronization

/// Runs a command-line tool (ffmpeg, bsdtar, zip, osascript) without blocking,
/// and kills it if the job is cancelled.
nonisolated enum Shell {
    struct Failure: LocalizedError {
        let tool: String
        let status: Int32
        /// Everything the tool wrote to stderr.
        let output: String

        var errorDescription: String? { Self.explain(output, tool: tool, status: status) }

        /// Known problems in plain words; otherwise the line that names the
        /// problem (tools often end with a summary like "Error exit delayed").
        static func explain(_ output: String, tool: String, status: Int32) -> String {
            let lines = output.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            for (patterns, reason) in plainReasons
            where lines.contains(where: { line in patterns.contains { line.localizedCaseInsensitiveContains($0) } }) {
                return reason
            }
            let meaningful = lines.filter { line in !noise.contains { line.hasPrefix($0) } }
            let problem = meaningful.last { line in problemWords.contains { line.localizedCaseInsensitiveContains($0) } }
            guard let line = problem ?? meaningful.last else { return "\(tool) stopped (\(status))." }
            return cleaned(line, tool: tool)
        }

        /// Checked in order: "Data Error in encrypted file. Wrong password?" is a password problem.
        static let plainReasons: [([String], String)] = [
            (["password", "passphrase", "encrypted", "encryption"], "This file is password-protected."),
            (["No space left on device", "Disk full", "not enough space", "ENOSPC"], "The disk is full."),
            (["Permission denied", "Operation not permitted", "Read-only file system"],
             "Cutie isn't allowed to read or write there (permission denied)."),
            (["Could not find tag for codec", "not currently supported in container"],
             "That format can't hold this file's audio or video."),
            (["Unknown encoder", "Encoder not found", "Decoder not found", "Unsupported codec", "could not find codec"],
             "This file's audio or video codec isn't supported."),
            (["Invalid data found when processing input", "moov atom not found", "corrupt", "Truncated", "Unexpected end",
              "unexpected EOF", "CRC Failed", "Data Error", "Can't open as archive", "Unrecognized archive format",
              "Damaged"],
             "This file is damaged or isn't what its name says."),
            (["No such file or directory"], "A file Cutie needed wasn't there (moved or renamed?)."),
        ]

        /// Banners, progress and summaries that never say what went wrong.
        static let noise = [
            "frame=", "size=", "video:", "Press [q]", "ffmpeg version", "built with", "configuration:", "libav", "libsw",
            "libpostproc", "Input #", "Output #", "Stream #", "Duration:", "Metadata:", "Stream mapping", "Side data:",
            "7-Zip", "p7zip", "Scanning the drive", "Extracting archive", "Path =", "Type =", "Physical Size", "--",
            "Sub items Errors", "Archives with Errors", "Files:", "Size:", "Compressed:", "Folders:",
            "tar: Error exit delayed",
        ]

        static let problemWords = [
            "error", "invalid", "no such", "denied", "not permitted", "corrupt", "unsupported", "not supported",
            "failed", "cannot", "can't", "unable", "could not", "couldn't", "unknown", "wrong", "incorrect", "missing",
        ]

        /// "tar: x: Something: Unknown error: -1" → "x: Something"; "[mp4 @ 0x1] Oops" → "Oops".
        static func cleaned(_ line: String, tool: String) -> String {
            var line = line
            for prefix in ["\(tool): ", "tar: ", "ERROR: ", "Error: "] where line.hasPrefix(prefix) {
                line.removeFirst(prefix.count)
            }
            if line.hasPrefix("["), let close = line.firstIndex(of: "]"), line[..<close].contains("@ 0x") {
                line = String(line[line.index(after: close)...]).trimmingCharacters(in: .whitespaces)
            }
            if let range = line.range(of: ": Unknown error: -1") { line.removeSubrange(range) }
            return line.prefix(1).uppercased() + line.dropFirst()
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
