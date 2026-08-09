import AppKit
import CodeInsightReaderCore
import Foundation
import Testing
@testable import CodeInsightApp

@MainActor
@Test
func scopeHeaderMatchesPrototypeAndCollapsesOutsideDeclarations() throws {
    _ = NSApplication.shared
    let source = """
        use std::future::Future;

        impl Runtime {
            fn spawn_on() {
                let value = 1;
            }
        }
        """
    let bytes = Array(source.utf8)
    let file = URL(fileURLWithPath: "/scope-header.rs")
    let controller = ReaderViewController()
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 720, height: 420),
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    window.contentViewController = controller
    controller.view.frame = NSRect(x: 0, y: 0, width: 720, height: 420)
    controller.display(file, source: { _ in bytes })
    window.contentView?.layoutSubtreeIfNeeded()

    _ = controller.selfTestActivate(at: 0)
    window.contentView?.layoutSubtreeIfNeeded()
    let hidden = controller.selfTestScopeHeader
    #expect(hidden.hidden)

    let signature = try #require(source.utf8Offset(of: "    fn spawn_on"))
    _ = controller.selfTestActivate(at: UInt32(signature))
    window.contentView?.layoutSubtreeIfNeeded()
    let signatureHeader = controller.selfTestScopeHeader
    #expect(!signatureHeader.hidden)
    #expect(signatureHeader.frame.height == 26)
    #expect(signatureHeader.labels == [
        "impl", "Runtime", "▸", "fn", "spawn_on", "scope-header.rs:4",
    ])
    #expect(signatureHeader.fontNames.count == signatureHeader.labels.count)
    #expect(signatureHeader.fontNames.allSatisfy {
        $0.localizedCaseInsensitiveContains("mono")
    })
    #expect(abs(
        signatureHeader.labelFrames[0].minX - signatureHeader.frame.minX - 13
    ) < 1)
    for index in signatureHeader.labelFrames.indices.dropFirst() {
        #expect(abs(
            signatureHeader.labelFrames[index].minX
                - signatureHeader.labelFrames[index - 1].maxX
                - 8
        ) < 1)
    }
    #expect(signatureHeader.accessibilityLabel
        == "Current scope: impl Runtime, fn spawn_on, scope-header.rs line 4")
    #expect(abs(signatureHeader.frame.minY - signatureHeader.readerFrame.maxY) < 1)
    #expect(abs(hidden.readerFrame.height - signatureHeader.readerFrame.height - 26) < 1)

    let closingBrace = try #require(source.utf8Offset(of: "    }\n}"))
    _ = controller.selfTestActivate(at: UInt32(closingBrace))
    #expect(controller.selfTestScopeHeader.labels.prefix(5) == [
        "impl", "Runtime", "▸", "fn", "spawn_on",
    ])

    for selection in [
        ReaderSettings.Theme.light,
        .dark,
        .siClassic,
    ] {
        controller.apply(settings: ReaderSettings(theme: selection))
        #expect(controller.selfTestScopeHeader.labels.prefix(5) == [
            "impl", "Runtime", "▸", "fn", "spawn_on",
        ])
    }
    withExtendedLifetime(window) {}
}

private extension String {
    func utf8Offset(of needle: String) -> Int? {
        guard let range = range(of: needle) else { return nil }
        return utf8.distance(from: utf8.startIndex, to: range.lowerBound)
    }
}
