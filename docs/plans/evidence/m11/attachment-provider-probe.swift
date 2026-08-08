import AppKit
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

func makeView(_ s: NSAttributedString, width: CGFloat = 200) -> NSTextView {
    let tv = NSTextView(usingTextLayoutManager: true)
    tv.isEditable = false; tv.isSelectable = true
    tv.frame = NSRect(x: 0, y: 0, width: width, height: 400)
    tv.textContainer?.widthTracksTextView = true
    tv.textContainer?.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
    tv.textContentStorage?.textStorage?.setAttributedString(s)
    tv.textLayoutManager?.textViewportLayoutController.layoutViewport()
    tv.textLayoutManager?.ensureLayout(for: tv.textLayoutManager!.documentRange)
    return tv
}

func stats(_ tv: NSTextView) -> (frags: Int, lines: Int, providers: Int) {
    guard let lm = tv.textLayoutManager else { return (0,0,0) }
    var f = 0, l = 0, p = 0
    lm.enumerateTextLayoutFragments(from: lm.documentRange.location, options: []) { fr in
        f += 1; l += fr.textLineFragments.count
        p += fr.textAttachmentViewProviders.count
        return true
    }
    return (f, l, p)
}

// A. 普通 attachment，无注册 provider
let plainAtt = NSTextAttachment()
plainAtt.bounds = NSRect(x: 0, y: 0, width: 20, height: 14)
let a = NSMutableAttributedString(string: "fn spawn() ")
a.append(NSAttributedString(attachment: plainAtt))
a.append(NSAttributedString(string: " trailing words here to fill the line"))
let tvA = makeView(a)
print("A plain attachment(w=20):", stats(tvA))

// B. 同一段，attachment 宽度改成 100
let wideAtt = NSTextAttachment()
wideAtt.bounds = NSRect(x: 0, y: 0, width: 100, height: 14)
let b = NSMutableAttributedString(string: "fn spawn() ")
b.append(NSAttributedString(attachment: wideAtt))
b.append(NSAttributedString(string: " trailing words here to fill the line"))
let tvB = makeView(b)
print("B plain attachment(w=100):", stats(tvB))
print("   UTF-16 length A == B ?", a.length == b.length, "(A=\(a.length) B=\(b.length))")
