import AppKit

/// Lays an attributed string out on US Letter pages and draws them into a PDF.
@MainActor
enum PDFRenderer {
    static func render(_ text: NSAttributedString, to url: URL, title: String, landscape: Bool = false) throws {
        let page = landscape ? CGSize(width: 792, height: 612) : CGSize(width: 612, height: 792)
        let margin: CGFloat = 54
        var mediaBox = CGRect(origin: .zero, size: page)
        let info = [kCGPDFContextTitle: title, kCGPDFContextCreator: "Cutie"] as CFDictionary
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, info) else {
            throw CutieError("Couldn't create the PDF.")
        }

        let storage = NSTextStorage(attributedString: text)
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)

        let graphics = NSGraphicsContext(cgContext: context, flipped: true)
        var pages = 0
        while pages < 5000 {
            let container = NSTextContainer(size: CGSize(width: page.width - margin * 2, height: page.height - margin * 2))
            container.lineFragmentPadding = 0
            layout.addTextContainer(container)
            let glyphs = layout.glyphRange(for: container)
            if glyphs.length == 0 && pages > 0 { break }

            context.beginPDFPage(nil)
            context.saveGState()
            context.translateBy(x: 0, y: page.height)
            context.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphics
            let origin = CGPoint(x: margin, y: margin)
            layout.drawBackground(forGlyphRange: glyphs, at: origin)
            layout.drawGlyphs(forGlyphRange: glyphs, at: origin)
            NSGraphicsContext.restoreGraphicsState()
            context.restoreGState()
            context.endPDFPage()
            pages += 1

            if NSMaxRange(glyphs) >= layout.numberOfGlyphs { break }
        }
        context.closePDF()
    }
}
