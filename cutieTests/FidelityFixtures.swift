import AppKit
import CoreImage
import ImageIO
import PDFKit
import UniformTypeIdentifiers
@testable import cutie

/// Files built to catch quality loss: wide colour, 16-bit, CMYK, HDR,
/// animation, camera metadata, scans and print PDFs. Everything here is invented.
extension Fixtures {
    static let p3 = CGColorSpace(name: CGColorSpace.displayP3)!

    func context(_ width: Int, _ height: Int, space: CGColorSpace = Fixtures.p3, depth: Int = 8, alpha: Bool = false) -> CGContext {
        var info = (alpha ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast).rawValue
        if depth == 16 { info |= CGBitmapInfo.byteOrder16Little.rawValue }
        return CGContext(data: nil, width: width, height: height, bitsPerComponent: depth, bytesPerRow: 0, space: space, bitmapInfo: info)!
    }

    func save(_ image: CGImage, _ name: String, type: UTType, properties: [CFString: Any] = [:], metadata: CGImageMetadata? = nil) -> URL {
        let url = url(name)
        let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
        if let metadata {
            CGImageDestinationAddImageAndMetadata(destination, image, metadata, properties as CFDictionary)
        } else {
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        }
        CGImageDestinationFinalize(destination)
        return url
    }

