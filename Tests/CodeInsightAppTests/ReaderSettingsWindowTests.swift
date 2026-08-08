import AppKit
import CodeInsightExact
import CodeInsightReaderCore
import Foundation
import Testing
@testable import CodeInsightApp
@testable import CodeInsightAppModel

@MainActor
@Test
func readerVisualSettingControlsAreVisibleAndDoNotOverlap() {
    _ = NSApplication.shared
    let coordinator = ExactCoordinator(
        providerFactory: { _ in throw CocoaError(.featureUnsupported) },
        sandboxAvailable: { false }
    )
    defer { coordinator.shutdown() }
    let controller = ReaderSettingsWindowController(
        settings: ReaderSettings(),
        exactCoordinator: coordinator,
        onRevoke: { _ in },
        onChange: { _ in }
    )
    defer { controller.close() }

    controller.showWindow(nil)
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
    let geometry = controller.selfTestVisualControlGeometry

    #expect(controller.selfTestReaderToggleCount == 4)
    #expect(geometry.frames.count == 4)
    #expect(geometry.frames.allSatisfy {
        $0.width > 0 && $0.height > 0 && geometry.visibleFrame.contains($0)
    })
    #expect(!geometry.existingFrames.isEmpty)
    for index in geometry.frames.indices {
        for other in geometry.frames.indices where other > index {
            #expect(!geometry.frames[index].intersects(geometry.frames[other]))
        }
        #expect(geometry.existingFrames.allSatisfy {
            !geometry.frames[index].intersects($0)
        })
    }
}

@MainActor
@Test
func existingSettingsWindowAcceptsFreshSettingsWithoutObservableState() {
    _ = NSApplication.shared
    let coordinator = ExactCoordinator(
        providerFactory: { _ in throw CocoaError(.featureUnsupported) },
        sandboxAvailable: { false }
    )
    defer { coordinator.shutdown() }
    let controller = ReaderSettingsWindowController(
        settings: ReaderSettings(fontSize: 13),
        exactCoordinator: coordinator,
        onRevoke: { _ in },
        onChange: { _ in }
    )
    defer { controller.close() }

    controller.showWindow(nil)
    var changed = ReaderSettings(fontSize: 17)
    changed.wrapLines = true
    controller.update(settings: changed)

    #expect(controller.currentSettings == changed)
    #expect(controller.selfTestReaderToggleCount == 4)
    #expect(controller.window?.contentViewController != nil)
}
