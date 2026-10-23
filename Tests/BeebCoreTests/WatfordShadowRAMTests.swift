// The Watford Electronics 32K RAM board with its own ROM, Shadow RAM OS
// 2.40: the latch (writes to &FFFC, &FFFE, &FFFF), physically separate
// RAM, the video always reading main RAM, and the ROM's commands.

import BeebCapture
import Foundation
import Testing
@testable import BeebCore
import BeebROMs

func watfordMachine(tv: TVOutput? = nil) -> BBCMicro {
    let m = BBCMicro(configuration: BeebROMs.configuration(for: .modelB, expansions: .init(board: .watford32K)))
    m.tv = tv
    m.runUntilIdle()
    return m
}

/// Types a line and waits for the prompt.
func enter(_ m: BBCMicro, _ line: String, maxSeconds: Double = 30) {
    m.paste(line + "\n")
    m.runUntilIdle(maxSeconds: maxSeconds)
}

struct WatfordShadowRAMTests {
    /// The latch maps the board's RAM by the address written, at exactly
    /// &3000 and the whole 32K; the RAM is separate from main RAM.
    @Test func latchMapsPhysicalRAM() {
        let m = BBCMicro(configuration: BeebROMs.configuration(for: .modelB, expansions: .init(board: .watford32K)))
        // Fill main RAM through the CPU's view in BBC mode.
        #expect(m.watfordMapping == .bbc)
        for a: UInt16 in [0x0000, 0x2FFF, 0x3000, 0x7FFF] { m.poke(a, 0x11) }
        m.watfordControl(0xFFFF)
        #expect(m.watfordMapping == .upper)
        #expect(m.peek(0x2FFF) == 0x11)
        #expect(m.peek(0x3000) == 0x00 && m.peek(0x7FFF) == 0x00)
        for a: UInt16 in [0x3000, 0x7FFF] { m.poke(a, 0x22) }
        m.watfordControl(0xFFFC)
        #expect(m.watfordMapping == .all)
        #expect(m.peek(0x0000) == 0x00 && m.peek(0x2FFF) == 0x00)
        #expect(m.peek(0x3000) == 0x22 && m.peek(0x7FFF) == 0x22)
        m.poke(0x0000, 0x33)
        m.watfordControl(0xFFFE)
        #expect(m.watfordMapping == .bbc)
        #expect([0x0000, 0x2FFF, 0x3000, 0x7FFF].map { m.peek($0) } == [0x11, 0x11, 0x11, 0x11])
        // The board's 32K, physically.
        #expect(m.debugRead(.boardRAM, 0x0000) == 0x33)
        #expect(m.debugRead(.boardRAM, 0x3000) == 0x22)
        #expect(m.debugRead(.boardRAM, 0x7FFF) == 0x22)
        #expect(m.debugRead(.mainRAM, 0x3000) == 0x11)
        // &FFFD changes nothing that's known; it's counted.
        m.watfordControl(0xFFFD)
        #expect(m.watfordMapping == .bbc && m.watfordFFFDWrites == 1)
    }

    /// Only CPU writes to &FFFC-&FFFF move the latch: a peek or a host poke
    /// doesn't, and a stock Model B has no latch at all.
    @Test func onlyCPUWritesSwitch() {
        let m = BBCMicro(configuration: BeebROMs.configuration(for: .modelB, expansions: .init(board: .watford32K)))
        m.poke(0xFFFF, 0)
        _ = m.debugWrite(.cpu(.host), 0xFFFF, 0)
        _ = m.peek(0xFFFC)
        #expect(m.watfordMapping == .bbc)
        let stock = BBCMicro(configuration: BeebROMs.configuration(for: .modelB))
        stock.paste("?&FFFF=0\n")
        stock.runUntilIdle()
        #expect(stock.watfordMapping == .bbc && !stock.watfordFitted)
        #expect(stock.debugRead(.boardRAM, 0) == nil)
    }

    @Test func romIsFoundAndReportsItself() {
        let m = watfordMachine()
        enter(m, "*HELP")
        #expect(m.screenText().contains("Watford Electronics 32k Shadow RAM 2.40"), "\(m.screenText())")
        enter(m, "*HELP RAMSTATUS")
        let status = m.screenText()
        for line in ["RAM board active", "HIMEM at &8000"] {
            #expect(status.contains(line), "\(status)")
        }
        enter(m, "*HELP RAM")
        let commands = m.screenText().joined(separator: "\n")
        for command in ["RAMON", "RAMOFF", "BUFFERON", "SSAVE", "SLOAD", "RAMEDIT"] {
            #expect(commands.contains(command), "\(commands)")
        }
        #expect(m.sidewaysSlots[13].header?.title == "Shadow RAM OS")
        #expect(m.sidewaysSlots[13].owner == "Watford board's ROM, in a motherboard socket")
    }

