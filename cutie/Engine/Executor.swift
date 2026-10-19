import AppKit
import CryptoKit

/// Runs a Convert or Tools slice on the dropped files, off the main thread.
/// Every output is made in a scratch folder and only moved beside the
/// original (with a fresh name) once it's complete.
nonisolated enum Executor {
    @concurrent
    static func run(_ item: WheelItem, inputs: [URL], context: JobContext) async throws -> JobOutcome {
        guard let first = inputs.first else { throw CutieError("Nothing to work on.") }
        let scratch = try Scratch(near: context.output.directory(for: first))
        defer { scratch.remove() }
        switch item.kind {
        case .convert(let format):
            return try await convert(inputs, to: format, context: context, scratch: scratch)
        case .tool(let tool):
            return try await runTool(tool, inputs: inputs, context: context, scratch: scratch)
        case .action:
            throw CutieError("Actions run on the main thread.")
        }
    }

    // MARK: - Convert

    static func convert(_ inputs: [URL], to format: Format, context: JobContext, scratch: Scratch) async throws -> JobOutcome {
        let kinds = Set(inputs.map(FileKind.of))
        if [.zip, .tar, .gzip].contains(format) && kinds != [.archive] {
            return JobOutcome(files: [try await archiveAll(inputs, as: format, context: context, scratch: scratch)])
        }
        return try await eachFile(inputs, context: context) { input, fileContext in
            if Format.matching(extension: FileKind.fileExtension(of: input)) == format { return nil }
            return try await convertOne(input, to: format, context: fileContext, scratch: scratch)
        }
    }

    static func convertOne(_ input: URL, to format: Format, context: JobContext, scratch: Scratch) async throws -> URL {
        let base = Output.baseName(of: input)
        let ext = FileKind.fileExtension(of: input)
        let work = try scratch.folder(UUID().uuidString)
        var target = work.appending(path: "\(base).\(format.fileExtension)")

        // LibreOffice, pandoc, Pages or Numbers when one does this conversion better.
        if let done = try await Office.convert(input, to: format, in: work, context: context, scratch: scratch) {
            return try context.output.place(done, named: done.lastPathComponent, beside: input)
        }

        switch FileKind.of(input) {
        case .image:
            try await ImageConverter.convert(input, to: format, at: target, context: context, scratch: scratch)
        case .video, .audio:
            try await MediaConverter.convert(input, to: format, at: target, context: context, scratch: scratch)
        case .pdf:
            switch format {
            case .jpg, .png: target = try PDFConverter.images(input, as: format, in: work, context: context)
            case .pptx: try await PowerPoint.write(from: input, to: target, scratch: scratch, context: context)
            case .docx: try await PDFToWord.write(from: input, to: target, context: context, scratch: scratch)
            case .xlsx: try await PDFToWord.writeTables(from: input, to: target, context: context, scratch: scratch)
            case .pages:
                let docx = scratch.file(UUID().uuidString + ".docx")
                try await PDFToWord.write(from: input, to: docx, context: context, scratch: scratch)
                try await IWork.export(docx, with: .pages, to: .pages, at: target, toolbox: context.toolbox)
            default: try await writeDocument(from: input, as: format, to: target, context: context, scratch: scratch)
            }
        case .document, .ebook:
            if ext == "pages", [.pdf, .docx, .epub, .txt, .rtf].contains(format) {
                try await IWork.export(input, with: .pages, to: format, at: target, toolbox: context.toolbox)
            } else {
                try await writeDocument(from: input, as: format, to: target, context: context, scratch: scratch)
            }
        case .slides:
            if format == .jpg || format == .png {
                target = work.appending(path: "\(base) (\(format.title))", directoryHint: .isDirectory)
            }
            try await IWork.export(input, with: .keynote, to: format, at: target, toolbox: context.toolbox)
        case .spreadsheet:
            if ["numbers", "xls"].contains(ext), [.pdf, .xlsx, .csv].contains(format) {
                try await IWork.export(input, with: .numbers, to: format, at: target, toolbox: context.toolbox)
            } else {
                let book = try await Spreadsheet.read(input, scratch: scratch, toolbox: context.toolbox)
                if [.csv, .tsv].contains(format), book.sheets.count > 1 {
                    target = work.appending(path: "\(base) (\(format.title))", directoryHint: .isDirectory)
                }
                try await Spreadsheet.write(book, as: format, to: target, title: base, scratch: scratch, toolbox: context.toolbox)
            }
        case .subtitle:
            try Subtitles.convert(input, to: format, at: target)
        case .archive:
            let unpacked = try scratch.folder(UUID().uuidString)
            try await ArchiveConverter.extract(input, into: unpacked, toolbox: context.toolbox)
            try await ArchiveConverter.archive(try ArchiveConverter.topLevelItems(in: unpacked), as: format, to: target)
            ArchiveConverter.copyQuarantine(from: input, to: target)
        case .folder, .other:
            throw CutieError("Nothing to convert this to.")
        }
        return try context.output.place(target, named: target.lastPathComponent, beside: input)
    }

    @MainActor
    private static func writeDocument(from input: URL, as format: Format, to target: URL, context: JobContext, scratch: Scratch) async throws {
        let base = Output.baseName(of: input)
        var html: String?
        if ["md", "markdown"].contains(FileKind.fileExtension(of: input)) {
            html = Markdown.htmlPage(from: try DocumentReader.readText(input), title: base, baseURL: input.deletingLastPathComponent())
        }
        let text = try await DocumentReader.read(input, context: context, scratch: scratch)
        try await DocumentWriter.write(text, html: html, baseURL: input.deletingLastPathComponent(), as: format, to: target,
                                       title: base, context: context, scratch: scratch)
    }

    /// One archive of everything dropped: "Folder.zip" for one item, "Archive.zip" for several.
    /// GZIP of a single regular file is that file gzipped ("notes.txt.gz").
    static func archiveAll(_ inputs: [URL], as format: Format, context: JobContext, scratch: Scratch) async throws -> URL {
        let work = try scratch.folder(UUID().uuidString)
        let single = inputs.count == 1 ? inputs[0] : nil
        var isFolder: ObjCBool = false
        if let single, format == .gzip,
           FileManager.default.fileExists(atPath: single.path, isDirectory: &isFolder), !isFolder.boolValue {
            let target = work.appending(path: single.lastPathComponent + ".gz")
            try await ArchiveConverter.gzipFile(single, to: target)
            return try context.output.place(target, named: target.lastPathComponent, beside: single)
        }
        let name = single.map { $0.lastPathComponent } ?? "Archive"
        let target = work.appending(path: "\(name).\(format.fileExtension)")
        try await ArchiveConverter.archive(inputs, as: format, to: target)
        return try context.output.place(target, named: target.lastPathComponent, beside: inputs[0])
    }

    // MARK: - Tools

    static func runTool(_ tool: Tool, inputs: [URL], context: JobContext, scratch: Scratch) async throws -> JobOutcome {
        let first = inputs[0]
        switch tool {
        case .combineToPDF:
            let target = scratch.file("Combined.pdf")
            try ImageConverter.writePDF(from: inputs, to: target, quality: context.imageQuality)
            return JobOutcome(files: [try context.output.place(target, named: "Combined.pdf", beside: first)])
        case .mergePDFs:
            let target = scratch.file("Merged.pdf")
            try PDFConverter.merge(inputs, to: target)
            return JobOutcome(files: [try context.output.place(target, named: "Merged.pdf", beside: first)])
        case .mergeAudio:
            let target = scratch.file("Merged.m4a")
            try await MediaTools.mergeAudio(inputs, to: target, context: context)
            return JobOutcome(files: [try context.output.place(target, named: "Merged.m4a", beside: first)])
        case .zip:
            return JobOutcome(files: [try await archiveAll(inputs, as: .zip, context: context, scratch: scratch)])
        case .checksum:
            var lines: [String] = []
            for input in inputs {
                let hash = try sha256(of: input)
                lines.append(inputs.count == 1 ? hash : "\(hash)  \(input.lastPathComponent)")
            }
            return JobOutcome(message: "SHA-256 copied", copied: lines.joined(separator: "\n"))
        case .wordCount:
            return JobOutcome(message: try await wordCount(inputs, context: context, scratch: scratch))
        case .trimMedia:
            throw CutieError("Trim opens its own window.")
        default:
            var outcome = try await eachFile(inputs, context: context) { input, fileContext in
                try await toolOne(tool, input: input, context: fileContext, scratch: scratch)
            }
            if [.compressImage, .compressPDF, .compressVideo, .compressAudio].contains(tool) {
                outcome.message = sizeChange(from: inputs, to: outcome.files)
            }
            return outcome
        }
    }

    static func toolOne(_ tool: Tool, input: URL, context: JobContext, scratch: Scratch) async throws -> URL {
        let base = Output.baseName(of: input)
        let work = try scratch.folder(UUID().uuidString)
        let (_, mediaExt) = MediaTools.fileType(for: input)
        var target: URL

        switch tool {
        case .compressImage, .resizeImage, .rotateImage, .flipImage, .grayscale, .cropSquare, .stripMetadata, .removeBackground:
            target = try await imageTool(tool, input: input, in: work, context: context, scratch: scratch)
        case .extractText:
            target = work.appending(path: "\(base).txt")
            let text = try await ImageTools.recognizedText(try ImageConverter.load(input).image)
            try Data(text.utf8).write(to: target)
        case .compressPDF:
            target = work.appending(path: "\(base)\(tool.suffix).pdf")
            try await PDFConverter.compress(input, to: target, toolbox: context.toolbox)
        case .makeSearchable:
            target = work.appending(path: "\(base)\(tool.suffix).pdf")
            try await PDFConverter.makeSearchable(input, to: target, context: context)
        case .splitPDF:
            target = work.appending(path: "\(base) (pages)", directoryHint: .isDirectory)
            try PDFConverter.split(input, into: target, context: context)
        case .rotatePDF:
            target = work.appending(path: "\(base)\(tool.suffix).pdf")
            try PDFConverter.rotate(input, to: target)
        case .compressVideo:
            target = work.appending(path: "\(base)\(tool.suffix).mp4")
            try await MediaTools.compressVideo(input, to: target, context: context)
        case .muteVideo:
            let ext = MediaTools.isNative(input) ? mediaExt : FileKind.fileExtension(of: input)
            target = work.appending(path: "\(base)\(tool.suffix).\(ext)")
            try await MediaTools.mute(input, to: target, context: context)
        case .extractAudio:
            let format = await MediaTools.audioFormat(for: input, context: context)
            target = work.appending(path: "\(base).\(format.fileExtension)")
            try await MediaTools.extractAudio(input, as: format, to: target, context: context)
        case .extractSubtitles:
            target = try await MediaTools.extractSubtitles(input, in: work, context: context)
        case .rotateVideo:
            target = work.appending(path: "\(base)\(tool.suffix).\(MediaTools.isNative(input) ? mediaExt : "mp4")")
            try await MediaTools.rotate(input, to: target, context: context)
        case .resizeVideo:
            target = work.appending(path: "\(base)\(tool.suffix).mp4")
            try await MediaTools.resize720(input, to: target, context: context)
        case .snapshot:
            target = work.appending(path: "\(base).png")
            try await MediaTools.snapshot(input, to: target, context: context, scratch: scratch)
        case .compressAudio:
            target = work.appending(path: "\(base)\(tool.suffix).m4a")
            try await MediaTools.compressAudio(input, to: target, context: context)
        case .normalizeAudio:
            target = work.appending(path: "\(base)\(tool.suffix).\(FileKind.fileExtension(of: input))")
            try await MediaTools.normalize(input, to: target, context: context)
        case .extract:
            let unpacked = try scratch.folder(UUID().uuidString)
            try await ArchiveConverter.extract(input, into: unpacked, toolbox: context.toolbox)
            let items = try ArchiveConverter.topLevelItems(in: unpacked)
            guard !items.isEmpty else { throw CutieError("This archive is empty.") }
            if items.count == 1 {
                target = items[0]
            } else {
                target = work.appending(path: base, directoryHint: .isDirectory)
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                for item in items {
                    try FileManager.default.moveItem(at: item, to: target.appending(path: item.lastPathComponent))
                }
            }
        default:
            throw CutieError("\(tool.title) doesn't work on this file.")
        }
        return try context.output.place(target, named: target.lastPathComponent, beside: input)
    }

    /// An image tool, keeping everything the tool doesn't change: format,
    /// colour space, bit depth, HDR, metadata and animation. A JPEG's rotate,
    /// flip and metadata removal only rewrite tags, so the photo isn't re-compressed.
    static func imageTool(_ tool: Tool, input: URL, in work: URL, context: JobContext, scratch: Scratch) async throws -> URL {
        let format = tool == .removeBackground ? Format.png : ImageConverter.outputFormat(for: input, toolbox: context.toolbox)
        let target = work.appending(path: "\(Output.baseName(of: input))\(tool.suffix).\(format.fileExtension)")

        let turn: ImageConverter.OrientationChange? = switch tool {
        case .rotateImage: .turnClockwise
        case .flipImage: .mirror
        default: nil
        }
        if turn != nil || tool == .stripMetadata,
           try ImageConverter.losslessEdit(input, to: target, turn: turn, stripMetadata: tool == .stripMetadata) {
            return target
        }

        let transform: (CGImage) throws -> CGImage = switch tool {
        case .resizeImage: ImageTools.halfSize
        case .rotateImage: ImageTools.rotated
        case .flipImage: ImageTools.flipped
        case .grayscale: ImageTools.grayscale
        case .cropSquare: ImageTools.squared
        default: { $0 }
        }
        let lossless = ImageConverter.isLossless(input) && tool != .compressImage
        if tool != .removeBackground, ImageConverter.animatedFormats.contains(format),
           format != .webp || context.toolbox.img2webp != nil,
           var animation = try ImageConverter.animation(input) {
            animation.frames = try animation.frames.map(transform)
            try await ImageConverter.writeAnimation(animation, as: format, to: target, quality: context.imageQuality,
                                                    lossless: lossless, toolbox: context.toolbox, scratch: scratch)
            return target
        }

        var loaded = try ImageConverter.load(input, keepHDR: ImageConverter.gainMapFormats.contains(format))
        var quality = context.imageQuality
        switch tool {
        case .compressImage: quality = min(quality, 0.6)
        case .stripMetadata: loaded.metadata = nil
        case .removeBackground:
            loaded.image = try ImageTools.removingBackground(loaded.image)
            loaded.metadata = nil
        default: loaded.image = try transform(loaded.image)
        }
        if format == .webp {
            try await ImageConverter.writeWebP(loaded.image, to: target, quality: quality, lossless: lossless,
                                               metadata: loaded.metadata, cwebp: context.toolbox.cwebp, scratch: scratch)
        } else {
            try ImageConverter.write(loaded, as: format, to: target, quality: quality)
        }
        return target
    }

    // MARK: - Helpers

    /// Runs `body` on each input with progress spread across them. One failure
    /// doesn't stop the batch; if everything fails, the first error is thrown.
    /// Cancelling takes back the results already placed: a cancelled job leaves nothing.
    static func eachFile(
        _ inputs: [URL], context: JobContext,
        _ body: (URL, JobContext) async throws -> URL?
    ) async throws -> JobOutcome {
        var outcome = JobOutcome()
        var firstError: Error?
        let count = Double(inputs.count)
        for (index, input) in inputs.enumerated() {
            if Task.isCancelled {
                for file in outcome.files { try? FileManager.default.removeItem(at: file) }
                throw CancellationError()
            }
            var fileContext = context
            let report = context.progress
            fileContext.progress = { report((Double(index) + min(max($0, 0), 1)) / count) }
            do {
                if let file = try await body(input, fileContext) { outcome.files.append(file) }
            } catch is CancellationError {
                for file in outcome.files { try? FileManager.default.removeItem(at: file) }
                throw CancellationError()
            } catch {
                firstError = firstError ?? error
                outcome.failures.append("\(input.lastPathComponent): \(error.localizedDescription)")
            }
            report(Double(index + 1) / count)
        }
        if outcome.files.isEmpty, let firstError { throw firstError }
        return outcome
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    @MainActor
    static func wordCount(_ inputs: [URL], context: JobContext, scratch: Scratch) async throws -> String {
        var words = 0, characters = 0
        for input in inputs {
            let text: String
            if FileKind.of(input) == .subtitle {
                text = Subtitles.text(Subtitles.parse(try DocumentReader.readText(input)))
            } else {
                text = try await DocumentReader.read(input, context: context, scratch: scratch).string
            }
            text.enumerateSubstrings(in: text.startIndex..., options: [.byWords, .substringNotRequired]) { _, _, _, _ in words += 1 }
            characters += text.count
        }
        let minutes = max(1, Int((Double(words) / 238).rounded()))
        let number = IntegerFormatStyle<Int>.number
        return "\(words.formatted(number)) words · \(characters.formatted(number)) characters · \(minutes) min read"
    }

    static func sizeChange(from inputs: [URL], to outputs: [URL]) -> String? {
        func size(_ urls: [URL]) -> Int64 {
            urls.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { Int64($0) } ?? 0) }
        }
        let before = size(inputs), after = size(outputs)
        guard before > 0, after > 0 else { return nil }
        let style = ByteCountFormatStyle(style: .file)
        let percent = Int((Double(before - after) / Double(before) * 100).rounded())
        let saving = percent > 0 ? " (−\(percent)%)" : ""
        return "\(before.formatted(style)) → \(after.formatted(style))\(saving)"
    }
}
