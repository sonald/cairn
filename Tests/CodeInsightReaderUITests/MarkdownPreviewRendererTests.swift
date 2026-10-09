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
}
