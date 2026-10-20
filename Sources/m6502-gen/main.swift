// Regenerates BeebCore/CPU/M6502+Generated.swift.
//
// Usage: swift run m6502-gen [output-path]

import Foundation
import M6502GenKit

let defaultOutput = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("BeebCore/CPU/M6502+Generated.swift")

let output = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1])
    : defaultOutput

do {
    try generateSwift().write(to: output, atomically: true, encoding: .utf8)
    print("Wrote \(output.path)")
} catch {
    FileHandle.standardError.write(Data("m6502-gen: \(error)\n".utf8))
    exit(1)
}
