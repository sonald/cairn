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
