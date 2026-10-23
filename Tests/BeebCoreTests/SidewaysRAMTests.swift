// Sideways RAM boards on the Model B: 16K and 32K modules in the
// BeebMaster module's wiring (a socket bank, and a second bank four or
// eight below it), written whenever selected.

import Foundation
import Testing
@testable import BeebCore
import BeebROMs

func sidewaysRAMMachine(_ board: BBCMicro.MemoryBoard, socket: Int = 13, below: Int = 4,
                        discInterface: BBCMicro.DiscInterface = .intel8271,
                        images: [Int: [UInt8]] = [:]) -> BBCMicro {
    let expansions = BBCMicro.Expansions(board: board, sidewaysRAMSocket: socket, secondBankBelow: below)
    return BBCMicro(configuration: BeebROMs.configuration(for: .modelB, discInterface: discInterface,
                                                          expansions: expansions, sidewaysImages: images))
}

/// Ctrl-Break: a hard reset, so the MOS scans the ROMs afresh.
func ctrlBreak(_ m: BBCMicro) {
    m.setKey(.ctrl, down: true)
    m.setKey(.breakKey, down: true)
    m.run(seconds: 0.1)
    m.setKey(.breakKey, down: false)
    m.run(seconds: 0.5)
    m.setKey(.ctrl, down: false)
    m.runUntilIdle()
}

/// Writes through the CPU, as code does: select the bank in ROMSEL, store.
func cpuWrite(_ m: BBCMicro, bank: Int, _ address: UInt16, _ value: UInt8) {
    let saved = m.romsel
    m.romsel = UInt8(bank)
    m.updatePaging()
    m.poke(address, value)
    m.romsel = saved
    m.updatePaging()
}

func cpuRead(_ m: BBCMicro, bank: Int, _ address: UInt16) -> UInt8 {
    let saved = m.romsel
    m.romsel = UInt8(bank)
    m.updatePaging()
    defer {
        m.romsel = saved
        m.updatePaging()
    }
    return m.peek(address)
}

struct SidewaysRAMTests {
    @Test func stockModelBHasNoSidewaysRAM() {
        let m = BBCMicro(configuration: BeebROMs.configuration(for: .modelB))
        #expect(m.sidewaysSlots.filter { $0.kind == .ram }.isEmpty)
        #expect(m.configuration.expansions == .none)
    }

    @Test func sixteenKIsOneBankInItsSocket() {
        let m = sidewaysRAMMachine(.sidewaysRAM16, socket: 12)
        #expect(m.sidewaysRAMBanks == [12])
        let slots = m.sidewaysSlots
        #expect(slots[12].kind == .ram && slots[12].writePolicy == .whenSelected && slots[12].owner == "16K sideways RAM module")
        #expect(slots[13].kind == .empty && slots[14].kind == .rom && slots[15].kind == .rom)
    }

    @Test(arguments: [(13, 4, [13, 9]), (13, 8, [13, 5]), (12, 4, [12, 8]), (12, 8, [12, 4])])
    func thirtyTwoKFollowsTheWiring(socket: Int, below: Int, banks: [Int]) {
        let m = sidewaysRAMMachine(.sidewaysRAM32, socket: socket, below: below)
        #expect(m.sidewaysRAMBanks == Set(banks))
        #expect(m.configuration.expansions.sidewaysRAMBanks == banks)
    }

