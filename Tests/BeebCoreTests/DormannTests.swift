// Klaus Dormann's 6502/65C02 functional and decimal tests
// (https://github.com/Klaus2m5/6502_65C02_functional_tests), as built by b2:
// success writes 0 to $FF00; failure is an instruction that jumps to itself.

import Testing
@testable import BeebCore

struct DormannTests {
    struct Case: CustomTestStringConvertible, Sendable {
        var file: String
        var loadAddress: Int
        var startAddress: UInt16
        var variant: M6502.Variant
        var testDescription: String { "\(file) on \(variant)" }
    }

    static let cases: [Case] = [
        Case(file: "6502.bin", loadAddress: 0, startAddress: 0x400, variant: .nmos),
        Case(file: "6502.bin", loadAddress: 0, startAddress: 0x400, variant: .cmos),
        Case(file: "6502.bin", loadAddress: 0, startAddress: 0x400, variant: .rockwell),
        Case(file: "65c02.bin", loadAddress: 0, startAddress: 0x400, variant: .cmos),
        Case(file: "65c02_rockwell.bin", loadAddress: 0, startAddress: 0x400, variant: .rockwell),
        Case(file: "d0.bin", loadAddress: 0x200, startAddress: 0x200, variant: .nmos),
        Case(file: "d1.bin", loadAddress: 0x200, startAddress: 0x200, variant: .cmos),
        Case(file: "d1.bin", loadAddress: 0x200, startAddress: 0x200, variant: .rockwell),
    ]

    @Test(arguments: cases)
    func functionalTest(_ test: Case) throws {
        let machine = FlatMachine(variant: test.variant)
        machine.load(try testResource("dormann/\(test.file)"), at: test.loadAddress)
        let cpu = machine.cpu
        cpu.start(at: test.startAddress)
        machine.access()

        var lastPC: UInt16?
        let maxCycles = 200_000_000
        while machine.cycles < maxCycles {
            machine.step()
            if cpu.access == .write && cpu.abus == 0xFF00 {
                #expect(cpu.dbus == 0, "test reported failure \(cpu.dbus)")
                return
            }
            if cpu.isAboutToExecute {
                if cpu.abus == lastPC {
                    Issue.record("trapped at $\(hex(cpu.abus)) after \(machine.cycles) cycles: A=\(hex(cpu.a)) X=\(hex(cpu.x)) Y=\(hex(cpu.y)) P=\(hex(cpu.p))")
                    return
                }
                lastPC = cpu.abus
            }
        }
        Issue.record("didn't finish in \(maxCycles) cycles")
    }
}

func hex(_ value: UInt8) -> String { String(format: "%02X", value) }
func hex(_ value: UInt16) -> String { String(format: "%04X", value) }
