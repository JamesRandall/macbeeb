// CMOS ADC/SBC results for every input, recorded by Tom Seddon on a real
// Master 128 65C12 (from b2's etc/cmos_adc_sbc).

import Testing
@testable import BeebCore

struct CMOSDecimalTests {
    struct Case: CustomTestStringConvertible, Sendable {
        var name: String
        var op: M6502.Op
        var carry: Bool
        var decimal: Bool
        var testDescription: String { "\(name) C=\(carry ? 1 : 0) D=\(decimal ? 1 : 0)" }
    }

    static let cases: [Case] = ["ADC", "SBC"].flatMap { name in
        [false, true].flatMap { carry in
            [false, true].map { decimal in
                Case(name: name, op: name == "ADC" ? .adcCMOS : .sbcCMOS, carry: carry, decimal: decimal)
            }
        }
    }

    @Test(arguments: cases)
    func matchesHardware(_ test: Case) throws {
        let suffix = "\(test.name)C\(test.carry ? 1 : 0)D\(test.decimal ? 1 : 0)"
        let expectedA = try testResource("cmos_adc_sbc/A\(suffix)")
        let expectedP = try testResource("cmos_adc_sbc/P\(suffix)")
        let cpu = M6502(variant: .cmos)
        var mismatches = 0
        for operand in 0..<256 {
            for a in 0..<256 {
                cpu.c = test.carry
                cpu.d = test.decimal
                cpu.a = UInt8(a)
                cpu.data = UInt8(operand)
                cpu.execute(test.op)
                let index = a + operand * 256
                let p = expectedP[index]
                let ok = cpu.a == expectedA[index]
                    && cpu.c == (p & 0x01 != 0)
                    && cpu.z == (p & 0x02 != 0)
                    && cpu.v == (p & 0x40 != 0)
                    && cpu.n == (p & 0x80 != 0)
                if !ok {
                    mismatches += 1
                    if mismatches <= 5 {
                        Issue.record("A=\(hex(UInt8(a))) operand=\(hex(UInt8(operand))): got A=\(hex(cpu.a)) P=\(hex(cpu.p)), want A=\(hex(expectedA[index])) P=\(hex(p))")
                    }
                }
            }
        }
        #expect(mismatches == 0)
    }
}
