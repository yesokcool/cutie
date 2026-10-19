import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Images through ImageIO: every format macOS reads in, JPG/PNG/HEIC/AVIF/TIFF/
/// BMP/GIF/PDF out, WebP out through `cwebp` when it's installed.
///
/// Pixels keep their colour space and bit depth (Display P3, 16-bit, CMYK) all
/// the way through; HDR photos keep their gain map in formats that hold one and
/// are tone-mapped for the rest; animations keep every frame.
nonisolated enum ImageConverter {
    struct Loaded {
        /// Upright: the EXIF orientation is applied.
        var image: CGImage
        /// EXIF, GPS, IPTC and XMP from the source, orientation reset (it's baked in).
        var metadata: CGImageMetadata?
        var dpi: CGSize
        /// The image is HDR (decoded for a gain map) rather than its SDR rendition.
        var isHDR = false
    }

    struct Animation {
        var frames: [CGImage]
        /// Seconds each frame shows.
        var delays: [Double]
        /// 0 loops forever.
        var loopCount: Int
    }

    /// Formats that carry an HDR gain map beside their SDR image (checked on macOS 27).
    static let gainMapFormats: Set<Format> = [.jpg, .heic, .avif]
    /// Formats Cutie writes as animations.
    static let animatedFormats: Set<Format> = [.gif, .png, .webp]

    // MARK: - Reading

    /// Opens an image file for reading, refusing one that was cut off.
    static func source(_ url: URL) throws -> CGImageSource {
        try FileIntegrity.checkImage(url)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 else {
            throw CutieError("Couldn't open this image.")
        }
        return source
    }

    /// Opens an image upright. `keepHDR` decodes an HDR photo as HDR (for a
    /// format that keeps a gain map); otherwise HDR is tone-mapped to SDR.
    /// SVG and anything ImageIO can't open go through NSImage.
    static func load(_ url: URL, keepHDR: Bool = false) throws -> Loaded {
        if FileKind.fileExtension(of: url) != "svg" {
            try FileIntegrity.checkImage(url)
            if let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 {
                return try load(from: source, keepHDR: keepHDR)
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
        return Loaded(image: cgImage, metadata: nil, dpi: CGSize(width: 72, height: 72))
    }

    static func load(from source: CGImageSource, index: Int = 0, keepHDR: Bool) throws -> Loaded {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
        let hdr = isHDR(source, index: index)
        var options: [CFString: Any] = [:]
        if hdr {
            options[kCGImageSourceDecodeRequest] = keepHDR ? kCGImageSourceDecodeToHDR : kCGImageSourceDecodeToSDR
        }
        guard let decoded = CGImageSourceCreateImageAtIndex(source, index, options as CFDictionary) else {
            throw CutieError("Couldn't open this image.")
        }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        let image = orientation == 1 ? decoded : try upright(decoded, orientation: orientation)
        let dpiX = properties[kCGImagePropertyDPIWidth] as? Double ?? 72
        let dpiY = properties[kCGImagePropertyDPIHeight] as? Double ?? dpiX
        return Loaded(image: image, metadata: portableMetadata(source, index: index),
                      dpi: CGSize(width: dpiX, height: dpiY), isHDR: hdr && keepHDR)
    }

    /// An HDR photo: a gain map beside the SDR image, or HDR (PQ/HLG) pixels.
    static func isHDR(_ source: CGImageSource, index: Int = 0) -> Bool {
        for type in [kCGImageAuxiliaryDataTypeISOGainMap, kCGImageAuxiliaryDataTypeHDRGainMap] {
            if CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, index, type) != nil { return true }
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
        if let depth = properties[kCGImagePropertyDepth] as? Int, depth > 8,
           let image = CGImageSourceCreateImageAtIndex(source, index, nil),
           let space = image.colorSpace, CGColorSpaceUsesITUR_2100TF(space) {
            return true
        }
        return false
    }

    /// Every frame of an animated GIF, PNG, WebP or HEIC sequence; nil for a still.
    static func animation(_ url: URL) throws -> Animation? {
        guard FileKind.fileExtension(of: url) != "svg",
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 1,
              let type = CGImageSourceGetType(source).flatMap({ UTType($0 as String) }),
              [UTType.gif, .png, .webP, UTType("public.heics")].contains(type) else { return nil }
        try FileIntegrity.checkImage(url)
        var animation = Animation(frames: [], delays: [], loopCount: 0)
        let container = CGImageSourceCopyProperties(source, nil) as? [CFString: Any] ?? [:]
        animation.loopCount = loopCount(in: container)
        for index in 0..<CGImageSourceGetCount(source) {
            guard let frame = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
            animation.frames.append(frame)
            animation.delays.append(delay(in: properties))
        }
        return animation.frames.count > 1 ? animation : nil
    }

    /// Per container: where frame delays (unclamped first) and the loop count live.
    private static var frameKeys: [(CFString, [CFString], CFString)] {
        [
            (kCGImagePropertyGIFDictionary, [kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime], kCGImagePropertyGIFLoopCount),
            (kCGImagePropertyPNGDictionary, [kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime], kCGImagePropertyAPNGLoopCount),
            (kCGImagePropertyWebPDictionary, [kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime], kCGImagePropertyWebPLoopCount),
            (kCGImagePropertyHEICSDictionary, [kCGImagePropertyHEICSUnclampedDelayTime, kCGImagePropertyHEICSDelayTime], kCGImagePropertyHEICSLoopCount),
        ]
    }

    private static func delay(in properties: [CFString: Any]) -> Double {
        for (dictionary, keys, _) in frameKeys {
            guard let values = properties[dictionary] as? [CFString: Any] else { continue }
            for key in keys {
                if let delay = values[key] as? Double, delay > 0 { return delay }
            }
        }
        return 0.1
    }

    private static func loopCount(in properties: [CFString: Any]) -> Int {
        for (dictionary, _, key) in frameKeys {
            if let count = (properties[dictionary] as? [CFString: Any])?[key] as? Int { return count }
        }
        return 0
    }

    // MARK: - Writing

    /// Writes `image` as `format`. WebP needs `cwebp` (see `writeWebP`). With
    /// `hdr`, the image is HDR and gets a gain map (JPG/HEIC/AVIF).
    static func write(_ image: CGImage, as format: Format, to url: URL, quality: Double,
                      metadata: CGImageMetadata? = nil, dpi: CGSize? = nil, hdr: Bool = false) throws {
        if format == .pdf { return try writePDF([(image, dpi ?? CGSize(width: 72, height: 72))], to: url) }
        guard let type = format.imageIOType,
              let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw CutieError("Can't write \(format.title) images.")
        }
        var image = image
        if image.colorSpace?.model == .cmyk, ![.jpg, .tiff].contains(format) {
            image = try converted(image, to: CGColorSpace(name: CGColorSpace.sRGB)!)
        }
        if format == .jpg || format == .bmp, hasAlpha(image) {
            image = try flattened(image)
        }
        var properties: [CFString: Any] = [:]
        if [.jpg, .heic, .avif].contains(format) {
            properties[kCGImageDestinationLossyCompressionQuality] = quality
        }
        if format == .tiff {
            properties[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFCompression: 5] // LZW
        }
        if let dpi, dpi.width > 0, dpi.height > 0 {
            properties[kCGImagePropertyDPIWidth] = dpi.width
            properties[kCGImagePropertyDPIHeight] = dpi.height
        }
        if hdr, gainMapFormats.contains(format) {
            properties[kCGImageDestinationEncodeRequest] = kCGImageDestinationEncodeToISOGainmap
        }
        // GIF and BMP have nowhere to keep camera metadata.
        if let metadata, ![.gif, .bmp].contains(format) {
            CGImageDestinationAddImageAndMetadata(destination, image, metadata, properties as CFDictionary)
        } else {
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else {
            throw CutieError("Couldn't write the \(format.title).")
        }
    }

    static func write(_ loaded: Loaded, as format: Format, to url: URL, quality: Double) throws {
        try write(loaded.image, as: format, to: url, quality: quality, metadata: loaded.metadata, dpi: loaded.dpi, hdr: loaded.isHDR)
    }

    /// WebP through `cwebp`: lossless for lossless sources, ICC profile and EXIF kept.
    static func writeWebP(_ image: CGImage, to url: URL, quality: Double, lossless: Bool = false,
                          metadata: CGImageMetadata? = nil, cwebp: URL?, scratch: Scratch) async throws {
        guard let cwebp else { throw CutieError("WebP needs cwebp (brew install webp).") }
        let png = scratch.file(UUID().uuidString + ".png")
        try write(eightBit(image), as: .png, to: png, quality: 1, metadata: metadata)
        var arguments = ["-quiet", "-metadata", "all"]
        arguments += lossless ? ["-lossless", "-exact"] : ["-q", String(Int(quality * 100))]
        try await Shell.run(cwebp, arguments + [png.path, "-o", url.path])
    }

    /// Writes every frame as an animated GIF, PNG (APNG) or WebP (`img2webp`).
    static func writeAnimation(_ animation: Animation, as format: Format, to url: URL, quality: Double,
                               lossless: Bool, toolbox: Toolbox, scratch: Scratch) async throws {
        if format == .webp {
            guard let img2webp = toolbox.img2webp else { throw CutieError("Animated WebP needs img2webp (brew install webp).") }
            var arguments = ["-loop", String(animation.loopCount)]
            arguments += lossless ? ["-lossless"] : ["-lossy", "-q", String(Int(quality * 100))]
            for (index, frame) in animation.frames.enumerated() {
                let png = scratch.file("\(UUID().uuidString).png")
                try write(eightBit(frame), as: .png, to: png, quality: 1)
                arguments += ["-d", String(Int((animation.delays[index] * 1000).rounded())), png.path]
            }
            try await Shell.run(img2webp, arguments + ["-o", url.path])
            return
        }
        guard let type = format.imageIOType,
              let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, animation.frames.count, nil) else {
            throw CutieError("Can't write animated \(format.title) images.")
        }
        let (dictionary, delayKey, loopKey) = format == .gif
            ? (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFDelayTime, kCGImagePropertyGIFLoopCount)
            : (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGDelayTime, kCGImagePropertyAPNGLoopCount)
        CGImageDestinationSetProperties(destination, [dictionary: [loopKey: animation.loopCount]] as CFDictionary)
        for (index, frame) in animation.frames.enumerated() {
            CGImageDestinationAddImage(destination, frame, [dictionary: [delayKey: animation.delays[index]]] as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else {
            throw CutieError("Couldn't write the animated \(format.title).")
        }
    }

    /// One page per image. Pages follow the image's DPI; plain 72-DPI photos are
    /// fitted to an A4-sized page (the pixels are kept, only the page shrinks).
    static func writePDF(_ images: [(CGImage, CGSize)], to url: URL) throws {
        guard let context = CGContext(url as CFURL, mediaBox: nil, nil) else {
            throw CutieError("Couldn't create the PDF.")
        }
        for (image, dpi) in images {
            var box = CGRect(origin: .zero, size: pageSize(width: image.width, height: image.height, dpi: dpi))
            context.beginPage(mediaBox: &box)
            context.interpolationQuality = .high
            context.draw(image, in: box)
            context.endPage()
        }
        context.closePDF()
    }

    /// One page per image file. A JPEG goes into the PDF as it is (no
    /// re-encoding); HEIC, AVIF and WebP become JPEG at `quality` (a PDF can't
    /// hold them); lossless images stay lossless.
    static func writePDF(from files: [URL], to url: URL, quality: Double) throws {
        guard let context = CGContext(url as CFURL, mediaBox: nil, nil) else {
            throw CutieError("Couldn't create the PDF.")
        }
        for file in files {
            try Task.checkCancellation()
            let ext = FileKind.fileExtension(of: file)
            var image: CGImage
            var orientation = 1
            var dpi = CGSize(width: 72, height: 72)
            if ext != "svg", let source = CGImageSourceCreateWithURL(file as CFURL, nil), CGImageSourceGetCount(source) > 0 {
                try FileIntegrity.checkImage(file)
                let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
                orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
                dpi.width = properties[kCGImagePropertyDPIWidth] as? Double ?? 72
                dpi.height = properties[kCGImagePropertyDPIHeight] as? Double ?? dpi.width
                let decode: [CFString: Any] = isHDR(source) ? [kCGImageSourceDecodeRequest: kCGImageSourceDecodeToSDR] : [:]
                guard let decoded = CGImageSourceCreateImageAtIndex(source, 0, decode as CFDictionary) else {
                    throw CutieError("Couldn't open \(file.lastPathComponent).")
                }
                // ImageIO keeps a JPEG's compressed data with the image, and Quartz
                // writes that straight into the PDF; other lossy formats become JPEG first.
                image = ["heic", "heif", "avif", "webp"].contains(ext) && !hasAlpha(decoded)
                    ? try jpegBacked(decoded, quality: quality) : decoded
            } else {
                image = try load(file).image
            }
            let turned = [5, 6, 7, 8].contains(orientation)
            let size = pageSize(width: turned ? image.height : image.width, height: turned ? image.width : image.height,
                                dpi: turned ? CGSize(width: dpi.height, height: dpi.width) : dpi)
            var box = CGRect(origin: .zero, size: size)
            context.beginPage(mediaBox: &box)
            context.interpolationQuality = .high
            context.concatenate(orientationTransform(orientation, displaySize: size))
            let drawn = turned ? CGSize(width: size.height, height: size.width) : size
            context.draw(image, in: CGRect(origin: .zero, size: drawn))
            context.endPage()
        }
        context.closePDF()
    }

    static func pageSize(width: Int, height: Int, dpi: CGSize) -> CGSize {
        var size = CGSize(width: Double(width) * 72 / max(dpi.width, 1), height: Double(height) * 72 / max(dpi.height, 1))
        let longest = max(size.width, size.height)
        if max(dpi.width, dpi.height) <= 72, longest > 842 {
            size.width *= 842 / longest
            size.height *= 842 / longest
        }
        return size
    }

    /// Converts one image file to `format`, keeping its metadata, colour, depth,
    /// HDR (where the format allows) and animation.
    static func convert(_ input: URL, to format: Format, at output: URL, context: JobContext, scratch: Scratch) async throws {
        let lossless = isLossless(input)
        if animatedFormats.contains(format), format != .webp || context.toolbox.img2webp != nil,
           let animation = try animation(input) {
            return try await writeAnimation(animation, as: format, to: output, quality: context.imageQuality,
                                            lossless: lossless, toolbox: context.toolbox, scratch: scratch)
        }
        if format == .pdf {
            return try writePDF(from: [input], to: output, quality: context.imageQuality)
        }
        let loaded = try load(input, keepHDR: gainMapFormats.contains(format))
        if format == .webp {
            try await writeWebP(loaded.image, to: output, quality: context.imageQuality, lossless: lossless,
                                metadata: loaded.metadata, cwebp: context.toolbox.cwebp, scratch: scratch)
        } else {
            try write(loaded, as: format, to: output, quality: context.imageQuality)
        }
    }

    // MARK: - Lossless edits

    /// Rotates, mirrors or strips a JPEG without re-encoding it: only the
    /// orientation tag or the metadata changes, the compressed image is copied
    /// as is. Returns false when the format doesn't allow it (the caller
    /// re-encodes instead).
    static func losslessEdit(_ input: URL, to output: URL, turn: OrientationChange?, stripMetadata: Bool) throws -> Bool {
        guard ["jpg", "jpeg"].contains(FileKind.fileExtension(of: input)) else { return false }
        let source = try source(input)
        guard let type = CGImageSourceGetType(source),
              let destination = CGImageDestinationCreateWithURL(output as CFURL, type, 1, nil) else { return false }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let current = properties[kCGImagePropertyOrientation] as? Int ?? 1
        let orientation = turn.map { $0.applied(to: current) } ?? current
        var options: [CFString: Any]
        if stripMetadata {
            // Only the orientation survives, so the photo still shows the right way up.
            let metadata = CGImageMetadataCreateMutable()
            CGImageMetadataSetValueMatchingImageProperty(metadata, kCGImagePropertyTIFFDictionary,
                                                         kCGImagePropertyTIFFOrientation, orientation as CFNumber)
            options = [kCGImageDestinationMetadata: metadata, kCGImageDestinationMergeMetadata: false,
                       kCGImageMetadataShouldExcludeGPS: true]
        } else {
            options = [kCGImageDestinationOrientation: orientation, kCGImageDestinationMergeMetadata: true]
        }
        return CGImageDestinationCopyImageSource(destination, source, options as CFDictionary, nil)
    }

    /// A quarter turn clockwise or a left-right mirror, applied on top of an
    /// EXIF orientation (1–8). Orientations are modelled as "mirror first, then
    /// turn clockwise by a multiple of 90°".
    enum OrientationChange {
        case turnClockwise, mirror

        private static let table: [(mirrored: Bool, degrees: Int)] = [
            (false, 0), (true, 0), (false, 180), (true, 180), (true, 270), (false, 90), (true, 90), (false, 270),
        ]

        func applied(to orientation: Int) -> Int {
            let (mirrored, degrees) = Self.table[max(1, min(8, orientation)) - 1]
            let result = switch self {
            case .turnClockwise: (mirrored: mirrored, degrees: (degrees + 90) % 360)
            case .mirror: (mirrored: !mirrored, degrees: (360 - degrees) % 360)
            }
            return Self.table.firstIndex { $0 == result }! + 1
        }
    }

    // MARK: - Helpers

    static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: false
        default: true
        }
    }

    /// Lossless sources get lossless WebP; photos get lossy.
    static func isLossless(_ url: URL) -> Bool {
        ["png", "tif", "tiff", "gif", "bmp"].contains(FileKind.fileExtension(of: url))
    }

    static func bitmapContext(width: Int, height: Int, alpha: Bool) -> CGContext? {
        CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: alpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
        )
    }

    /// A drawing surface that matches `image`: same colour space, same bit
    /// depth (8, 16 or half-float), so a rotate or resize changes nothing else.
    /// Falls back to 16- then 8-bit sRGB for spaces Quartz can't draw into.
    static func bitmapContext(like image: CGImage, width: Int, height: Int, alpha: Bool? = nil) -> CGContext? {
        let alpha = alpha ?? hasAlpha(image)
        var space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        if space.model == .indexed { space = space.baseColorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)! }
        let float = image.bitmapInfo.contains(.floatComponents)
        let depth = float ? 16 : (image.bitsPerComponent > 8 ? 16 : 8)
        let alphaInfo = alpha ? CGImageAlphaInfo.premultipliedLast : (space.model == .rgb ? .noneSkipLast : .none)
        var info = alphaInfo.rawValue
        if depth == 16 { info |= CGBitmapInfo.byteOrder16Little.rawValue }
        if float { info |= CGBitmapInfo.floatComponents.rawValue }

        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        let rgbAlpha = (alpha ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast).rawValue
        let attempts: [(CGColorSpace, Int, UInt32)] = [
            (space, depth, info),
            (srgb, 16, rgbAlpha | CGBitmapInfo.byteOrder16Little.rawValue),
            (srgb, 8, rgbAlpha),
        ]
        for (space, depth, info) in attempts {
            if let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: depth,
                                       bytesPerRow: 0, space: space, bitmapInfo: info) {
                return context
            }
        }
        return nil
    }

    /// Redraws `image` with `body` on a matching surface of the given size.
    static func redraw(_ image: CGImage, width: Int, height: Int, alpha: Bool? = nil, _ body: (CGContext) -> Void) throws -> CGImage {
        guard let context = bitmapContext(like: image, width: width, height: height, alpha: alpha) else {
            throw CutieError("Couldn't draw this image.")
        }
        context.interpolationQuality = .high
        body(context)
        guard let result = context.makeImage() else { throw CutieError("Couldn't draw this image.") }
        return result
    }

    /// Applies an EXIF orientation (1–8) to the pixels.
    static func upright(_ image: CGImage, orientation: Int) throws -> CGImage {
        let turned = [5, 6, 7, 8].contains(orientation)
        let size = CGSize(width: turned ? image.height : image.width, height: turned ? image.width : image.height)
        return try redraw(image, width: Int(size.width), height: Int(size.height)) { context in
            context.concatenate(orientationTransform(orientation, displaySize: size))
            let drawn = turned ? CGSize(width: size.height, height: size.width) : size
            context.draw(image, in: CGRect(origin: .zero, size: drawn))
        }
    }

    /// Maps the stored image (drawn at the origin, un-rotated) onto a display
    /// area of `displaySize`, in Quartz's bottom-up coordinates.
    static func orientationTransform(_ orientation: Int, displaySize size: CGSize) -> CGAffineTransform {
        let (w, h) = (size.width, size.height)
        switch orientation {
        case 2: return CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: w, ty: 0)
        case 3: return CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h)
        case 4: return CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: h)
        case 5: return CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: w, ty: h)
        case 6: return CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: h)
        case 7: return CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
        case 8: return CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: w, ty: 0)
        default: return .identity
        }
    }

    /// Transparent pixels on white, for formats without alpha (JPG, BMP).
    static func flattened(_ image: CGImage) throws -> CGImage {
        try redraw(image, width: image.width, height: image.height, alpha: false) { context in
            let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(rect)
            context.draw(image, in: rect)
        }
    }

    static func converted(_ image: CGImage, to space: CGColorSpace) throws -> CGImage {
        let depth = image.bitsPerComponent > 8 ? 16 : 8
        var info = (hasAlpha(image) ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast).rawValue
        if depth == 16 { info |= CGBitmapInfo.byteOrder16Little.rawValue }
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: depth,
                                      bytesPerRow: 0, space: space, bitmapInfo: info) else {
            throw CutieError("Couldn't convert this image's colours.")
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let result = context.makeImage() else { throw CutieError("Couldn't convert this image's colours.") }
        return result
    }

    /// 8-bit in the same colour space, for tools that only read 8-bit files (cwebp, img2webp).
    static func eightBit(_ image: CGImage) throws -> CGImage {
        guard image.bitsPerComponent > 8 || image.colorSpace?.model == .cmyk else { return image }
        let space = image.colorSpace?.model == .rgb ? image.colorSpace! : CGColorSpace(name: CGColorSpace.sRGB)!
        let info = (hasAlpha(image) ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast).rawValue
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space, bitmapInfo: info) else { return image }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage() ?? image
    }

    /// The same picture, compressed as JPEG, so a PDF can carry it as JPEG.
    static func jpegBacked(_ image: CGImage, quality: Double) throws -> CGImage {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CutieError("Couldn't compress this image.")
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination),
              let source = CGImageSourceCreateWithData(data, nil),
              let jpeg = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw CutieError("Couldn't compress this image.")
        }
        return jpeg
    }

    /// All of the source's metadata (EXIF, GPS, IPTC, XMP) except what no
    /// longer applies once the pixels are upright and maybe resized.
    static func portableMetadata(_ source: CGImageSource, index: Int) -> CGImageMetadata? {
        guard let original = CGImageSourceCopyMetadataAtIndex(source, index, nil),
              let metadata = CGImageMetadataCreateMutableCopy(original) else { return nil }
        CGImageMetadataSetValueMatchingImageProperty(metadata, kCGImagePropertyTIFFDictionary,
                                                     kCGImagePropertyTIFFOrientation, 1 as CFNumber)
        for path in ["exif:PixelXDimension", "exif:PixelYDimension", "tiff:ImageWidth", "tiff:ImageLength"] {
            CGImageMetadataRemoveTagWithPath(metadata, nil, path as CFString)
        }
        return metadata
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
