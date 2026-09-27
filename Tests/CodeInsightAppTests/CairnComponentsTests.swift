import AppKit
import CodeInsightCore
import CodeInsightReaderCore
import CodeInsightReaderUI
import Testing
@testable import CodeInsightApp
@testable import CodeInsightAppModel

@MainActor
private func host(_ view: NSView) -> NSWindow {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
    view.translatesAutoresizingMaskIntoConstraints = false
    window.contentView?.addSubview(view)
    if let content = window.contentView {
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            view.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
        ])
        content.layoutSubtreeIfNeeded()
    }
    return window
}

@MainActor
private func expectVisible(_ view: NSView, in window: NSWindow) {
    #expect(view.window === window)
    #expect(!view.isHiddenOrHasHiddenAncestor)
    let frame = view.convert(view.bounds, to: nil)
    #expect(frame.width > 0 && frame.height > 0)
    #expect(window.contentView.map { $0.bounds.contains(frame) } == true)
}

@MainActor
private func rgb(_ color: NSColor?, _ appearance: NSAppearance.Name) -> UInt32? {
    guard let color, let appearance = NSAppearance(named: appearance) else { return nil }
    var value: UInt32?
    appearance.performAsCurrentDrawingAppearance {
        guard let srgb = color.usingColorSpace(.sRGB) else { return }
        value = UInt32((srgb.redComponent * 255).rounded()) << 16
            | UInt32((srgb.greenComponent * 255).rounded()) << 8
            | UInt32((srgb.blueComponent * 255).rounded())
    }
    return value
}

private let lightTheme = ReaderTheme(settings: ReaderSettings(theme: .light))
private let darkTheme = ReaderTheme(settings: ReaderSettings(theme: .dark))
private let siTheme = ReaderTheme(settings: ReaderSettings(theme: .siClassic))

@MainActor
@Test
func certaintyStonesFillOneStonePerLevelAndDashUnresolved() {
    let expected: [(Certainty, [CertaintyStonesView.StoneState])] = [
        (.exact, [.filled, .filled, .filled, .filled]),
        (.strong, [.filled, .filled, .filled, .outlined]),
        (.probable, [.filled, .filled, .outlined, .outlined]),
        (.possible, [.filled, .outlined, .outlined, .outlined]),
        (.unresolved, [.dashed, .dashed, .dashed, .dashed]),
    ]
    for (certainty, states) in expected {
        let view = CertaintyStonesView(certainty: certainty, theme: lightTheme)
        let window = host(view)
        expectVisible(view, in: window)
        #expect(view.stoneStates == states)
        #expect(view.accessibilityRole() == .image)
        #expect(view.accessibilityLabel() == resolutionCertaintyLabel(certainty))
    }
}

@MainActor
@Test
func certaintyStonesScaleFromTheSixteenPointUnitBox() {
    let view = CertaintyStonesView(certainty: .exact, theme: lightTheme, size: 22)
    let window = host(view)
    expectVisible(view, in: window)
    #expect(view.intrinsicContentSize == NSSize(width: 22, height: 22))
    #expect(view.frame.size == NSSize(width: 22, height: 22))
    let scale = 22.0 / 16.0
    #expect(view.stoneRects.first == CGRect(x: 2 * scale, y: 12 * scale, width: 12 * scale, height: 3 * scale))
    #expect(view.stoneRects.last == CGRect(x: 6.5 * scale, y: 1.5 * scale, width: 3 * scale, height: 3 * scale))
}

@MainActor
@Test
func certaintyStonesUseVerifiedForStrongAndInferredForWeakCertainty() {
    for theme in [lightTheme, darkTheme] {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            #expect(rgb(CertaintyStonesView(certainty: .exact, theme: theme).fillColor, appearance)
                == rgb(theme.verifiedColor, appearance))
            #expect(rgb(CertaintyStonesView(certainty: .strong, theme: theme).fillColor, appearance)
                == rgb(theme.verifiedColor, appearance))
            #expect(rgb(CertaintyStonesView(certainty: .possible, theme: theme).fillColor, appearance)
                == rgb(theme.inferredColor, appearance))
        }
    }
    // Granite moss and slate differ in lightness, not hue alone.
    #expect(rgb(lightTheme.verifiedColor, .aqua) == 0x2B5849)
    #expect(rgb(lightTheme.inferredColor, .aqua) == 0x3A5873)
}

@MainActor
@Test
func certaintyStonesFollowUpdatedCertaintyAndAccessibility() {
    let view = CertaintyStonesView(certainty: .possible, theme: lightTheme)
    view.update(certainty: .exact, theme: darkTheme)
    #expect(view.stoneStates == [.filled, .filled, .filled, .filled])
    #expect(view.accessibilityLabel() == resolutionCertaintyLabel(.exact))
    #expect(view.theme == darkTheme)
}

@MainActor
@Test
func cairnBadgeStylesResolveToThemeTokens() {
    for theme in [lightTheme, darkTheme, siTheme] {
        let appearance: NSAppearance.Name = theme == darkTheme ? .darkAqua : .aqua
        let table: [(CairnBadgeView.Style, NSColor, NSColor, NSColor?)] = [
            (.verified, theme.verifiedColor, theme.mossSoftColor, nil),
            (.inferred, theme.inferredColor, theme.slateSoftColor, nil),
            (.unresolved, theme.unresolvedColor, .clear, theme.unresolvedBorderColor),
            (.corrected, theme.unresolvedColor, theme.rustSoftColor, nil),
            (.dispatch, theme.chromeSecondaryColor, .clear, theme.chromeDividerColor),
            (.dependency, theme.chipForegroundColor, theme.chipBackgroundColor, nil),
            (.captured, theme.chipForegroundColor, theme.chipBackgroundColor, nil),
            (.commit, theme.histColor, theme.histSoftColor, nil),
            (.limited, theme.warningColor, theme.amberSoftColor, nil),
        ]
        #expect(table.count == CairnBadgeView.Style.allCases.count)
        for (style, text, fill, border) in table {
            let colors = CairnBadgeView.colors(for: style, theme: theme)
            #expect(rgb(colors.text, appearance) == rgb(text, appearance))
            #expect(rgb(colors.fill, appearance) == rgb(fill, appearance))
            #expect(rgb(colors.border, appearance) == rgb(border, appearance))
        }
    }
}

@MainActor
@Test
func cairnBadgeKeepsFixedHeightAndGrowsWithText() {
    let short = CairnBadgeView(style: .verified, text: "Verified", theme: lightTheme)
    let long = CairnBadgeView(style: .dispatch, text: "macroGenerated", theme: lightTheme)
    let window = host(short)
    expectVisible(short, in: window)
    #expect(short.frame.height == CairnBadgeView.height)
    #expect(short.intrinsicContentSize.height == CairnBadgeView.height)
    #expect(long.intrinsicContentSize.height == CairnBadgeView.height)
    #expect(long.intrinsicContentSize.width > short.intrinsicContentSize.width)
    #expect(short.accessibilityLabel() == "Verified")
    #expect(short.layer?.borderWidth == 0)
    #expect(long.layer?.borderWidth == 1)
}
