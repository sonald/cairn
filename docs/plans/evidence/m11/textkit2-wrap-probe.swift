import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

let tv = NSTextView(usingTextLayoutManager: true)
tv.isEditable = false
tv.isSelectable = true
tv.frame = NSRect(x: 0, y: 0, width: 200, height: 600)

// 三个源码"行"（段落），其中第一段很长，必须换行才能放进 200pt 宽
let long = String(repeating: "wrapme ", count: 40)
let src = long + "\nshort line two\nshort line three\n"

let storage = NSTextStorage(string: src, attributes: [
    .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
])
tv.textContentStorage?.textStorage = storage

func probe(wrap: Bool) {
    if wrap {
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.containerSize = NSSize(width: 200, height: CGFloat.greatestFiniteMagnitude)
    } else {
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    }
    guard let lm = tv.textLayoutManager else { return }
    lm.textViewportLayoutController.layoutViewport()
    lm.ensureLayout(for: lm.documentRange)

    var fragments = 0
    var lineFragments = 0
    var perFragment: [Int] = []
    lm.enumerateTextLayoutFragments(from: lm.documentRange.location, options: []) { f in
        fragments += 1
        lineFragments += f.textLineFragments.count
        perFragment.append(f.textLineFragments.count)
        return true
    }
    print("wrap=\(wrap)  layoutFragments=\(fragments)  textLineFragments=\(lineFragments)  perFragment=\(perFragment)")
}

probe(wrap: false)
probe(wrap: true)
print("源码行数(段落数)=3")
