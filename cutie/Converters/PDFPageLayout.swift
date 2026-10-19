import AppKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import Vision

/// One PDF page taken apart for rebuilding as a Word document: lines of styled
/// text, pictures (embedded images and drawn charts), and tables, all in
/// display coordinates (the crop box as shown, rotation applied, origin at the
/// bottom left). Scanned pages get their text and tables from Vision.
nonisolated struct PDFPageLayout {
    struct Glyph {
        var text: String
        var frame: CGRect
        var style: WordDocument.TextStyle
        var link: URL?
        var isSpace: Bool { text.allSatisfy(\.isWhitespace) }
    }

    struct Line {
        var glyphs: [Glyph]
        var frame: CGRect
        var size: Double
        var text: String { glyphs.map(\.text).joined() }

        init(glyphs: [Glyph]) {
            self.glyphs = glyphs
            let solid = glyphs.filter { !$0.isSpace && !$0.frame.isEmpty }
            frame = solid.reduce(CGRect.null) { $0.union($1.frame) }
            var sizes: [Double: Int] = [:]
            for glyph in solid { sizes[glyph.style.size, default: 0] += 1 }
            size = sizes.max { $0.value < $1.value }?.key ?? glyphs.first?.style.size ?? 11
        }
    }

    struct PlacedPicture {
        var frame: CGRect
        var picture: WordDocument.Picture
    }

    struct PlacedTable {
        var frame: CGRect
        /// Column and row edges, left to right and top to bottom.
        var columnEdges: [Double]
        var cells: [[CellContent]]
        var bordered: Bool
    }

    struct CellContent {
        var lines: [Line]
        var rowSpan = 1
        var columnSpan = 1
        /// Covered by a merged cell above or to the left: that cell's row and column.
        var owner: (row: Int, column: Int)?
        var covered: Bool { owner != nil }
    }

    var size: CGSize
    var lines: [Line] = []
    var pictures: [PlacedPicture] = []
    var tables: [PlacedTable] = []
    /// The text came from Live Text (a scan), so fonts are guesses.
    var scanned = false

    // MARK: - Reading

    static func read(_ page: PDFPage, cgPage: CGPDFPage) async throws -> PDFPageLayout {
        let display = page.transform(for: .cropBox)
        let crop = page.bounds(for: .cropBox)
        let quarterTurns = ((page.rotation % 360) + 360) % 360 / 90
        let size = quarterTurns % 2 == 0 ? crop.size : CGSize(width: crop.height, height: crop.width)
        var layout = PDFPageLayout(size: size)
        let content = PDFContent(page: cgPage)

        var glyphs = textGlyphs(page, content: content, display: display)
        let visible = content.runs.contains { !$0.invisible } || (content.runs.isEmpty && !glyphs.isEmpty)
        let pageArea = size.width * size.height

        // Pictures, minus a full-page scan sitting under an OCR text layer.
        for placement in content.images {
            let frame = placement.frame.applying(display).intersection(CGRect(origin: .zero, size: size))
            guard !frame.isNull, frame.width >= 6, frame.height >= 6 else { continue }
            if !visible, frame.width * frame.height > pageArea * 0.6 { continue }
            if let picture = picture(placement, frame: frame, page: page, display: display) {
                layout.pictures.append(PlacedPicture(frame: frame, picture: picture))
            }
        }

        // Vision reads the page as shown: tables everywhere, all the text on a scan.
        let observation = try await document(in: try PDFConverter.render(page, dpi: 200))
        let toDisplay = { (rect: CGRect) in
            CGRect(x: rect.minX * size.width, y: rect.minY * size.height, width: rect.width * size.width, height: rect.height * size.height)
        }

        if glyphs.isEmpty, let observation {
            // A scan: Live Text's lines become the text; the scan itself isn't kept.
            layout.scanned = true
            layout.pictures.removeAll { $0.frame.width * $0.frame.height > pageArea * 0.6 }
            glyphs = observation.text.lines.flatMap { line -> [Glyph] in
                let frame = toDisplay(line.boundingRegion.boundingBox.cgRect)
                let style = WordDocument.TextStyle(family: nil, size: max(6, min(72, (frame.height / 1.2 * 2).rounded() / 2)))
                return [Glyph(text: line.transcript, frame: frame, style: style), Glyph(text: "\n", frame: .null, style: style)]
            }
        }

        // Tables first: their text leaves the running text.
        let rules = content.rules.map { $0.applying(display) }
        var used = Set<Int>()
        for table in observation?.tables ?? [] {
            let frame = toDisplay(table.boundingRegion.boundingBox.cgRect)
            guard table.rows.count >= 2, (table.rows.map(\.count).max() ?? 0) >= 2 else { continue }
            if let placed = placedTable(table, frame: frame, glyphs: glyphs, used: &used, rules: rules,
                                        scanned: layout.scanned, toDisplay: toDisplay) {
                layout.tables.append(placed)
            }
        }

        // Charts and diagrams drawn with paths become pictures, labels included.
        for found in figureFrames(content.paths.map { ($0, $0.frame.applying(display)) }, size: size,
                                  avoiding: layout.tables.map(\.frame) + layout.pictures.map(\.frame), glyphs: glyphs) {
            // Labels sitting just outside the drawing (axis labels, a legend) belong to it.
            var frame = found
            let near = found.insetBy(dx: -20, dy: -20)
            for range in lineRanges(glyphs) {
                let solid = glyphs[range].filter { !$0.isSpace && !$0.frame.isNull }
                if !solid.isEmpty, solid.allSatisfy({ near.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) }) {
                    frame = solid.reduce(frame) { $0.union($1.frame) }
                }
            }
            if let picture = renderedPicture(page, frame: frame) {
                layout.pictures.append(PlacedPicture(frame: frame, picture: picture))
                for (index, glyph) in glyphs.enumerated() where frame.contains(CGPoint(x: glyph.frame.midX, y: glyph.frame.midY)) {
                    used.insert(index)
                }
            }
        }

        let remaining = glyphs.enumerated().filter { !used.contains($0.offset) }.map(\.element)
        layout.lines = lines(from: remaining)
        return layout
    }

    // MARK: Text

    /// Every character on the page with its frame and style: positions from
    /// PDFKit, fonts and colours from the content stream.
    private static func textGlyphs(_ page: PDFPage, content: PDFContent, display: CGAffineTransform) -> [Glyph] {
        guard let string = page.string as NSString?, string.length > 0 else { return [] }
        let attributed = page.attributedString
        let links: [(CGRect, URL)] = page.annotations.compactMap { annotation in
            annotation.url.map { (annotation.bounds, $0) }
        }
        let runs = content.runs
        var glyphs: [Glyph] = []
        var index = 0
        var lastStyle = WordDocument.TextStyle(family: nil, size: 11)
        while index < string.length {
            let range = string.rangeOfComposedCharacterSequence(at: index)
            defer { index = NSMaxRange(range) }
            var text = string.substring(with: range)
            if text == "\n" || text == "\r" || text == "\u{2028}" {
                glyphs.append(Glyph(text: "\n", frame: .null, style: lastStyle))
                continue
            }
            if text == "\t" { text = " " }
            // Control characters and object placeholders aren't text.
            if text.unicodeScalars.allSatisfy({ $0.properties.generalCategory == .control || $0.value == 0xFFFC || $0.value == 0xFFFD }) {
                continue
            }
            // `characterBounds(at:)` drifts after line breaks and ligatures ("fi" is one glyph); a selection doesn't.
            let bounds = page.selection(for: range)?.bounds(for: page) ?? .null
            let font = index < (attributed?.length ?? 0) ? attributed?.attribute(.font, at: index, effectiveRange: nil) as? NSFont : nil
            let color = index < (attributed?.length ?? 0) ? attributed?.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor : nil
            var style = lastStyle
            if !bounds.isNull, !bounds.isEmpty {
                let size = Double(font?.pointSize ?? bounds.height / 1.2)
                let run = matchingRun(for: bounds, size: size, in: runs)
                if run?.invisible == true, runs.contains(where: { !$0.invisible }) { continue }
                style = WordDocument.TextStyle(
                    family: run?.font.family ?? font?.familyName,
                    size: ((run.map { $0.size } ?? size) * 2).rounded() / 2,
                    bold: run?.font.bold ?? font.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } ?? false,
                    italic: run?.font.italic ?? font.map { NSFontManager.shared.traits(of: $0).contains(.italicFontMask) } ?? false,
                    color: hex(run?.color, fallback: color)
                )
                if run?.invisible == true { style.family = nil; style.color = nil }
                lastStyle = style
            }
            let frame = bounds.isNull || bounds.isEmpty ? CGRect.null : bounds.applying(display)
            let link = frame.isNull ? nil : links.first { $0.0.contains(CGPoint(x: bounds.midX, y: bounds.midY)) }?.1
            glyphs.append(Glyph(text: text, frame: frame, style: style, link: link))
        }
        return glyphs
    }

    /// The content-stream run a character belongs to: same baseline, inside its span.
    private static func matchingRun(for bounds: CGRect, size: Double, in runs: [PDFContent.TextRun]) -> PDFContent.TextRun? {
        var best: PDFContent.TextRun?
        var bestDistance = Double.infinity
        let x = bounds.midX
        for run in runs {
            let low = min(run.start.x, run.end.x) - 0.5, high = max(run.start.x, run.end.x) + 0.5
            let baseline = run.start.y
            guard baseline >= bounds.minY - size * 0.35, baseline <= bounds.maxY + size * 0.1 else { continue }
            let distance = x < low ? low - x : (x > high ? x - high : 0)
            if distance < bestDistance {
                bestDistance = distance
                best = run
                if distance == 0, abs(run.size - size) < 0.6 { break }
            }
        }
        return bestDistance <= max(2, size * 0.3) ? best : nil
    }

    private static func hex(_ color: PDFContent.RGB?, fallback: NSColor?) -> String? {
        if let color { return color.isBlack ? nil : color.hex }
        guard let rgb = fallback?.usingColorSpace(.sRGB) else { return nil }
        let value = PDFContent.RGB(red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent)
        return value.isBlack ? nil : value.hex
    }

    /// The index ranges of PDFKit's lines.
    private static func lineRanges(_ glyphs: [Glyph]) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var start = 0
        for (index, glyph) in glyphs.enumerated() where glyph.text == "\n" {
            if index > start { ranges.append(start..<index) }
            start = index + 1
        }
        if start < glyphs.count { ranges.append(start..<glyphs.count) }
        return ranges
    }

    /// Splits glyphs into lines at PDFKit's line breaks and at wide gaps (columns side by side).
    static func lines(from glyphs: [Glyph]) -> [Line] {
        var lines: [Line] = []
        var current: [Glyph] = []
        func flush() {
            if current.contains(where: { !$0.isSpace && !$0.frame.isNull }) { lines.append(Line(glyphs: current)) }
            current = []
        }
        for glyph in glyphs {
            if glyph.text == "\n" { flush(); continue }
            if let last = current.last(where: { !$0.frame.isNull && !$0.isSpace }), !glyph.frame.isNull, !glyph.isSpace {
                let gap = glyph.frame.minX - last.frame.maxX
                let size = max(glyph.style.size, last.style.size)
                let newBaseline = abs(glyph.frame.minY - last.frame.minY) > size * 0.8
                if gap > size * 2.5 || gap < -size * 4 || newBaseline { flush() }
            }
            current.append(glyph)
        }
        flush()
        return lines.map { line in
            var glyphs = line.glyphs
            // PDFKit sometimes lists a line's pieces out of order ("Page of 1 10"); left to right
            // is the reading order, except in right-to-left scripts.
            let rightToLeft = glyphs.contains { $0.text.unicodeScalars.contains { (0x0590...0x08FF).contains($0.value) || (0xFB1D...0xFEFC).contains($0.value) } }
            let outOfOrder = zip(glyphs, glyphs.dropFirst()).contains { !$0.frame.isNull && !$1.frame.isNull && $1.frame.midX < $0.frame.minX - 1 }
            if !rightToLeft, outOfOrder {
                glyphs = glyphs.enumerated().sorted { a, b in
                    let (x, y) = (a.element.frame.isNull ? Double(a.offset) : a.element.frame.midX, b.element.frame.isNull ? Double(b.offset) : b.element.frame.midX)
                    return x == y ? a.offset < b.offset : x < y
                }.map(\.element)
            }
            // Trim spaces at the ends.
            while glyphs.first?.isSpace == true { glyphs.removeFirst() }
            while glyphs.last?.isSpace == true { glyphs.removeLast() }
            return Line(glyphs: glyphs)
        }
    }

    // MARK: Tables

    private static func placedTable(
        _ table: DocumentObservation.Container.Table, frame: CGRect, glyphs: [Glyph], used: inout Set<Int>,
        rules: [CGRect], scanned: Bool, toDisplay: (CGRect) -> CGRect
    ) -> PlacedTable? {
        let rowCount = table.rows.count
        let columnCount = (table.rows.flatMap { $0.map { $0.columnRange.upperBound } }.max() ?? 0) + 1
        guard rowCount >= 2, columnCount >= 2 else { return nil }

        // Edges from the cells Vision found text in (rows measured downwards from the top); gaps filled in evenly.
        var lefts = [Double?](repeating: nil, count: columnCount), rights = lefts
        var tops = [Double?](repeating: nil, count: rowCount), bottoms = tops
        for row in table.rows {
            for cell in row {
                let box = toDisplay(cell.content.boundingRegion.boundingBox.cgRect)
                guard box.width > 0, box.height > 0, !cell.content.text.transcript.isEmpty else { continue }
                if cell.columnRange.count == 1, cell.columnRange.lowerBound < columnCount {
                    let column = cell.columnRange.lowerBound
                    lefts[column] = min(lefts[column] ?? .infinity, box.minX)
                    rights[column] = max(rights[column] ?? -.infinity, box.maxX)
                }
                if cell.rowRange.count == 1, cell.rowRange.lowerBound < rowCount {
                    let row = cell.rowRange.lowerBound
                    tops[row] = min(tops[row] ?? .infinity, frame.maxY - box.maxY)
                    bottoms[row] = max(bottoms[row] ?? -.infinity, frame.maxY - box.minY)
                }
            }
        }
        let verticalRules = rules.filter { $0.height > $0.width * 4 && frame.insetBy(dx: -4, dy: -4).intersects($0) }.map { Double($0.midX) }
        let horizontalRules = rules.filter { $0.width > $0.height * 4 && frame.insetBy(dx: -4, dy: -4).intersects($0) }.map { Double(frame.maxY - $0.midY) }
        let columnEdges = snapped(edges(count: columnCount, start: frame.minX, end: frame.maxX, lows: lefts, highs: rights), to: verticalRules)
        let rowEdges = snapped(edges(count: rowCount, start: 0, end: frame.height, lows: tops, highs: bottoms), to: horizontalRules)

        // Which cell owns each slot (merged cells own every slot they cover).
        var cells = (0..<rowCount).map { _ in (0..<columnCount).map { _ in CellContent(lines: []) } }
        var owner = (0..<rowCount).map { r in (0..<columnCount).map { c in (r, c) } }
        for row in table.rows {
            for cell in row where cell.rowRange.lowerBound < rowCount && cell.columnRange.lowerBound < columnCount {
                let (r, c) = (cell.rowRange.lowerBound, cell.columnRange.lowerBound)
                cells[r][c].rowSpan = min(cell.rowRange.count, rowCount - r)
                cells[r][c].columnSpan = min(cell.columnRange.count, columnCount - c)
                for rr in cell.rowRange where rr < rowCount {
                    for cc in cell.columnRange where cc < columnCount && (rr, cc) != (r, c) {
                        cells[rr][cc].owner = (r, c)
                        owner[rr][cc] = (r, c)
                    }
                }
                if scanned, !cell.content.text.transcript.isEmpty {
                    let box = toDisplay(cell.content.boundingRegion.boundingBox.cgRect)
                    let lineCount = Double(max(1, cell.content.text.lines.count))
                    let size = max(6, min(36, (box.height / lineCount / 1.2 * 2).rounded() / 2))
                    cells[r][c].lines = [Line(glyphs: [Glyph(text: cell.content.text.transcript, frame: box, style: .init(family: nil, size: size))])]
                }
            }
        }

        var cellGlyphs = (0..<rowCount).map { _ in (0..<columnCount).map { _ in [Glyph]() } }
        let area = frame.insetBy(dx: -2, dy: -2)
        for (index, glyph) in glyphs.enumerated() where !glyph.frame.isNull {
            let center = CGPoint(x: glyph.frame.midX, y: glyph.frame.midY)
            guard area.contains(center) else { continue }
            used.insert(index)
            guard !scanned else { continue }
            let column = min(max(0, (columnEdges.lastIndex { $0 <= center.x } ?? 0)), columnCount - 1)
            let row = min(max(0, (rowEdges.lastIndex { $0 <= frame.maxY - center.y } ?? 0)), rowCount - 1)
            let (r, c) = owner[row][column]
            cellGlyphs[r][c].append(glyph)
        }
        if !scanned {
            for r in 0..<rowCount {
                for c in 0..<columnCount {
                    var withBreaks: [Glyph] = []
                    for glyph in cellGlyphs[r][c] {
                        if let last = withBreaks.last, abs(last.frame.minY - glyph.frame.minY) > glyph.style.size * 0.8 {
                            withBreaks.append(Glyph(text: "\n", frame: .null, style: glyph.style))
                        }
                        withBreaks.append(glyph)
                    }
                    cells[r][c].lines = lines(from: withBreaks)
                }
            }
        }
        return PlacedTable(frame: frame, columnEdges: columnEdges, cells: cells,
                           bordered: verticalRules.count + horizontalRules.count >= 3)
    }

    /// `count + 1` increasing edges from `start` to `end`, halfway between
    /// neighbours' extents; unknown edges are spread evenly between known ones.
    private static func edges(count: Int, start: Double, end: Double, lows: [Double?], highs: [Double?]) -> [Double] {
        var result = [Double?](repeating: nil, count: count + 1)
        result[0] = start
        result[count] = end
        for index in 1..<count {
            if let high = highs[index - 1], let low = lows[index], low > high - 1 {
                result[index] = (high + low) / 2
            }
        }
        var index = 0
        while index < count {
            var next = index + 1
            while result[next] == nil { next += 1 }
            let from = result[index]!, to = result[next]!
            if next - index > 1 {
                for missing in (index + 1)..<next {
                    result[missing] = from + (to - from) * Double(missing - index) / Double(next - index)
                }
            }
            index = next
        }
        return result.map { $0! }
    }

    /// Moves inner edges onto drawn rules when one is close: exact column widths for ruled tables.
    private static func snapped(_ edges: [Double], to rules: [Double]) -> [Double] {
        guard edges.count > 2 else { return edges }
        var result = edges
        for index in 1..<(edges.count - 1) {
            let limit = min(edges[index] - edges[index - 1], edges[index + 1] - edges[index]) / 2
            if let rule = rules.min(by: { abs($0 - edges[index]) < abs($1 - edges[index]) }), abs(rule - edges[index]) < limit {
                result[index] = rule
            }
        }
        return result
    }

    // MARK: Pictures

    /// The image as stored in the PDF (JPEG passed through untouched), or the
    /// page area it covers drawn at 200 DPI when it's placed turned or uses a
    /// colour space Cutie can't read directly.
    private static func picture(_ placement: PDFContent.ImagePlacement, frame: CGRect, page: PDFPage, display: CGAffineTransform) -> WordDocument.Picture? {
        let shown = placement.transform.concatenating(display)
        let upright = abs(shown.b) < 0.01 && abs(shown.c) < 0.01 && shown.a > 0 && shown.d > 0
        if upright, let (data, type) = extract(placement.stream) {
            return WordDocument.Picture(data: data, type: type, size: frame.size)
        }
        return renderedPicture(page, frame: frame)
    }

    private static func extract(_ stream: CGPDFStreamRef) -> (Data, String)? {
        guard let dictionary = CGPDFStreamGetDictionary(stream) else { return nil }
        var format = CGPDFDataFormat.raw
        guard let raw = CGPDFStreamCopyData(stream, &format) as Data? else { return nil }
        var smask: CGPDFStreamRef?
        let hasMask = CGPDFDictionaryGetStream(dictionary, "SMask", &smask)
        switch format {
        case .jpegEncoded where !hasMask:
            return (raw, "jpeg")
        case .jpegEncoded, .JPEG2000:
            guard let source = CGImageSourceCreateWithData(raw as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
            return png(masked(image, by: smask)).map { ($0, "png") }
        default:
            guard let image = rawImage(raw, dictionary: dictionary) else { return nil }
            return png(masked(image, by: smask)).map { ($0, "png") }
        }
    }

    private static func rawImage(_ data: Data, dictionary: CGPDFDictionaryRef) -> CGImage? {
        var width: CGPDFInteger = 0, height: CGPDFInteger = 0, bits: CGPDFInteger = 8
        guard CGPDFDictionaryGetInteger(dictionary, "Width", &width), CGPDFDictionaryGetInteger(dictionary, "Height", &height),
              width > 0, height > 0 else { return nil }
        _ = CGPDFDictionaryGetInteger(dictionary, "BitsPerComponent", &bits)
        var decode: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(dictionary, "Decode", &decode) { return nil }
        var object: CGPDFObjectRef?
        guard CGPDFDictionaryGetObject(dictionary, "ColorSpace", &object), let object,
              let (space, components) = colorSpace(object), [1, 2, 4, 8, 16].contains(bits) else { return nil }
        let bitsPerPixel = Int(bits) * components
        let bytesPerRow = (Int(width) * bitsPerPixel + 7) / 8
        guard data.count >= bytesPerRow * Int(height), let provider = CGDataProvider(data: data as CFData) else { return nil }
        let info: CGBitmapInfo = bits == 16 ? CGBitmapInfo(rawValue: CGImageByteOrderInfo.order16Big.rawValue) : []
        return CGImage(width: Int(width), height: Int(height), bitsPerComponent: Int(bits), bitsPerPixel: bitsPerPixel,
                       bytesPerRow: bytesPerRow, space: space, bitmapInfo: info, provider: provider,
                       decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    private static func colorSpace(_ object: CGPDFObjectRef) -> (CGColorSpace, Int)? {
        var name: UnsafePointer<CChar>?
        if CGPDFObjectGetValue(object, .name, &name), let name {
            switch String(cString: name) {
            case "DeviceRGB", "CalRGB": return (CGColorSpace(name: CGColorSpace.sRGB)!, 3)
            case "DeviceGray", "CalGray": return (CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!, 1)
            case "DeviceCMYK": return (CGColorSpace(name: CGColorSpace.genericCMYK)!, 4)
            default: return nil
            }
        }
        var array: CGPDFArrayRef?
        guard CGPDFObjectGetValue(object, .array, &array), let array else { return nil }
        var family: UnsafePointer<CChar>?
        guard CGPDFArrayGetName(array, 0, &family), let family else { return nil }
        switch String(cString: family) {
        case "ICCBased":
            var stream: CGPDFStreamRef?
            guard CGPDFArrayGetStream(array, 1, &stream), let stream else { return nil }
            var format = CGPDFDataFormat.raw
            var count: CGPDFInteger = 3
            if let dictionary = CGPDFStreamGetDictionary(stream) { _ = CGPDFDictionaryGetInteger(dictionary, "N", &count) }
            if let profile = CGPDFStreamCopyData(stream, &format), let space = CGColorSpace(iccData: profile) {
                return (space, Int(count))
            }
            switch count {
            case 1: return (CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!, 1)
            case 4: return (CGColorSpace(name: CGColorSpace.genericCMYK)!, 4)
            default: return (CGColorSpace(name: CGColorSpace.sRGB)!, 3)
            }
        case "Indexed", "I":
            var baseObject: CGPDFObjectRef?
            var last: CGPDFInteger = 0
            guard CGPDFArrayGetObject(array, 1, &baseObject), let baseObject, let (base, baseCount) = colorSpace(baseObject),
                  CGPDFArrayGetInteger(array, 2, &last) else { return nil }
            var table = Data()
            var string: CGPDFStringRef?
            var stream: CGPDFStreamRef?
            if CGPDFArrayGetString(array, 3, &string), let string, let bytes = CGPDFStringGetBytePtr(string) {
                table = Data(bytes: bytes, count: CGPDFStringGetLength(string))
            } else if CGPDFArrayGetStream(array, 3, &stream), let stream {
                var format = CGPDFDataFormat.raw
                table = (CGPDFStreamCopyData(stream, &format) as Data?) ?? Data()
            }
            guard table.count >= (Int(last) + 1) * baseCount else { return nil }
            let space = table.withUnsafeBytes { buffer in
                CGColorSpace(indexedBaseSpace: base, last: Int(last), colorTable: buffer.bindMemory(to: UInt8.self).baseAddress!)
            }
            return space.map { ($0, 1) }
        default:
            return nil
        }
    }

    /// Applies a soft mask (the PDF's alpha channel).
    private static func masked(_ image: CGImage, by stream: CGPDFStreamRef?) -> CGImage {
        guard let stream, let dictionary = CGPDFStreamGetDictionary(stream) else { return image }
        var format = CGPDFDataFormat.raw
        guard let data = CGPDFStreamCopyData(stream, &format) as Data?, format == .raw else { return image }
        var width: CGPDFInteger = 0, height: CGPDFInteger = 0
        guard CGPDFDictionaryGetInteger(dictionary, "Width", &width), CGPDFDictionaryGetInteger(dictionary, "Height", &height),
              data.count >= Int(width * height), let provider = CGDataProvider(data: data as CFData),
              // Inverted decode: the mask's samples act as alpha, not as "inverse alpha".
              let mask = CGImage(width: Int(width), height: Int(height), bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: Int(width),
                                 space: CGColorSpaceCreateDeviceGray(), bitmapInfo: [], provider: provider,
                                 decode: [1, 0], shouldInterpolate: true, intent: .defaultIntent),
              let result = rgb(image)?.masking(mask) else { return image }
        return result
    }

    private static func rgb(_ image: CGImage) -> CGImage? {
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }

    private static func png(_ image: CGImage) -> Data? {
        var image = image
        if image.colorSpace?.model == .cmyk || image.colorSpace?.model == .indexed, let converted = rgb(image) { image = converted }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// The page area `frame` (display coordinates) drawn at 200 DPI, as PNG.
    static func renderedPicture(_ page: PDFPage, frame: CGRect) -> WordDocument.Picture? {
        let scale = 200.0 / 72
        let width = max(1, Int(frame.width * scale)), height = max(1, Int(frame.height * scale))
        guard width * height < 60_000_000,
              let context = ImageConverter.bitmapContext(width: width, height: height, alpha: false) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -frame.minX, y: -frame.minY)
        page.draw(with: .cropBox, to: context)
        guard let image = context.makeImage(), let data = png(image) else { return nil }
        return WordDocument.Picture(data: data, type: "png", size: frame.size)
    }

    /// Clusters of drawn shapes that look like a chart or diagram (curves, or
    /// many shapes together), not table rules, page borders or text boxes.
    private static func figureFrames(_ paths: [(PDFContent.PaintedPath, CGRect)], size: CGSize, avoiding: [CGRect], glyphs: [Glyph]) -> [CGRect] {
        let pageArea = size.width * size.height
        var clusters: [(frame: CGRect, members: [PDFContent.PaintedPath])] = paths.compactMap { path, frame in
            let area = frame.width * frame.height
            guard area < pageArea * 0.5, !avoiding.contains(where: { $0.insetBy(dx: -4, dy: -4).contains(frame) }) else { return nil }
            return (frame, [path])
        }
        var merged = true
        while merged {
            merged = false
            var index = 0
            while index < clusters.count {
                var other = index + 1
                while other < clusters.count {
                    if clusters[index].frame.insetBy(dx: -16, dy: -16).intersects(clusters[other].frame) {
                        clusters[index].frame = clusters[index].frame.union(clusters[other].frame)
                        clusters[index].members += clusters[other].members
                        clusters.remove(at: other)
                        merged = true
                    } else {
                        other += 1
                    }
                }
                index += 1
            }
        }
        let textGlyphs = glyphs.filter { !$0.frame.isNull && !$0.isSpace }
        return clusters.compactMap { cluster in
            let frame = cluster.frame.intersection(CGRect(origin: .zero, size: size))
            let area = frame.width * frame.height
            guard !frame.isNull, area >= 2_500, area < pageArea * 0.6 else { return nil }
            let onlyRules = cluster.members.allSatisfy { !$0.curves && (min($0.frame.width, $0.frame.height) <= 2.5 || !$0.filled) && $0.segments <= 4 }
            let shapes = cluster.members.filter { $0.filled && min($0.frame.width, $0.frame.height) > 2.5 }.count
            let drawn = (cluster.members.contains(where: \.curves) && cluster.members.count >= 3) || cluster.members.count >= 6 || shapes >= 3
            guard drawn, !onlyRules else { return nil }
            guard !avoiding.contains(where: { $0.intersection(frame).width * $0.intersection(frame).height > area * 0.3 }) else { return nil }
            // A box full of text is a text box, not a chart: keep its text editable.
            let inside = textGlyphs.filter { frame.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) }
            let textArea = inside.reduce(0) { $0 + $1.frame.width * $1.frame.height }
            guard textArea < area * 0.12, textGlyphs.isEmpty || Double(inside.count) < Double(textGlyphs.count) * 0.4 else { return nil }
            return frame
        }
    }

    // MARK: Vision

    static func document(in image: CGImage) async throws -> DocumentObservation.Container? {
        var request = RecognizeDocumentsRequest()
        request.textRecognitionOptions.automaticallyDetectLanguage = true
        request.textRecognitionOptions.useLanguageCorrection = true
        return try await request.perform(on: image).first?.document
    }
}
