// The Aries B32 (and B12) with the real ARIES-B32 1.00 ROM. The hardware
// model comes from what the ROM writes and what its own *XTEST expects
// (docs/development/expansion-hardware-notes.md); these check it against
// the manual's examples, figure for figure where it gives them.

import BeebCapture
import Foundation
import Testing
@testable import BeebCore
import BeebROMs

func ariesMachine(_ board: BBCMicro.MemoryBoard = .ariesB32, link: Bool = true, tv: TVOutput? = nil) -> BBCMicro {
    let m = BBCMicro(configuration: BeebROMs.configuration(for: .modelB,
                                                           expansions: .init(board: board, ariesStartUpLink: link)))
    m.tv = tv
    m.runUntilIdle()
    return m
}

/// The screen's lines, trimmed of trailing spaces.
func lines(_ m: BBCMicro) -> [String] {
    m.screenText().map { $0.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }
}

/// Presses Break and waits for the prompt.
func breakAndWait(_ m: BBCMicro) {
    m.pressBreak()
    m.run(seconds: 0.5)
    m.runUntilIdle()
}

/// Long-running tests: on in optimised builds, or when asked for.
let optimisedOrSlowTestsWanted: Bool = {
    #if DEBUG
    return ProcessInfo.processInfo.environment["MACBEEB_SLOW_TESTS"] != nil
    #else
    return true
    #endif
}()

struct AriesTests {
    @Test func bootsAndReportsAsTheManualSays() {
        let m = ariesMachine()
        #expect(lines(m).contains("BBC Computer 64K"))
        enter(m, "*XSTATUS X S")
        let screen = lines(m)
        for line in ["Current shadow RAM: 20K", "Workspace page: dynamic", "Start-up link: ON",
                     "Program/data RAM: 26112 bytes", "From: &1A00  To: &8000",
                     "10: ROM 16K DFS,NET", "11: ROM 16K BASIC", "14: RAM 12K Unused",
                     "15: ROM 16K ARIES-B32 1.00", "RWRITE OFF"] {
            #expect(screen.contains(line), "\(line) in \(screen)")
        }
        // The motherboard's sockets are 12, 9, 10, 11; the B32's ROM is 15.
        #expect(m.sidewaysSlots[15].header?.name == "ARIES-B32 1.00")
        #expect(m.sidewaysSlots[11].header?.title == "BASIC")
        #expect(m.isSidewaysRAM(13) && m.isSidewaysRAM(14) && !m.isSidewaysRAM(0))
    }

    /// The ROM's own full test of the hardware passes: every shadow state,
    /// both banks, write-through, and with the B12, its RAM. It runs for
    /// about 230 emulated seconds, so only in optimised builds (make test)
    /// or with MACBEEB_SLOW_TESTS set.
    @Test(.enabled(if: optimisedOrSlowTestsWanted), arguments: [BBCMicro.MemoryBoard.ariesB32, .ariesB32B12])
    func xtestPasses(board: BBCMicro.MemoryBoard) {
        let m = ariesMachine(board)
        m.paste("*XTEST\n")
        for _ in 0..<60 {
            m.run(seconds: 10)
            if lines(m).contains(where: { $0.contains("Press BREAK") || $0.contains("failed") || $0.contains("Should be") }) { break }
        }
        let screen = lines(m)
        #expect(screen.contains("Test OK. Press BREAK to continue:"), "\(screen)")
        for line in ["B32 hardware present", "Testing state A OK", "Testing state B OK", "Testing state C OK",
                     "RWRITE 13 OK", "RWRITE 14 OK", "RWRITE OFF OK", "B32 RAM: Pass  256 OK"] {
            #expect(screen.contains(line), "\(line) in \(screen)")
        }
        if board == .ariesB32B12 {
            #expect(screen.contains("Bank  0: 16K RAM present") && screen.contains("RWRITE  0 OK"), "\(screen)")
        } else {
            #expect(screen.contains("Bank  0: No RAM present"), "\(screen)")
        }
    }

