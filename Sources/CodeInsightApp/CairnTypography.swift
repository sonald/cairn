import AppKit

/// The redesign's display face: the system serif (New York), used for symbol
/// titles and prose headlines. Falls back to the system font if unavailable.
@MainActor
func cairnSerifFont(ofSize size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: weight)
    guard let descriptor = base.fontDescriptor.withDesign(.serif),
          let serif = NSFont(descriptor: descriptor, size: size)
    else { return base }
    return serif
}
