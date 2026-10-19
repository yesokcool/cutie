import Foundation

/// Decides which slices each wheel shows for the files being dragged. Pure, so
/// it's tested directly; what's offered depends on the helpers in `Toolbox`.
nonisolated enum Catalog {
    /// Video AVFoundation opens itself (anything else goes through ffmpeg).
    static let nativeVideo: Set<String> = ["mp4", "m4v", "mov", "3gp"]
    /// Audio AVAudioFile reads on macOS 26+ (Ogg Opus included, checked 2026-10-18).
    static let nativeAudio: Set<String> = ["mp3", "m4a", "aac", "wav", "flac", "aif", "aiff", "aifc", "caf", "ogg", "opus", "amr"]
    /// Documents NSAttributedString (or Cutie's own readers) open without Pages.
    static let nativeDocuments: Set<String> = ["docx", "doc", "rtf", "rtfd", "txt", "text", "md", "markdown", "html", "htm", "odt", "webarchive", "textclipping"]
    static let nativeSpreadsheets: Set<String> = ["xlsx", "csv", "tsv", "ods"]

    static func items(for inputs: [URL], wheel: Wheel, toolbox: Toolbox) -> [WheelItem] {
        guard !inputs.isEmpty else { return [] }
        switch wheel {
        case .convert: return conversions(for: inputs, toolbox: toolbox).map(WheelItem.convert)
        case .tools: return tools(for: inputs, toolbox: toolbox).map(WheelItem.tool)
        case .actions: return FileAction.allCases.map(WheelItem.action)
        }
    }

    // MARK: - Convert

    static func conversions(for inputs: [URL], toolbox: Toolbox) -> [Format] {
        let kinds = Set(inputs.map(FileKind.of))
        let extensions = inputs.map(FileKind.fileExtension(of:))
        guard kinds.count == 1, let kind = kinds.first else { return [.zip, .tar, .gzip] }

        var formats: [Format]
        switch kind {
        case .image:
            formats = [.jpg, .png, .heic, .pdf, .webp, .avif, .tiff, .gif, .bmp]
            if toolbox.cwebp == nil { formats.removeAll { $0 == .webp } }
        case .video:
            let native = extensions.allSatisfy(nativeVideo.contains)
            guard native || toolbox.ffmpeg != nil else { return [] }
            formats = [.mp4, .mov, .gif, .mp3, .m4a, .mkv, .webm, .avi, .wmv]
            if toolbox.ffmpeg == nil { formats = [.mp4, .mov, .gif, .m4a] }
        case .audio:
            let native = extensions.allSatisfy(nativeAudio.contains)
            if toolbox.ffmpeg != nil {
                formats = [.mp3, .m4a, .wav, .flac, .aiff, .ogg, .opus, .wma]
            } else if native {
                formats = [.m4a, .wav, .flac, .aiff]
            } else {
                return []
            }
        case .pdf:
            formats = [.docx, .txt, .md, .jpg, .png, .epub, .rtf, .html, .pptx]
            if toolbox.pages != nil { formats.insert(.pages, at: 1) }
        case .document:
            let native = extensions.allSatisfy(nativeDocuments.contains)
            guard native || toolbox.pages != nil else { return [] }
            formats = [.docx, .pdf, .md, .txt, .rtf, .html, .epub, .odt]
            if toolbox.pages != nil { formats.insert(.pages, at: 1) }
        case .ebook:
            formats = [.pdf, .docx, .md, .txt, .html, .rtf]
        case .slides:
            // Keynote opens everything; LibreOffice everything but Keynote's own files.
            let libreOffice = toolbox.soffice != nil && !extensions.contains("key")
            guard toolbox.keynote != nil || libreOffice else { return [] }
            formats = [.pdf, .pptx, .key, .jpg, .png]
            if toolbox.keynote == nil { formats.removeAll { $0 == .key } }
        case .spreadsheet:
            let native = extensions.allSatisfy(nativeSpreadsheets.contains)
            let libreOffice = toolbox.soffice != nil && !extensions.contains("numbers")
            guard native || toolbox.numbers != nil || libreOffice else { return [] }
            formats = [.xlsx, .csv, .pdf, .tsv, .ods]
            if toolbox.numbers != nil { formats.append(.numbers) }
        case .subtitle:
            formats = [.srt, .vtt, .txt]
        case .archive, .folder, .other:
            formats = [.zip, .tar, .gzip]
        }

        // Don't offer what every input already is.
        let current = Set(extensions.compactMap(Format.matching(extension:)))
        if current.count == 1, let only = current.first, kind != .folder {
            formats.removeAll { $0 == only }
        }
        return formats
    }

    // MARK: - Tools

    static func tools(for inputs: [URL], toolbox: Toolbox) -> [Tool] {
        let kinds = Set(inputs.map(FileKind.of))
        let extensions = inputs.map(FileKind.fileExtension(of:))
        let many = inputs.count > 1
        let regularFiles = !kinds.contains(.folder)
        var tools: [Tool] = []

        if kinds.count == 1, let kind = kinds.first {
            switch kind {
            case .image:
                let lossy: Set<String> = ["jpg", "jpeg", "heic", "heif", "avif", "tif", "tiff"]
                if extensions.allSatisfy(lossy.contains) { tools.append(.compressImage) }
                tools += [.resizeImage, .rotateImage, .flipImage, .cropSquare, .grayscale,
                          .removeBackground, .extractText, .stripMetadata]
                if many { tools.append(.combineToPDF) }
            case .pdf:
                tools += [.compressPDF, .splitPDF, .rotatePDF, .makeSearchable]
                if many { tools.append(.mergePDFs) }
            case .video:
                let native = extensions.allSatisfy(nativeVideo.contains)
                let ffmpeg = toolbox.ffmpeg != nil
                if native || ffmpeg {
                    tools.append(.compressVideo)
                    if native && !many { tools.append(.trimMedia) }
                    tools += [.muteVideo, .extractAudio, .rotateVideo, .resizeVideo, .snapshot]
                }
            case .audio:
                let native = extensions.allSatisfy(nativeAudio.contains)
                if native && !many { tools.append(.trimMedia) }
                if native || toolbox.ffmpeg != nil { tools.append(.compressAudio) }
                if toolbox.ffmpeg != nil { tools.append(.normalizeAudio) }
                if native && many { tools.append(.mergeAudio) }
            case .document, .ebook, .subtitle:
                tools.append(.wordCount)
            case .archive:
                tools.append(.extract)
            case .slides, .spreadsheet, .folder, .other:
                break
            }
        }

        if !(kinds == [.archive]) { tools.append(.zip) }
        if regularFiles { tools.append(.checksum) }
        return tools
    }
}
