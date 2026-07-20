import CodeInsightCore
import TreeSitterKit

struct RustCalls {
    let bytes: [UInt8]
    let names: Interner<NameID>
    private(set) var calls: [UnresolvedCall] = []

    mutating func enter(_ node: Node, regionID: ExecutableRegionID?) {
        guard let regionID else { return }

        if node.kind == "macro_invocation" {
            guard let macro = node.namedChildren.first,
                  let nameNode = finalName(in: macro),
                  let name = nameNode.text(in: bytes)
            else { return }
            calls.append(UnresolvedCall(
                regionID: regionID,
                nameID: names.intern(name),
                range: node.coreByteRange,
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
              let call = classify(callee)
        else { return }

        let arguments = node.directNamedChild { $0.kind == "arguments" }
        calls.append(UnresolvedCall(
            regionID: regionID,
            nameID: names.intern(call.name),
            range: node.coreByteRange,
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
        _ node: Node
    ) -> (
        name: String,
        kind: CallKind,
        qualifierRange: CodeInsightCore.ByteRange?,
        receiverRange: CodeInsightCore.ByteRange?
    )? {
        switch node.kind {
        case "identifier":
            return node.text(in: bytes).map {
                ($0, .directCall, nil, nil)
            }
        case "scoped_identifier":
            let children = node.namedChildren
            guard children.count >= 2,
                  let name = children.last?.text(in: bytes)
            else { return nil }
            return (name, .qualifiedCall, children.first?.coreByteRange, nil)
        case "field_expression":
            let children = node.namedChildren
            guard children.count >= 2,
                  let name = children.last?.text(in: bytes)
            else { return nil }
            return (name, .methodCall, nil, children.first?.coreByteRange)
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