    /// Exactly &8000-&BFFF, distinct banks, nothing leaking into main RAM
    /// or a ROM, and the ROMs and empty sockets unwritable.
    @Test func banksAreSeparateAndWritableOnlyWhenRAM() {
        let m = sidewaysRAMMachine(.sidewaysRAM32)
        let mainBefore = (0..<0x8000).map { m.peekMainRAM(UInt16($0)) }
        for (bank, base) in [(13, UInt8(0x10)), (9, UInt8(0x90))] {
            for (i, offset) in [0x0000, 0x1FFF, 0x3FFF].enumerated() {
                cpuWrite(m, bank: bank, 0x8000 + UInt16(offset), base + UInt8(i))
            }
        }
        for (bank, base) in [(13, UInt8(0x10)), (9, UInt8(0x90))] {
            for (i, offset) in [0x0000, 0x1FFF, 0x3FFF].enumerated() {
                #expect(cpuRead(m, bank: bank, 0x8000 + UInt16(offset)) == base + UInt8(i), "bank \(bank) +\(offset)")
                #expect(m.debugRead(.sidewaysBank(bank), 0x8000 + offset) == base + UInt8(i))
            }
        }
        // The bank isn't seen above &BFFF (that's the OS) or below &8000.
        #expect(m.peek(0xC000) == BeebROMs.data(.os12)[0])
        #expect((0..<0x8000).map { m.peekMainRAM(UInt16($0)) } == mainBefore)
        // ROM: written, unchanged.
        let basic = BeebROMs.data(.basic2)
        cpuWrite(m, bank: 15, 0x8000, basic[0] ^ 0xFF)
        #expect(cpuRead(m, bank: 15, 0x8000) == basic[0])
        // An empty socket keeps nothing.
        cpuWrite(m, bank: 7, 0x8000, 0x42)
        #expect(m.sidewaysBankContents(7) == nil)
        #expect(m.debugRead(.sidewaysBank(7), 0x8000) == nil)
    }

