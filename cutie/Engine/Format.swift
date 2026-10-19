import Foundation
import UniformTypeIdentifiers

/// A format Cutie can write. Inputs are matched by extension (`FileKind`), so
/// formats Cutie only reads (RAR, XLS, SVG…) don't appear here.
nonisolated enum Format: String, CaseIterable, Sendable, Hashable {
    // Images
    case jpg, png, heic, webp, avif, tiff, bmp, gif, pdf
    // Video
    case mp4, mov, mkv, webm, avi, wmv
    // Audio
    case mp3, m4a, wav, flac, ogg, opus, aiff, wma
    // Documents
    case docx, pages, md, txt, rtf, html, epub, odt
    // Slides
    case pptx, key
    // Spreadsheets
    case xlsx, csv, tsv, ods, numbers
    // Subtitles
    case srt, vtt, ass
    // Archives
    case zip, tar, gzip

    /// The extension written. GZIP is a tarball (a lone file gets `.gz`, see `ArchiveConverter`).
    var fileExtension: String {
        switch self {
        case .gzip: "tar.gz"
        default: rawValue
        }
    }

    var title: String {
        switch self {
        case .jpg: "JPG"
        case .png: "PNG"
        case .heic: "HEIC"
        case .webp: "WebP"
        case .avif: "AVIF"
        case .tiff: "TIFF"
        case .bmp: "BMP"
        case .gif: "GIF"
        case .pdf: "PDF"
        case .mp4: "MP4"
        case .mov: "MOV"
        case .mkv: "MKV"
        case .webm: "WebM"
        case .avi: "AVI"
        case .wmv: "WMV"
        case .mp3: "MP3"
        case .m4a: "M4A"
        case .wav: "WAV"
        case .flac: "FLAC"
        case .ogg: "OGG"
        case .opus: "Opus"
        case .aiff: "AIFF"
        case .wma: "WMA"
        case .docx: "Word"
        case .pages: "Pages"
        case .md: "Markdown"
        case .txt: "Text"
        case .rtf: "RTF"
        case .html: "HTML"
        case .epub: "EPUB"
        case .odt: "ODT"
        case .pptx: "PowerPoint"
        case .key: "Keynote"
        case .xlsx: "Excel"
        case .csv: "CSV"
        case .tsv: "TSV"
        case .ods: "ODS"
        case .numbers: "Numbers"
        case .srt: "SRT"
        case .vtt: "VTT"
        case .ass: "ASS"
        case .zip: "ZIP"
        case .tar: "TAR"
        case .gzip: "GZIP"
        }
    }

    var symbol: String {
        switch self {
        case .jpg, .png, .heic, .webp, .avif, .tiff, .bmp: "photo"
        case .gif: "square.stack.3d.forward.dottedline"
        case .pdf: "doc.richtext"
        case .mp4, .mov, .mkv, .webm, .avi, .wmv: "film"
        case .mp3, .m4a, .wav, .flac, .ogg, .opus, .aiff, .wma: "waveform"
        case .docx, .pages, .rtf, .odt: "doc.text"
        case .md: "text.alignleft"
        case .txt: "doc.plaintext"
        case .html: "chevron.left.forwardslash.chevron.right"
        case .epub: "book"
        case .pptx, .key: "rectangle.on.rectangle"
        case .xlsx, .csv, .tsv, .ods, .numbers: "tablecells"
        case .srt, .vtt, .ass: "captions.bubble"
        case .zip, .tar, .gzip: "archivebox"
        }
    }

    /// The image type ImageIO writes for this format, when it's an image format ImageIO handles.
    var imageIOType: UTType? {
        switch self {
        case .jpg: .jpeg
        case .png: .png
        case .heic: .heic
        case .avif: UTType("public.avif")
        case .tiff: .tiff
        case .bmp: .bmp
        case .gif: .gif
        default: nil
        }
    }

    /// The format an input extension already is, so the wheel doesn't offer "PNG" for a PNG.
    static func matching(extension ext: String) -> Format? {
        switch ext {
        case "jpeg": .jpg
        case "tif": .tiff
        case "heif": .heic
        case "aif", "aifc": .aiff
        case "markdown": .md
        case "text": .txt
        case "htm": .html
        case "tgz", "tar.gz": .gzip
        case "oga": .ogg
        default: Format(rawValue: ext)
        }
    }
}