    /// *XON 16 is pending until MODE; then MODE 1 takes 4K from programs
    /// (the manual's 22016 bytes, &1A00 to &7000).
    @Test func xon16IsPendingUntilMode() {
        let m = ariesMachine()
        enter(m, "*XON 16")
        enter(m, "*XSTATUS")
        #expect(lines(m).contains("Pending shadow RAM: 16K"), "\(lines(m))")
        #expect(!m.aries.shadowLow == false, "still 20K before MODE")
        enter(m, "MODE 7")
        enter(m, "*XSTATUS")
        #expect(lines(m).contains("Current shadow RAM: 16K"), "\(lines(m))")
        #expect(!m.aries.shadowLow && m.aries.shadowHigh)
        enter(m, "MODE 1")
        enter(m, "*XSTATUS")
        #expect(lines(m).contains("Program/data RAM: 22016 bytes") && lines(m).contains("From: &1A00  To: &7000"), "\(lines(m))")
        // And 16K of sideways RAM in bank 14 now.
        enter(m, "*XON")
        enter(m, "MODE 7")
        enter(m, "*XSTATUS X")
        #expect(lines(m).contains("Current shadow RAM: 20K"), "\(lines(m))")
    }

    /// *XOFF asks for Break, after which there's no shadow RAM: MODE 1
    /// leaves the manual's 5888 bytes (&1900 to &3000). *XON brings it back.
    @Test func xoffAndXonWithBreak() {
        let m = ariesMachine()
        // It waits for Break, not at the prompt.
        enter(m, "*XOFF", maxSeconds: 1)
        #expect(lines(m).contains("B32: Press BREAK to continue:"), "\(lines(m))")
        breakAndWait(m)
        enter(m, "MODE 1")
        enter(m, "*XSTATUS")
        #expect(lines(m).contains("Program/data RAM:  5888 bytes") && lines(m).contains("From: &1900  To: &3000"), "\(lines(m))")
        enter(m, "*XON", maxSeconds: 1)
        #expect(lines(m).contains("B32: Press BREAK to continue:"))
        breakAndWait(m)
        enter(m, "MODE 1")
        enter(m, "*XSTATUS")
        #expect(lines(m).contains("Program/data RAM: 26112 bytes") && lines(m).contains("From: &1A00  To: &8000"), "\(lines(m))")
    }

