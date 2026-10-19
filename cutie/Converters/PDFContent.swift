import CoreGraphics
import CoreText
import Foundation

/// What a PDF page's content stream draws, read with `CGPDFScanner`: where each
/// piece of text starts and ends and in which font (PDFKit's own text falls
/// back to Times for fonts this Mac doesn't have, losing bold and italic), the
/// images and where they sit, and the painted paths (table rules, charts).
/// All positions are in the page's user space.
nonisolated final class PDFContent {
    struct TextRun {
        var start: CGPoint
        var end: CGPoint
        var size: Double
        var font: FontInfo
        var color: RGB?
        /// Render mode 3: invisible text, like an OCR layer over a scan.
        var invisible: Bool
    }

    struct FontInfo: Hashable {
        var family: String
        var bold: Bool
        var italic: Bool
    }

    struct RGB: Hashable {
        var red: Double, green: Double, blue: Double
        var hex: String {
            String(format: "%02X%02X%02X", Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()))
        }
        var isBlack: Bool { max(red, green, blue) < 0.08 }
    }

    struct ImagePlacement {
        /// Maps the unit square onto the page.
        var transform: CGAffineTransform
        var stream: CGPDFStreamRef
        var frame: CGRect { CGRect(x: 0, y: 0, width: 1, height: 1).applying(transform) }
    }

    struct PaintedPath {
        var frame: CGRect
        var curves: Bool
        var segments: Int
        var filled: Bool
    }

    private(set) var runs: [TextRun] = []
    private(set) var images: [ImagePlacement] = []
    private(set) var paths: [PaintedPath] = []
    /// Straight horizontal and vertical strokes and hairline boxes: table rules, underlines.
    private(set) var rules: [CGRect] = []

    // Graphics and text state.
    private struct State {
        var ctm = CGAffineTransform.identity
        var fill: RGB? = RGB(red: 0, green: 0, blue: 0)
        var fillComponents = 1
        var lineWidth = 1.0
        var font: Font?
        var fontSize = 12.0
        var characterSpacing = 0.0
        var wordSpacing = 0.0
        var horizontalScale = 1.0
        var leading = 0.0
        var rise = 0.0
        var renderMode = 0
    }

    private var state = State()
    private var stack: [State] = []
    private var textMatrix = CGAffineTransform.identity
    private var lineMatrix = CGAffineTransform.identity
    private var path = PathBuilder()
    private var fonts: [String: Font] = [:]
    private var depth = 0

    private struct PathBuilder {
        var bounds = CGRect.null
        var curves = false
        var segments = 0
        var current = CGPoint.zero
        /// Straight segments in page space, for rules.
        var lines: [(CGPoint, CGPoint)] = []
        var rects: [CGRect] = []

        mutating func add(_ point: CGPoint) {
            bounds = bounds.union(CGRect(origin: point, size: .zero))
        }
    }

    // MARK: Fonts

    private final class Font {
        let info: FontInfo
        let twoByte: Bool
        let widths: [Int: Double]
        let defaultWidth: Double
        let scale: Double

        init(dictionary: CGPDFDictionaryRef) {
            let subtype = PDFContent.name(dictionary, "Subtype") ?? ""
            var baseName = PDFContent.name(dictionary, "BaseFont") ?? ""
            var widths: [Int: Double] = [:]
            var defaultWidth = 0.0
            var descriptor: CGPDFDictionaryRef?
            twoByte = subtype == "Type0"
            if twoByte {
                var descendants: CGPDFArrayRef?
                var descendant: CGPDFDictionaryRef?
                if CGPDFDictionaryGetArray(dictionary, "DescendantFonts", &descendants), let descendants,
                   CGPDFArrayGetDictionary(descendants, 0, &descendant), let descendant {
                    if let name = PDFContent.name(descendant, "BaseFont"), baseName.isEmpty { baseName = name }
                    var dw: CGPDFReal = 1000
                    _ = CGPDFDictionaryGetNumber(descendant, "DW", &dw)
                    defaultWidth = Double(dw)
                    var w: CGPDFArrayRef?
                    if CGPDFDictionaryGetArray(descendant, "W", &w), let w { widths = Font.cidWidths(w) }
                    CGPDFDictionaryGetDictionary(descendant, "FontDescriptor", &descriptor)
                }
            } else {
                var first: CGPDFInteger = 0
                _ = CGPDFDictionaryGetInteger(dictionary, "FirstChar", &first)
                var array: CGPDFArrayRef?
                if CGPDFDictionaryGetArray(dictionary, "Widths", &array), let array {
                    for index in 0..<CGPDFArrayGetCount(array) {
                        var value: CGPDFReal = 0
                        if CGPDFArrayGetNumber(array, index, &value) { widths[Int(first) + index] = Double(value) }
                    }
                }
                CGPDFDictionaryGetDictionary(dictionary, "FontDescriptor", &descriptor)
                if let descriptor {
                    var missing: CGPDFReal = 0
                    if CGPDFDictionaryGetNumber(descriptor, "MissingWidth", &missing) { defaultWidth = Double(missing) }
                }
                if widths.isEmpty { defaultWidth = 500 } // a standard font with no widths: an average
            }
            var matrix: CGPDFArrayRef?
            var a: CGPDFReal = 0.001
            if subtype == "Type3", CGPDFDictionaryGetArray(dictionary, "FontMatrix", &matrix), let matrix {
                _ = CGPDFArrayGetNumber(matrix, 0, &a)
            }
            scale = subtype == "Type3" ? Double(a) : 0.001

            var bold = false, italic = false
            if let descriptor {
                var flags: CGPDFInteger = 0
                if CGPDFDictionaryGetInteger(descriptor, "Flags", &flags) {
                    italic = flags & 64 != 0
                    bold = flags & (1 << 18) != 0
                }
                var weight: CGPDFReal = 0
                if CGPDFDictionaryGetNumber(descriptor, "FontWeight", &weight), weight >= 600 { bold = true }
                var angle: CGPDFReal = 0
                if CGPDFDictionaryGetNumber(descriptor, "ItalicAngle", &angle), angle != 0 { italic = true }
            }
            info = Font.info(fromName: baseName, bold: bold, italic: italic)
            self.widths = widths
            self.defaultWidth = defaultWidth
        }

        /// `[c [w1 w2 …]]` and `[cFirst cLast w]` runs.
        private static func cidWidths(_ array: CGPDFArrayRef) -> [Int: Double] {
            var result: [Int: Double] = [:]
            var index = 0
            let count = CGPDFArrayGetCount(array)
            while index < count {
                var first: CGPDFInteger = 0
                guard CGPDFArrayGetInteger(array, index, &first) else { break }
                var list: CGPDFArrayRef?
                if CGPDFArrayGetArray(array, index + 1, &list), let list {
                    for offset in 0..<CGPDFArrayGetCount(list) {
                        var width: CGPDFReal = 0
                        if CGPDFArrayGetNumber(list, offset, &width) { result[Int(first) + offset] = Double(width) }
                    }
                    index += 2
                } else {
                    var last: CGPDFInteger = 0
                    var width: CGPDFReal = 0
                    guard CGPDFArrayGetInteger(array, index + 1, &last), CGPDFArrayGetNumber(array, index + 2, &width),
                          last >= first, last - first < 65_536 else { break }
                    for code in Int(first)...Int(last) { result[code] = Double(width) }
                    index += 3
                }
            }
            return result
        }

        /// "ABCDEF+TimesNewRomanPS-BoldItalicMT" → Times New Roman, bold, italic.
        static func info(fromName raw: String, bold: Bool, italic: Bool) -> FontInfo {
            var name = raw
            if let plus = name.firstIndex(of: "+"), name.distance(from: name.startIndex, to: plus) == 6 {
                name = String(name[name.index(after: plus)...])
            }
            let lower = name.lowercased()
            let isBold = bold || ["bold", "black", "heavy", "semibold", "demi"].contains { lower.contains($0) }
            let isItalic = italic || lower.contains("italic") || lower.contains("oblique")
            return FontInfo(family: family(of: name), bold: isBold, italic: isItalic)
        }

        static func family(of postScriptName: String) -> String {
            if postScriptName.hasPrefix(".SF") || postScriptName.hasPrefix("SFPro") || postScriptName.isEmpty { return "Helvetica Neue" }
            let font = CTFontCreateWithName(postScriptName as CFString, 12, nil)
            if (CTFontCopyPostScriptName(font) as String) == postScriptName {
                return CTFontCopyFamilyName(font) as String
            }
            // Not on this Mac: "TimesNewRomanPS-BoldMT" → "Times New Roman".
            var base = String(postScriptName.split(separator: "-").first ?? Substring(postScriptName))
            for suffix in ["PSMT", "MT", "PS", "Std", "Pro", "LT"] where base.hasSuffix(suffix) && base.count > suffix.count + 2 {
                base.removeLast(suffix.count)
            }
            base = base.replacingOccurrences(of: ",", with: " ")
            var spaced = ""
            for (index, character) in base.enumerated() {
                if index > 0, character.isUppercase, let previous = spaced.last, previous.isLowercase { spaced.append(" ") }
                spaced.append(character)
            }
            return spaced
        }

        func advance(of string: CGPDFStringRef, size: Double, characterSpacing: Double, wordSpacing: Double) -> Double {
            guard let bytes = CGPDFStringGetBytePtr(string) else { return 0 }
            let length = CGPDFStringGetLength(string)
            var total = 0.0
            if twoByte {
                var index = 0
                while index + 1 < length {
                    let code = Int(bytes[index]) << 8 | Int(bytes[index + 1])
                    total += (widths[code] ?? defaultWidth) * scale * size + characterSpacing
                    index += 2
                }
            } else {
                for index in 0..<length {
                    let code = Int(bytes[index])
                    total += (widths[code] ?? defaultWidth) * scale * size + characterSpacing
                    if code == 32 { total += wordSpacing }
                }
            }
            return total
        }
    }

    // MARK: Scanning

    init(page: CGPDFPage) {
        guard let table = CGPDFOperatorTableCreate() else { return }
        PDFContent.register(table)
        scan(CGPDFContentStreamCreateWithPage(page), table: table)
        CGPDFOperatorTableRelease(table)
    }

    private func scan(_ stream: CGPDFContentStreamRef, table: CGPDFOperatorTableRef) {
        let scanner = CGPDFScannerCreate(stream, table, Unmanaged.passUnretained(self).toOpaque())
        CGPDFScannerScan(scanner)
        CGPDFScannerRelease(scanner)
        CGPDFContentStreamRelease(stream)
    }

    private static func me(_ info: UnsafeMutableRawPointer?) -> PDFContent {
        Unmanaged<PDFContent>.fromOpaque(info!).takeUnretainedValue()
    }

    private static func numbers(_ scanner: CGPDFScannerRef, _ count: Int) -> [Double]? {
        var values = [Double](repeating: 0, count: count)
        for index in stride(from: count - 1, through: 0, by: -1) {
            var value: CGPDFReal = 0
            guard CGPDFScannerPopNumber(scanner, &value) else { return nil }
            values[index] = Double(value)
        }
        return values
    }

    private static func point(_ scanner: CGPDFScannerRef) -> CGPoint? {
        numbers(scanner, 2).map { CGPoint(x: $0[0], y: $0[1]) }
    }

    private static func name(_ dictionary: CGPDFDictionaryRef, _ key: String) -> String? {
        var value: UnsafePointer<CChar>?
        guard CGPDFDictionaryGetName(dictionary, key, &value), let value else { return nil }
        return String(cString: value)
    }

    private static func register(_ table: CGPDFOperatorTableRef) {
        CGPDFOperatorTableSetCallback(table, "q") { _, info in let me = PDFContent.me(info); me.stack.append(me.state) }
        CGPDFOperatorTableSetCallback(table, "Q") { _, info in let me = PDFContent.me(info); if let last = me.stack.popLast() { me.state = last } }
        CGPDFOperatorTableSetCallback(table, "cm") { scanner, info in
            guard let n = PDFContent.numbers(scanner, 6) else { return }
            let me = PDFContent.me(info)
            me.state.ctm = CGAffineTransform(a: n[0], b: n[1], c: n[2], d: n[3], tx: n[4], ty: n[5]).concatenating(me.state.ctm)
        }
        CGPDFOperatorTableSetCallback(table, "w") { scanner, info in
            if let n = PDFContent.numbers(scanner, 1) { PDFContent.me(info).state.lineWidth = n[0] }
        }

        // Colour (fill only: that's the text colour).
        CGPDFOperatorTableSetCallback(table, "g") { scanner, info in
            if let n = PDFContent.numbers(scanner, 1) { PDFContent.me(info).state.fill = RGB(red: n[0], green: n[0], blue: n[0]) }
        }
        CGPDFOperatorTableSetCallback(table, "rg") { scanner, info in
            if let n = PDFContent.numbers(scanner, 3) { PDFContent.me(info).state.fill = RGB(red: n[0], green: n[1], blue: n[2]) }
        }
        CGPDFOperatorTableSetCallback(table, "k") { scanner, info in
            if let n = PDFContent.numbers(scanner, 4) { PDFContent.me(info).state.fill = PDFContent.cmyk(n) }
        }
        CGPDFOperatorTableSetCallback(table, "cs") { scanner, info in
            var value: UnsafePointer<CChar>?
            guard CGPDFScannerPopName(scanner, &value), let value else { return }
            let me = PDFContent.me(info)
            switch String(cString: value) {
            case "DeviceGray", "CalGray": me.state.fillComponents = 1
            case "DeviceCMYK": me.state.fillComponents = 4
            case "Pattern": me.state.fillComponents = 0
            default: me.state.fillComponents = 3
            }
        }
        let setColor: CGPDFOperatorCallback = { scanner, info in
            let me = PDFContent.me(info)
            let count = me.state.fillComponents
            guard count > 0, let n = PDFContent.numbers(scanner, count) else { me.state.fill = nil; return }
            switch count {
            case 1: me.state.fill = RGB(red: n[0], green: n[0], blue: n[0])
            case 4: me.state.fill = PDFContent.cmyk(n)
            default: me.state.fill = RGB(red: n[0], green: n[1], blue: n[2])
            }
        }
        CGPDFOperatorTableSetCallback(table, "sc", setColor)
        CGPDFOperatorTableSetCallback(table, "scn", setColor)

        // Text.
        CGPDFOperatorTableSetCallback(table, "BT") { _, info in
            let me = PDFContent.me(info)
            me.textMatrix = .identity
            me.lineMatrix = .identity
        }
        CGPDFOperatorTableSetCallback(table, "Tf") { scanner, info in
            var size: CGPDFReal = 0
            var value: UnsafePointer<CChar>?
            guard CGPDFScannerPopNumber(scanner, &size), CGPDFScannerPopName(scanner, &value), let value else { return }
            let me = PDFContent.me(info)
            me.state.fontSize = Double(size)
            me.state.font = me.font(named: String(cString: value), scanner: scanner)
        }
        CGPDFOperatorTableSetCallback(table, "Tc") { scanner, info in if let n = PDFContent.numbers(scanner, 1) { PDFContent.me(info).state.characterSpacing = n[0] } }
        CGPDFOperatorTableSetCallback(table, "Tw") { scanner, info in if let n = PDFContent.numbers(scanner, 1) { PDFContent.me(info).state.wordSpacing = n[0] } }
        CGPDFOperatorTableSetCallback(table, "Tz") { scanner, info in if let n = PDFContent.numbers(scanner, 1) { PDFContent.me(info).state.horizontalScale = n[0] / 100 } }
        CGPDFOperatorTableSetCallback(table, "TL") { scanner, info in if let n = PDFContent.numbers(scanner, 1) { PDFContent.me(info).state.leading = n[0] } }
        CGPDFOperatorTableSetCallback(table, "Ts") { scanner, info in if let n = PDFContent.numbers(scanner, 1) { PDFContent.me(info).state.rise = n[0] } }
        CGPDFOperatorTableSetCallback(table, "Tr") { scanner, info in if let n = PDFContent.numbers(scanner, 1) { PDFContent.me(info).state.renderMode = Int(n[0]) } }
        CGPDFOperatorTableSetCallback(table, "Td") { scanner, info in
            guard let p = PDFContent.point(scanner) else { return }
            PDFContent.me(info).moveLine(p.x, p.y)
        }
        CGPDFOperatorTableSetCallback(table, "TD") { scanner, info in
            guard let p = PDFContent.point(scanner) else { return }
            let me = PDFContent.me(info)
            me.state.leading = -p.y
            me.moveLine(p.x, p.y)
        }
        CGPDFOperatorTableSetCallback(table, "Tm") { scanner, info in
            guard let n = PDFContent.numbers(scanner, 6) else { return }
            let me = PDFContent.me(info)
            me.lineMatrix = CGAffineTransform(a: n[0], b: n[1], c: n[2], d: n[3], tx: n[4], ty: n[5])
            me.textMatrix = me.lineMatrix
        }
        CGPDFOperatorTableSetCallback(table, "T*") { _, info in let me = PDFContent.me(info); me.moveLine(0, -me.state.leading) }
        CGPDFOperatorTableSetCallback(table, "Tj") { scanner, info in
            var string: CGPDFStringRef?
            guard CGPDFScannerPopString(scanner, &string), let string else { return }
            PDFContent.me(info).show([.string(string)])
        }
        CGPDFOperatorTableSetCallback(table, "'") { scanner, info in
            var string: CGPDFStringRef?
            guard CGPDFScannerPopString(scanner, &string), let string else { return }
            let me = PDFContent.me(info)
            me.moveLine(0, -me.state.leading)
            me.show([.string(string)])
        }
        CGPDFOperatorTableSetCallback(table, "\"") { scanner, info in
            var string: CGPDFStringRef?
            guard CGPDFScannerPopString(scanner, &string), let string, let n = PDFContent.numbers(scanner, 2) else { return }
            let me = PDFContent.me(info)
            me.state.wordSpacing = n[0]
            me.state.characterSpacing = n[1]
            me.moveLine(0, -me.state.leading)
            me.show([.string(string)])
        }
        CGPDFOperatorTableSetCallback(table, "TJ") { scanner, info in
            var array: CGPDFArrayRef?
            guard CGPDFScannerPopArray(scanner, &array), let array else { return }
            var parts: [ShowPart] = []
            for index in 0..<CGPDFArrayGetCount(array) {
                var string: CGPDFStringRef?
                var number: CGPDFReal = 0
                if CGPDFArrayGetString(array, index, &string), let string {
                    parts.append(.string(string))
                } else if CGPDFArrayGetNumber(array, index, &number) {
                    parts.append(.adjust(Double(number)))
                }
            }
            PDFContent.me(info).show(parts)
        }

        // Paths.
        CGPDFOperatorTableSetCallback(table, "m") { scanner, info in
            guard let p = PDFContent.point(scanner) else { return }
            let me = PDFContent.me(info)
            me.path.current = p
            me.path.add(p.applying(me.state.ctm))
        }
        CGPDFOperatorTableSetCallback(table, "l") { scanner, info in
            guard let p = PDFContent.point(scanner) else { return }
            let me = PDFContent.me(info)
            me.path.lines.append((me.path.current.applying(me.state.ctm), p.applying(me.state.ctm)))
            me.path.current = p
            me.path.segments += 1
            me.path.add(p.applying(me.state.ctm))
        }
        CGPDFOperatorTableSetCallback(table, "c") { scanner, info in PDFContent.curve(scanner, info, 6) }
        CGPDFOperatorTableSetCallback(table, "v") { scanner, info in PDFContent.curve(scanner, info, 4) }
        CGPDFOperatorTableSetCallback(table, "y") { scanner, info in PDFContent.curve(scanner, info, 4) }
        CGPDFOperatorTableSetCallback(table, "re") { scanner, info in
            guard let n = PDFContent.numbers(scanner, 4) else { return }
            let me = PDFContent.me(info)
            let rect = CGRect(x: n[0], y: n[1], width: n[2], height: n[3]).applying(me.state.ctm)
            me.path.bounds = me.path.bounds.union(rect)
            me.path.rects.append(rect)
            me.path.segments += 4
        }
        for (op, fill, stroke) in [("S", false, true), ("s", false, true), ("f", true, false), ("F", true, false), ("f*", true, false),
                                   ("B", true, true), ("B*", true, true), ("b", true, true), ("b*", true, true)] {
            let callback: CGPDFOperatorCallback = switch (fill, stroke) {
            case (true, true): { _, info in PDFContent.me(info).paint(fill: true, stroke: true) }
            case (true, false): { _, info in PDFContent.me(info).paint(fill: true, stroke: false) }
            default: { _, info in PDFContent.me(info).paint(fill: false, stroke: true) }
            }
            CGPDFOperatorTableSetCallback(table, op, callback)
        }
        CGPDFOperatorTableSetCallback(table, "n") { _, info in PDFContent.me(info).path = PathBuilder() }

        // Images and forms.
        CGPDFOperatorTableSetCallback(table, "Do") { scanner, info in
            var value: UnsafePointer<CChar>?
            guard CGPDFScannerPopName(scanner, &value), let value else { return }
            PDFContent.me(info).drawObject(named: String(cString: value), scanner: scanner)
        }
    }

    private static func curve(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?, _ count: Int) {
        guard let n = numbers(scanner, count) else { return }
        let me = me(info)
        for index in stride(from: 0, to: count, by: 2) { me.path.add(CGPoint(x: n[index], y: n[index + 1]).applying(me.state.ctm)) }
        me.path.current = CGPoint(x: n[count - 2], y: n[count - 1])
        me.path.curves = true
        me.path.segments += 1
    }

    private static func cmyk(_ n: [Double]) -> RGB {
        RGB(red: (1 - n[0]) * (1 - n[3]), green: (1 - n[1]) * (1 - n[3]), blue: (1 - n[2]) * (1 - n[3]))
    }

    private enum ShowPart {
        case string(CGPDFStringRef)
        case adjust(Double)
    }

    private func moveLine(_ x: Double, _ y: Double) {
        lineMatrix = CGAffineTransform(translationX: x, y: y).concatenating(lineMatrix)
        textMatrix = lineMatrix
    }

    private func show(_ parts: [ShowPart]) {
        guard let font = state.font else { return }
        let size = state.fontSize
        let toPage = textMatrix.concatenating(state.ctm)
        let start = CGPoint(x: 0, y: state.rise).applying(toPage)
        for part in parts {
            switch part {
            case .string(let string):
                let advance = font.advance(of: string, size: size, characterSpacing: state.characterSpacing,
                                           wordSpacing: state.wordSpacing) * state.horizontalScale
                textMatrix = CGAffineTransform(translationX: advance, y: 0).concatenating(textMatrix)
            case .adjust(let amount):
                textMatrix = CGAffineTransform(translationX: -amount / 1000 * size * state.horizontalScale, y: 0).concatenating(textMatrix)
            }
        }
        let end = CGPoint(x: 0, y: state.rise).applying(textMatrix.concatenating(state.ctm))
        let scaleY = hypot(toPage.c, toPage.d)
        runs.append(TextRun(start: start, end: end, size: size * scaleY, font: font.info, color: state.fill,
                            invisible: state.renderMode == 3 || state.renderMode == 7))
    }

    private func paint(fill: Bool, stroke: Bool) {
        let width = max(0.5, state.lineWidth * hypot(state.ctm.a, state.ctm.b))
        if stroke {
            for (from, to) in path.lines where abs(from.x - to.x) < 0.5 || abs(from.y - to.y) < 0.5 {
                rules.append(CGRect(x: min(from.x, to.x), y: min(from.y, to.y), width: abs(to.x - from.x), height: abs(to.y - from.y))
                    .insetBy(dx: -width / 2, dy: -width / 2))
            }
        }
        for rect in path.rects {
            if min(rect.width, rect.height) <= 2.5, fill || stroke {
                rules.append(rect)
            } else if stroke {
                // A stroked box: four rules.
                for edge in [CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: 0), CGRect(x: rect.minX, y: rect.maxY, width: rect.width, height: 0),
                             CGRect(x: rect.minX, y: rect.minY, width: 0, height: rect.height), CGRect(x: rect.maxX, y: rect.minY, width: 0, height: rect.height)] {
                    rules.append(edge.insetBy(dx: -width / 2, dy: -width / 2))
                }
            }
        }
        if !path.bounds.isNull {
            var frame = path.bounds
            if stroke {
                let width = state.lineWidth * hypot(state.ctm.a, state.ctm.b)
                frame = frame.insetBy(dx: -width / 2, dy: -width / 2)
            }
            paths.append(PaintedPath(frame: frame, curves: path.curves, segments: path.segments, filled: fill))
        }
        path = PathBuilder()
    }

    private func font(named name: String, scanner: CGPDFScannerRef) -> Font? {
        let stream = CGPDFScannerGetContentStream(scanner)
        guard let object = CGPDFContentStreamGetResource(stream, "Font", name) else { return fonts[name] }
        var dictionary: CGPDFDictionaryRef?
        guard CGPDFObjectGetValue(object, .dictionary, &dictionary), let dictionary else { return nil }
        let key = "\(name)-\(String(describing: dictionary))"
        if let cached = fonts[key] { return cached }
        let font = Font(dictionary: dictionary)
        fonts[key] = font
        return font
    }

    private func drawObject(named name: String, scanner: CGPDFScannerRef) {
        let content = CGPDFScannerGetContentStream(scanner)
        guard let object = CGPDFContentStreamGetResource(content, "XObject", name) else { return }
        var stream: CGPDFStreamRef?
        guard CGPDFObjectGetValue(object, .stream, &stream), let stream, let dictionary = CGPDFStreamGetDictionary(stream) else { return }
        switch PDFContent.name(dictionary, "Subtype") {
        case "Image":
            var mask = false
            if CGPDFDictionaryGetBoolean(dictionary, "ImageMask", &mask), mask { return }
            images.append(ImagePlacement(transform: state.ctm, stream: stream))
        case "Form":
            guard depth < 12, let table = CGPDFOperatorTableCreate() else { return }
            var resources: CGPDFDictionaryRef?
            CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources)
            let saved = state
            var matrix: CGPDFArrayRef?
            if CGPDFDictionaryGetArray(dictionary, "Matrix", &matrix), let matrix, CGPDFArrayGetCount(matrix) == 6 {
                var n = [CGPDFReal](repeating: 0, count: 6)
                for index in 0..<6 { _ = CGPDFArrayGetNumber(matrix, index, &n[index]) }
                state.ctm = CGAffineTransform(a: n[0], b: n[1], c: n[2], d: n[3], tx: n[4], ty: n[5]).concatenating(state.ctm)
            }
            PDFContent.register(table)
            depth += 1
            scan(CGPDFContentStreamCreateWithStream(stream, resources ?? dictionary, content), table: table)
            depth -= 1
            CGPDFOperatorTableRelease(table)
            state = saved
        default:
            break
        }
    }
}
