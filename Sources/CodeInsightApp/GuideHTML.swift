import AppKit
import CodeInsightAI
import CodeInsightReaderCore
import CodeInsightReaderUI

/// Lays out a checked guide draft as one self-contained page: Markdown prose,
/// flow cards, a roles table, a sequence diagram and follow-up questions.
/// Every resolved anchor becomes a link the panel turns into a jump; the
/// page loads nothing (its CSP allows only its own inline style and script).
@MainActor
enum GuideHTML {
    static func page(_ draft: GuideDraft, resolve: (String) -> GuideTarget?, theme: ReaderTheme) -> String {
        var body = ""
        if !draft.title.isEmpty { body += "<h1>\(inline(draft.title, resolve))</h1>" }
        for block in draft.blocks {
            switch block {
            case .heading(let text): body += "<h2>\(inline(text, resolve))</h2>"
            case .markdown(let lines): body += markdown(lines, resolve)
            case .path(let name, let from, let steps): body += flow(name, from, steps, resolve)
            case .roles(let roles): body += rolesTable(roles, resolve)
            case .sequence(let lines): body += sequence(lines, resolve)
            case .state(let lines):
                body += "<ul class=\"state\">" + lines.map { "<li>\(inline($0, resolve))</li>" }.joined() + "</ul>"
            case .ask(let questions):
                body += "<div class=\"ask\">" + questions.map {
                    "<button class=\"question\" data-ask=\"\(escape($0))\">\(escape($0))</button>"
                }.joined() + "</div>"
            }
        }
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'">
        <style>\(style(theme))</style></head><body>\(body)<script>\(script)</script></body></html>
        """
    }

    // MARK: Text

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func anchor(_ target: GuideTarget, label: String) -> String {
        "<a class=\"anchor\" href=\"#\" data-path=\"\(escape(target.path))\" data-start=\"\(target.start)\" data-end=\"\(target.end)\">\(label)</a>"
    }

    /// Code spans become anchors (or plain code); the rest is escaped, with
    /// **bold** and *italic*.
    static func inline(_ text: String, _ resolve: (String) -> GuideTarget?) -> String {
        var out = ""
        for (index, part) in text.components(separatedBy: "`").enumerated() {
            if index % 2 == 1 {
                let code = "<code>\(escape(part))</code>"
                out += resolve(part).map { anchor($0, label: code) } ?? code
            } else {
                var plain = escape(part)
                plain = plain.replacing(#/\*\*(.+?)\*\*/#) { "<strong>\($0.1)</strong>" }
                plain = plain.replacing(#/\*([^*\s](?:[^*]*[^*\s])?)\*/#) { "<em>\($0.1)</em>" }
                out += plain
            }
        }
        return out
    }

    /// Paragraphs, bullet and numbered lists, block quotes and pipe tables.
    static func markdown(_ lines: [String], _ resolve: (String) -> GuideTarget?) -> String {
        var out = "", paragraph: [String] = [], list: (tag: String, items: [String])?, table: [[String]] = []
        func cells(_ line: String) -> [String] {
            var row = line.trimmingCharacters(in: .whitespaces)
            if row.hasPrefix("|") { row.removeFirst() }
            if row.hasSuffix("|") { row.removeLast() }
            return row.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        func flush() {
            if !paragraph.isEmpty { out += "<p>\(inline(paragraph.joined(separator: " "), resolve))</p>" }
            paragraph = []
            if let list { out += "<\(list.tag)>" + list.items.map { "<li>\(inline($0, resolve))</li>" }.joined() + "</\(list.tag)>" }
            list = nil
            if !table.isEmpty {
                let rows = table.filter { !$0.allSatisfy { $0.allSatisfy { "-: ".contains($0) } } }
                out += "<table>" + rows.enumerated().map { index, row in
                    let tag = index == 0 && table.count > 1 ? "th" : "td"
                    return "<tr>" + row.map { "<\(tag)>\(inline($0, resolve))</\(tag)>" }.joined() + "</tr>"
                }.joined() + "</table>"
            }
            table = []
        }
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flush(); continue }
            if line.hasPrefix("|") {
                if table.isEmpty { flush() }
                table.append(cells(line))
            } else if let m = line.wholeMatch(of: #/[-*]\s+(.*)/#) {
                if list?.tag != "ul" { flush(); list = ("ul", []) }
                list?.items.append(String(m.1))
            } else if let m = line.wholeMatch(of: #/\d+[.)]\s+(.*)/#) {
                if list?.tag != "ol" { flush(); list = ("ol", []) }
                list?.items.append(String(m.1))
            } else if let m = line.wholeMatch(of: #/>\s?(.*)/#) {
                flush()
                out += "<blockquote>\(inline(String(m.1), resolve))</blockquote>"
            } else if list != nil, raw.hasPrefix("  ") {
                if let last = list?.items.popLast() { list?.items.append(last + " " + line) }
            } else {
                if list != nil || !table.isEmpty { flush() }
                paragraph.append(line)
            }
        }
        flush()
        return out
    }

    // MARK: Components

    static func flow(_ name: String, _ from: String, _ steps: [GuideDraft.Step], _ resolve: (String) -> GuideTarget?) -> String {
        let items = steps.enumerated().map { index, step -> String in
            let target = resolve(step.anchor)
            let data = target.map { " data-path=\"\(escape($0.path))\" data-start=\"\($0.start)\" data-end=\"\($0.end)\"" } ?? ""
            let title = target.map { anchor($0, label: "<code>\(escape(step.anchor))</code>") } ?? "<code>\(escape(step.anchor))</code>"
            return "<li class=\"step\"\(data)><span class=\"num\">\(index + 1)</span><div><div class=\"step-title\">\(title)</div><div class=\"step-why\">\(inline(step.text, resolve))</div></div></li>"
        }.joined()
        return """
        <div class="card player"><div class="flowhead"><span class="flowname">\(escape(name))</span>\
        <button class="play">\(escape(localized("guide.play")))</button></div>\
        <div class="flowfrom">\(escape(localized("guide.from"))) \(inline(from, resolve))</div>\
        <ol class="path">\(items)</ol></div>
        """
    }

    static func rolesTable(_ roles: [GuideDraft.Role], _ resolve: (String) -> GuideTarget?) -> String {
        let rows = roles.map { role -> String in
            let anchors = role.anchors.map { "`\($0)`" }.joined(separator: " ")
            let name = localized("guide.role." + role.role)
            return "<tr><td>\(inline(anchors, resolve))</td><td><span class=\"role role-\(role.role)\">\(escape(name))</span></td><td>\(inline(role.text, resolve))</td></tr>"
        }.joined()
        return "<table class=\"roles\">\(rows)</table>"
    }

    /// Parties as columns in order of first appearance, one row per message;
    /// a loop draws a box around its rows.
    static func sequence(_ lines: [GuideDraft.SequenceLine], _ resolve: (String) -> GuideTarget?) -> String {
        var parties: [String] = []
        for case .message(let from, let to, _, _, _) in lines {
            for party in [from, to] where !parties.contains(party) { parties.append(party) }
        }
        let column = 120.0, row = 36.0, top = 40.0
        let width = column * Double(parties.count)
        func x(_ party: String) -> Double { column / 2 + column * Double(parties.firstIndex(of: party) ?? 0) }
        var svg = "", y = top + 10, loops: [(label: String, y: Double)] = []
        var boxes = ""
        for line in lines {
            switch line {
            case .loop(let label):
                loops.append((label, y))
                y += 18
            case .end:
                guard let open = loops.popLast() else { continue }
                let inset = 8.0 * Double(loops.count + 1)
                boxes += "<rect class=\"loop\" x=\"\(inset)\" y=\"\(open.y - 4)\" width=\"\(width - 2 * inset)\" height=\"\(y - open.y + 2)\" rx=\"4\"/><text class=\"looplabel\" x=\"\(inset + 6)\" y=\"\(open.y + 9)\">loop \(escape(open.label))</text>"
                y += 8
            case .message(let from, let to, let label, let reply, let anchor):
                y += row
                let target = anchor.flatMap(resolve)
                let data = target.map { " data-path=\"\(escape($0.path))\" data-start=\"\($0.start)\" data-end=\"\($0.end)\"" } ?? ""
                let x1 = x(from), x2 = x(to)
                let shape = from == to
                    ? "<path class=\"flow\" d=\"M\(x1) \(y - 8) h36 v14 h-32\" marker-end=\"url(#ah)\"/>"
                    : "<line class=\"flow\(reply ? " reply" : "")\" x1=\"\(x1)\" y1=\"\(y)\" x2=\"\(x2 + (x2 > x1 ? -5 : 5))\" y2=\"\(y)\" marker-end=\"url(#ah)\"/>"
                let tx = from == to ? x1 + 42 : (x1 + x2) / 2
                svg += "<g class=\"msg step\"\(data)><rect class=\"hitbox\" x=\"\(min(x1, x2))\" y=\"\(y - 22)\" width=\"\(max(abs(x2 - x1), 60))\" height=\"28\"/>\(shape)<text x=\"\(tx)\" y=\"\(y - 6)\" text-anchor=\"\(from == to ? "start" : "middle")\">\(escape(label))</text></g>"
            }
        }
        let height = y + 24
        let heads = parties.map { party in
            "<text class=\"party\" x=\"\(x(party))\" y=\"22\" text-anchor=\"middle\">\(escape(party))</text><line class=\"lifeline\" x1=\"\(x(party))\" y1=\"30\" x2=\"\(x(party))\" y2=\"\(height - 6)\"/>"
        }.joined()
        return """
        <div class="card player"><div class="flowhead"><span class="flowname"></span>\
        <button class="play">\(escape(localized("guide.play")))</button></div>\
        <svg class="sequence" viewBox="0 0 \(width) \(height)" style="width:100%;max-width:\(Int(width))px"><defs><marker id="ah" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto"><path d="M0 0L10 5L0 10z" class="arrowhead"/></marker></defs>\(boxes)\(heads)\(svg)</svg></div>
        """
    }

    // MARK: Page

    static func css(_ color: NSColor) -> String {
        guard let rgb = color.usingColorSpace(.sRGB) else { return "#888" }
        return String(format: "#%02x%02x%02x", Int(rgb.redComponent * 255), Int(rgb.greenComponent * 255), Int(rgb.blueComponent * 255))
    }

    static func style(_ theme: ReaderTheme) -> String {
        """
        :root{--bg:\(css(theme.backgroundColor));--fg:\(css(theme.foregroundColor));--muted:\(css(theme.chromeSecondaryColor));\
        --faint:\(css(theme.chromeTertiaryColor));--accent:\(css(theme.accentColor));--line:\(css(theme.chromeDividerColor));\
        --chip:\(css(theme.chromeColor));--hl:\(css(theme.chromeSelectionColor))}
        *{box-sizing:border-box}
        body{margin:0;padding:10px 14px 24px;overflow-wrap:anywhere;background:var(--bg);color:var(--fg);font:13px/1.55 -apple-system,system-ui,sans-serif}
        h1{font-size:15px;margin:2px 0 6px}h2{font-size:12.5px;margin:18px 0 6px;color:var(--muted);text-transform:none}
        p,ul,ol,blockquote{margin:6px 0}ul,ol{padding-left:20px}blockquote{border-left:3px solid var(--line);padding-left:8px;color:var(--muted)}
        code{font:12px ui-monospace,SFMono-Regular,Menlo,monospace;background:var(--chip);border-radius:4px;padding:0 3px}
        a.anchor{color:var(--accent);text-decoration:none}a.anchor code{color:var(--accent)}a.anchor:hover code{text-decoration:underline}
        table{border-collapse:collapse;width:100%;margin:6px 0}td,th{border-bottom:1px solid var(--line);padding:4px 6px;vertical-align:top;text-align:left}
        .card{border:1px solid var(--line);border-radius:8px;padding:8px 10px;margin:8px 0;overflow-x:auto}
        .flowhead{display:flex;align-items:center;gap:8px}.flowname{font-weight:600;flex:1}
        .flowfrom{color:var(--muted);font-size:12px;margin:2px 0 6px}
        .play{font:11.5px -apple-system,system-ui;color:var(--accent);background:none;border:1px solid var(--line);border-radius:10px;padding:1px 8px;cursor:pointer}
        ol.path{list-style:none;padding:0;margin:0;position:relative}
        ol.path li{display:flex;gap:8px;padding:4px 0 8px;position:relative;border-radius:6px}
        ol.path li:not(:last-child)::before{content:"";position:absolute;left:9px;top:24px;bottom:-2px;border-left:2px dashed var(--faint);animation:dash 1.2s linear infinite}
        .num{flex:none;width:20px;height:20px;border-radius:10px;background:var(--chip);color:var(--muted);font-size:11px;display:flex;align-items:center;justify-content:center}
        .step-why{color:var(--muted)}
        .step.active{background:var(--hl)}.step.active .num{background:var(--accent);color:var(--bg)}
        .role{font-size:11px;border-radius:8px;padding:0 6px;background:var(--chip);color:var(--muted);white-space:nowrap}
        .role-main{color:var(--accent)}
        ul.state{list-style:none;padding-left:0}ul.state li::before{content:"⇢ ";color:var(--faint)}
        .ask{display:flex;flex-direction:column;align-items:flex-start;gap:4px;margin-top:6px}
        .question{font:12.5px -apple-system,system-ui;color:var(--accent);background:var(--chip);border:none;border-radius:10px;padding:3px 10px;cursor:pointer;text-align:left}
        svg.sequence{display:block;font:11.5px -apple-system,system-ui}
        .party{fill:var(--fg);font-weight:600}.lifeline{stroke:var(--line);stroke-dasharray:3 4}
        .flow{stroke:var(--accent);stroke-width:1.4;fill:none;stroke-dasharray:6 4;animation:dash 1.2s linear infinite}
        .flow.reply{stroke:var(--muted)}.arrowhead{fill:var(--accent)}
        .msg text{fill:var(--fg)}.hitbox{fill:transparent}.msg[data-path]{cursor:pointer}
        .msg.active .flow{stroke-width:2.6}.msg.active text{font-weight:600}
        .loop{fill:none;stroke:var(--line)}.looplabel{fill:var(--muted);font-size:11px}
        @keyframes dash{to{stroke-dashoffset:-20;background-position:0 20px}}
        @media (prefers-reduced-motion: reduce){.flow,ol.path li::before{animation:none}}
        """
    }

    /// Clicks post to the panel; ▶ steps through a card's items, jumping to each.
    static let script = """
    const post=m=>window.webkit.messageHandlers.cairn.postMessage(m);
    const jump=(el,play)=>post({path:el.dataset.path,start:+el.dataset.start,end:+el.dataset.end,play:!!play});
    document.addEventListener('click',e=>{
      const q=e.target.closest('[data-ask]');if(q){e.preventDefault();post({ask:q.dataset.ask});return}
      const b=e.target.closest('.play');if(b){e.preventDefault();toggle(b);return}
      const a=e.target.closest('[data-path]');if(a){e.preventDefault();jump(a)}
    });
    let playing=null;
    function stop(){if(!playing)return;clearTimeout(playing.timer);playing.items.forEach(i=>i.classList.remove('active'));playing.button.textContent=playing.label;playing=null}
    function toggle(button){
      const again=playing&&playing.button===button;stop();if(again)return;
      const items=[...button.closest('.player').querySelectorAll('.step')];if(!items.length)return;
      playing={button,items,label:button.textContent,index:0};button.textContent='■';
      const tick=()=>{if(!playing)return;items.forEach(i=>i.classList.remove('active'));
        if(playing.index>=items.length){stop();return}
        const item=items[playing.index++];item.classList.add('active');item.scrollIntoView({block:'nearest'});
        if(item.dataset.path)jump(item,true);playing.timer=setTimeout(tick,1600)};
      tick();
    }
    """
}
