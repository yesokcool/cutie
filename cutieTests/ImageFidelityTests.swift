import AppKit
import ImageIO
import PDFKit
import Testing
@testable import cutie

/// Images must come out as good as they went in: colour space, bit depth,
/// HDR, metadata, DPI and animation survive; damaged files are refused; JPEG
/// rotate/flip/strip never re-compress.
@Suite(.serialized)
struct ImageFidelityTests {
    struct Info {
        var space: String
        var model: CGColorSpaceModel
        var depth: Int
        var frames: Int
        var properties: [CFString: Any]
        var metadata: CGImageMetadata?
        var hasGainMap: Bool
        var usesHDRCurve: Bool
        var rawPixels: Data

        var orientation: Int { properties[kCGImagePropertyOrientation] as? Int ?? 1 }
        var dpi: Double { properties[kCGImagePropertyDPIWidth] as? Double ?? 0 }
        var hasGPS: Bool { properties[kCGImagePropertyGPSDictionary] != nil }
    }

    func info(_ url: URL) throws -> Info {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let space = try #require(image.colorSpace)
        return Info(
            space: (space.name as String?) ?? "",
            model: space.model,
            depth: image.bitsPerComponent,
            frames: CGImageSourceGetCount(source),
            properties: CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:],
            metadata: CGImageSourceCopyMetadataAtIndex(source, 0, nil),
            hasGainMap: CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeISOGainMap) != nil,
            usesHDRCurve: CGColorSpaceUsesITUR_2100TF(space),
            rawPixels: (image.dataProvider?.data as Data?) ?? Data()
        )
    }

    func convert(_ input: URL, to format: Format, _ context: JobContext) async throws -> URL {
        let outcome = try await Executor.run(.convert(format), inputs: [input], context: context)
        return try #require(outcome.files.first)
    }

    func tool(_ tool: Tool, _ input: URL, _ context: JobContext) async throws -> URL {
        let outcome = try await Executor.run(.tool(tool), inputs: [input], context: context)
        return try #require(outcome.files.first)
    }

    @Test func deepColorSurvivesConversionsAndTools() async throws {
        let fixtures = try Fixtures(); defer { fixtures.remove() }
        let input = fixtures.deepPNG()
        let tiff = try info(try await convert(input, to: .tiff, fixtures.context))
        #expect(tiff.depth == 16)
        #expect(tiff.space == CGColorSpace.displayP3 as String)
        for each in [Tool.rotateImage, .resizeImage, .flipImage, .cropSquare, .grayscale] {
            let result = try info(try await tool(each, input, fixtures.context))
            #expect(result.depth == 16, "\(each)")
            #expect(result.space == CGColorSpace.displayP3 as String, "\(each)")
        }
    }

    @Test func cmykStaysCMYKWhereTheFormatAllows() async throws {
        let fixtures = try Fixtures(); defer { fixtures.remove() }
        let input = fixtures.cmykJPEG()
        #expect(try info(try await convert(input, to: .tiff, fixtures.context)).model == .cmyk)
        #expect(try info(try await convert(input, to: .png, fixtures.context)).model == .rgb)
    }

    @Test func metadataAndDPICarryOver() async throws {
        let fixtures = try Fixtures(); defer { fixtures.remove() }
        let input = fixtures.cameraJPEG()
        for format in [Format.tiff, .heic, .png] {
            let result = try info(try await convert(input, to: format, fixtures.context))
            #expect(result.dpi == 300, "\(format)")
            #expect(result.hasGPS, "\(format)")
            #expect(result.orientation == 1, "\(format)")
            let rating = result.metadata.flatMap { CGImageMetadataCopyStringValueWithPath($0, nil, "xmp:Rating" as CFString) as String? }
            #expect(rating == "5", "\(format)")
            #expect(result.space == CGColorSpace.displayP3 as String, "\(format)")
        }
    }

    @Test func damagedImagesAreRefused() async throws {
        let fixtures = try Fixtures(); defer { fixtures.remove() }
        let broken = try fixtures.truncatedJPEG()
        await #expect(throws: (any Error).self) {
            _ = try await Executor.run(.convert(.png), inputs: [broken], context: fixtures.context)
        }
        #expect(FileIntegrity.isTruncated(try Data(contentsOf: broken)))
        #expect(!FileIntegrity.isTruncated(try Data(contentsOf: fixtures.cameraJPEG())))
        #expect(!FileIntegrity.isTruncated(try Data(contentsOf: fixtures.deepPNG())))
        #expect(!FileIntegrity.isTruncated(try Data(contentsOf: try fixtures.gainMapHEIC())))
        let png = try Data(contentsOf: fixtures.deepPNG())
        #expect(FileIntegrity.isTruncated(png.prefix(png.count - 20)))
    }

    @Test func jpegRotateFlipAndStripDontRecompress() async throws {
        let fixtures = try Fixtures(); defer { fixtures.remove() }
        let input = fixtures.cameraJPEG()
        let original = try info(input)
        #expect(original.orientation == 6)

        let rotated = try info(try await tool(.rotateImage, input, fixtures.context))
        #expect(rotated.rawPixels == original.rawPixels)
        #expect(rotated.orientation == 3)
        #expect(rotated.hasGPS)

        let flipped = try info(try await tool(.flipImage, input, fixtures.context))
        #expect(flipped.rawPixels == original.rawPixels)
        #expect(flipped.orientation == 5)

        let cleanURL = try await tool(.stripMetadata, input, fixtures.context)
        let clean = try info(cleanURL)
        #expect(clean.rawPixels == original.rawPixels)
        #expect(clean.orientation == 6)
        #expect(!clean.hasGPS)
        #expect(clean.properties[kCGImagePropertyExifDictionary] == nil)
        #expect(clean.space == CGColorSpace.displayP3 as String)
        let bytes = try Data(contentsOf: cleanURL)
        #expect(bytes.range(of: Data("Photographer".utf8)) == nil)
        #expect(bytes.range(of: Data("TestCam".utf8)) == nil)
    }

    @Test func orientationChangesComposeCorrectly() {
        typealias Change = ImageConverter.OrientationChange
        for orientation in 1...8 {
            var turned = orientation
            for _ in 0..<4 { turned = Change.turnClockwise.applied(to: turned) }
            #expect(turned == orientation)
            #expect(Change.mirror.applied(to: Change.mirror.applied(to: orientation)) == orientation)
        }
        #expect(Change.turnClockwise.applied(to: 1) == 6)
        #expect(Change.turnClockwise.applied(to: 6) == 3)
        #expect(Change.mirror.applied(to: 1) == 2)
        #expect(Change.mirror.applied(to: 6) == 5)
    }

    @Test func hdrPhotosKeepTheirGainMap() async throws {
        let fixtures = try Fixtures(); defer { fixtures.remove() }
        let input = try fixtures.gainMapHEIC()
        #expect(try info(input).hasGainMap)
        for format in [Format.jpg, .avif] {
            #expect(try info(try await convert(input, to: format, fixtures.context)).hasGainMap, "\(format)")
        }
        let png = try info(try await convert(input, to: .png, fixtures.context))
        #expect(!png.usesHDRCurve)
        #expect(try info(try await tool(.compressImage, input, fixtures.context)).hasGainMap)
        #expect(try info(try await tool(.resizeImage, input, fixtures.context)).hasGainMap)
    }

    @Test func hdr10IsToneMappedForSDRFormats() async throws {
        let fixtures = try Fixtures(); defer { fixtures.remove() }
        let input = try fixtures.pqHEIC()
        #expect(try info(input).usesHDRCurve)
        let png = try info(try await convert(input, to: .png, fixtures.context))
        #expect(!png.usesHDRCurve)
        let jpg = try info(try await convert(input, to: .jpg, fixtures.context))
        #expect(!jpg.usesHDRCurve)
        #expect(jpg.hasGainMap)
    }

    @Test func animationsKeepEveryFrame() async throws {
        let fixtures = try Fixtures(); defer { fixtures.remove() }
        let input = fixtures.animatedGIF()
        let half = try await tool(.resizeImage, input, fixtures.context)
        let halfInfo = try info(half)
        #expect(halfInfo.frames == 5)
        let animation = try #require(try ImageConverter.animation(half))
        #expect(animation.delays.allSatisfy { abs($0 - 0.2) < 0.01 })
        #expect(animation.frames.first?.width == 60)

        #expect(try info(try await convert(input, to: .png, fixtures.context)).frames == 5)
        #expect(try info(try await convert(input, to: .jpg, fixtures.context)).frames == 1)
    }

    @Test func webpWithHelpers() async throws {
        let fixtures = try Fixtures(); defer { fixtures.remove() }
        let context = fixtures.fullContext
        guard context.toolbox.cwebp != nil, context.toolbox.img2webp != nil else { return }
        let animated = try info(try await convert(fixtures.animatedGIF(), to: .webp, context))
        #expect(animated.frames == 5)
        let still = try await convert(fixtures.deepPNG(), to: .webp, context)
        #expect(try info(still).space == CGColorSpace.displayP3 as String)
        // Lossless source → lossless WebP ("VP8L" chunk), photo → lossy ("VP8 ").
        #expect(try Data(contentsOf: still).range(of: Data("VP8L".utf8)) != nil)
        let photo = try await convert(fixtures.cameraJPEG(), to: .webp, context)
        #expect(try Data(contentsOf: photo).range(of: Data("VP8 ".utf8)) != nil)
    }

    @Test func textInColumnsReadsInOrder() async throws {
        let fixtures = try Fixtures(); defer { fixtures.remove() }
        let output = try await tool(.extractText, try fixtures.twoColumnImage(), fixtures.context)
        let text = try String(contentsOf: output, encoding: .utf8)
        let order = (Fixtures.leftColumn + Fixtures.rightColumn).map { line in
            text.range(of: line.split(separator: " ").prefix(2).joined(separator: " "))?.lowerBound
        }
        #expect(order.allSatisfy { $0 != nil })
        let positions = order.compactMap { $0 }
        #expect(positions == positions.sorted())
    }

    @Test func combineKeepsJPEGsAsJPEG() async throws {
        let fixtures = try Fixtures(); defer { fixtures.remove() }
        let photos = [fixtures.noisePhoto("a.jpg", width: 1200, height: 900), fixtures.noisePhoto("b.jpg", width: 1200, height: 900)]
        let pdf = try #require(try await Executor.run(.tool(.combineToPDF), inputs: photos, context: fixtures.context).files.first)
        let size = PDFConverter.fileSize(pdf)
        let sources = photos.map(PDFConverter.fileSize).reduce(0, +)
        #expect(Double(size) < Double(sources) * 1.05)
        #expect(try Data(contentsOf: pdf).range(of: Data("DCTDecode".utf8)) != nil)

        // A sideways phone photo becomes an upright page.
        let camera = try #require(try await Executor.run(.convert(.pdf), inputs: [fixtures.cameraJPEG()], context: fixtures.context).files.first)
        let page = try #require(PDFDocument(url: camera)?.page(at: 0))
        let bounds = page.bounds(for: .mediaBox)
        #expect(bounds.height > bounds.width)
    }
}
