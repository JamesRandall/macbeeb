import Foundation
import M6502GenKit
import Testing

struct GeneratedCodeTests {
    @Test func generatedStateMachineIsUpToDate() throws {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/BeebCore/CPU/M6502+Generated.swift")
        let onDisk = try String(contentsOf: path, encoding: .utf8)
        #expect(onDisk == generateSwift(), "M6502+Generated.swift is stale: run `swift run m6502-gen`")
    }
}
