import Foundation
import PDFKit

/// PDF → PowerPoint: one slide per page, each page a full-slide picture
/// (what PDF-to-slides tools do; text isn't editable). The package is the
/// smallest set of parts PowerPoint and Keynote open without repairs.
nonisolated enum PowerPoint {
    static func write(from input: URL, to output: URL, scratch: Scratch, context: JobContext) async throws {
        let document = try PDFConverter.open(input)
        guard document.pageCount > 0, let first = document.page(at: 0) else { throw CutieError("This PDF has no pages.") }

        let root = try scratch.folder("pptx-" + UUID().uuidString)
        for folder in ["_rels", "ppt/_rels", "ppt/slides/_rels", "ppt/slideLayouts/_rels", "ppt/slideMasters/_rels", "ppt/theme", "ppt/media"] {
            try FileManager.default.createDirectory(at: root.appending(path: folder), withIntermediateDirectories: true)
        }
        func put(_ path: String, _ text: String) throws {
            try Data(text.utf8).write(to: root.appending(path: path))
        }

        // Slide size follows the first page (EMU: 12,700 per point), within PowerPoint's limits.
        let firstSize = displaySize(first)
        let slideWidth = clampEMU(Double(firstSize.width) * 12_700)
        let slideHeight = clampEMU(Double(firstSize.height) * 12_700)

        var slideOverrides = ""
        var slideIDs = ""
        var slideRels = ""
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else { continue }
            let number = index + 1
            try ImageConverter.write(try PDFConverter.render(page, dpi: 200), as: .png,
                                     to: root.appending(path: "ppt/media/image\(number).png"), quality: 1)

            // Fit the page inside the slide, centered.
            let size = displaySize(page)
            let pageWidth = Double(size.width) * 12_700
            let pageHeight = Double(size.height) * 12_700
            let scale = min(Double(slideWidth) / pageWidth, Double(slideHeight) / pageHeight)
            let width = Int(pageWidth * scale), height = Int(pageHeight * scale)
            let x = (slideWidth - width) / 2, y = (slideHeight - height) / 2

            try put("ppt/slides/slide\(number).xml", """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <p:sld \(namespaces)><p:cSld><p:spTree>
            <p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>
            <p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>
            <p:pic><p:nvPicPr><p:cNvPr id="2" name="Page \(number)"/><p:cNvPicPr><a:picLocks noChangeAspect="1"/></p:cNvPicPr><p:nvPr/></p:nvPicPr>
            <p:blipFill><a:blip r:embed="rId2"/><a:stretch><a:fillRect/></a:stretch></p:blipFill>
            <p:spPr><a:xfrm><a:off x="\(x)" y="\(y)"/><a:ext cx="\(width)" cy="\(height)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr></p:pic>
            </p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>
            """)
            try put("ppt/slides/_rels/slide\(number).xml.rels", relationships([
                ("rId1", "slideLayout", "../slideLayouts/slideLayout1.xml"),
                ("rId2", "image", "../media/image\(number).png"),
            ]))
            slideOverrides += #"<Override PartName="/ppt/slides/slide\#(number).xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slide+xml"/>"#
            slideIDs += #"<p:sldId id="\#(255 + number)" r:id="rId\#(number + 2)"/>"#
            slideRels += #"<Relationship Id="rId\#(number + 2)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" Target="slides/slide\#(number).xml"/>"#
            context.progress(Double(number) / Double(document.pageCount))
        }

        try put("[Content_Types].xml", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
        <Default Extension="xml" ContentType="application/xml"/>
        <Default Extension="png" ContentType="image/png"/>
        <Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/>
        <Override PartName="/ppt/slideMasters/slideMaster1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml"/>
        <Override PartName="/ppt/slideLayouts/slideLayout1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml"/>
        <Override PartName="/ppt/theme/theme1.xml" ContentType="application/vnd.openxmlformats-officedocument.theme+xml"/>
        \(slideOverrides)
        </Types>
        """)
        try put("_rels/.rels", relationships([("rId1", "officeDocument", "ppt/presentation.xml")]))
        try put("ppt/presentation.xml", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:presentation \(namespaces)>
        <p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rId1"/></p:sldMasterIdLst>
        <p:sldIdLst>\(slideIDs)</p:sldIdLst>
        <p:sldSz cx="\(slideWidth)" cy="\(slideHeight)"/>
        <p:notesSz cx="6858000" cy="9144000"/>
        </p:presentation>
        """)
        try put("ppt/_rels/presentation.xml.rels", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" Target="slideMasters/slideMaster1.xml"/>
        <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme" Target="theme/theme1.xml"/>
        \(slideRels)
        </Relationships>
        """)
        try put("ppt/slideMasters/slideMaster1.xml", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:sldMaster \(namespaces)><p:cSld><p:bg><p:bgRef idx="1001"><a:schemeClr val="bg1"/></p:bgRef></p:bg><p:spTree>\(emptyTree)</p:spTree></p:cSld>
        <p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" accent3="accent3" accent4="accent4" accent5="accent5" accent6="accent6" hlink="hlink" folHlink="folHlink"/>
        <p:sldLayoutIdLst><p:sldLayoutId id="2147483649" r:id="rId1"/></p:sldLayoutIdLst>
        </p:sldMaster>
        """)
        try put("ppt/slideMasters/_rels/slideMaster1.xml.rels", relationships([
            ("rId1", "slideLayout", "../slideLayouts/slideLayout1.xml"),
            ("rId2", "theme", "../theme/theme1.xml"),
        ]))
        try put("ppt/slideLayouts/slideLayout1.xml", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:sldLayout \(namespaces) type="blank" preserve="1"><p:cSld name="Blank"><p:spTree>\(emptyTree)</p:spTree></p:cSld>
        <p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>
        """)
        try put("ppt/slideLayouts/_rels/slideLayout1.xml.rels", relationships([("rId1", "slideMaster", "../slideMasters/slideMaster1.xml")]))
        try put("ppt/theme/theme1.xml", theme)

        try await ArchiveConverter.zipContents(of: root, to: output)
    }

    private static func displaySize(_ page: PDFPage) -> CGSize {
        let bounds = page.bounds(for: .mediaBox)
        return (page.rotation / 90) % 2 == 0 ? bounds.size : CGSize(width: bounds.height, height: bounds.width)
    }

    private static func clampEMU(_ value: Double) -> Int {
        Int(min(max(value, 914_400), 51_206_400))
    }

    private static let namespaces = #"xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main""#

    private static let emptyTree = #"<p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>"#

    private static func relationships(_ items: [(id: String, type: String, target: String)]) -> String {
        let rows = items.map {
            #"<Relationship Id="\#($0.id)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/\#($0.type)" Target="\#($0.target)"/>"#
        }.joined()
        return #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\#(rows)</Relationships>"#
    }

    /// The minimal complete Office theme (PowerPoint refuses a file without one).
    private static let theme = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" name="Cutie"><a:themeElements>
    <a:clrScheme name="Cutie"><a:dk1><a:srgbClr val="000000"/></a:dk1><a:lt1><a:srgbClr val="FFFFFF"/></a:lt1><a:dk2><a:srgbClr val="1F1F1F"/></a:dk2><a:lt2><a:srgbClr val="EEEEEE"/></a:lt2><a:accent1><a:srgbClr val="FF7D19"/></a:accent1><a:accent2><a:srgbClr val="ED7D31"/></a:accent2><a:accent3><a:srgbClr val="A5A5A5"/></a:accent3><a:accent4><a:srgbClr val="FFC000"/></a:accent4><a:accent5><a:srgbClr val="5B9BD5"/></a:accent5><a:accent6><a:srgbClr val="70AD47"/></a:accent6><a:hlink><a:srgbClr val="0563C1"/></a:hlink><a:folHlink><a:srgbClr val="954F72"/></a:folHlink></a:clrScheme>
    <a:fontScheme name="Cutie"><a:majorFont><a:latin typeface="Helvetica Neue"/><a:ea typeface=""/><a:cs typeface=""/></a:majorFont><a:minorFont><a:latin typeface="Helvetica Neue"/><a:ea typeface=""/><a:cs typeface=""/></a:minorFont></a:fontScheme>
    <a:fmtScheme name="Cutie">
    <a:fillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:fillStyleLst>
    <a:lnStyleLst><a:ln w="6350"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln><a:ln w="12700"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln><a:ln w="19050"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln></a:lnStyleLst>
    <a:effectStyleLst><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle></a:effectStyleLst>
    <a:bgFillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:bgFillStyleLst>
    </a:fmtScheme></a:themeElements></a:theme>
    """
}
