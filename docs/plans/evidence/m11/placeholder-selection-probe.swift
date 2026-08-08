import AppKit
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

// A. 纯字符串占位符
let plain = NSMutableAttributedString(string: "fn spawn() { … 42 lines }\nnext line\n")
print("A plain: placeholder run length =", ("{ … 42 lines }" as NSString).length)

let tvA = NSTextView(usingTextLayoutManager: true)
tvA.isEditable = false; tvA.isSelectable = true
tvA.textContentStorage?.textStorage?.setAttributedString(plain)
tvA.setSelectedRange(NSRange(location: 15, length: 3))   // 落在占位符内部
print("A plain: setSelectedRange(15,3) ->", tvA.selectedRange())

// B. NSTextAttachment 占位符
let att = NSTextAttachment()
let attStr = NSMutableAttributedString(string: "fn spawn() ")
attStr.append(NSAttributedString(attachment: att))
attStr.append(NSAttributedString(string: "\nnext line\n"))
print("B attachment: attachment run length =", NSAttributedString(attachment: att).length)
print("B attachment: unichar ==U+FFFC ?",
      (NSAttributedString(attachment: att).string as NSString).character(at: 0) == 0xFFFC)

let tvB = NSTextView(usingTextLayoutManager: true)
tvB.isEditable = false; tvB.isSelectable = true
tvB.textContentStorage?.textStorage?.setAttributedString(attStr)
tvB.setSelectedRange(NSRange(location: 11, length: 1))
print("B attachment: whole-attachment select ->", tvB.selectedRange())
