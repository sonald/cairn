import AppKit

private let cairnLightStone = CGColor(
    srgbRed: 0xF2 / 255,
    green: 0xF4 / 255,
    blue: 0xF7 / 255,
    alpha: 1
)
private let cairnMutedStone = CGColor(
    srgbRed: 0xC9 / 255,
    green: 0xD0 / 255,
    blue: 0xD8 / 255,
    alpha: 1
)
private let cairnAccentBlue = CGColor(
    srgbRed: 0x4C / 255,
    green: 0x9D / 255,
    blue: 0xFF / 255,
    alpha: 1
)
private let cairnStoneOutline = CGColor(
    srgbRed: 0x1D / 255,
    green: 0x21 / 255,
    blue: 0x29 / 255,
    alpha: 1
)

func drawCairnMark(
    in rect: CGRect,
    logicalSize: CGFloat,
    context: CGContext
) {
    context.saveGState()
    defer { context.restoreGState() }
    context.translateBy(x: rect.minX, y: rect.minY)
    context.scaleBy(x: rect.width, y: rect.height)
    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)
    context.setStrokeColor(cairnStoneOutline)
    context.setLineWidth(max(0.75 / rect.width, 0.0065))

    if logicalSize <= 32 {
        let stones: [(CGRect, CGFloat, CGColor)] = [
            (CGRect(x: 0.16, y: 0.14, width: 0.68, height: 0.21), 0.08, cairnLightStone),
            (CGRect(x: 0.28, y: 0.41, width: 0.50, height: 0.18), 0.08, cairnMutedStone),
            (CGRect(x: 0.40, y: 0.66, width: 0.32, height: 0.17), 0.08, cairnAccentBlue),
        ]
        for (stone, radius, color) in stones {
            context.addPath(CGPath(
                roundedRect: stone,
                cornerWidth: radius,
                cornerHeight: radius,
                transform: nil
            ))
            context.setFillColor(color)
            context.drawPath(using: .fillStroke)
        }
        return
    }

    func stonePath(_ stone: CGRect) -> CGPath {
        let x = stone.minX
        let y = stone.minY
        let width = stone.width
        let height = stone.height
        let path = CGMutablePath()
        path.move(to: CGPoint(x: x + width * 0.12, y: y))
        path.addCurve(
            to: CGPoint(x: x + width * 0.89, y: y + height * 0.01),
            control1: CGPoint(x: x + width * 0.34, y: y - height * 0.03),
            control2: CGPoint(x: x + width * 0.72, y: y + height * 0.02)
        )
        path.addCurve(
            to: CGPoint(x: x + width, y: y + height * 0.47),
            control1: CGPoint(x: x + width * 0.97, y: y + height * 0.04),
            control2: CGPoint(x: x + width, y: y + height * 0.24)
        )
        path.addCurve(
            to: CGPoint(x: x + width * 0.84, y: y + height),
            control1: CGPoint(x: x + width, y: y + height * 0.72),
            control2: CGPoint(x: x + width * 0.95, y: y + height * 0.94)
        )
        path.addCurve(
            to: CGPoint(x: x + width * 0.17, y: y + height * 0.96),
            control1: CGPoint(x: x + width * 0.64, y: y + height * 1.03),
            control2: CGPoint(x: x + width * 0.34, y: y + height)
        )
        path.addCurve(
            to: CGPoint(x: x, y: y + height * 0.43),
            control1: CGPoint(x: x + width * 0.05, y: y + height * 0.91),
            control2: CGPoint(x: x, y: y + height * 0.69)
        )
        path.addCurve(
            to: CGPoint(x: x + width * 0.12, y: y),
            control1: CGPoint(x: x, y: y + height * 0.19),
            control2: CGPoint(x: x + width * 0.04, y: y + height * 0.04)
        )
        path.closeSubpath()
        return path
    }

    let stones: [(CGRect, CGColor)] = [
        (CGRect(x: 0.16, y: 0.14, width: 0.68, height: 0.22), cairnLightStone),
        (CGRect(x: 0.28, y: 0.41, width: 0.50, height: 0.19), cairnMutedStone),
        (CGRect(x: 0.40, y: 0.66, width: 0.32, height: 0.17), cairnAccentBlue),
    ]
    for (stone, color) in stones {
        context.addPath(stonePath(stone))
        context.setFillColor(color)
        context.drawPath(using: .fillStroke)
    }
}

func cairnMarkImage(size: CGSize) -> NSImage {
    let image = NSImage(size: size, flipped: false) { rect in
        guard let context = NSGraphicsContext.current?.cgContext else {
            return false
        }
        drawCairnMark(in: rect, logicalSize: size.width, context: context)
        return true
    }
    image.accessibilityDescription = "Cairn"
    return image
}
