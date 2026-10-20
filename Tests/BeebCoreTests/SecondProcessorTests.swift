// The 6502 Second Processor across the Tube, on every model.

import Foundation
import Testing
@testable import BeebCore
import BeebROMs

struct SecondProcessorTests {
    func boot(_ model: BBCMicro.Model, secondProcessor: Bool = true) -> BBCMicro {
        let machine = BBCMicro(configuration: BeebROMs.configuration(for: model, secondProcessor: secondProcessor))
        #expect(machine.runUntilIdle())
        return machine
    }

    @Test(arguments: BBCMicro.Model.allCases)
    func basicRunsInTheSecondProcessor(_ model: BBCMicro.Model) throws {
        let machine = boot(model)
        #expect(machine.screenText().contains("Acorn TUBE 6502 64K"), "\(machine.screenText())")
        let screen = command(machine, "PRINT ~PAGE,~HIMEM,6*7")
        #expect(screen.contains("       800      8000        42"), "\(screen)")
        // BASIC's copy of itself in the parasite, and its PAGE.
        let p = try #require(machine.secondProcessor)
        #expect(!p.bootMode)
        #expect(p.peek(0x8000) == BeebROMs.data(.basic2)[0] || model == .master128)
    }

    @Test func runsAtThreeMegahertz() {
        func centiseconds(secondProcessor: Bool) -> Int {
            let machine = boot(.modelB, secondProcessor: secondProcessor)
            let screen = command(machine, "T%=TIME:FOR I%=1 TO 3000:NEXT:PRINT TIME-T%", maxSeconds: 30)
            return screen.reversed().compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }.first ?? 0
        }
        let host = Double(centiseconds(secondProcessor: false))
        let parasite = Double(centiseconds(secondProcessor: true))
        // 3MHz against 2MHz, and the parasite isn't interrupted or slowed
        // by the host's 1MHz accesses.
        #expect(host / parasite > 1.4 && host / parasite < 1.8, "host \(host)cs, parasite \(parasite)cs")
    }

    @Test func breakRebootsTheSecondProcessor() throws {
        let machine = boot(.modelB)
        command(machine, "10 PRINT \"HELLO\"")
        machine.pressBreak()
        #expect(machine.runUntilIdle())
        #expect(machine.screenText().contains("Acorn TUBE 6502 64K"))
        // The program survives in the parasite. (OLD returns to the
        // prompt, so LIST needs its own line.)
        command(machine, "OLD")
        let screen = command(machine, "LIST")
        #expect(screen.contains("   10 PRINT \"HELLO\""), "\(screen)")
    }

    @Test func masterNeedsTheExternalTubeSelected() {
        let machine = boot(.master128)
        #expect(machine.tubeAccessible)
        machine.acccon |= 0x10
        #expect(!machine.tubeAccessible)
    }

    @Test func restoredMachineRunsIdentically() throws {
        let original = boot(.modelB)
        original.paste("10 A%=A%+1:GOTO 10\nRUN\n")
        original.run(seconds: 0.5)
        let snapshot = original.snapshot()
        let data = try JSONEncoder().encode(snapshot)
        let copy = BBCMicro(configuration: original.configuration)
        try copy.restore(try JSONDecoder().decode(BBCMicro.Snapshot.self, from: data))
        for machine in [original, copy] {
            machine.run(seconds: 1)
        }
        let a = try #require(original.secondProcessor), b = try #require(copy.secondProcessor)
        #expect((0..<0x10000).allSatisfy { a.peek(UInt16($0)) == b.peek(UInt16($0)) })
        #expect(a.cpu.pc == b.cpu.pc && original.cpu.pc == copy.cpu.pc)
        #expect(original.tube == copy.tube)
    }

    @Test func restoreNeedsTheSameHardware() {
        let with = boot(.modelB)
        let without = BBCMicro(configuration: BeebROMs.configuration(for: .modelB))
        #expect(throws: BBCMicro.RestoreError.self) { try without.restore(with.snapshot()) }
    }
}
