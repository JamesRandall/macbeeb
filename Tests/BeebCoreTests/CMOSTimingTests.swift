// CMOS instruction timings, from the WDC W65C02S and Rockwell R65C02
// datasheets. (NMOS timings are checked cycle by cycle against perfect6502
// in Oracle6502Tests.)

import Testing
@testable import BeebCore

struct CMOSTimingTests {
    struct Case: CustomTestStringConvertible, Sendable {
        var name: String
        var bytes: [UInt8]
        var cycles: Int
        var variant: M6502.Variant = .cmos
        var x: UInt8 = 0
        var y: UInt8 = 0
        var decimal = false
        var carry = false
        var testDescription: String { "\(name): \(cycles)" }
    }

    // Page-crossing cases use base $12FF with X/Y = 1. The zero page
    // pointer at $80 points to $12FF.
    static let cases: [Case] = [
        Case(name: "LDA #", bytes: [0xA9, 0x00], cycles: 2),
        Case(name: "ADC # binary", bytes: [0x69, 0x01], cycles: 2),
        Case(name: "ADC # decimal", bytes: [0x69, 0x01], cycles: 3, decimal: true),
        Case(name: "SBC abs decimal", bytes: [0xED, 0x00, 0x30], cycles: 5, decimal: true),
        Case(name: "ADC abs,X decimal page cross", bytes: [0x7D, 0xFF, 0x12], cycles: 6, x: 1, decimal: true),
        Case(name: "ADC (zp),Y decimal", bytes: [0x71, 0x80], cycles: 6, decimal: true),
        Case(name: "LDA abs,X", bytes: [0xBD, 0x00, 0x12], cycles: 4, x: 1),
        Case(name: "LDA abs,X page cross", bytes: [0xBD, 0xFF, 0x12], cycles: 5, x: 1),
        Case(name: "LDA (zp),Y", bytes: [0xB1, 0x80], cycles: 5),
        Case(name: "LDA (zp),Y page cross", bytes: [0xB1, 0x80], cycles: 6, y: 1),
        Case(name: "LDA (zp)", bytes: [0xB2, 0x80], cycles: 5),
        Case(name: "STA abs,X", bytes: [0x9D, 0x00, 0x30], cycles: 5),
        Case(name: "STA (zp),Y", bytes: [0x91, 0x80], cycles: 6),
        Case(name: "INC zp", bytes: [0xE6, 0x10], cycles: 5),
        Case(name: "INC abs", bytes: [0xEE, 0x00, 0x30], cycles: 6),
        Case(name: "INC zp,X", bytes: [0xF6, 0x10], cycles: 6),
        Case(name: "INC abs,X", bytes: [0xFE, 0x00, 0x30], cycles: 7),
        Case(name: "INC abs,X page cross", bytes: [0xFE, 0xFF, 0x12], cycles: 7, x: 1),
        Case(name: "ASL abs,X", bytes: [0x1E, 0x00, 0x30], cycles: 6),
        Case(name: "ASL abs,X page cross", bytes: [0x1E, 0xFF, 0x12], cycles: 7, x: 1),
        Case(name: "TRB zp", bytes: [0x14, 0x10], cycles: 5),
        Case(name: "TSB abs", bytes: [0x0C, 0x00, 0x30], cycles: 6),
        Case(name: "STZ abs", bytes: [0x9C, 0x00, 0x30], cycles: 4),
        Case(name: "STZ abs,X", bytes: [0x9E, 0x00, 0x30], cycles: 5),
        Case(name: "BIT #", bytes: [0x89, 0x00], cycles: 2),
        Case(name: "BIT abs,X", bytes: [0x3C, 0x00, 0x30], cycles: 4),
        Case(name: "INC A", bytes: [0x1A], cycles: 2),
        Case(name: "JMP abs", bytes: [0x4C, 0x00, 0x30], cycles: 3),
        Case(name: "JMP (abs)", bytes: [0x6C, 0x00, 0x30], cycles: 6),
        Case(name: "JMP (abs,X)", bytes: [0x7C, 0x00, 0x30], cycles: 6),
        Case(name: "JSR", bytes: [0x20, 0x00, 0x30], cycles: 6),
        Case(name: "RTS", bytes: [0x60], cycles: 6),
        Case(name: "RTI", bytes: [0x40], cycles: 6),
        Case(name: "BRK", bytes: [0x00, 0x00], cycles: 7),
        Case(name: "PHX", bytes: [0xDA], cycles: 3),
        Case(name: "PLY", bytes: [0x7A], cycles: 4),
        Case(name: "BRA", bytes: [0x80, 0x10], cycles: 3),
        Case(name: "BRA page cross", bytes: [0x80, 0xF0], cycles: 4),
        Case(name: "BCC not taken", bytes: [0x90, 0x10], cycles: 2, carry: true),
        Case(name: "NOP $02", bytes: [0x02, 0x00], cycles: 2),
        Case(name: "NOP $44", bytes: [0x44, 0x00], cycles: 3),
        Case(name: "NOP $54", bytes: [0x54, 0x00], cycles: 4),
        Case(name: "NOP $5C", bytes: [0x5C, 0x00, 0x00], cycles: 8),
        Case(name: "NOP $DC", bytes: [0xDC, 0x00, 0x00], cycles: 4),
        Case(name: "NOP $03", bytes: [0x03], cycles: 1),
        Case(name: "RMB0 zp", bytes: [0x07, 0x10], cycles: 5, variant: .rockwell),
        Case(name: "SMB7 zp", bytes: [0xF7, 0x10], cycles: 5, variant: .rockwell),
        Case(name: "BBR0 not taken", bytes: [0x0F, 0x11, 0x10], cycles: 5, variant: .rockwell),
        Case(name: "BBR0 taken", bytes: [0x0F, 0x10, 0x10], cycles: 6, variant: .rockwell),
        Case(name: "BBR0 taken page cross", bytes: [0x0F, 0x10, 0xE0], cycles: 7, variant: .rockwell),
    ]

    @Test(arguments: cases)
    func instructionTakesDatasheetCycles(_ test: Case) {
        let machine = FlatMachine(variant: test.variant)
        machine.load(test.bytes, at: 0x0200)
        machine.memory[0x10] = 0xFE // bit 0 clear for BBR0
        machine.memory[0x11] = 0x01 // bit 0 set
        machine.memory[0x80] = 0xFF
        machine.memory[0x81] = 0x12
        let cpu = machine.cpu
        cpu.x = test.x
        cpu.y = test.y
        cpu.d = test.decimal
        cpu.c = test.carry
        cpu.s = 0xFF
        cpu.start(at: 0x0200)
        machine.access()
        machine.stepInstruction()
        #expect(machine.cycles == test.cycles)
    }
}