    /// The point of it: in MODE 1 (a 20K screen) BASIC keeps HIMEM at
    /// &8000, a program's data above &3000 lives in the board's RAM, and the
    /// picture it draws stays in main RAM, undisturbed.
    @Test func programAndScreenStaySeparateInMode1() throws {
        let tv = TVOutput()
        let m = watfordMachine(tv: tv)
        enter(m, "MODE 1")
        enter(m, "PRINT ~HIMEM")
        #expect(m.screenText().contains { $0.trimmingCharacters(in: .whitespaces) == "8000" }, "\(m.screenText())")
        enter(m, "10 DIM A%(4000)")
        enter(m, "20 FOR I%=0 TO 4000:A%(I%)=I%*3:NEXT")
        enter(m, "30 GCOL 0,1:FOR X%=0 TO 1279 STEP 40:MOVE X%,0:DRAW 1279-X%,1023:NEXT")
        enter(m, "40 S%=0:FOR I%=0 TO 4000:S%=S%+A%(I%)-I%*3:NEXT")
        enter(m, "50 PRINT \"SUM \";S%")
        enter(m, "RUN", maxSeconds: 60)
        // (The text shares rows with the lines drawn: match within them.)
        #expect(m.screenText().contains { $0.hasPrefix("SUM 0 ") }, "\(m.screenText())")
        // The array (16K of it) is in the board's RAM above &3000.
        let boardUsed = (0x3000..<0x8000).filter { m.debugRead(.boardRAM, $0) != 0 }.count
        #expect(boardUsed > 15000)
        // The picture survives a burst of program activity in the board's
        // RAM: typing goes in a text window at the top, and below it the
        // lines drawn stay exactly as they were.
        enter(m, "VDU 28,0,2,39,0")
        m.run(seconds: 0.1)
        let below = TVOutput.width * 100
        let before = StockBaselineTests.hash(Array(tv.lastFrame[below...]))
        enter(m, "FOR I%=0 TO 4000:A%(I%)=-I%:NEXT", maxSeconds: 30)
        enter(m, "PRINT A%(4000)")
        #expect(m.screenText().contains { $0.contains("-4000") }, "\(m.screenText())")
        m.run(seconds: 0.1)
        #expect(StockBaselineTests.hash(Array(tv.lastFrame[below...])) == before)
        // Shadow RAM OS 2.40 never touches &FFFD.
        #expect(m.watfordFFFDWrites == 0)
    }

    /// OSBYTE 34 (*FX34) switches the data area for programs that want the
    /// other RAM; the screen in main RAM is untouched by data written to
    /// data area 1.
    @Test func osbyte34SelectsTheDataArea() {
        let m = watfordMachine()
        enter(m, "MODE 7")
        enter(m, "*FX34,1")
        enter(m, "?&7000=&5A")
        enter(m, "*FX34,0")
        enter(m, "?&7001=&A5")
        enter(m, "*FX34,1")
        #expect(m.debugRead(.boardRAM, 0x7000) == 0x5A)
        #expect(m.debugRead(.mainRAM, 0x7001) == 0xA5)
        #expect(m.debugRead(.mainRAM, 0x7000) != 0x5A)
    }

    /// *RAMOFF and *RAMON: off, MODE 1 has the usual HIMEM (&3000); on
    /// again (after Break), &8000.
    @Test func ramOffAndOn() {
        let m = watfordMachine()
        enter(m, "*RAMOFF")
        enter(m, "MODE 1")
        enter(m, "PRINT ~HIMEM")
        #expect(m.screenText().contains { $0.trimmingCharacters(in: .whitespaces) == "3000" }, "\(m.screenText())")
        enter(m, "*RAMON")
        m.pressBreak()
        m.run(seconds: 0.5)
        m.runUntilIdle()
        enter(m, "MODE 1")
        enter(m, "PRINT ~HIMEM")
        #expect(m.screenText().contains { $0.trimmingCharacters(in: .whitespaces) == "8000" }, "\(m.screenText())")
    }

    /// SAVE and LOAD of a program that runs past &3000, in MODE 1: the disc
    /// system reads and writes the board's RAM.
    @Test func longProgramSavesAndLoads() throws {
        let m = watfordMachine()
        m.insertDisc(try Disc.fromImage(BlankDisc.dfs80.image(title: "T"), format: .ssd))
        enter(m, "MODE 1")
        enter(m, "10 PRINT \"LOADED OK\"")
        var lines = ""
        for i in 0..<300 { lines += "\(100 + i) REM ABCDEFGHIJKLMNOPQRSTUVWXYZABCDEFGHIJKLMNOPQRSTUVWXYZ\n" }
        m.paste(lines)
        m.runUntilIdle(maxSeconds: 120)
        enter(m, "PRINT ~TOP")
        let top = m.screenText().last { !$0.isEmpty && !$0.hasPrefix(">") }?.trimmingCharacters(in: .whitespaces)
        #expect(top.flatMap { Int($0, radix: 16) }.map { $0 > 0x3000 } == true, "\(m.screenText())")
        enter(m, "SAVE \"PROG\"")
        enter(m, "NEW")
        enter(m, "GCOL 0,2:MOVE 0,0:DRAW 1279,1023")
        enter(m, "LOAD \"PROG\"")
        enter(m, "PRINT ~TOP")
        #expect(m.screenText().contains { $0.trimmingCharacters(in: .whitespaces) == top }, "\(m.screenText())")
        enter(m, "RUN")
        #expect(m.screenText().contains("LOADED OK"), "\(m.screenText())")
        #expect(m.watfordFFFDWrites == 0)
    }

