import Foundation

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data(
        "usage: swift scripts/generate-m6-reference-fixture.swift <output>\n".utf8
    ))
    exit(2)
}

var source = ""
source.reserveCapacity(3_200_000)
for functionIndex in 0..<1_000 {
    source += "fn fixture_\(functionIndex)(p0: u64, p1: u64) -> u64 {\n"
    source += "    let v0 = p0 + p1;\n"
    for bindingIndex in 1...16 {
        source += "    let v\(bindingIndex) = v\(bindingIndex - 1) + p0;\n"
    }
    source += "    let v17 = 0;\n"
    source += "    v16\n"
    source += "}\n"
    for paddingIndex in 0..<79 {
        source += "// f\(functionIndex) deterministic padding \(paddingIndex)\n"
    }
}

let output = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(
    at: output.deletingLastPathComponent(),
    withIntermediateDirectories: true
)
try Data(source.utf8).write(to: output, options: .atomic)
