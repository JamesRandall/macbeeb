// scarybeasts' VIA tests: BASIC programs with inline assembler that store
// results at &100, compared with values from a real BBC. From jsbeeb's
// tests/integration/via.js.

import Foundation
import Testing
@testable import BeebCore
import BeebROMs

struct VIATests {
    struct Case: Decodable, CustomTestStringConvertible, Sendable {
        var name: String
        var source: String
        var expected: [UInt8]
        var model: String?
        var testDescription: String { name }
    }

    struct File: Decodable {
        var tests: [Case]
    }

    static let cases: [Case] = {
        let data = try! Data(testResource("via_tests.json"))
        return try! JSONDecoder().decode(File.self, from: data).tests.filter { $0.model == nil }
    }()

    @Test(arguments: cases)
    func matchesRealBBC(_ test: Case) {
        let machine = bootModelB()
        machine.paste(numberedBASIC(test.source) + "RUN\n")
        #expect(machine.runUntilIdle(), "program didn't finish")
        let results = (0..<test.expected.count).map { machine.peek(0x100 + UInt16($0)) }
        #expect(results == test.expected, "screen:\n\(machine.teletextScreenText()?.joined(separator: "\n") ?? "")")
    }
}

/// Adds line numbers to a BASIC listing without them.
func numberedBASIC(_ source: String) -> String {
    source.split(separator: "\n", omittingEmptySubsequences: true)
        .enumerated()
        .map { "\(($0.offset + 1) * 10) \($0.element)\n" }
        .joined()
}

/// A Model B with OS 1.2 and BASIC 2, booted to the BASIC prompt.
func bootModelB() -> BBCMicro {
    let machine = BBCMicro(os: BeebROMs.data(.os12), sidewaysROMs: [15: BeebROMs.data(.basic2)])
    machine.runUntilIdle()
    return machine
}
