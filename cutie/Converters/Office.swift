import Foundation

/// Office documents through the best tool this Mac has. LibreOffice (headless)
/// gives Word, Excel and PowerPoint files their real page layout, formulas and
/// slides; pandoc keeps document structure (heading styles, tables, footnotes,
/// links, images) between Word, ODT, Markdown, HTML and EPUB; Pages, Keynote
/// and Numbers come next. Without any of them, Cutie's own converters run.
nonisolated enum Office {
    /// Converts with a helper when one fits and returns what it wrote in
    /// `work` (a file, or a folder of slide images); nil when the built-in
    /// path should run. PDFs are another converter's business.
    static func convert(_ input: URL, to format: Format, in work: URL, context: JobContext, scratch: Scratch) async throws -> URL? {
        let toolbox = context.toolbox
        let ext = FileKind.fileExtension(of: input)
        let base = Output.baseName(of: input)
        let target = work.appending(path: "\(base).\(format.fileExtension)")

        switch FileKind.of(input) {
        case .document, .ebook:
            guard ext != "pages" else { return nil }
            let layout: Set<String> = ["docx", "doc", "odt", "rtf"]
            let structured: Set<String> = ["docx", "odt", "rtf", "md", "markdown", "html", "htm", "epub"]
            switch format {
            case .pdf:
                if let soffice = toolbox.soffice, layout.contains(ext) {
                    try await LibreOffice.convert(input, to: .pdf, at: target, soffice: soffice, scratch: scratch)
                } else if toolbox.pages != nil, ["docx", "doc", "rtf"].contains(ext) {
                    try await IWork.export(input, with: .pages, to: .pdf, at: target, toolbox: toolbox)
                } else if let soffice = toolbox.soffice, let pandoc = toolbox.pandoc, structured.contains(ext) {
                    // Structure from pandoc, page layout from LibreOffice.
                    let docx = try scratch.folder(UUID().uuidString).appending(path: "\(base).docx")
                    try await Pandoc.convert(input, to: .docx, at: docx, pandoc: pandoc, scratch: scratch)
                    try await LibreOffice.convert(docx, to: .pdf, at: target, soffice: soffice, scratch: scratch)
                } else {
                    return nil
                }
            case .docx, .odt, .rtf:
                if let soffice = toolbox.soffice, layout.contains(ext) {
                    try await LibreOffice.convert(input, to: format, at: target, soffice: soffice, scratch: scratch)
                } else if let pandoc = toolbox.pandoc, format != .rtf, structured.contains(ext) {
                    try await Pandoc.convert(input, to: format, at: target, pandoc: pandoc, scratch: scratch)
                } else {
                    return nil
                }
            case .md, .html, .epub:
                guard let pandoc = toolbox.pandoc else { return nil }
                var source = input
                if ext == "doc" {
                    guard let soffice = toolbox.soffice else { return nil }
                    source = try scratch.folder(UUID().uuidString).appending(path: "\(base).docx")
                    try await LibreOffice.convert(input, to: .docx, at: source, soffice: soffice, scratch: scratch)
                } else if !structured.contains(ext) {
                    return nil
                }
                return try await Pandoc.convert(source, to: format, at: target, pandoc: pandoc, scratch: scratch)
            default:
                return nil
            }
        case .slides:
            // Keynote handles slides when it's installed; LibreOffice otherwise.
            guard toolbox.keynote == nil || ext == "odp", ext != "key", let soffice = toolbox.soffice else { return nil }
            switch format {
            case .pdf, .pptx:
                try await LibreOffice.convert(input, to: format, at: target, soffice: soffice, scratch: scratch)
            case .jpg, .png:
                let pdf = try scratch.folder(UUID().uuidString).appending(path: "\(base).pdf")
                try await LibreOffice.convert(input, to: .pdf, at: pdf, soffice: soffice, scratch: scratch)
                return try PDFConverter.images(pdf, as: format, in: work, context: context)
            default:
                return nil
            }
        case .spreadsheet:
            guard ext != "numbers" else { return nil }
            switch format {
            case .pdf:
                if let soffice = toolbox.soffice {
                    try await LibreOffice.convert(input, to: .pdf, at: target, soffice: soffice, scratch: scratch)
                } else if toolbox.numbers != nil, ["xlsx", "xls", "csv"].contains(ext) {
                    try await IWork.export(input, with: .numbers, to: .pdf, at: target, toolbox: toolbox)
                } else {
                    return nil
                }
            case .xlsx, .ods:
                // Formulas, styles and merged cells survive only through LibreOffice.
                guard let soffice = toolbox.soffice, ["xlsx", "xls", "ods"].contains(ext) else { return nil }
                try await LibreOffice.convert(input, to: format, at: target, soffice: soffice, scratch: scratch)
            default:
                return nil
            }
        default:
            return nil
        }
        return target
    }

    /// Runs `body`, giving up after `seconds` (which also stops a helper it started).
    static func withTimeout<T: Sendable>(_ seconds: Double, _ helper: String,
                                         _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw CutieError("\(helper) took too long and was stopped.")
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw CancellationError() }
            return result
        }
    }
}

