import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import Vision

/// The image half of the Tools wheel. Each returns a new image; the caller writes it.
nonisolated enum ImageTools {
    static func halfSize(_ image: CGImage) throws -> CGImage {
        let width = max(1, image.width / 2)
        let height = max(1, image.height / 2)
        return try draw(width: width, height: height, alpha: ImageConverter.hasAlpha(image)) { context in
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    /// 90° clockwise.
    static func rotated(_ image: CGImage) throws -> CGImage {
        let (width, height) = (image.width, image.height)
        return try draw(width: height, height: width, alpha: ImageConverter.hasAlpha(image)) { context in
            context.translateBy(x: 0, y: CGFloat(width))
            context.rotate(by: -.pi / 2)
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    /// Mirrored left to right.
    static func flipped(_ image: CGImage) throws -> CGImage {
        try draw(width: image.width, height: image.height, alpha: ImageConverter.hasAlpha(image)) { context in
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
        guard let output = filter.outputImage,
              let result = CIContext().createCGImage(output, from: CGRect(x: 0, y: 0, width: image.width, height: image.height)) else {
            throw CutieError("Couldn't remove the color.")
        }
        return result
    }

    /// The subject (person, pet, object) on a transparent background.
    static func removingBackground(_ image: CGImage) throws -> CGImage {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let request = VNGenerateForegroundInstanceMaskRequest()
        try handler.perform([request])
        guard let observation = request.results?.first, !observation.allInstances.isEmpty else {
            throw CutieError("Couldn't find a subject in this image.")
        }
        let buffer = try observation.generateMaskedImage(ofInstances: observation.allInstances, from: handler, croppedToInstancesExtent: false)
        let masked = CIImage(cvPixelBuffer: buffer)
        guard let result = CIContext().createCGImage(masked, from: masked.extent) else {
            throw CutieError("Couldn't cut out the subject.")
        }
        return result
    }

    /// The text in an image, top to bottom (Live Text's recognizer).
    static func recognizedText(_ image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let lines = (request.results ?? [])
            .sorted { $0.boundingBox.maxY > $1.boundingBox.maxY }
            .compactMap { $0.topCandidates(1).first?.string }
        guard !lines.isEmpty else { throw CutieError("No text found in this image.") }
        return lines.joined(separator: "\n")
    }

    private static func draw(width: Int, height: Int, alpha: Bool, _ body: (CGContext) -> Void) throws -> CGImage {
        guard let context = ImageConverter.bitmapContext(width: width, height: height, alpha: alpha) else {
            throw CutieError("Couldn't draw this image.")
        }
        body(context)
        guard let image = context.makeImage() else { throw CutieError("Couldn't draw this image.") }
        return image
    }
}
