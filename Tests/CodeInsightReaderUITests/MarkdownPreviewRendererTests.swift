import AppKit
import CodeInsightReaderCore
@testable import CodeInsightReaderUI
import Foundation
import Testing

@MainActor
struct MarkdownPreviewRendererTests {
    @Test func strongEmphasisClosesBetweenPunctuationAndChinese() throws {
        let renderer = MarkdownPreviewRenderer(theme: ReaderTheme(settings: ReaderSettings()), baseURL: nil)
        let source = """
        使用**相同命令＋`--resume --execute`**继续

        以及**“引号”**后文，和**粗体。**后文

        中**粗**中

        ```sh
        echo 中**“x”**中
        ```
        """
        let output = try #require(renderer.render(source))
        let text = output.string as NSString
        func isBold(_ word: String) -> Bool {
            let range = text.range(of: word)
            guard range.location != NSNotFound,
                  let font = output.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
            else { return false }
            return NSFontManager.shared.traits(of: font).contains(.boldFontMask)
        }
        #expect(isBold("相同命令"))
        #expect(isBold("--resume"))
        #expect(!isBold("继续"))
        #expect(isBold("“引号”"))
        #expect(isBold("粗体。"))
        #expect(!isBold("后文"))
        #expect(isBold("粗"))
        #expect(text.components(separatedBy: "**").count == 3, "only the fenced code keeps literal **")
        #expect(text.contains("echo 中**“x”**中"))
        #expect(!text.contains("\u{2E31}"))
    }

