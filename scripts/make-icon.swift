import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

@main
private struct MakeIcon {
    private static let sizes = [16, 32, 128, 256, 512]
    private static let backgroundColor = CGColor(
        srgbRed: 0x30 / 255,
        green: 0x35 / 255,
        blue: 0x40 / 255,
        alpha: 1
    )

    static func main() throws {
        let root = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        )
        let iconset = root.appendingPathComponent(".build/AppIcon.iconset")
        let resources = root.appendingPathComponent("Resources")
        let output = resources.appendingPathComponent("AppIcon.icns")

        try? FileManager.default.removeItem(at: iconset)
        try FileManager.default.createDirectory(
            at: iconset,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: resources,
            withIntermediateDirectories: true
        )

        for size in sizes {
            try writePNG(
                pixels: size,
                logicalSize: size,
                to: iconset.appendingPathComponent("icon_\(size)x\(size).png")
            )
            try writePNG(
                pixels: size * 2,
                logicalSize: size,
                to: iconset.appendingPathComponent(
                    "icon_\(size)x\(size)@2x.png"
                )
            )
        }

        try? FileManager.default.removeItem(at: output)
        // iconutil may reject the same iconset or rewrite its small representations
        // depending on the host. Fixed-order assembly keeps identical PNGs byte-stable.
        try writeICNS(iconset: iconset, to: output)
        print(output.path)
    }

    private static func writeICNS(iconset: URL, to output: URL) throws {
        let representations = [
            ("icp4", "icon_16x16.png"),
            ("ic11", "icon_16x16@2x.png"),
            ("icp5", "icon_32x32.png"),
            ("ic12", "icon_32x32@2x.png"),
            ("ic07", "icon_128x128.png"),
            ("ic13", "icon_128x128@2x.png"),
            ("ic08", "icon_256x256.png"),
            ("ic14", "icon_256x256@2x.png"),
            ("ic09", "icon_512x512.png"),
            ("ic10", "icon_512x512@2x.png"),
        ]
        var payload = Data()
        for (type, file) in representations {
            let png = try Data(contentsOf: iconset.appendingPathComponent(file))
            payload.append(contentsOf: type.utf8)
            append(UInt32(png.count + 8), to: &payload)
            payload.append(png)
        }
        var icns = Data("icns".utf8)
        append(UInt32(payload.count + 8), to: &icns)
        icns.append(payload)
        try icns.write(to: output, options: .atomic)
    }

    private static func append(_ value: UInt32, to data: inout Data) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }

    private static func writePNG(
        pixels: Int,
        logicalSize: Int,
        to url: URL
    ) throws {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        var bytes = [UInt8](repeating: 0, count: pixels * pixels * 4)
        let image: CGImage? = bytes.withUnsafeMutableBytes { storage in
            guard let context = CGContext(
                data: storage.baseAddress,
                width: pixels,
                height: pixels,
                bitsPerComponent: 8,
                bytesPerRow: pixels * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue
            ) else { return nil }
            context.clear(CGRect(x: 0, y: 0, width: pixels, height: pixels))
            drawBackground(
                in: CGRect(x: 0, y: 0, width: pixels, height: pixels),
                context: context
            )
            drawCairnMark(
                in: CGRect(x: 0, y: 0, width: pixels, height: pixels),
                logicalSize: CGFloat(logicalSize),
                context: context
            )
            return context.makeImage()
        }
        guard let image,
              let destination = CGImageDestinationCreateWithURL(
                  url as CFURL,
                  UTType.png.identifier as CFString,
                  1,
                  nil
              )
        else {
            throw IconError.couldNotWritePNG(url.path)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw IconError.couldNotWritePNG(url.path)
        }
    }

    private static func drawBackground(in rect: CGRect, context: CGContext) {
        let background = rect.insetBy(
            dx: rect.width * 0.0625,
            dy: rect.height * 0.0625
        )
        let radius = background.width * 0.23
        context.addPath(CGPath(
            roundedRect: background,
            cornerWidth: radius,
            cornerHeight: radius,
            transform: nil
        ))
        context.setFillColor(backgroundColor)
        context.fillPath()
    }
}

private enum IconError: Error {
    case couldNotWritePNG(String)
}
