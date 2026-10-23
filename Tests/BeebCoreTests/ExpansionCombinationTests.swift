// A board in the 6502's socket and a sideways RAM module in a ROM socket,
// together: the Watford board or the Aries B32 with a 16K or 32K module.
// The B12 takes all four ROM sockets, so it can't have one.

import Foundation
import Testing
@testable import BeebCore
import BeebROMs

struct ExpansionCombinationTests {
    /// The Watford ROM takes whichever of the two free sockets the module
    /// doesn't, and both work: shadow RAM, and RAM written when selected.
    @Test(arguments: [12, 13])
    func watfordWithAModule(socket: Int) {
        let m = sidewaysRAMMachine(.ram16, board: .watford32K, socket: socket)
        m.runUntilIdle()
        let romBank = socket == 13 ? 12 : 13
        #expect(m.configuration.fittedExpansions.controllerROMBank == romBank)
        #expect(m.sidewaysRAMBanks == [socket])
        #expect(m.sidewaysSlots[romBank].header?.title.contains("Shadow") == true, "\(String(describing: m.sidewaysSlots[romBank].header))")
        cpuWrite(m, bank: socket, 0x8000, 0x5A)
        #expect(m.debugRead(.sidewaysBank(socket), 0x8000) == 0x5A)
        enter(m, "*HELP RAMSTATUS")
        #expect(lines(m).contains { $0.contains("Shadow") }, "\(lines(m))")
        enter(m, "MODE 1:*FX34,1")
        enter(m, "PRINT ~HIMEM")
        #expect(lines(m).contains { $0.trimmingCharacters(in: .whitespaces) == "8000" }, "\(lines(m))")
    }

    /// With the B32, the module's socket answers to its renumbered bank,
    /// and writes reach it only while *RWRITE EXTERNAL passes them on.
    @Test func ariesB32WithAModule() {
        let m = BBCMicro(configuration: BeebROMs.configuration(
            for: .modelB, expansions: .init(board: .ariesB32, sidewaysRAM: .ram16, sidewaysRAMSocket: 12)))
        m.runUntilIdle()
        #expect([12, 13, 14].allSatisfy(m.isSidewaysRAM) && !m.isSidewaysRAM(9))
        #expect(m.sidewaysSlots[15].header?.name == "ARIES-B32 1.00")
        #expect(m.sidewaysSlots[11].header?.title == "BASIC")
        // Write-protected after Break (RWRITE OFF).
        cpuWrite(m, bank: 12, 0x8000, 0x5A)
        #expect(m.debugRead(.sidewaysBank(12), 0x8000) != 0x5A)
        enter(m, "*RWRITE EXTERNAL")
        cpuWrite(m, bank: 12, 0x8000, 0x5A)
        #expect(m.debugRead(.sidewaysBank(12), 0x8000) == 0x5A)
        // Writes on the bus only reach the module while it's selected.
        cpuWrite(m, bank: 11, 0x8001, 0xA5)
        #expect(m.debugRead(.sidewaysBank(12), 0x8001) != 0xA5)
        #expect(m.sidewaysBankContents(11) == BeebROMs.data(.basic2))
        enter(m, "*RWRITE OFF")
        cpuWrite(m, bank: 12, 0x8002, 0x77)
        #expect(m.debugRead(.sidewaysBank(12), 0x8002) != 0x77)
        // The shadow RAM still works.
        enter(m, "*XSTATUS X")
        #expect(lines(m).contains("Current shadow RAM: 20K"), "\(lines(m))")
    }

    /// A 32K module in the next socket (bank 9 with the B32): the second
    /// bank is assumed to move with the first, four below.
    @Test func ariesB32WithA32KModule() {
        let e = BBCMicro.Expansions(board: .ariesB32, sidewaysRAM: .ram32, sidewaysRAMSocket: 13)
        #expect(e.problem == nil)
        #expect(e.moduleBanks == [9, 5])
        #expect(e.secondBankIsAssumed)
        let m = BBCMicro(configuration: BeebROMs.configuration(for: .modelB, expansions: e))
        m.runUntilIdle()
        #expect(m.sidewaysSlots[10].header?.title.contains("DFS") == true)
        enter(m, "*RWRITE EXTERNAL")
        cpuWrite(m, bank: 5, 0x9000, 0x42)
        #expect(m.debugRead(.sidewaysBank(5), 0x9000) == 0x42)
    }

    @Test func theB12LeavesNoSocketForAModule() {
        #expect(!BBCMicro.MemoryBoard.ariesB32B12.takesSidewaysModule)
        #expect(BBCMicro.Expansions(board: .ariesB32B12, sidewaysRAM: .ram16).problem != nil)
        #expect(BBCMicro.Expansions(board: .ariesB32B12).sidewaysRAMBanks == [0])
        #expect(BBCMicro.Expansions(board: .watford32K, sidewaysRAM: .ram32).problem == nil)
    }

    /// Configurations from before boards and modules were separate: a
    /// sideways RAM "board" is no board and that module.
    @Test(arguments: [("sidewaysRAM16", BBCMicro.SidewaysModule.ram16), ("sidewaysRAM32", .ram32)])
    func olderSidewaysRAMBoardsDecode(name: String, module: BBCMicro.SidewaysModule) throws {
        let json = #"{"board":"\#(name)","sidewaysRAMSocket":12,"secondBankBelow":8,"ariesStartUpLink":true}"#
        let e = try JSONDecoder().decode(BBCMicro.Expansions.self, from: Data(json.utf8))
        #expect(e.board == .none)
        #expect(e.sidewaysRAM == module)
        #expect(e.sidewaysRAMSocket == 12 && e.secondBankBelow == 8)
        let other = try JSONDecoder().decode(BBCMicro.Expansions.self, from: Data(#"{"board":"watford32K"}"#.utf8))
        #expect(other.board == .watford32K && other.sidewaysRAM == .none)
    }

    @Test func saveStateKeepsBoth() throws {
        let m = sidewaysRAMMachine(.ram32, board: .watford32K, socket: 12)
        try m.loadSidewaysImage(try testResource("expansions/hello.rom"), bank: 8)
        let restored = try SaveStateFile(data: try SaveStateFile(m).data()).makeMachine()
        #expect(restored.configuration.expansions == m.configuration.expansions)
        #expect(restored.sidewaysSlots[8].header?.title == "MacBeeb Hello")
    }
}