    @Test func headingsCarryGitHubAnchors() throws {
        let renderer = MarkdownPreviewRenderer(theme: ReaderTheme(settings: ReaderSettings()), baseURL: nil)
        let output = try #require(renderer.render("""
        # 中断、恢复与产物

        ## Two-Stage A: `lipsync.py`!

        ## FAQ

        ## FAQ
        """))
        func anchored(_ fragment: String) -> String? {
            MarkdownPreviewRenderer.anchorRange(for: fragment, in: output)
                .map { (output.string as NSString).substring(with: $0) }
        }
        #expect(anchored("中断恢复与产物") == "中断、恢复与产物")
        #expect(anchored("%E4%B8%AD%E6%96%AD%E6%81%A2%E5%A4%8D%E4%B8%8E%E4%BA%A7%E7%89%A9") == "中断、恢复与产物")
        #expect(anchored("Two-Stage-A-lipsyncpy") == "Two-Stage A: lipsync.py!")
        let first = try #require(MarkdownPreviewRenderer.anchorRange(for: "faq", in: output))
        let second = try #require(MarkdownPreviewRenderer.anchorRange(for: "faq-1", in: output))
        #expect(first.location < second.location)
        #expect(anchored("missing") == nil)
    }

    @Test func readmeHTMLPreservesHeadingParagraphsAndOfflineBadgeText() throws {
        let file = URL(fileURLWithPath: "/project/README.md")
        let renderer = MarkdownPreviewRenderer(theme: ReaderTheme(settings: ReaderSettings()), baseURL: file)
        let output = try #require(renderer.render("""
        <p align="center">
          <h1 align="center">Demo</h1>
          <p align="center"><b>A short introduction.</b></p>
          <p align="center"><sub>See <a href="#demo-1">details</a>.</sub></p>
          <p align="center"><a href="https://example.invalid/"><img src="https://example.invalid/badge.svg" alt="Offline badge"></a></p>
        </p>

        <script>hiddenScriptContent()</script>

        ## Demo

        Regular Markdown.
        """))
        let text = output.string as NSString
        let title = try #require(MarkdownPreviewRenderer.anchorRange(for: "demo", in: output))
        let markdownHeading = try #require(MarkdownPreviewRenderer.anchorRange(for: "demo-1", in: output))
        #expect(text.substring(with: title) == "Demo")
        #expect(text.substring(with: markdownHeading) == "Demo")
        #expect(title.location < markdownHeading.location)
        #expect(output.attribute(.markdownHeadingLevel, at: title.location, effectiveRange: nil) as? Int == 1)
        #expect(output.attribute(.markdownHeadingLevel, at: markdownHeading.location, effectiveRange: nil) as? Int == 2)
        for paragraph in ["A short introduction.", "See details.", "Offline badge"] {
            let range = text.range(of: paragraph)
            try #require(range.location != NSNotFound)
            #expect(output.attribute(.markdownHeadingLevel, at: range.location, effectiveRange: nil) == nil)
            let enclosing = text.paragraphRange(for: range)
            #expect(text.substring(with: enclosing).trimmingCharacters(in: .whitespacesAndNewlines) == paragraph)
        }
        let link = output.attribute(.link, at: text.range(of: "details").location, effectiveRange: nil) as? URL
        #expect(link?.fragment == "demo-1")
        #expect(!output.string.contains("\u{FFFC}"))
        #expect(!output.string.contains("hiddenScriptContent"))
    }

    @Test func readmeHTMLImagesFitThePageAndTheirTableCellsAsTheReaderNarrows() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 1000, pixelsHigh: 200, bitsPerSample: 8,
            samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ))
        bitmap.bitmapData?.initialize(repeating: 0, count: bitmap.bytesPerPlane)
        let image = try #require(bitmap.representation(using: .png, properties: [:]))
        try image.write(to: directory.appendingPathComponent("demo.png"))
        let renderer = MarkdownPreviewRenderer(
            theme: ReaderTheme(settings: ReaderSettings()), baseURL: directory.appendingPathComponent("README.md")
        )
        let output = try #require(renderer.render("""
        <p align="center">A wide image:<br>
          <img src="demo.png" alt="Wide" width="100%"><br>
          A caption.
        </p>

        <table align="center" width="100%">
          <tr>
            <td width="50%" align="center">
              <a href="#demo"><img src="demo.png" alt="First" width="100%"></a>
              <sub><b>First demo</b> — first description.</sub>
            </td>
            <td width="50%" align="center">
              <a href="#demo"><img src="demo.png" alt="Second" width="100%"></a>
              <sub><b>Second demo</b> — second description.</sub>
            </td>
          </tr>
        </table>

        ## Demo
        """))
        let text = output.string as NSString
        var attachments: [NSRange] = []
        output.enumerateAttribute(.attachment, in: NSRange(location: 0, length: output.length)) { value, range, _ in
            if value is NSTextAttachment { attachments.append(range) }
        }
        try #require(attachments.count == 3)

        let view = MarkdownPreviewTextView()
        let layout = try #require(view.layoutManager)
        let container = try #require(view.textContainer)
        container.widthTracksTextView = true
        view.show(output)
        var previousWidths: [CGFloat] = []
        for width: CGFloat in [1000, 520] {
            view.setFrameSize(NSSize(width: width, height: 800))
            layout.ensureLayout(for: container)
            let images = attachments.map { range in
                let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                let line = layout.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
                let location = layout.location(forGlyphAt: glyphs.location)
                let size = layout.attachmentSize(forGlyphAt: glyphs.location)
                return NSRect(x: line.minX + location.x, y: line.minY, width: size.width, height: size.height)
            }
            for image in images {
                #expect(image.width > 0)
                #expect(abs(image.height / image.width - 0.2) < 0.01)
                #expect(image.minX >= 0)
                #expect(image.maxX <= container.containerSize.width + 1)
            }
            #expect(images[1].maxX <= images[2].minX + 1)
            #expect(abs(images[1].minY - images[2].minY) < images[1].height)
            for (image, previousWidth) in zip(images, previousWidths) {
                #expect(image.width < previousWidth)
            }
            previousWidths = images.map(\.width)
        }

        let cells = try attachments.dropFirst().map { attachment in
            let style = output.attribute(.paragraphStyle, at: attachment.location, effectiveRange: nil) as? NSParagraphStyle
            return try #require(style?.textBlocks.last as? NSTextTableBlock)
        }
        #expect(cells[0].table === cells[1].table)
        #expect(cells[0].startingRow == cells[1].startingRow)
        #expect(cells.map(\.startingColumn) == [0, 1])
        for (index, caption) in ["First demo", "Second demo"].enumerated() {
            let range = text.range(of: caption)
            try #require(range.location != NSNotFound)
            let style = output.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
            #expect(style?.textBlocks.last === cells[index])
        }
    }

    @Test func hiddenFoldedHeadingLendsNoChevronToTheNextHeading() throws {
        let renderer = MarkdownPreviewRenderer(theme: ReaderTheme(settings: ReaderSettings()), baseURL: nil)
        let output = try #require(renderer.render("""
        # Alpha

        ## Beta

        beta text

        # Gamma

        gamma text
        """))
        let view = MarkdownPreviewTextView()
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 800)
        view.show(output)
        let text = output.string as NSString
        func start(_ word: String) -> Int {
            text.paragraphRange(for: NSRange(location: text.range(of: word).location, length: 0)).location
        }
        let alpha = start("Alpha"), beta = start("Beta"), gamma = start("Gamma")
        #expect(view.toggleHeadingFold(at: beta))
        #expect(view.toggleHeadingFold(at: alpha))
        #expect(view.foldedHeadings == [alpha, beta])

        // Beta is hidden inside Alpha's fold: it has no line to draw a chevron on.
        #expect(view.firstLineRect(ofHeadingAt: beta) == nil)
        // Gamma's line holds Gamma's chevron, so a click there folds Gamma.
        let gammaLine = try #require(view.firstLineRect(ofHeadingAt: gamma))
        #expect(view.headingLine(atY: gammaLine.midY)?.start == gamma)
    }

    @Test func keyboardFoldToggleAtAFoldPointReachesTheShownHeading() throws {
        let renderer = MarkdownPreviewRenderer(theme: ReaderTheme(settings: ReaderSettings()), baseURL: nil)
        for source in ["# Alpha\n\nintro\n\n## Beta\n\nbeta text\n\n# Gamma\n\ngamma text",
                       "# Alpha\n\n## Beta\n\nbeta text\n\n# Gamma\n\ngamma text"] {
            let output = try #require(renderer.render(source))
            let view = MarkdownPreviewTextView()
            view.frame = NSRect(x: 0, y: 0, width: 600, height: 800)
            view.show(output)
            let text = output.string as NSString
            let alpha = text.paragraphRange(for: NSRange(location: text.range(of: "Alpha").location, length: 0)).location
            // The caret sits in Alpha's section; folding collapses it to the fold point.
            view.setSelectedRange(NSRange(location: text.range(of: "beta text").location + 2, length: 0))
            #expect(view.toggleHeadingFold(at: alpha))
            let heading = try #require(view.heading(containing: view.selectedRange().location))
            #expect(heading == alpha, "\(source)")
            #expect(view.toggleHeadingFold(at: heading))
            #expect(view.foldedHeadings.isEmpty, "\(source)")
        }
    }
}

/// AI answers are rendered with `loadsImages: false`: no image of any kind
/// (local file, data URI, remote, HTML `<img>`) becomes an attachment.
@MainActor
@Test func untrustedMarkdownLoadsNoImages() throws {
    let png = FileManager.default.temporaryDirectory.appendingPathComponent("ai-image-\(UUID().uuidString).png")
    let image = NSImage(size: NSSize(width: 4, height: 4), flipped: false) { rect in
        NSColor.red.setFill(); rect.fill(); return true
    }
    let tiff = try #require(image.tiffRepresentation)
    let data = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
    try data.write(to: png)
    let markdown = """
    ![local](\(png.absoluteString)) ![remote](https://example.invalid/a.png)
    ![inline](data:image/png;base64,\(data.base64EncodedString()))

    <p><img src="\(png.absoluteString)" alt="html"></p>
    """
    func attachments(_ loadsImages: Bool) throws -> Int {
        let output = try #require(MarkdownPreviewRenderer(
            theme: ReaderTheme(settings: ReaderSettings()), baseURL: nil, loadsImages: loadsImages
        ).render(markdown))
        var count = 0
        output.enumerateAttribute(.attachment, in: NSRange(location: 0, length: output.length)) { value, _, _ in
            if value != nil { count += 1 }
        }
        return count
    }
    #expect(try attachments(true) >= 2)
    #expect(try attachments(false) == 0)
}
