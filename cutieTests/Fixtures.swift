import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
@testable import cutie

/// Builds sample files in a throwaway folder. Everything here is invented.
struct Fixtures {
    let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "CutieTests-" + UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: folder) }

    func url(_ name: String) -> URL { folder.appending(path: name) }

    var context: JobContext { JobContext(toolbox: .none, output: Output(location: .nextToOriginal), imageQuality: 0.85) }
    var fullContext: JobContext { JobContext(toolbox: .detect(), output: Output(location: .nextToOriginal), imageQuality: 0.85) }

    /// A 200×100 image: orange left half, transparent right half.
    func png(_ name: String = "photo.png", width: Int = 200, height: Int = 100) throws -> URL {
        let context = ImageConverter.bitmapContext(width: width, height: height, alpha: true)!
        context.setFillColor(CGColor(red: 1, green: 0.5, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        let url = url(name)
        try ImageConverter.write(context.makeImage()!, as: .png, to: url, quality: 1)
        return url
    }

    /// A 200×100 JPEG tagged "rotate 90° to display" (EXIF orientation 6), as phones write.
    func rotatedJPEG() throws -> URL {
        let context = ImageConverter.bitmapContext(width: 200, height: 100, alpha: false)!
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
        let url = url("phone.jpg")
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, [kCGImagePropertyOrientation: 6] as CFDictionary)
        CGImageDestinationFinalize(destination)
        return url
    }

    /// Black text on white, big enough for Live Text.
    func textImage(_ text: String) throws -> URL {
        let size = CGSize(width: 900, height: 200)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            (text as NSString).draw(at: CGPoint(x: 40, y: 70), withAttributes: [.font: NSFont.systemFont(ofSize: 64), .foregroundColor: NSColor.black])
            return true
        }
        let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        let url = url("words.png")
        try ImageConverter.write(cg, as: .png, to: url, quality: 1)
        return url
    }

    func svg() throws -> URL {
        let url = url("vector.svg")
        try ##"<svg xmlns="http://www.w3.org/2000/svg" width="64" height="32"><rect width="64" height="32" fill="#f80"/></svg>"##
            .write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// One second of a 440 Hz tone.
    func wav(_ name: String = "tone.wav", seconds: Double = 1) throws -> URL {
        let url = url(name)
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(44_100 * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for index in 0..<Int(frames) {
            buffer.floatChannelData![0][index] = Float(sin(Double(index) * 2 * .pi * 440 / 44_100) * 0.5)
        }
        try file.write(from: buffer)
        return url
    }

    /// A 2-second test-pattern MP4 with sound (needs ffmpeg).
    func mp4(_ ffmpeg: URL) async throws -> URL {
        let url = url("clip.mp4")
        try await Shell.run(ffmpeg, ["-hide_banner", "-loglevel", "error", "-y",
                                     "-f", "lavfi", "-i", "testsrc=duration=2:size=320x240:rate=15",
                                     "-f", "lavfi", "-i", "sine=frequency=440:duration=2",
                                     "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest", url.path])
        return url
    }

    func text(_ name: String, _ contents: String) throws -> URL {
        let url = url(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static let markdown = """
    # Trip Notes

    Pack **sunscreen** and *a hat*. See [the map](https://example.com/map).

    - Tickets
    - Snacks

    ```
    let cutie = true
    ```
    """

    /// A PDF of several pages ("Page 1 of the report." …), made by overflowing each page.
    @MainActor
    func pdf() throws -> URL {
        let url = url("report.pdf")
        let text = NSMutableAttributedString()
        for page in 1...3 {
            let body = "Page \(page) of the report.\n" + String(repeating: "Line of filler text. ", count: 40) + "\n"
            text.append(NSAttributedString(string: body + String(repeating: "\n", count: 30), attributes: [.font: NSFont.systemFont(ofSize: 14)]))
        }
        try PDFRenderer.render(text, to: url, title: "Report")
        return url
    }
}