    /// Break keeps the board's state, as the manual says. Ctrl-Break
    /// disables it ("On CTRL-BREAK the whole system is disabled and no
    /// workspace is claimed, which is usually necessary for games"), and
    /// *RAMON then Break brings it back.
    @Test func breakAndCtrlBreak() {
        let m = watfordMachine()
        enter(m, "10 PRINT \"STILL HERE\"")
        m.pressBreak()
        m.run(seconds: 0.5)
        m.runUntilIdle()
        enter(m, "OLD")
        enter(m, "RUN")
        #expect(m.screenText().contains("STILL HERE"), "\(m.screenText())")
        ctrlBreak(m)
        enter(m, "MODE 0")
        enter(m, "PRINT ~HIMEM,~PAGE")
        #expect(m.screenText().contains { $0.trimmingCharacters(in: .whitespaces) == "3000      1900" }, "\(m.screenText())")
        enter(m, "*RAMON")
        m.pressBreak()
        m.run(seconds: 0.5)
        m.runUntilIdle()
        enter(m, "MODE 0")
        enter(m, "PRINT ~HIMEM,~PAGE")
        #expect(m.screenText().contains { $0.trimmingCharacters(in: .whitespaces) == "8000      1A00" }, "\(m.screenText())")
    }

    /// The guide's example, Examples/shadow-ram/shadow.bas: out of memory
    /// on a stock Model B, fine with the board.
    @Test(arguments: [false, true]) func guideExample(withBoard: Bool) throws {
        let program = String(decoding: try testResource("expansions/shadow.bas"), as: UTF8.self)
        let m = withBoard ? watfordMachine()
            : BBCMicro(configuration: BeebROMs.configuration(for: .modelB))
        m.runUntilIdle()
        for line in program.split(separator: "\n") { enter(m, String(line)) }
        enter(m, "RUN", maxSeconds: 60)
        let screen = m.screenText()
        if withBoard {
            #expect(screen.contains("HIMEM is &8000"), "\(screen)")
            #expect(screen.contains { $0.hasPrefix("Free for programs: ") }, "\(screen)")
        } else {
            #expect(screen.contains("HIMEM is &3000") && screen.contains("DIM space at line 40"), "\(screen)")
        }
    }

    @Test func saveStateKeepsTheLatchAndRAM() throws {
        let m = watfordMachine()
        enter(m, "MODE 1")
        enter(m, "*FX34,1")
        enter(m, "?&4000=&77")
        let file = SaveStateFile(m)
        let restored = try SaveStateFile(data: try file.data()).makeMachine()
        #expect(restored.watfordMapping == m.watfordMapping)
        #expect(restored.debugRead(.boardRAM, 0x4000) == 0x77)
        #expect(restored.configuration.expansions.board == .watford32K)
        // And it carries on as before.
        restored.paste("PRINT ?&4000\n")
        restored.runUntilIdle()
        #expect(restored.screenText().contains { $0.trimmingCharacters(in: .whitespaces) == "119" }, "\(restored.screenText())")
    }

    @Test func firmwareIsKnownAndChecked() {
        let bundled = BeebROMs.data(.watford32KRAM240)
        #expect(Firmware.identify(bundled, for: .watford32K) == .known(Firmware.standard(for: .watford32K)!))
        #expect(Firmware.sha256(bundled) == "a2e7c05f809e62faf980096459165fa356cf7c253265131ec68a91bcd2f8bfcb")
        // A 16K dump with the 8K twice is the same ROM.
        #expect(Firmware.identify(bundled + bundled, for: .watford32K) == .known(Firmware.standard(for: .watford32K)!))
        #expect(Firmware.identify([UInt8](repeating: 0, count: 100), for: .watford32K) == .wrongSize(100, expected: 0x2000))
        if case .unknown = Firmware.identify([UInt8](repeating: 0xEA, count: 0x2000), for: .watford32K) {} else {
            Issue.record("an unknown 8K image")
        }
    }

    /// Without its ROM the board does nothing on its own: the machine is
    /// usable and says so, rather than pretending.
    @Test func withoutTheROMTheProblemIsReported() {
        var config = BeebROMs.configuration(for: .modelB, expansions: .init(board: .watford32K))
        config.sidewaysROMs[13] = nil
        #expect(config.expansionProblem != nil)
        let m = BBCMicro(configuration: config)
        m.runUntilIdle()
        enter(m, "MODE 1")
        enter(m, "PRINT ~HIMEM")
        #expect(m.screenText().contains { $0.trimmingCharacters(in: .whitespaces) == "3000" })
        #expect(BeebROMs.configuration(for: .modelB, expansions: .init(board: .watford32K)).expansionProblem == nil)
    }
}
