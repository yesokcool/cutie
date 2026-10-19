import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Images through ImageIO: every format macOS reads in, JPG/PNG/HEIC/AVIF/TIFF/
/// BMP/GIF/PDF out, WebP out through `cwebp` when it's installed.
nonisolated enum ImageConverter {
    struct Loaded {
        var image: CGImage
        /// EXIF/GPS/TIFF dictionaries from the source, orientation reset (it's baked in).
        var metadata: [CFString: Any]
        var dpi: Double
    }

    /// Opens an image upright (EXIF orientation applied). SVG and anything
    /// ImageIO can't open go through NSImage.
    static func load(_ url: URL) throws -> Loaded {
        if FileKind.fileExtension(of: url) != "svg",
           let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           CGImageSourceGetCount(source) > 0 {
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
            let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
            let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(width, height),
                kCGImageSourceShouldCacheImmediately: true,
            ]
            let image = max(width, height) > 0
                ? CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
                : CGImageSourceCreateImageAtIndex(source, 0, nil)
            if let image {
                return Loaded(image: image, metadata: portableMetadata(properties),
                              dpi: properties[kCGImagePropertyDPIWidth] as? Double ?? 72)
            }
        }
        guard let image = NSImage(contentsOf: url), image.size.width > 0, image.size.height > 0 else {
            throw CutieError("Couldn't open this image.")
        }
        // Vector art (SVG) is drawn with its long edge at 2048 px.
        let scale = max(1, 2048 / max(image.size.width, image.size.height))
        let width = Int((image.size.width * scale).rounded())
        let height = Int((image.size.height * scale).rounded())
        guard let context = bitmapContext(width: width, height: height, alpha: true) else {
            throw CutieError("Couldn't draw this image.")
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(in: CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        guard let cgImage = context.makeImage() else { throw CutieError("Couldn't draw this image.") }
        return Loaded(image: cgImage, metadata: [:], dpi: 72)
    }

    /// Writes `image` as `format`. WebP needs `cwebp` (see `writeWebP`).
    static func write(_ image: CGImage, as format: Format, to url: URL, quality: Double, metadata: [CFString: Any] = [:], dpi: Double = 72) throws {
        if format == .pdf { return try writePDF([(image, dpi)], to: url) }
        guard let type = format.imageIOType,
              let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw CutieError("Can't write \(format.title) images.")
        }
        var image = image
        if format == .jpg || format == .bmp, hasAlpha(image), let flat = flattened(image) {
            image = flat
        }
        var properties = metadata
        if [.jpg, .heic, .avif].contains(format) {
            properties[kCGImageDestinationLossyCompressionQuality] = quality
        }
        if format == .tiff {
            var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
            tiff[kCGImagePropertyTIFFCompression] = 5 // LZW
            properties[kCGImagePropertyTIFFDictionary] = tiff
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw CutieError("Couldn't write the \(format.title).")
        }
    }

    static func writeWebP(_ image: CGImage, to url: URL, quality: Double, cwebp: URL?, scratch: Scratch) async throws {
        guard let cwebp else { throw CutieError("WebP needs cwebp (brew install webp).") }
        let png = scratch.file(UUID().uuidString + ".png")
        try write(image, as: .png, to: png, quality: 1)
        try await Shell.run(cwebp, ["-quiet", "-q", String(Int(quality * 100)), png.path, "-o", url.path])
    }

    /// One page per image. Pages follow the image's DPI; plain 72-DPI photos are
    /// fitted to an A4-sized page (the pixels are kept, only the page shrinks).
    static func writePDF(_ images: [(CGImage, Double)], to url: URL) throws {
        guard let context = CGContext(url as CFURL, mediaBox: nil, nil) else {
            throw CutieError("Couldn't create the PDF.")
        }
        for (image, dpi) in images {
            var width = Double(image.width) * 72 / max(dpi, 1)
            var height = Double(image.height) * 72 / max(dpi, 1)
            let longest = max(width, height)
            if dpi <= 72, longest > 842 {
                width *= 842 / longest
                height *= 842 / longest
            }
            var box = CGRect(x: 0, y: 0, width: width, height: height)
            context.beginPage(mediaBox: &box)
            context.interpolationQuality = .high
            context.draw(image, in: box)
            context.endPage()
        }
        context.closePDF()
    }

    /// Converts one image file to `format`, keeping its EXIF/GPS metadata.
    static func convert(_ input: URL, to format: Format, at output: URL, context: JobContext, scratch: Scratch) async throws {
        let loaded = try load(input)
        if format == .webp {
            try await writeWebP(loaded.image, to: output, quality: context.imageQuality, cwebp: context.toolbox.cwebp, scratch: scratch)
        } else {
            try write(loaded.image, as: format, to: output, quality: context.imageQuality, metadata: loaded.metadata, dpi: loaded.dpi)
        }
    }

    // MARK: - Helpers

    static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: false
        default: true
        }
    }

    static func bitmapContext(width: Int, height: Int, alpha: Bool) -> CGContext? {
        CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: alpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
        )
    }

    /// Transparent pixels on white, for formats without alpha (JPG, BMP).
    static func flattened(_ image: CGImage) -> CGImage? {
        guard let context = bitmapContext(width: image.width, height: image.height, alpha: false) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(rect)
        context.draw(image, in: rect)
        return context.makeImage()
    }

    /// Keeps camera metadata worth carrying across formats; drops sizes and
    /// orientation, which no longer apply once the pixels are upright.
    static func portableMetadata(_ properties: [CFString: Any]) -> [CFString: Any] {
        var kept: [CFString: Any] = [:]
        for key in [kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary] {
            if let value = properties[key] { kept[key] = value }
        }
        if var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            kept[kCGImagePropertyTIFFDictionary] = tiff
        }
        kept[kCGImagePropertyOrientation] = 1
        return kept
    }

    /// The format a tool writes its result in: the input's own format when
    /// Cutie can write it, PNG otherwise.
    static func outputFormat(for input: URL, toolbox: Toolbox) -> Format {
        let ext = FileKind.fileExtension(of: input)
        guard let format = Format.matching(extension: ext) else { return .png }
        if format == .webp { return toolbox.cwebp == nil ? .png : .webp }
        return format.imageIOType == nil ? .png : format
    }
}
