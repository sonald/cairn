import CodeInsightCore
@testable import CodeInsightEngine
import Foundation
import Testing

/// Direct subtypes: a same-file base, an imported base, and a decoy whose
/// base name is another declaration in its own file.
@Test(arguments: [
    (LanguageID.python, "base.py", "Base", [
        "base.py": "class Base:\n    pass\n\nclass Same(Base):\n    pass\n",
        "sub.py": "import typing\nfrom base import Base\n\nclass Child(typing.Generic[T], Base, metaclass=M):\n    pass\n",
        "other.py": "class Base:\n    pass\n\nclass Wrong(Base):\n    pass\n",
    ], ["base.py:Same", "sub.py:Child"]),
    (LanguageID.typescript, "base.ts", "Shape", [
        "base.ts": "export interface Shape {}\nexport interface Sub extends Shape {}\nexport class Same implements Shape {}\n",
        "sub.ts": "import { Shape } from \"./base\";\nexport class Child extends Object implements ns.Other<T>, Shape {}\n",
        "other.ts": "export interface Shape {}\nexport class Wrong implements Shape {}\n",
    ], ["base.ts:Sub", "base.ts:Same", "sub.ts:Child"]),
    (LanguageID.rust, "src/lib.rs", "Base", [
        "Cargo.toml": "[package]\nname = \"subtypes\"\nversion = \"0.1.0\"\nedition = \"2021\"\n",
        "src/lib.rs": "mod other;\nmod sub;\npub trait Base {}\npub trait Same: Base + ?Sized {}\n",
        "src/sub.rs": "use crate::Base;\npub trait Child: 'static + Base {}\n",
        "src/other.rs": "pub trait Base {}\npub trait Wrong: Base {}\n",
    ], ["src/lib.rs:Same", "src/sub.rs:Child"]),
])
func subtypesListDirectSubtypesAndDropOtherBases(
    language: LanguageID,
    file: String,
    name: String,
    files: [String: String],
    expected: [String]
) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "subtypes-\(UUID().uuidString)"
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    for (path, contents) in files {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }
    let session = try ProjectIndexer().index(root: root, language: language)
    let context = QueryContext(
        snapshotID: session.snapshotID,
        analysisProfileID: session.analysisProfile.id,
        generation: 1
    )
    let base = try #require(session.definitions(of: name, context: context).first {
        session.paths.resolve($0.2) == file
    }?.0)
    let subtypes = try session.subtypes(of: base, context: context)
    let found = try subtypes.map { candidate in
        let index = try #require(session.contentForCLI(at: candidate.target.pathID))
        let facet = index.symbols[Int(candidate.target.localIndex)]
        return "\(session.paths.resolve(candidate.target.pathID)):\(session.names.resolve(facet.nameID))"
    }
    #expect(found == expected)
    #expect(subtypes.first?.certainty == .strong)
}

/// `h.Base` resolves to a class attribute binding in another file; reading
/// that index from the subclass's own (shorter) binding list trapped.
@Test
func subtypesJudgeAnAttributeBaseByItsOwnFileBinding() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "subtypes-attr-\(UUID().uuidString)"
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let files = [
        "base.py": "class Base:\n    pass\n",
        "holder.py": "class Holder:\n    Other: int\n    Base: type\n",
        "sub.py": "from holder import Holder\nh: Holder = Holder()\n\nclass Child(h.Base):\n    pass\n",
    ]
    for (path, contents) in files {
        try contents.write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
    }
    let session = try ProjectIndexer().index(root: root, language: .python)
    let context = QueryContext(
        snapshotID: session.snapshotID,
        analysisProfileID: session.analysisProfile.id,
        generation: 1
    )
    let base = try #require(session.definitions(of: "Base", context: context).first {
        session.paths.resolve($0.2) == "base.py"
    }?.0)
    #expect(try session.subtypes(of: base, context: context).isEmpty)
}
