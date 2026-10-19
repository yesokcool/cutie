import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import Vision

/// The image half of the Tools wheel. Each returns a new image in the source's
/// own colour space and bit depth; the caller writes it.
nonisolated enum ImageTools {
    static func halfSize(_ image: CGImage) throws -> CGImage {
        let width = max(1, image.width / 2)
        let height = max(1, image.height / 2)
        return try ImageConverter.redraw(image, width: width, height: height) { context in
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    /// 90° clockwise.
    static func rotated(_ image: CGImage) throws -> CGImage {
        let (width, height) = (image.width, image.height)
        return try ImageConverter.redraw(image, width: height, height: width) { context in
            context.translateBy(x: 0, y: CGFloat(width))
            context.rotate(by: -.pi / 2)
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    /// Mirrored left to right.
    static func flipped(_ image: CGImage) throws -> CGImage {
        try ImageConverter.redraw(image, width: image.width, height: image.height) { context in
            context.translateBy(x: CGFloat(image.width), y: 0)
            context.scaleBy(x: -1, y: 1)
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
    }

    /// The largest centered square.
    static func squared(_ image: CGImage) throws -> CGImage {
        let side = min(image.width, image.height)
        let rect = CGRect(x: (image.width - side) / 2, y: (image.height - side) / 2, width: side, height: side)
        guard let cropped = image.cropping(to: rect) else { throw CutieError("Couldn't crop this image.") }
        return cropped
    }

    static func grayscale(_ image: CGImage) throws -> CGImage {
        let filter = CIFilter.colorControls()
        filter.inputImage = CIImage(cgImage: image)
        filter.saturation = 0
        guard let output = filter.outputImage else { throw CutieError("Couldn't remove the color.") }
        return try render(output, like: image)
    }

    /// The subject (person, pet, object) on a transparent background, at the
    /// source's full size, colour space and depth.
    static func removingBackground(_ image: CGImage) throws -> CGImage {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let request = VNGenerateForegroundInstanceMaskRequest()
        try handler.perform([request])
        guard let observation = request.results?.first, !observation.allInstances.isEmpty else {
            throw CutieError("Couldn't find a subject in this image.")
        }
        let mask = try observation.generateScaledMaskForImage(forInstances: observation.allInstances, from: handler)
        let source = CIImage(cgImage: image)
        let cutout = source.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.empty(),
            kCIInputMaskImageKey: CIImage(cvPixelBuffer: mask),
        ])
        return try render(cutout, like: image, alpha: true)
    }

    /// The text in an image in reading order: columns one after the other,
    /// paragraphs kept together (Vision's document reader).
    static func recognizedText(_ image: CGImage) async throws -> String {
        let text = try await document(in: image)?.text.transcript.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { throw CutieError("No text found in this image.") }
        return text
    }

    /// Each line of text with its corners, in the image's normalized coordinates (origin bottom left).
    static func recognizedLines(_ image: CGImage) async throws -> [(text: String, corners: [CGPoint])] {
        guard let document = try await document(in: image) else { return [] }
        return document.text.lines.map { line in
            (line.transcript, [line.bottomLeft.cgPoint, line.bottomRight.cgPoint, line.topRight.cgPoint, line.topLeft.cgPoint])
        }
    }

    private static func document(in image: CGImage) async throws -> DocumentObservation.Container? {
        var request = RecognizeDocumentsRequest()
        request.textRecognitionOptions.automaticallyDetectLanguage = true
        request.textRecognitionOptions.useLanguageCorrection = true
        return try await request.perform(on: image).first?.document
    }

    /// Renders a Core Image result in `image`'s colour space and depth, opaque
    /// unless the source (or `alpha`) has transparency.
    static func render(_ output: CIImage, like image: CGImage, alpha: Bool? = nil) throws -> CGImage {
        let rgb = image.colorSpace?.model == .rgb ? image.colorSpace : nil
        let space = rgb ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let format: CIFormat = image.bitmapInfo.contains(.floatComponents) ? .RGBAh : (image.bitsPerComponent > 8 ? .RGBA16 : .RGBA8)
        let extent = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        guard let rendered = CIContext().createCGImage(output, from: extent, format: format, colorSpace: space) else {
            throw CutieError("Couldn't draw this image.")
        }
        guard !(alpha ?? ImageConverter.hasAlpha(image)) else { return rendered }
        return try ImageConverter.redraw(rendered, width: rendered.width, height: rendered.height, alpha: false) { context in
            context.draw(rendered, in: extent)
        }
    }
}