    /// *XOFF 2: no Break, pending until MODE, workspace kept (the manual's
    /// 25088 bytes, &1A00 to &7C00 in MODE 7).
    @Test func xoff2KeepsWorkspace() {
        let m = ariesMachine()
        enter(m, "*XOFF 2")
        enter(m, "*XSTATUS")
        #expect(lines(m).contains("Pending shadow RAM:  0K"), "\(lines(m))")
        enter(m, "MODE 7")
        enter(m, "*XSTATUS")
        #expect(lines(m).contains("Current shadow RAM:  0K") && lines(m).contains("Program/data RAM: 25088 bytes")
                && lines(m).contains("From: &1A00  To: &7C00"), "\(lines(m))")
    }

    /// *RWRITE 14 sends writes to bank 14 while BASIC (bank 11) is still
    /// read; *RWRITE OFF protects it again.
    @Test func rwriteSeparatesReadingAndWriting() {
        let m = ariesMachine()
        let basicByte = m.peek(0x8100)
        enter(m, "*RWRITE 14")
        enter(m, "?&8100=&5A")
        enter(m, "PRINT ?&8100")
        #expect(m.debugRead(.sidewaysBank(14), 0x8100) == 0x5A)
        #expect(lines(m).contains { $0.trimmingCharacters(in: .whitespaces) == "\(basicByte)" }, "reads still BASIC: \(lines(m))")
        enter(m, "*RWRITE OFF")
        enter(m, "?&8101=&A5")
        #expect(m.debugRead(.sidewaysBank(14), 0x8101) != 0xA5)
        #expect(m.aries.ramsel == 15)
        // BASIC itself is ROM throughout.
        #expect(m.sidewaysBankContents(11) == BeebROMs.data(.basic2))
    }

    /// *RLOAD from disc into bank 14 (12K free with 20K of shadow), then
    /// Break: the ROM runs from the B32's RAM.
    @Test func rloadThenBreak() throws {
        let m = ariesMachine()
        m.insertDisc(try Disc.fromSSD(testResource("expansions/hello-rom.ssd")))
        enter(m, "*RLOAD HELLO 14")
        #expect(m.sidewaysSlots[14].header?.name == "MacBeeb Hello 1.00", "\(lines(m))")
        breakAndWait(m)
        enter(m, "*HELLO")
        #expect(lines(m).contains("Hello from sideways RAM bank 14"), "\(lines(m))")
        enter(m, "*XSTATUS S")
        #expect(lines(m).contains { $0.hasPrefix("14: RAM") && $0.contains("MacBeeb Hello 1.00") }, "\(lines(m))")
    }

    /// A 16K image needs 16K of sideways RAM: with 20K of shadow RAM bank 14
    /// has 12K ("Not enough RAM"); after *XON 16 and MODE it fits, and then
    /// *XON 20 can't take the top 4K back ("RAM in use"), as the manual
    /// says.
    @Test func sixteenKImagesNeedXon16() throws {
        var side = try DFSDisc(side: testResource("expansions/hello-rom.ssd"))
        var big = try testResource("expansions/hello.rom")
        big += [UInt8](repeating: 0xFF, count: 0x4000 - big.count)
        try side.save(name: "BIG", loadAddress: 0x8000, executionAddress: 0x8000, contents: big)
        let m = ariesMachine()
        m.insertDisc(try Disc.fromSSD(DFSDisc.image(sides: [side])))
        enter(m, "*RLOAD BIG 14")
        #expect(lines(m).contains("B32: Not enough RAM"), "\(lines(m))")
        enter(m, "*XON 16")
        enter(m, "MODE 7")
        enter(m, "*RLOAD BIG 14")
        #expect(m.sidewaysSlots[14].header?.name == "MacBeeb Hello 1.00", "\(lines(m))")
        enter(m, "*XON 20")
        #expect(lines(m).contains("B32: RAM in use"), "\(lines(m))")
    }

    /// The Watford guide's example runs with the B32's 20K of shadow RAM.
    @Test func shadowExampleRuns() throws {
        let program = String(decoding: try testResource("expansions/shadow.bas"), as: UTF8.self)
        let m = ariesMachine()
        for line in program.split(separator: "\n") { enter(m, String(line)) }
        enter(m, "RUN", maxSeconds: 60)
        #expect(lines(m).contains("HIMEM is &8000"), "\(lines(m))")
        #expect(lines(m).contains { $0.hasPrefix("Free for programs: ") }, "\(lines(m))")
    }

    /// Shadow RAM at work: MODE 1, a 16K array, the picture untouched.
    @Test func shadowRAMKeepsProgramAndScreenApart() {
        let tv = TVOutput()
        let m = ariesMachine(tv: tv)
        enter(m, "MODE 1")
        enter(m, "PRINT ~HIMEM")
        #expect(lines(m).contains { $0.trimmingCharacters(in: .whitespaces) == "8000" }, "\(lines(m))")
        enter(m, "DIM A%(4000):FOR I%=0 TO 4000:A%(I%)=I%:NEXT", maxSeconds: 30)
        enter(m, "GCOL 0,2:MOVE 0,0:DRAW 1279,1023:VDU 28,0,2,39,0")
        m.run(seconds: 0.1)
        let below = TVOutput.width * 100
        let before = StockBaselineTests.hash(Array(tv.lastFrame[below...]))
        enter(m, "FOR I%=0 TO 4000:A%(I%)=-I%:NEXT:PRINT A%(4000)", maxSeconds: 30)
        #expect(lines(m).contains { $0.contains("-4000") }, "\(lines(m))")
        m.run(seconds: 0.1)
        #expect(StockBaselineTests.hash(Array(tv.lastFrame[below...])) == before)
    }

    /// The physical pool: &4000-&7FFF is bank 13, &3000-&3FFF the top 4K of
    /// bank 14; the switches choose which pieces are shadowed.
    @Test func poolLayout() {
        let m = BBCMicro(configuration: BeebROMs.configuration(for: .modelB, expansions: .init(board: .ariesB32)))
        func set(_ address: UInt16) { m.ariesControl(address, 0) }
        set(0xFE3F); set(0xFE3A); set(0xFE36)
        for (address, value) in [(UInt16(0x3000), UInt8(1)), (0x4000, 2), (0x7FFF, 3)] { m.poke(address, value) }
        #expect(m.debugRead(.sidewaysBank(14), 0xB000) == 1)
        #expect(m.debugRead(.sidewaysBank(13), 0x8000) == 2)
        #expect(m.debugRead(.sidewaysBank(13), 0xBFFF) == 3)
        #expect(m.debugRead(.mainRAM, 0x3000) == 0 && m.debugRead(.mainRAM, 0x4000) == 0)
        // 16K: &3000 is main RAM again.
        set(0xFE3C)
        m.poke(0x3000, 9)
        #expect(m.debugRead(.mainRAM, 0x3000) == 9 && m.debugRead(.sidewaysBank(14), 0xB000) == 1)
        // &7000 off: main.
        set(0xFE34)
        m.poke(0x7000, 7)
        #expect(m.debugRead(.mainRAM, 0x7000) == 7)
        // Shadow off: all main.
        set(0xFE3E)
        #expect(m.peek(0x4000) == 0)
        // &FE38 sets shadow as the start-up link does.
        set(0xFE38)
        #expect(m.aries.shadow)
    }

    @Test func withoutTheStartUpLink() {
        let m = ariesMachine(link: false)
        enter(m, "*XSTATUS X")
        #expect(lines(m).contains("Start-up link: OFF"), "\(lines(m))")
    }

    /// The B12: its RAM is bank 0, the ROMs are in its sockets 11 and 12,
    /// and *RWRITE 0 writes through to bank 0.
    @Test func b12() {
        let m = ariesMachine(.ariesB32B12)
        enter(m, "*XSTATUS S")
        let screen = lines(m)
        #expect(screen.contains("11: ROM 16K DFS,NET") && screen.contains("12: ROM 16K BASIC"), "\(screen)")
        #expect(screen.contains { $0.hasPrefix(" 0: RAM 16K") || $0.hasPrefix("0: RAM 16K") }, "\(screen)")
        enter(m, "*RWRITE 0")
        enter(m, "?&9000=&3C")
        #expect(m.debugRead(.sidewaysBank(0), 0x9000) == 0x3C)
        enter(m, "*RWRITE OFF")
        enter(m, "?&9001=&C3")
        #expect(m.debugRead(.sidewaysBank(0), 0x9001) != 0xC3)
        #expect(m.sidewaysSlots[0].owner == "Aries B12 RAM (0L and 0H)")
        #expect(m.sidewaysSlots[5].owner == "Aries B12 socket")
    }

    /// Ctrl-Break with the link fitted: back to 20K, as the manual says.
    @Test func ctrlBreakRestoresTwentyK() {
        let m = ariesMachine()
        enter(m, "*XON 16")
        enter(m, "MODE 7")
        ctrlBreak(m)
        enter(m, "*XSTATUS X")
        #expect(lines(m).contains("Current shadow RAM: 20K"), "\(lines(m))")
    }

    @Test func saveStateKeepsTheLatches() throws {
        let m = ariesMachine()
        enter(m, "*XON 16")
        enter(m, "MODE 7")
        enter(m, "*RWRITE 14")
        let restored = try SaveStateFile(data: try SaveStateFile(m).data()).makeMachine()
        #expect(restored.aries == m.aries)
        restored.paste("*XSTATUS X S\n")
        restored.runUntilIdle()
        #expect(lines(restored).contains("Current shadow RAM: 16K") && lines(restored).contains("RWRITE 14"), "\(lines(restored))")
    }

    @Test func firmwareIsKnown() {
        let rom = BeebROMs.data(.ariesB32100)
        #expect(Firmware.identify(rom, for: .ariesB32) == .known(Firmware.standard(for: .ariesB32)!))
        #expect(Firmware.identify(rom, for: .ariesB32B12) == .known(Firmware.standard(for: .ariesB32)!))
        if case .anotherBoard = Firmware.identify(rom, for: .watford32K) {} else { Issue.record("the Aries ROM isn't Watford's") }
    }
}
