// The Master 128: MOS 3.20, paging, shadow and sideways RAM, the RTC and
// the 1770.

import Foundation
import Testing
@testable import BeebCore
import BeebROMs

func bootMaster(disc discName: String? = nil, configure: (BBCMicro) -> Void = { _ in }) throws -> BBCMicro {
    let machine = BBCMicro(configuration: BeebROMs.configuration(for: .master128))
    configure(machine)
    if let discName {
        machine.insertDisc(try Disc.fromSSD(testResource("discs/\(discName)")))
    }
    #expect(machine.runUntilIdle())
    return machine
}

/// Runs a BASIC line and returns the screen text.
@discardableResult
func command(_ machine: BBCMicro, _ line: String, maxSeconds: Double = 10) -> [String] {
    machine.paste(line + "\n")
    #expect(machine.runUntilIdle(maxSeconds: maxSeconds))
    return machine.screenText()
}

struct MasterTests {
    @Test func bootsToBASIC4() throws {
        let machine = try bootMaster()
        let screen = machine.screenText()
        #expect(screen.contains("Acorn MOS"), "\(screen)")
        #expect(screen.contains("Acorn 1770 DFS"), "\(screen)")
        #expect(screen.contains("BASIC"), "\(screen)")
        #expect(machine.cpu.variant == .cmos)
        // DFS workspace is in HAZEL, so PAGE stays at &E00.
        #expect(machine.peek(0x18) == 0x0E)
    }

    @Test func listsItsROMs() throws {
        let machine = try bootMaster()
        let screen = command(machine, "*ROMS")
        for line in ["ROM F TERMINAL 01", "ROM C BASIC 04", "ROM 9 DFS 79", "ROM D Acorn ADFS 50"] {
            #expect(screen.contains(line), "\(screen)")
        }
    }

    @Test func shadowModesKeepMainRAMFree() throws {
        let machine = try bootMaster()
        // MODE 128 is MODE 0 in shadow RAM.
        command(machine, "MODE 128")
        command(machine, "?&3000=&5A:PRINT HIMEM")
        #expect(machine.screenText().contains("     32768"), "\(machine.screenText())")
        #expect(machine.acccon & 0x01 != 0)
        // BASIC's write went to main RAM; the display shows shadow RAM.
        #expect(machine.peekMainRAM(0x3000) == 0x5A)
        #expect(machine.peekScreen(0x3000) != 0x5A)
    }

    @Test func sidewaysRAMIsWritableAndROMIsNot() throws {
        let machine = try bootMaster()
        // Writes &A5 to &8000 in `bank`, reads it back to &70, and pages
        // BASIC (bank 12) back in.
        func probe(bank: UInt8) -> UInt8 {
            let code: [UInt8] = [
                0x78,                   // SEI
                0xA9, bank, 0x8D, 0x30, 0xFE, // LDA #bank: STA &FE30
                0xA9, 0xA5, 0x8D, 0x00, 0x80, // LDA #&A5: STA &8000
                0xAD, 0x00, 0x80, 0x85, 0x70, // LDA &8000: STA &70
                0xA9, 0x0C, 0x8D, 0x30, 0xFE, // LDA #12: STA &FE30
                0x58, 0x60,             // CLI: RTS
            ]
            for (i, byte) in code.enumerated() {
                machine.poke(0x2000 + UInt16(i), byte)
            }
            command(machine, "CALL &2000")
            return machine.peek(0x70)
        }
        #expect(probe(bank: 4) == 0xA5)
        #expect(probe(bank: 7) == 0xA5)
        // Bank 9 is the DFS ROM.
        #expect(probe(bank: 9) == BeebROMs.data(.mos320DFS)[0])
    }

    @Test func readsTheRealTimeClock() throws {
        let machine = try bootMaster { machine in
            machine.rtc.setTime(year: 87, month: 3, dayOfMonth: 14, dayOfWeek: 7,
                                hours: 15, minutes: 9, seconds: 26)
        }
        let screen = command(machine, "PRINT TIME$")
        #expect(screen.contains { $0.hasPrefix("Sat,14 Mar 1987.15:09:2") }, "\(screen)")
    }

