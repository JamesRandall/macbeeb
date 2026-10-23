// RESET sets I on every variant, and the CMOS parts also clear D (WDC
// W65C02S and Rockwell R65C02 datasheets). NMOS leaves D alone. BeebEm and
// jsbeeb set I too; b2 doesn't.

import Testing
@testable import BeebCore

struct ResetTests {
    @Test(arguments: [M6502.Variant.nmos, .cmos, .rockwell])
    func resetSetsIAndClearsDOnCMOS(variant: M6502.Variant) {
        let m = FlatMachine(variant: variant)
        m.load([0x00, 0xF8], at: 0xFFFC)
        m.cpu.i = false
        m.cpu.d = true
        m.cpu.reset()
        m.stepInstruction()
        #expect(m.cpu.abus == 0xF800)
        #expect(m.cpu.i)
        #expect(m.cpu.d == (variant == .nmos))
    }

    /// With I set by the reset, an IRQ already asserted isn't taken before
    /// the first instruction at the reset vector.
    @Test func pendingIRQWaitsUntilCLI() {
        let m = FlatMachine(variant: .cmos)
        m.load([0x00, 0xF8], at: 0xFFFC)
        m.load([0x00, 0x90], at: 0xFFFE)
        m.load([0xEA, 0xEA, 0x58, 0xEA, 0xEA], at: 0xF800) // NOP NOP CLI NOP NOP
        m.cpu.i = false
        m.cpu.setIRQ(1, true)
        m.cpu.reset()
        var fetched: [UInt16] = []
        for _ in 0..<5 {
            m.stepInstruction()
            fetched.append(m.cpu.abus)
        }
        // CLI takes effect after the following instruction.
        #expect(fetched == [0xF800, 0xF801, 0xF802, 0xF803, 0x9000])
    }
}
