import Foundation

/// EPUB 3 in and out. Writing makes one chapter from an XHTML page (local
/// images are copied in); reading joins the spine's chapters into one page.
nonisolated enum EPUB {
    /// `baseURL` resolves pictures given by relative path (a Markdown file's "photos/a.png").
    static func write(title: String, xhtml: String, to output: URL, baseURL: URL? = nil, scratch: Scratch) async throws {
        let root = try scratch.folder("epub-" + UUID().uuidString)
        let oebps = root.appending(path: "OEBPS", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: oebps.appending(path: "images"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appending(path: "META-INF"), withIntermediateDirectories: true)

        // Copy local images in and point the chapter at the copies.
        var chapter = xhtml
        var images: [(href: String, type: String)] = []
        let pattern = try NSRegularExpression(pattern: #"src="([^"]+)""#)
        let matches = pattern.matches(in: xhtml, range: NSRange(xhtml.startIndex..., in: xhtml))
        for match in matches.reversed() {
            guard let range = Range(match.range(at: 1), in: xhtml) else { continue }
            let source = String(xhtml[range]).replacingOccurrences(of: "&amp;", with: "&")
            guard let url = source.hasPrefix("file://") ? URL(string: source) : baseURL.flatMap({ URL(string: source, relativeTo: $0) }),
                  url.isFileURL, FileManager.default.fileExists(atPath: url.path) else { continue }
            let ext = url.pathExtension.lowercased()
            let href = "images/\(images.count + 1).\(ext)"
            try FileManager.default.copyItem(at: url, to: oebps.appending(path: href))
            images.append((href, mediaType(forImageExtension: ext)))
            if let chapterRange = Range(match.range(at: 1), in: chapter) {
                chapter.replaceSubrange(chapterRange, with: href)
            }
        }

        let manifestImages = images.enumerated().map { index, image in
            #"<item id="img\#(index + 1)" href="\#(image.href)" media-type="\#(image.type)"/>"#
        }.joined(separator: "\n    ")
        let modified = ISO8601DateFormatter().string(from: Date()).prefix(19) + "Z"
        let escapedTitle = HTML.escape(title)

        try Data("application/epub+zip".utf8).write(to: root.appending(path: "mimetype"))
        try Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
        </container>
        """.utf8).write(to: root.appending(path: "META-INF/container.xml"))
        try Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="uid">urn:uuid:\(UUID().uuidString.lowercased())</dc:identifier>
            <dc:title>\(escapedTitle)</dc:title>
            <dc:language>\(Locale.current.language.languageCode?.identifier ?? "en")</dc:language>
            <meta property="dcterms:modified">\(modified)</meta>
          </metadata>
          <manifest>
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
            <item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/>
            \(manifestImages)
          </manifest>
          <spine><itemref idref="chapter"/></spine>
        </package>
        """.utf8).write(to: oebps.appending(path: "content.opf"))
        try Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
        <head><title>\(escapedTitle)</title></head>
        <body><nav epub:type="toc"><ol><li><a href="chapter.xhtml">\(escapedTitle)</a></li></ol></nav></body>
        </html>
        """.utf8).write(to: oebps.appending(path: "nav.xhtml"))
        try Data(chapter.utf8).write(to: oebps.appending(path: "chapter.xhtml"))

        try await ArchiveConverter.zipContents(of: root, to: output, storedFirst: "mimetype")
    }

    struct Book {
        var html: String
        var folder: URL
    }

    /// All chapters in reading order as one HTML page, images pointing at the unpacked files.
    static func read(_ url: URL, scratch: Scratch) async throws -> Book {
        let folder = try scratch.folder("book-" + UUID().uuidString)
        try await ArchiveConverter.unzip(url, into: folder)

        let container = try XMLDocument(contentsOf: folder.appending(path: "META-INF/container.xml"))
        guard let opfPath = try container.nodes(forXPath: "//*[local-name()='rootfile']/@full-path").first?.stringValue else {
            throw CutieError("This EPUB has no table of contents.")
        }
        let opfURL = folder.appending(path: opfPath)
        let opfFolder = opfURL.deletingLastPathComponent()
        let package = try XMLDocument(contentsOf: opfURL)

        var hrefs: [String: String] = [:]
        for item in try package.nodes(forXPath: "//*[local-name()='manifest']/*[local-name()='item']") {
            guard let element = item as? XMLElement,
                  let id = element.attribute(forName: "id")?.stringValue,
                  let href = element.attribute(forName: "href")?.stringValue else { continue }
            hrefs[id] = href.removingPercentEncoding ?? href
        }
        let spine = try package.nodes(forXPath: "//*[local-name()='spine']/*[local-name()='itemref']/@idref").compactMap(\.stringValue)

        var bodies: [String] = []
        for id in spine {
            guard let href = hrefs[id] else { continue }
            let chapterURL = opfFolder.appending(path: href)
            guard let document = try? XMLDocument(contentsOf: chapterURL, options: [.documentTidyHTML]) else { continue }
            let chapterFolder = chapterURL.deletingLastPathComponent()
            for node in (try? document.nodes(forXPath: "//*[local-name()='img']/@src | //*[local-name()='image']/@*[local-name()='href']")) ?? [] {
                guard let value = node.stringValue, !value.hasPrefix("http"), !value.hasPrefix("data:") else { continue }
                node.stringValue = chapterFolder.appending(path: value.removingPercentEncoding ?? value).absoluteString
            }
            if let body = try document.nodes(forXPath: "//*[local-name()='body']").first as? XMLElement {
                bodies.append(body.children?.map(\.xmlString).joined(separator: "\n") ?? "")
            }
        }
        guard !bodies.isEmpty else { throw CutieError("This EPUB has no readable chapters.") }
        let title = try package.nodes(forXPath: "//*[local-name()='title']").first?.stringValue ?? Output.baseName(of: url)
        return Book(html: HTML.page(title: title, body: bodies.joined(separator: "\n<hr/>\n")), folder: opfFolder)
    }

    static func mediaType(forImageExtension ext: String) -> String {
        switch ext {
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "svg": "image/svg+xml"
        case "webp": "image/webp"
        default: "image/png"
        }
    }
}
