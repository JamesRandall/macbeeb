// The Model B+ 128K: shadow RAM, the 12K private RAM, sideways RAM, and an
// Acorn 1770 at &FE80.

import Foundation
import Testing
@testable import BeebCore
import BeebROMs

struct BPlusTests {
    func boot(disc: String? = nil) throws -> BBCMicro {
        let machine = BBCMicro(configuration: BeebROMs.configuration(for: .bPlus))
        if let disc {
            machine.insertDisc(try Disc.fromSSD(testResource("discs/\(disc)")))
        }
        #expect(machine.runUntilIdle())
        return machine
    }

    /// Pokes `code` at &2000, calls it and returns &70.
    func call(_ machine: BBCMicro, _ code: [UInt8]) -> UInt8 {
        for (i, byte) in code.enumerated() {
            machine.poke(0x2000 + UInt16(i), byte)
        }
        command(machine, "CALL &2000")
        return machine.peek(0x70)
    }

    @Test func boots() throws {
        let machine = try boot()
        let screen = machine.screenText()
        #expect(screen.contains("Acorn OS 128K"), "\(screen)")
        #expect(screen.contains("Acorn 1770 DFS"), "\(screen)")
        #expect(machine.cpu.variant == .nmos)
    }

    @Test func shadowModes() throws {
        let machine = try boot()
        command(machine, "MODE 128")
        command(machine, "?&3000=&5A:PRINT HIMEM")
        #expect(machine.screenText().contains("     32768"), "\(machine.screenText())")
        #expect(machine.acccon == 0x80)
        #expect(machine.peekMainRAM(0x3000) == 0x5A)
        #expect(machine.peekScreen(0x3000) != 0x5A)
    }

    @Test func privateRAMAndSidewaysRAM() throws {
        let machine = try boot()
        // ROMSEL bit 7 pages 12K of RAM in at &8000-&AFFF; &B000 stays ROM.
        let privateRAM = call(machine, [
            0x78, 0xA9, 0x8F, 0x8D, 0x30, 0xFE, // SEI: LDA #&8F: STA &FE30
            0xA9, 0xA5, 0x8D, 0xFF, 0xAF,       // LDA #&A5: STA &AFFF
            0xAD, 0xFF, 0xAF, 0x85, 0x70,       // LDA &AFFF: STA &70
            0xA9, 0x0F, 0x8D, 0x30, 0xFE,       // LDA #15: STA &FE30
            0x58, 0x60,
        ])
        #expect(privateRAM == 0xA5)
        #expect(machine.peek(0xAFFF) != 0xA5)
        // Bank 12 is sideways RAM.
        let sideways = call(machine, [
            0x78, 0xA9, 0x0C, 0x8D, 0x30, 0xFE,
            0xA9, 0x3C, 0x8D, 0x00, 0xB0,       // STA &B000
            0xAD, 0x00, 0xB0, 0x85, 0x70,
            0xA9, 0x0F, 0x8D, 0x30, 0xFE,
            0x58, 0x60,
        ])
        #expect(sideways == 0x3C)
    }

    @Test func cataloguesADiscThroughThe1770() throws {
        let machine = try boot(disc: "TestTimings.ssd")
        let screen = command(machine, "*CAT")
        #expect(screen.contains { $0.contains("TEST") }, "\(screen)")
    }

    @Test func restoredBPlusRunsIdentically() throws {
        let original = try boot(disc: "TestTimings.ssd")
        command(original, "MODE 128")
        original.paste("*CAT\n")
        original.run(seconds: 0.2)
        let snapshot = original.snapshot()
        let copy = BBCMicro(configuration: BeebROMs.configuration(for: .bPlus))
        try copy.restore(snapshot)
        for machine in [original, copy] {
            machine.run(seconds: 1)
        }
        #expect(copy.snapshot().ram == original.snapshot().ram)
        #expect(copy.cycles == original.cycles && copy.cpu.pc == original.cpu.pc && copy.cpu.a == original.cpu.a)
    }

    @Test(arguments: [(BBCMicro.Model.modelB, true), (.bPlus, true), (.master128, false)])
    func teletextAt3C00(_ model: BBCMicro.Model, shows3C00: Bool) throws {
        let machine = BBCMicro(configuration: BeebROMs.configuration(for: model))
        #expect(machine.runUntilIdle())
        // R12/R13 = &2000: teletext with MA11 clear.
        command(machine, "?&3C00=ASC\"Q\":?&7C00=ASC\"Z\":VDU 23,0,12,&20,0,0,0,0,0,0:VDU 23,0,13,0,0,0,0,0,0,0")
        machine.run(seconds: 0.1)
        let first = machine.teletextScreenText()?.first?.first
        #expect(first == (shows3C00 ? "Q" : "Z"), "\(machine.teletextScreenText() ?? [])")
    }
}
