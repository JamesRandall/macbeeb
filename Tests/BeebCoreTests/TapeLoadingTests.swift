// Loading from cassette through the real OS: OS 1.20 and MOS 3.20.

import Foundation
import Testing
@testable import BeebCore
import BeebROMs

struct TapeLoadingTests {
    func machine(_ model: BBCMicro.Model) throws -> BBCMicro {
        let machine = BBCMicro(configuration: BeebROMs.configuration(for: model))
        machine.insertTape(try Tape(image: testResource("tapes/pugwash.uef")))
        #expect(machine.runUntilIdle())
        return machine
    }

    @Test(arguments: BBCMicro.Model.allCases.filter(\.hasCassette))
    func chainsAProgram(_ model: BBCMicro.Model) throws {
        let machine = try machine(model)
        var relaySwitches = 0
        machine.onCassetteMotor = { _ in relaySwitches += 1 }
        machine.paste("*TAPE\nCHAIN \"\"\n")
        machine.run(seconds: 6)
        let loading = machine.screenText()
        #expect(loading.contains("Searching"), "\(loading)")
        #expect(loading.contains("Loading"), "\(loading)")
        #expect(loading.contains("PUGWASH    00"), "\(loading)")
        machine.run(seconds: 34)
        let screen = machine.screenText()
        #expect(screen.contains { $0.contains("Pugwash Tune") }, "\(screen)")
        #expect(relaySwitches >= 2)
    }

    @Test func restoresMidLoad() throws {
        let original = try machine(.modelB)
        original.paste("*TAPE\nCHAIN \"\"\n")
        original.run(seconds: 5)
        #expect(original.serial.motorOn)
        let snapshot = original.snapshot()

        let copy = BBCMicro(configuration: BeebROMs.configuration(for: .modelB))
        try copy.restore(snapshot)
        #expect(copy.tape != nil)
        for machine in [original, copy] {
            machine.run(seconds: 35)
        }
        #expect(copy.snapshot().ram == original.snapshot().ram)
        #expect(copy.screenText().contains { $0.contains("Pugwash Tune") })
    }
}
