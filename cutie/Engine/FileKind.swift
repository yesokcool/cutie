import Foundation
import UniformTypeIdentifiers

/// What a dropped file is, which decides what each wheel offers.
nonisolated enum FileKind: String, Sendable, Hashable {
    case image, video, audio, pdf, document, ebook, slides, spreadsheet, subtitle, archive, folder, other

    static func of(_ url: URL) -> FileKind {
        let ext = Self.fileExtension(of: url)
        if let kind = byExtension[ext] { return kind }
        // The first part of a split archive: "photos.7z.001".
        if ext == "001", ["7z", "zip", "rar"].contains(url.deletingPathExtension().pathExtension.lowercased()) {
            return .archive
        }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return .folder
        }
        // Camera raw files and other image types ImageIO reads.
        if let type = UTType(filenameExtension: ext) {
            if type.conforms(to: .image) { return .image }
            if type.conforms(to: .movie) { return .video }
            if type.conforms(to: .audio) { return .audio }
        }
        return .other
    }

    /// The lowercased extension, with compound archive extensions kept whole.
    static func fileExtension(of url: URL) -> String {
        let name = url.lastPathComponent.lowercased()
        for compound in ["tar.gz", "tar.bz2", "tar.xz"] where name.hasSuffix("." + compound) {
            return compound
        }
        return url.pathExtension.lowercased()
    }

    static let byExtension: [String: FileKind] = {
        var map: [String: FileKind] = [:]
        func add(_ kind: FileKind, _ extensions: [String]) { for ext in extensions { map[ext] = kind } }
        add(.image, ["jpg", "jpeg", "png", "gif", "tif", "tiff", "heic", "heif", "avif", "bmp", "webp",
                     "ico", "icns", "psd", "tga", "exr", "jxl", "jp2", "svg", "dng"])
        add(.video, ["mp4", "m4v", "mov", "mkv", "webm", "avi", "wmv", "flv", "mpg", "mpeg", "3gp",
                     "ts", "mts", "m2ts", "ogv"])
        add(.audio, ["mp3", "m4a", "aac", "wav", "flac", "ogg", "oga", "opus", "aif", "aiff", "aifc",
                     "wma", "caf", "amr"])
        add(.pdf, ["pdf"])
        add(.document, ["docx", "doc", "rtf", "rtfd", "txt", "text", "md", "markdown", "html", "htm",
                        "odt", "webarchive", "textclipping", "pages"])
        add(.ebook, ["epub"])
        add(.slides, ["pptx", "ppt", "key", "odp"])
        add(.spreadsheet, ["xlsx", "xls", "csv", "tsv", "ods", "numbers"])
        add(.subtitle, ["srt", "vtt", "ass", "ssa"])
        add(.archive, ["zip", "tar", "gz", "tgz", "tar.gz", "bz2", "tbz", "tbz2", "tar.bz2", "xz", "txz",
                       "tar.xz", "rar", "7z"])
        return map
    }()
}
