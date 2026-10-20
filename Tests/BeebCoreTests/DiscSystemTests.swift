// Running software from discs through DFS and the 8271.

import Foundation
import Testing
@testable import BeebCore
import BeebROMs

/// A Model B with DFS 1.2 and BASIC 2, with `disc` in drive 0.
func bootModelBWithDFS(_ discName: String? = nil, shiftBreak: Bool = false) throws -> BBCMicro {
    let machine = BBCMicro(os: BeebROMs.data(.os12),
                           sidewaysROMs: [15: BeebROMs.data(.basic2), 14: BeebROMs.data(.dfs12)])
    if let discName {
        machine.insertDisc(try Disc.fromSSD(testResource("discs/\(discName)")))
    }
    if shiftBreak {
        // Hold Shift through power on to boot the disc.
        machine.setKey(.shift, down: true)
        machine.run(seconds: 1)
        machine.setKey(.shift, down: false)
    }
    machine.runUntilIdle()
    return machine
}

struct DiscSystemTests {
    @Test func bootsWithDFS() throws {
        let machine = try bootModelBWithDFS()
        let screen = machine.teletextScreenText() ?? []
        #expect(screen.contains("Acorn DFS"), "\(screen)")
        // DFS moves PAGE up.
        #expect(machine.peek(0x18) == 0x19)
    }

    @Test func catalogue() throws {
        let machine = try bootModelBWithDFS("TestTimings.ssd")
        machine.paste("*CAT\n")
        #expect(machine.runUntilIdle(maxSeconds: 10))
        let screen = machine.teletextScreenText() ?? []
        #expect(screen.contains { $0.contains("TEST") }, "\(screen)")
    }

    /// The IRQ timing test, this time CHAINed from disc as jsbeeb runs it.
    @Test func chainFromDisc() throws {
        let machine = try bootModelBWithDFS("TestTimings.ssd")
        machine.paste("CHAIN \"TEST\"\n")
        #expect(machine.runUntilIdle(maxSeconds: 60))
        let count = Int(machine.peek(0x71)) + 1
        #expect(count == 26)
        // First and a later entry from jsbeeb's expected table.
        #expect(Int(machine.peek(0x4300)) << 8 | Int(machine.peek(0x4000)) == 0x4436)
        #expect(Int(machine.peek(0x4300 + 22)) << 8 | Int(machine.peek(0x4000 + 22)) == 0x458A)
    }

    /// Shift-Break runs !BOOT (*EXEC), which CHAINs the timing tests.
    @Test func shiftBreakBoot() throws {
        let machine = try bootModelBWithDFS("beeb_6502_timing_tests.ssd", shiftBreak: true)
        #expect(machine.runUntilIdle(maxSeconds: 60))
        let screen = (machine.teletextScreenText() ?? []).joined(separator: "\n")
        #expect(screen.contains("Total: 81"), "\(screen)")
    }

    @Test func saveAndLoad() throws {
        let machine = try bootModelBWithDFS("TestTimings.ssd")
        machine.paste("10PRINT \"SAVED OK\"\nSAVE \"NEW\"\nNEW\nLOAD \"NEW\"\nRUN\n")
        #expect(machine.runUntilIdle(maxSeconds: 30))
        let screen = machine.teletextScreenText() ?? []
        #expect(screen.contains("SAVED OK"), "\(screen)")
        // And it's on the disc.
        let disc = try #require(machine.drives[0].disc)
        let catalogue = try DFSDisc(side: disc.toSSDOrDSD())
        #expect(catalogue.file(named: "NEW") != nil)
    }
}