    @Test func imagesLoadClearAndRefuseROM() throws {
        let m = sidewaysRAMMachine(.sidewaysRAM16)
        let rom = try testResource("expansions/hello.rom")
        try m.loadSidewaysImage(rom, bank: 13)
        #expect(m.sidewaysSlots[13].header?.name == "MacBeeb Hello 1.00")
        #expect(throws: BBCMicro.SidewaysImageError.notRAM(15)) { try m.loadSidewaysImage(rom, bank: 15) }
        #expect(throws: BBCMicro.SidewaysImageError.notRAM(12)) { try m.loadSidewaysImage(rom, bank: 12) }
        #expect(throws: BBCMicro.SidewaysImageError.tooBig(0x4001)) {
            try m.loadSidewaysImage([UInt8](repeating: 0, count: 0x4001), bank: 13)
        }
        try m.clearSidewaysBank(13)
        #expect(m.sidewaysSlots[13].header == nil)
        #expect(m.sidewaysBankContents(13) == [UInt8](repeating: 0, count: 0x4000))
    }

    /// A ROM put in the RAM at power on is found by the MOS, *HELP lists
    /// it, and its command runs from the RAM bank.
    @Test func romImageAtPowerOnRuns() throws {
        let rom = try testResource("expansions/hello.rom")
        let m = sidewaysRAMMachine(.sidewaysRAM16, images: [13: rom])
        #expect(m.runUntilIdle())
        m.paste("*HELP\n*HELLO\n")
        #expect(m.runUntilIdle())
        let screen = m.screenText()
        #expect(screen.contains("MacBeeb Hello 1.00"), "\(screen)")
        #expect(screen.contains("Hello from sideways RAM bank 13"), "\(screen)")
    }

    /// The BBC writing its own sideways RAM: BASIC with a little machine
    /// code that selects a bank in ROMSEL and stores, as loaders do.
    @Test func inGuestWritesFollowTheHardware() {
        let m = sidewaysRAMMachine(.sidewaysRAM32)
        #expect(m.runUntilIdle())
        m.paste("""
        10 DIM C% 60
        20 FOR P=0 TO 2 STEP 2:P%=C%
        30 [OPT P
        40 .poke LDA &F4:PHA:LDA &70:STA &F4:STA &FE30:LDY #0:LDA &73:STA (&71),Y:JMP back
        50 .peek LDA &F4:PHA:LDA &70:STA &F4:STA &FE30:LDY #0:LDA (&71),Y:STA &73
        60 .back PLA:STA &F4:STA &FE30:RTS
        70 ]:NEXT
        80 DEF PROCW(B,A,V):?&70=B:!&71=A:?&73=V:CALL poke:ENDPROC
        90 DEF FNR(B,A):?&70=B:!&71=A:CALL peek:=?&73
        100 F%=0
        110 FOR I=0 TO 2:A=&8000+(&1FFF*I):PROCW(13,A,I+1):PROCW(9,A,I+&81):NEXT
        120 FOR I=0 TO 2:A=&8000+(&1FFF*I):IF FNR(13,A)<>I+1 OR FNR(9,A)<>I+&81 F%=F%+1
        130 NEXT
        140 V=FNR(15,&8000):PROCW(15,&8000,V EOR 255):IF FNR(15,&8000)<>V F%=F%+1
        150 IF F%=0 PRINT "PASS" ELSE PRINT "FAIL ";F%
        RUN

        """)
        #expect(m.runUntilIdle(maxSeconds: 30))
        #expect(m.screenText().contains("PASS"), "\(m.screenText())")
        #expect(m.debugRead(.sidewaysBank(13), 0xBFFE) == 3)
        #expect(m.debugRead(.sidewaysBank(9), 0x8000) == 0x81)
    }

    /// Acorn's own loader: DFS 2.26's *SRLOAD (SRAM 1.05) puts a ROM image
    /// from disc into the module, and after Ctrl-Break it's a working ROM.
    @Test func srloadFromDiscThenCtrlBreak() throws {
        let m = sidewaysRAMMachine(.sidewaysRAM32, discInterface: .acorn1770)
        m.insertDisc(try Disc.fromSSD(testResource("expansions/hello-rom.ssd")))
        #expect(m.runUntilIdle())
        m.paste("*SRLOAD HELLO 8000 9\n")
        #expect(m.runUntilIdle(maxSeconds: 20))
        #expect(m.sidewaysSlots[9].header?.name == "MacBeeb Hello 1.00", "\(m.screenText())")
        ctrlBreak(m)
        m.paste("*HELLO\n")
        #expect(m.runUntilIdle())
        #expect(m.screenText().contains("Hello from sideways RAM bank 9"), "\(m.screenText())")
        // The guide sends people to *HELP SRAM for the other commands.
        m.paste("*HELP SRAM\n")
        #expect(m.runUntilIdle())
        let help = m.screenText().joined(separator: "\n")
        for command in ["SRLOAD", "SRSAVE", "SRWRITE", "SRREAD", "SRROM", "SRDATA"] {
            #expect(help.contains(command), "\(help)")
        }
    }

    /// Save states keep the RAM's contents and the board.
    @Test func saveStateKeepsTheBanks() throws {
        let m = sidewaysRAMMachine(.sidewaysRAM32)
        try m.loadSidewaysImage(try testResource("expansions/hello.rom"), bank: 9)
        let file = SaveStateFile(m)
        let restored = try SaveStateFile(data: try file.data()).makeMachine()
        #expect(restored.configuration.expansions.board == .sidewaysRAM32)
        #expect(restored.sidewaysBankContents(9) == m.sidewaysBankContents(9))
        #expect(restored.sidewaysSlots[9].header?.title == "MacBeeb Hello")
    }

    /// An older save state, with no expansions, is a stock Model B.
    @Test func olderConfigurationsAreStock() throws {
        let stock = BeebROMs.configuration(for: .modelB)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(stock)) as! [String: Any]
        json.removeValue(forKey: "expansions")
        let decoded = try JSONDecoder().decode(BBCMicro.Configuration.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.expansions == .none)
        #expect(decoded == stock)
    }

    @Test func problemsAreExplained() {
        #expect(BBCMicro.Expansions(board: .sidewaysRAM16, sidewaysRAMSocket: 14).problem != nil)
        #expect(BBCMicro.Expansions(board: .sidewaysRAM32, secondBankBelow: 3).problem != nil)
        #expect(BBCMicro.Expansions(board: .sidewaysRAM32).problem == nil)
    }
}
