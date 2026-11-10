import Foundation

/// A Jupyter notebook (nbformat 4) as Markdown for the Markdown preview:
/// Markdown cells as written, code cells fenced in the kernel's language,
/// outputs quoted beneath their cell. Images stay inline as data URLs.
package enum NotebookMarkdown {
    /// `nil` when `data` is not an nbformat 4 notebook.
    package static func markdown(fromNotebook data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cells = root["cells"] as? [[String: Any]]
        else { return nil }
        let metadata = root["metadata"] as? [String: Any]
        let language = ((metadata?["language_info"] as? [String: Any])?["name"] as? String)
            ?? ((metadata?["kernelspec"] as? [String: Any])?["language"] as? String)
            ?? ""
        var parts: [String] = []
        for cell in cells {
            let source = text(cell["source"])
            switch cell["cell_type"] as? String {
            case "markdown":
                parts.append(source)
            case "code":
                let outputs = (cell["outputs"] as? [[String: Any]] ?? []).compactMap(render)
                if !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    parts.append(fenced(source, language: language))
                }
                parts += outputs.map(quoted)
            default:
                parts.append(fenced(source, language: ""))
            }
        }
        // The leading newline keeps a `---` first cell a rule, not front matter.
        return "\n" + parts.joined(separator: "\n\n")
    }

    // ponytail: rich outputs show their plain-text form (HTML tables, widgets
    // and LaTeX fall back to `text/plain`); add renderers when notebooks need them.
    private static func render(_ output: [String: Any]) -> String? {
        switch output["output_type"] as? String {
        case "stream":
            return fenced(terminal(text(output["text"])), language: "")
        case "error":
            let traceback = (output["traceback"] as? [String])?.joined(separator: "\n")
                ?? "\(output["ename"] as? String ?? ""): \(output["evalue"] as? String ?? "")"
            return fenced(terminal(traceback), language: "")
        case "execute_result", "display_data":
            let data = output["data"] as? [String: Any] ?? [:]
            for type in ["image/png", "image/jpeg", "image/gif"] where data[type] != nil {
                let base64 = text(data[type]).filter { !$0.isWhitespace }
                return "![](data:\(type);base64,\(base64))"
            }
            return data["text/plain"].map { fenced(terminal(text($0)), language: "") }
        default:
            return nil
        }
    }

    /// Terminal output as it last appeared: ANSI colours removed, and only
    /// the text after a line's last carriage return (progress bars redraw).
    private static func terminal(_ output: String) -> String {
        // "\r\n" is one Swift Character, so normalise it before splitting.
        output.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.split(separator: "\r").last.map(String.init) ?? "" }
            .joined(separator: "\n")
    }

    /// nbformat stores multiline strings as one string or a list of lines.
    private static func text(_ value: Any?) -> String {
        (value as? String) ?? (value as? [String])?.joined() ?? ""
    }

    /// A fence longer than any backtick run inside, so cell text cannot close it.
    private static func fenced(_ code: String, language: String) -> String {
        var longest = 0, run = 0
        for character in code {
            run = character == "`" ? run + 1 : 0
            longest = max(longest, run)
        }
        let fence = String(repeating: "`", count: max(3, longest + 1))
        var body = code
        while body.hasSuffix("\n") { body.removeLast() }
        return "\(fence)\(language)\n\(body)\n\(fence)"
    }

    private static func quoted(_ block: String) -> String {
        block.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.isEmpty ? ">" : "> \($0)" }
            .joined(separator: "\n")
    }
}