/// LibreOffice's `soffice --headless --convert-to`, in a throwaway profile so
/// it never touches (or waits for) a LibreOffice the user has open.
nonisolated enum LibreOffice {
    static func convert(_ input: URL, to format: Format, at output: URL, soffice: URL, scratch: Scratch) async throws {
        guard let filter = filter(for: format) else { throw CutieError("LibreOffice can't make \(format.title) files.") }
        let profile = try scratch.folder("libreoffice-" + UUID().uuidString)
        let outdir = try scratch.folder(UUID().uuidString)
        let arguments = [
            "-env:UserInstallation=\(profile.absoluteString)",
            "--headless", "--invisible", "--nologo", "--norestore", "--nolockcheck", "--nodefault",
            "--convert-to", filter, "--outdir", outdir.path, input.path,
        ]
        try await Office.withTimeout(300, "LibreOffice") {
            _ = try await Shell.run(soffice, arguments)
        }
        // soffice exits 0 even when it couldn't load the file; the output is the proof.
        let written = outdir.appending(path: input.deletingPathExtension().lastPathComponent + "." + format.fileExtension)
        guard FileManager.default.fileExists(atPath: written.path) else {
            throw CutieError("LibreOffice couldn't open this file.")
        }
        try FileManager.default.moveItem(at: written, to: output)
    }

    static func filter(for format: Format) -> String? {
        switch format {
        case .pdf: "pdf"
        case .docx: "docx:MS Word 2007 XML"
        case .odt: "odt"
        case .rtf: "rtf:Rich Text Format"
        case .xlsx: "xlsx:Calc MS Excel 2007 XML"
        case .ods: "ods"
        case .pptx: "pptx:Impress MS PowerPoint 2007 XML"
        default: nil
        }
    }
}

/// pandoc: documents as structure (headings, lists, tables, footnotes, links,
/// images) rather than as styled text.
nonisolated enum Pandoc {
    /// Returns what it wrote: `output`, or for Markdown with pictures a folder
    /// "name (Markdown)" holding the `.md` and its `media` folder.
    @discardableResult
    static func convert(_ input: URL, to format: Format, at output: URL, pandoc: URL, scratch: Scratch) async throws -> URL {
        guard let reader = reader(for: FileKind.fileExtension(of: input)), let writer = writer(for: format) else {
            throw CutieError("pandoc can't make \(format.title) files from this.")
        }
        let base = Output.baseName(of: input)
        // The file's name stands in for a title; one in the document itself wins.
        let metadata = scratch.file(UUID().uuidString + ".yaml")
        let quoted = base.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        try Data("title: \"\(quoted)\"\npagetitle: \"\(quoted)\"\n".utf8).write(to: metadata)

        let work = try scratch.folder(UUID().uuidString)
        let written = work.appending(path: "\(base).\(format.fileExtension)")
        var arguments = ["--from", reader, "--to", writer, "--output", written.path,
                         "--resource-path", input.deletingLastPathComponent().path,
                         "--metadata-file", metadata.path]
        switch format {
        case .html:
            arguments += ["--standalone", "--embed-resources"]
        case .md:
            // Word's picture sizes would turn images into raw <img> tags; plain ![](…) reads everywhere.
            let filter = scratch.file(UUID().uuidString + ".lua")
            try Data("function Image(image) image.attributes = {} return image end\n".utf8).write(to: filter)
            arguments += ["--wrap=none", "--extract-media=media", "--lua-filter", filter.path]
        default:
            break
        }
        arguments.append(input.path)
        let command = arguments
        try await Office.withTimeout(120, "pandoc") {
            _ = try await Shell.run(pandoc, command, in: work)
        }
        guard FileManager.default.fileExists(atPath: written.path) else { throw CutieError("pandoc didn't write the file.") }

        let media = work.appending(path: "media", directoryHint: .isDirectory)
        if format == .md, FileManager.default.fileExists(atPath: media.path) {
            try flatten(media, referencedIn: written)
            let folder = output.deletingLastPathComponent().appending(path: "\(base) (\(format.title))", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: written, to: folder.appending(path: written.lastPathComponent))
            try FileManager.default.moveItem(at: media, to: folder.appending(path: "media"))
            return folder
        }
        try FileManager.default.moveItem(at: written, to: output)
        return output
    }

    /// pandoc keeps the source's own folders ("media/media/rId12.png" from Word);
    /// pictures go straight into `media` and the Markdown follows.
    private static func flatten(_ media: URL, referencedIn markdown: URL) throws {
        var text = try String(contentsOf: markdown, encoding: .utf8)
        let files = FileManager.default.enumerator(at: media, includingPropertiesForKeys: [.isRegularFileKey])?
            .compactMap { $0 as? URL }.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true } ?? []
        for file in files where file.deletingLastPathComponent().standardizedFileURL != media.standardizedFileURL {
            let old = "media/" + file.path.dropFirst(media.path.count + 1)
            var name = file.lastPathComponent
            var number = 2
            while FileManager.default.fileExists(atPath: media.appending(path: name).path) {
                name = "\(file.deletingPathExtension().lastPathComponent) \(number).\(file.pathExtension)"
                number += 1
            }
            try FileManager.default.moveItem(at: file, to: media.appending(path: name))
            text = text.replacingOccurrences(of: old, with: "media/" + name)
        }
        for folder in (try? FileManager.default.contentsOfDirectory(at: media, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        where (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            try? FileManager.default.removeItem(at: folder)
        }
        try Data(text.utf8).write(to: markdown)
    }

    static func reader(for ext: String) -> String? {
        switch ext {
        case "md", "markdown": "gfm"
        case "html", "htm": "html"
        case "docx": "docx"
        case "odt": "odt"
        case "epub": "epub"
        case "rtf": "rtf"
        default: nil
        }
    }

    static func writer(for format: Format) -> String? {
        switch format {
        case .docx: "docx"
        case .odt: "odt"
        case .md: "gfm"
        case .html: "html5"
        case .epub: "epub3"
        default: nil
        }
    }
}
