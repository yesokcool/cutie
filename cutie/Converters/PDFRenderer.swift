import AppKit

/// Lays an attributed string out on pages of the region's paper size (A4, or
/// US Letter where that's the norm) and draws them into a PDF. TextKit 1 runs
/// on any thread as long as one thread owns the objects, so long documents
/// render off the main thread (`renderInBackground`).
nonisolated enum PDFRenderer {
    /// Countries and territories that use US Letter; everywhere else uses A4.
    static let letterRegions: Set<String> = ["US", "CA", "MX", "PR", "PH", "CL", "CO", "VE", "GT", "SV", "HN", "NI", "CR", "PA", "DO", "BZ"]

    /// The paper documents are laid out on, in points.
    static var paperSize: CGSize {
        let region = Locale.current.region?.identifier ?? "US"
        return letterRegions.contains(region) ? CGSize(width: 612, height: 792) : CGSize(width: 595.28, height: 841.89)
    }

    /// The same as `render`, off the main thread so a long document doesn't
    /// freeze the menu bar or the job pills. The text crosses over archived,
    /// so the background thread owns its own copy.
    nonisolated(nonsending)
    static func renderInBackground(_ text: NSAttributedString, to url: URL, title: String, landscape: Bool = false) async throws {
        let archive = try NSKeyedArchiver.archivedData(withRootObject: text, requiringSecureCoding: false)
        try await render(archive: archive, to: url, title: title, landscape: landscape)
    }

    @concurrent
    private static func render(archive: Data, to url: URL, title: String, landscape: Bool) async throws {
        let unarchiver = try NSKeyedUnarchiver(forReadingFrom: archive)
        unarchiver.requiresSecureCoding = false
        guard let text = unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey) as? NSAttributedString else {
            throw CutieError("Couldn't lay out this document.")
        }
        try render(text, to: url, title: title, landscape: landscape)
    }

    static func render(_ text: NSAttributedString, to url: URL, title: String, landscape: Bool = false) throws {
        let paper = paperSize
        let page = landscape ? CGSize(width: paper.height, height: paper.width) : paper
        let margin: CGFloat = 54
        let content = CGSize(width: page.width - margin * 2, height: page.height - margin * 2)
        var mediaBox = CGRect(origin: .zero, size: page)
        let info = [kCGPDFContextTitle: title, kCGPDFContextCreator: "Cutie"] as CFDictionary
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, info) else {
            throw CutieError("Couldn't create the PDF.")
        }

        let storage = NSTextStorage(attributedString: text)
        fitAttachments(in: storage, to: content)
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)

        let graphics = NSGraphicsContext(cgContext: context, flipped: true)
        var pages = 0
        while true {
            try Task.checkCancellation()
            let container = NSTextContainer(size: content)
            container.lineFragmentPadding = 0
            layout.addTextContainer(container)
            let glyphs = layout.glyphRange(for: container)
            if glyphs.length == 0 && pages > 0 {
                // Nothing fits on a fresh page: something is bigger than a page can hold.
                guard NSMaxRange(layout.glyphRange(for: layout.textContainers[pages - 1])) >= layout.numberOfGlyphs else {
                    throw CutieError("Part of this document is too big to fit on a page (after page \(pages)).")
                }
                break
            }

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

    /// Pictures larger than the page area are shrunk to fit (keeping their
    /// shape); left alone, a picture taller than a page never fits anywhere.
    static func fitAttachments(in text: NSTextStorage, to area: CGSize) {
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            guard let attachment = value as? NSTextAttachment else { return }
            var size = attachment.bounds.size
            if size.width <= 0 || size.height <= 0 {
                if let image = attachment.image {
                    size = image.size
                } else if let data = attachment.fileWrapper?.regularFileContents, let image = NSImage(data: data) {
                    size = image.size
                }
            }
            guard size.width > 0, size.height > 0 else { return }
            let scale = min(1, area.width / size.width, area.height * 0.95 / size.height)
            if scale < 1 {
                attachment.bounds = CGRect(x: 0, y: 0, width: (size.width * scale).rounded(.down), height: (size.height * scale).rounded(.down))
            }
        }
    }
}