    /// 1200×800 Display P3 JPEG at 300 DPI, stored sideways (orientation 6), with
    /// EXIF, GPS and XMP (rating, keywords, copyright).
    func cameraJPEG(_ name: String = "camera.jpg") -> URL {
        let context = context(1200, 800)
        context.setFillColor(CGColor(colorSpace: Fixtures.p3, components: [1, 0, 0, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: 600, height: 800))
        context.setFillColor(CGColor(colorSpace: Fixtures.p3, components: [0, 1, 0, 1])!)
        context.fill(CGRect(x: 600, y: 0, width: 600, height: 800))
        let metadata = CGImageMetadataCreateMutable()
        for (path, value) in [("xmp:Rating", 5 as CFNumber), ("dc:rights", "Test Photographer" as CFString),
                              ("tiff:Make", "TestCam" as CFString), ("tiff:Orientation", 6 as CFNumber),
                              ("exif:DateTimeOriginal", "2025-06-01T10:20:30" as CFString),
                              ("exif:GPSLatitude", "45,30.0N" as CFString), ("exif:GPSLongitude", "9,10.0E" as CFString)] as [(String, CFTypeRef)] {
            CGImageMetadataSetValueWithPath(metadata, nil, path as CFString, value)
        }
        CGImageMetadataSetValueWithPath(metadata, nil, "dc:subject" as CFString, ["holiday", "beach"] as CFArray)
        return save(context.makeImage()!, name, type: .jpeg,
                    properties: [kCGImagePropertyDPIWidth: 300, kCGImagePropertyDPIHeight: 300,
                                 kCGImageDestinationLossyCompressionQuality: 0.95],
                    metadata: metadata)
    }

    /// 400×100, 16-bit Display P3 with a transparent band.
    func deepPNG() -> URL {
        let context = context(400, 100, depth: 16, alpha: true)
        let gradient = CGGradient(colorsSpace: Fixtures.p3, colors: [
            CGColor(colorSpace: Fixtures.p3, components: [0, 0.02, 0.05, 1])!,
            CGColor(colorSpace: Fixtures.p3, components: [0.03, 0.06, 0.1, 1])!,
        ] as CFArray, locations: [0, 1])!
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 400, y: 0), options: [])
        context.clear(CGRect(x: 0, y: 0, width: 400, height: 20))
        return save(context.makeImage()!, "deep.png", type: .png)
    }

    func cmykJPEG() -> URL {
        let cmyk = CGColorSpace(name: CGColorSpace.genericCMYK)!
        let context = CGContext(data: nil, width: 300, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                                space: cmyk, bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        context.setFillColor(CGColor(colorSpace: cmyk, components: [0, 1, 1, 0, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: 300, height: 200))
        return save(context.makeImage()!, "print.jpg", type: .jpeg)
    }

    /// A JPEG cut off part way, like an interrupted download.
    func truncatedJPEG() throws -> URL {
        let whole = try Data(contentsOf: cameraJPEG("whole.jpg"))
        let url = url("broken.jpg")
        try whole.prefix(whole.count / 2).write(to: url)
        try FileManager.default.removeItem(at: self.url("whole.jpg"))
        return url
    }

    /// Five 120×120 frames, 0.2 s each, looping forever.
    func animatedGIF() -> URL {
        let url = url("anim.gif")
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, 5, nil)!
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for frame in 0..<5 {
            let context = context(120, 120, space: CGColorSpace(name: CGColorSpace.sRGB)!, alpha: true)
            context.setFillColor(CGColor(red: CGFloat(frame) / 4, green: 0.3, blue: 1 - CGFloat(frame) / 4, alpha: 1))
            context.fill(CGRect(x: frame * 15, y: 30, width: 50, height: 50))
            CGImageDestinationAddImage(destination, context.makeImage()!,
                                       [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.2]] as CFDictionary)
        }
        CGImageDestinationFinalize(destination)
        return url
    }

    /// An HDR scene: grey with a highlight four times brighter than SDR white.
    private func hdrScene() -> CIImage {
        let linear = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
        let context = CGContext(data: nil, width: 400, height: 200, bitsPerComponent: 16, bytesPerRow: 0, space: linear,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue
                                    | CGBitmapInfo.byteOrder16Little.rawValue)!
        context.setFillColor(CGColor(colorSpace: linear, components: [0.2, 0.2, 0.2, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 200))
        context.setFillColor(CGColor(colorSpace: linear, components: [4, 4, 3.5, 1])!)
        context.fill(CGRect(x: 150, y: 50, width: 100, height: 100))
        return CIImage(cgImage: context.makeImage()!)
    }

    /// An iPhone-style HDR photo: SDR HEIC plus a gain map.
    func gainMapHEIC() throws -> URL {
        let url = url("bright.heic")
        let scene = hdrScene()
        let sdr = scene.applyingFilter("CIToneMapHeadroom", parameters: ["inputSourceHeadroom": 4.0, "inputTargetHeadroom": 1.0])
        try CIContext().writeHEIFRepresentation(of: sdr, to: url, format: .RGBA8, colorSpace: Fixtures.p3,
                                                options: [CIImageRepresentationOption.hdrImage: scene])
        return url
    }

    /// A 10-bit PQ (HDR10) HEIC.
    func pqHEIC() throws -> URL {
        let url = url("hdr10.heic")
        try CIContext().writeHEIF10Representation(of: hdrScene(), to: url, colorSpace: CGColorSpace(name: CGColorSpace.itur_2100_PQ)!)
        return url
    }

    /// Text in two columns, three lines each.
    func twoColumnImage() throws -> URL {
        let image = NSImage(size: CGSize(width: 1600, height: 500), flipped: true) { rect in
            NSColor.white.setFill()
            rect.fill()
            let font = NSFont.systemFont(ofSize: 36)
            for (index, line) in Fixtures.leftColumn.enumerated() {
                (line as NSString).draw(at: CGPoint(x: 60, y: 100 + index * 60), withAttributes: [.font: font])
            }
            for (index, line) in Fixtures.rightColumn.enumerated() {
                (line as NSString).draw(at: CGPoint(x: 860, y: 100 + index * 60), withAttributes: [.font: font])
            }
            return true
        }
        return save(image.cgImage(forProposedRect: nil, context: nil, hints: nil)!, "columns.png", type: .png)
    }

    static let leftColumn = ["Alpha one starts the left column", "Alpha two continues on the left", "Alpha three ends the left column"]
    static let rightColumn = ["Beta one starts the right column", "Beta two continues on the right", "Beta three ends the right column"]

    /// A blurred-noise "photo", the kind of image compression has to work on.
    func noisePhoto(_ name: String = "noise.jpg", width: Int = 2400, height: Int = 1800) -> URL {
        let noise = CIFilter(name: "CIRandomGenerator")!.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        let photo = noise.applyingGaussianBlur(sigma: 1.5).cropped(to: noise.extent)
        let image = CIContext().createCGImage(photo, from: photo.extent)!
        return save(image, name, type: .jpeg, properties: [kCGImageDestinationLossyCompressionQuality: 0.95])
    }

    /// A print PDF: 700×900 media box with a 612×792 crop box, a red crop mark
    /// outside it, three titled pages with bookmarks, a link, title and author.
    func printPDF(_ name: String = "brochure.pdf", photo: URL? = nil) throws -> URL {
        let url = url(name)
        var media = CGRect(x: 0, y: 0, width: 700, height: 900)
        let context = CGContext(url as CFURL, mediaBox: &media, nil)!
        let image = photo.flatMap { CGImageSourceCreateWithURL($0 as CFURL, nil) }.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
        for page in 1...3 {
            context.beginPDFPage(nil)
            context.setFillColor(NSColor.red.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            ("Chapter \(page) heading" as NSString).draw(at: CGPoint(x: 80, y: 780), withAttributes: [.font: NSFont.systemFont(ofSize: 24)])
            NSGraphicsContext.restoreGraphicsState()
            if let image { context.draw(image, in: CGRect(x: 80, y: 100, width: 533, height: 400)) }
            context.endPDFPage()
        }
        context.closePDF()
        let document = PDFConverter.rebuilt(PDFDocument(url: url)!)
        let root = PDFOutline()
        for index in 0..<3 {
            let page = document.page(at: index)!
            page.setBounds(CGRect(x: 44, y: 54, width: 612, height: 792), for: .cropBox)
            let item = PDFOutline()
            item.label = "Chapter \(index + 1)"
            item.destination = PDFDestination(page: page, at: CGPoint(x: 44, y: 846))
            root.insertChild(item, at: index)
        }
        document.outlineRoot = root
        let link = PDFAnnotation(bounds: CGRect(x: 80, y: 760, width: 200, height: 20), forType: .link, withProperties: nil)
        link.url = URL(string: "https://example.com")
        document.page(at: 0)!.addAnnotation(link)
        document.documentAttributes = [PDFDocumentAttribute.titleAttribute: "Brochure", PDFDocumentAttribute.authorAttribute: "Test Author"]
        document.write(to: url)
        return url
    }

    /// A PDF whose second page is a picture of text (a scan), the first typed.
    /// With `typedFirst: false`, both pages are scans. `turned` stores the scans
    /// sideways with a 90° page rotation, as some scanners do; they still show upright.
    func scannedPDF(_ name: String = "scan.pdf", typedFirst: Bool = true, turned: Bool = false) throws -> URL {
        let url = url(name)
        let portrait = CGRect(x: 0, y: 0, width: 612, height: 792)
        var media = turned ? CGRect(x: 0, y: 0, width: 792, height: 612) : portrait
        let context = CGContext(url as CFURL, mediaBox: &media, nil)!
        for page in 1...2 {
            context.beginPDFPage(nil)
            if page == 1 && typedFirst {
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
                ("Typed first page" as NSString).draw(at: CGPoint(x: 72, y: 700), withAttributes: [.font: NSFont.systemFont(ofSize: 24)])
                NSGraphicsContext.restoreGraphicsState()
            } else {
                let scan = NSImage(size: CGSize(width: 2550, height: 3300), flipped: true) { rect in
                    NSColor.white.setFill()
                    rect.fill()
                    ("Scanned page \(page) says hello" as NSString).draw(at: CGPoint(x: 300, y: 400), withAttributes: [.font: NSFont.systemFont(ofSize: 110)])
                    return true
                }
                context.saveGState()
                if turned { context.concatenate(CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 792, ty: 0)) }
                context.draw(scan.cgImage(forProposedRect: nil, context: nil, hints: nil)!, in: portrait)
                context.restoreGState()
            }
            context.endPDFPage()
        }
        context.closePDF()
        if turned {
            let document = PDFDocument(url: url)!
            for index in 0..<document.pageCount { document.page(at: index)!.rotation = 90 }
            document.write(to: url)
        }
        return url
    }
}
