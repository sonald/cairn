import CodeInsightCore
import TreeSitterKit

struct RustCalls {
    let bytes: [UInt8]
    let names: Interner<NameID>
    private(set) var calls: [UnresolvedCall] = []

    mutating func enter(
        _ node: Node,
        regionID: ExecutableRegionID?,
        byteOffset: UInt32
    ) {
        guard let regionID else { return }

        if node.kind == "macro_invocation" {
            guard let macro = node.namedChildren.first,
                  let nameNode = finalName(in: macro),
                  let name = nameNode.text(in: bytes, byteOffset: byteOffset)
            else { return }
            calls.append(UnresolvedCall(
                regionID: regionID,
                nameID: names.intern(name),
                range: node.coreByteRange(byteOffset: byteOffset),
                nameRange: nameNode.coreByteRange(byteOffset: byteOffset),
                syntacticKind: .macroInvocation,
                qualifierRange: nil,
                receiverRange: nil,
                argumentCount: nil
            ))
            return
        }

        guard node.kind == "call_expression",
              let rawCallee = node.namedChildren.first,
              let callee = unwrapGenericFunction(rawCallee),
              let call = classify(callee, byteOffset: byteOffset)
        else { return }

        let arguments = node.directNamedChild { $0.kind == "arguments" }
        calls.append(UnresolvedCall(
            regionID: regionID,
            nameID: names.intern(call.name),
            range: node.coreByteRange(byteOffset: byteOffset),
            nameRange: call.nameRange,
            syntacticKind: call.kind,
            qualifierRange: call.qualifierRange,
            receiverRange: call.receiverRange,
            argumentCount: arguments.flatMap {
                UInt16(exactly: $0.namedChildren.count)
            }
        ))
    }

    private func unwrapGenericFunction(_ node: Node) -> Node? {
        node.kind == "generic_function" ? node.namedChildren.first : node
    }

    private func classify(
        _ node: Node,
        byteOffset: UInt32
    ) -> (
        name: String,
        nameRange: CodeInsightCore.ByteRange,
        kind: CallKind,
        qualifierRange: CodeInsightCore.ByteRange?,
        receiverRange: CodeInsightCore.ByteRange?
    )? {
        switch node.kind {
        case "identifier":
            return node.text(in: bytes, byteOffset: byteOffset).map {
                (
                    $0,
                    node.coreByteRange(byteOffset: byteOffset),
                    .directCall,
                    nil,
                    nil
                )
            }
        case "scoped_identifier":
            let children = node.namedChildren
            guard children.count >= 2,
                  let nameNode = children.last,
                  let name = nameNode.text(
                      in: bytes,
                      byteOffset: byteOffset
                  )
            else { return nil }
            return (
                name,
                nameNode.coreByteRange(byteOffset: byteOffset),
                .qualifiedCall,
                children.first?.coreByteRange(byteOffset: byteOffset),
                nil
            )
        case "field_expression":
            let children = node.namedChildren
            guard children.count >= 2,
                  let nameNode = children.last,
                  let name = nameNode.text(
                      in: bytes,
                      byteOffset: byteOffset
                  )
            else { return nil }
            return (
                name,
                nameNode.coreByteRange(byteOffset: byteOffset),
                .methodCall,
                nil,
                children.first?.coreByteRange(byteOffset: byteOffset)
            )
        default:
            return nil
        }
    }

    private func finalName(in node: Node) -> Node? {
        switch node.kind {
        case "identifier", "self", "super":
            return node
        case "scoped_identifier":
            return node.namedChildren.last
        default:
            return nil
        }
    }
}
