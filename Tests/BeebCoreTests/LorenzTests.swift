// Wolfgang Lorenz's C64 6502 test suite 2.15 (public domain), in the ASCII
// build from b2. The tests chain together by "loading" the next one via the
// C64 KERNAL; the KERNAL entry points are trapped here.

import Foundation
import Testing
@testable import BeebCore

struct LorenzTests {
    @Test func lorenzSuite() throws {
        let machine = FlatMachine(variant: .nmos)
        let cpu = machine.cpu

        var output = ""
        var currentTest = "start"
        var failures: [String] = []
        var testsRun: [String] = []

        func load(_ name: String) throws {
            let file = try testResource("lorenz/\(name)")
            machine.memory = [UInt8](repeating: 0, count: 0x10000)
            machine.load(Array(file[2...]), at: Int(file[0]) | Int(file[1]) << 8)

            // Enough of the C64 for the tests.
            machine.memory[0x0002] = 0x00
            machine.memory[0xA002] = 0x00
            machine.memory[0xA003] = 0x80
            machine.memory[0xFFFE] = 0x48
            machine.memory[0xFFFF] = 0xFF
            machine.memory[0x01FE] = 0xFF
            machine.memory[0x01FF] = 0x7F
            // IRQ handler: dispatches BRK via $0316, IRQ via $0314.
            machine.load([0x48, 0x8A, 0x48, 0x98, 0x48, 0xBA, 0xBD, 0x04, 0x01,
                          0x29, 0x10, 0xF0, 0x03, 0x6C, 0x16, 0x03, 0x6C, 0x14, 0x03], at: 0xFF48)
            // Trapped KERNAL routines return straight away.
            machine.memory[0xFFD2] = 0x60 // print character
            machine.memory[0xE16F] = 0x60 // load
            machine.memory[0xFFE4] = 0x60 // scan keyboard

            cpu.s = 0xFD
            cpu.i = true
            cpu.start(at: 0x0816)
            machine.access()
            currentTest = name
            testsRun.append(name)
        }

        try load("start")

        let maxCycles = 50_000_000_000
        while machine.cycles < maxCycles {
            machine.step()
            guard cpu.isAboutToExecute else { continue }

            switch cpu.abus {
            case 0xFFD2:
                machine.memory[0x030C] = 0
                output.append(cpu.a == 13 ? "\n" : String(UnicodeScalar(cpu.a)))
            case 0xE16F:
                let nameAddress = Int(machine.memory[0xBB]) | Int(machine.memory[0xBC]) << 8
                let length = Int(machine.memory[0xB7])
                let name = String(decoding: machine.memory[nameAddress..<nameAddress + length], as: UTF8.self)
                if name == "trap1" {
                    // The end of the tests that don't need C64 hardware.
                    #expect(failures.isEmpty, "failed: \(failures.joined(separator: ", "))\n\(output)")
                    #expect(testsRun.count > 200)
                    print("Lorenz: \(testsRun.count) tests, \(machine.cycles) cycles")
                    return
                }
                try load(name)
            case 0xFFE4:
                // Only called to wait for a key after reporting an error.
                failures.append(currentTest)
                cpu.a = 3
            case 0x8000, 0xA474:
                Issue.record("\(currentTest): crashed into BASIC\n\(output)")
                return
            default:
                break
            }
        }
        Issue.record("didn't finish in \(maxCycles) cycles; last test \(currentTest)")
    }
}
