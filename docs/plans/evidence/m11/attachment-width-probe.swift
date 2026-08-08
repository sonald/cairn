import AppKit
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
func measure(_ label: String, _ att: NSTextAttachment) {
    let s = NSMutableAttributedString(string: "AB")
    s.append(NSAttributedString(attachment: att))
    s.append(NSAttributedString(string: "CD"))
    let tv = NSTextView(usingTextLayoutManager: true)
    tv.frame = NSRect(x: 0, y: 0, width: 600, height: 200)
    tv.textContainer?.containerSize = NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude)
    tv.textContentStorage?.textStorage?.setAttributedString(s)
    tv.textLayoutManager?.ensureLayout(for: tv.textLayoutManager!.documentRange)
    var w: CGFloat = 0
    tv.textLayoutManager?.enumerateTextLayoutFragments(
        from: tv.textLayoutManager!.documentRange.location, options: []) { f in
        for lf in f.textLineFragments { w = max(w, lf.typographicBounds.width) }
        return true }
    print("\(label): 整行排版宽度 = \(String(format: "%.1f", w))pt")
}
let none = NSTextAttachment()
measure("无 bounds 无 image      ", none)
let b20 = NSTextAttachment(); b20.bounds = NSRect(x:0,y:0,width:20,height:14)
measure("bounds w=20 无 image    ", b20)
let b200 = NSTextAttachment(); b200.bounds = NSRect(x:0,y:0,width:200,height:14)
measure("bounds w=200 无 image   ", b200)
let img = NSTextAttachment()
img.image = NSImage(size: NSSize(width: 200, height: 14))
measure("image w=200            ", img)