    @Test func clockTicks() {
        var rtc = MC146818()
        rtc.setTime(year: 99, month: 12, dayOfMonth: 31, dayOfWeek: 6, hours: 23, minutes: 59, seconds: 59)
        for _ in 0...1_000_000 { rtc.update() }
        // Registers are BCD.
        func read(_ register: UInt8) -> UInt8 {
            rtc.setAddress(register)
            return rtc.read()
        }
        #expect([read(9), read(8), read(7), read(4), read(2), read(0)] == [0x00, 0x01, 0x01, 0x00, 0x00, 0x00])
    }

    @Test func cmosRAMRoundTrips() throws {
        let machine = try bootMaster()
        // *CONFIGURE MODE 3 sets CMOS location 10's low bits.
        command(machine, "*CONFIGURE MODE 3")
        #expect(machine.rtc.ram[10] & 7 == 3)
    }

    @Test func cataloguesADiscThroughThe1770() throws {
        let machine = try bootMaster(disc: "TestTimings.ssd")
        let screen = command(machine, "*CAT")
        #expect(screen.contains { $0.contains("TEST") }, "\(screen)")
    }

    @Test func restoredMasterRunsIdentically() throws {
        let original = try bootMaster(disc: "TestTimings.ssd")
        command(original, "*SHADOW")
        original.paste("*CAT\n")
        // Stop with the disc mid-read.
        original.run(seconds: 0.3)
        let snapshot = original.snapshot()

        func trace(_ machine: BBCMicro) -> (Int, Data) {
            var hasher = Hasher()
            for cycle in 0..<2_000_000 {
                if cycle % 1000 == 0 { machine.processKeyEvents() }
                machine.step()
                hasher.combine(machine.cpu.abus)
                hasher.combine(machine.cpu.dbus)
            }
            return (hasher.finalize(), machine.snapshot().ram)
        }
        let expected = trace(original)

        let encoded = try PropertyListEncoder().encode(SaveStateFile(try original.restoringFirst(snapshot)))
        let file = try PropertyListDecoder().decode(SaveStateFile.self, from: encoded)
        let copy = try file.makeMachine()
        let actual = trace(copy)
        #expect(actual.0 == expected.0)
        #expect(actual.1 == expected.1)
        #expect(copy.runUntilIdle())
        #expect(copy.screenText().contains { $0.contains("TEST") }, "\(copy.screenText())")
    }

    @Test func keypadIsMainKeysOnModelB() {
        let machine = BBCMicro(configuration: BeebROMs.configuration(for: .modelB))
        machine.setKey(.keypad7, down: true)
        #expect(machine.isKeyDown(.digit7))
        machine.setKey(.keypadPlus, down: true)
        #expect(!machine.isKeyDown(.keypadPlus))
        // Break's pseudo key code is in column 15 too.
        machine.setKey(.breakKey, down: true)
        #expect(machine.resetting)

        let master = BBCMicro(configuration: BeebROMs.configuration(for: .master128))
        master.setKey(.keypad7, down: true)
        #expect(master.isKeyDown(.keypad7) && !master.isKeyDown(.digit7))
    }

    @Test func keypadTypesOnMaster() throws {
        let machine = try bootMaster()
        machine.paste("PRINT ")
        #expect(machine.runUntilIdle())
        for key: BeebKey in [.keypad4, .keypadStar, .keypad6, .keypadReturn] {
            machine.setKey(key, down: true)
            machine.run(seconds: 0.1)
            machine.setKey(key, down: false)
            machine.run(seconds: 0.1)
        }
        #expect(machine.runUntilIdle())
        #expect(machine.screenText().contains("        24"), "\(machine.screenText())")
    }
}

extension BBCMicro {
    /// Rewinds to `snapshot` (for building a save state of that moment).
    fileprivate func restoringFirst(_ snapshot: Snapshot) throws -> BBCMicro {
        let machine = BBCMicro(configuration: configuration)
        try machine.restore(snapshot)
        return machine
    }
}
