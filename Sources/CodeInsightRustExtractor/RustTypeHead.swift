import CodeInsightCore
import TreeSitterKit

/// R1.4 head-type stripping for Rust: reduce a spelled type to the head name
/// the type hop should land on. Wrapper types (`&`, `*const`, `dyn`, `impl`,
/// and the smart-pointer/container strip list) peel to their first type
/// argument; paths peel to their last segment; primitives return their node
/// so the caller can mark `.primitive`.
enum RustTypeHead {
    static let genericStripList: Set<String> = [
        "Box", "Rc", "Arc", "RefCell", "Cell", "Mutex", "RwLock", "Option", "Vec",
    ]

    static func head(in type: Node, bytes: [UInt8], byteOffset: UInt32) -> Node? {
        switch type.kind {
        case "reference_type", "pointer_type":
            // `&mut Box<S>` carries a named `mutable_specifier`; the type is
            // the last named child.
            return type.namedChildren.last.flatMap {
                head(in: $0, bytes: bytes, byteOffset: byteOffset)
            }
        case "dynamic_type", "abstract_type":
            // `dyn T` / `impl T` → the trait name.
            return type.namedChildren.first.flatMap {
                head(in: $0, bytes: bytes, byteOffset: byteOffset)
            }
        case "generic_type":
            guard let outer = type.namedChildren.first else { return nil }
            // Peel paths first so `std::boxed::Box<S>` still matches the
            // strip list by its last segment.
            guard let outerHead = head(in: outer, bytes: bytes, byteOffset: byteOffset),
                  let outerName = outerHead.text(in: bytes, byteOffset: byteOffset)
            else { return nil }
            guard genericStripList.contains(outerName),
                  let arguments = type.directNamedChild(where: {
                      $0.kind == "type_arguments"
                  }),
                  let firstArgument = arguments.namedChildren.first
            else {
                return outerHead
            }
            return head(in: firstArgument, bytes: bytes, byteOffset: byteOffset)
        case "scoped_type_identifier":
            return type.namedChildren.last.flatMap {
                head(in: $0, bytes: bytes, byteOffset: byteOffset)
            }
        case "identifier", "type_identifier", "primitive_type":
            return type
        default:
            return nil
        }
    }

    /// The type spelled after the first `:` in a parameter / field / let node.
    static func annotatedType(in node: Node) -> Node? {
        var followsColon = false
        for index in 0..<node.childCount {
            guard let child = node.child(at: index) else { continue }
            if child.kind == ":" {
                followsColon = true
            } else if followsColon && child.isNamed {
                return child
            }
        }
        return nil
    }
}
