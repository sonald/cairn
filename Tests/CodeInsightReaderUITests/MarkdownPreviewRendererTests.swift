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
}
