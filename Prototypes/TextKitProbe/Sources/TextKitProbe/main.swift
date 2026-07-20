import AppKit
import Foundation
import TextKitProbeCore

@main
@MainActor
struct TextKitProbeCommand {
    private static var liveSession: ProbeSession?
    private static var liveWindow: NSWindow?

    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let command = arguments.first else { throw CLIError.usage }
        switch command {
        case "generate", "--generate":
            let destination = arguments.dropFirst().first.map {
                URL(fileURLWithPath: $0).standardizedFileURL
            }
            let output = try TextKitProbe.generate(destination: destination)
            let json = try JSONSerialization.data(withJSONObject: [
                "generated_file": output.path,
                "lines": 100_000,
            ])
            print(String(decoding: json, as: UTF8.self))
        case "measure":
            let (file, options) = try parseFileAndOptions(Array(arguments.dropFirst()))
            _ = NSApplication.shared
            let (metrics, session) = try TextKitProbe.measure(fileURL: file, options: options)
            liveSession = session
            printJSON(metrics)
        case "view":
            let (file, options) = try parseFileAndOptions(Array(arguments.dropFirst()))
            let app = NSApplication.shared
            app.setActivationPolicy(.regular)
            let (metrics, session) = try TextKitProbe.measure(fileURL: file, options: options)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1100, height: 800),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "TextKit 2 Probe — \(file.lastPathComponent) [\(options.mode.rawValue)]"
            window.contentView = session.scrollView
            window.center()
            window.makeKeyAndOrderFront(nil)
            liveSession = session
            liveWindow = window
            printJSON(metrics)
            app.activate(ignoringOtherApps: true)
            app.run()
        default:
            throw CLIError.usage
        }
    }

    private static func parseFileAndOptions(
        _ arguments: [String]
    ) throws -> (URL, ProbeOptions) {
        guard let path = arguments.first else { throw CLIError.usage }
        var mode: HighlightMode = .lazy
        var fontDelta = 1
        var commentFont = false
        var lineSpacing = 1.0
        var index = 1
        while index < arguments.count {
            switch arguments[index] {
            case "--lazy": mode = .lazy
            case "--eager": mode = .eager
            case "--comment-font": commentFont = true
            case "--font-delta":
                index += 1
                guard index < arguments.count, let value = Int(arguments[index]), [1, 2].contains(value) else {
                    throw CLIError.invalidFontDelta
                }
                fontDelta = value
            case "--line-spacing":
                index += 1
                guard index < arguments.count, let value = Double(arguments[index]),
                      (1.0...2.0).contains(value)
                else {
                    throw CLIError.unknownOption("--line-spacing expects 1.0...2.0")
                }
                lineSpacing = value
            default: throw CLIError.unknownOption(arguments[index])
            }
            index += 1
        }
        return (
            URL(fileURLWithPath: path).standardizedFileURL,
            ProbeOptions(
                mode: mode,
                fontDelta: fontDelta,
                commentFont: commentFont,
                lineSpacing: lineSpacing
            )
        )
    }

    private static func printJSON<T: Encodable>(_ value: T) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        print(String(decoding: try! encoder.encode(value), as: UTF8.self))
    }
}

private enum CLIError: Error, CustomStringConvertible {
    case usage
    case invalidFontDelta
    case unknownOption(String)

    var description: String {
        switch self {
        case .usage:
            "usage: TextKitProbe generate [output] | measure <file> [--lazy|--eager] [--font-delta 1|2] [--comment-font] | view <file> [options]"
        case .invalidFontDelta: "--font-delta must be 1 or 2"
        case let .unknownOption(option): "unknown option: \(option)"
        }
    }
}
