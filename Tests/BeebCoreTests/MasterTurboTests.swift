// The Master Turbo: a Master 128 with the 65C102 Co-Processor, a 4MHz 65C02
// on the internal Tube.

import Testing
@testable import BeebCore
import BeebROMs

struct MasterTurboTests {
    func turbo() -> BBCMicro {
        BBCMicro(configuration: BeebROMs.configuration(for: .master128, secondProcessor: true, coprocessor: .masterTurbo))
    }

    func screen(_ m: BBCMicro) -> [String] { m.screenText().filter { !$0.isEmpty } }

    @Test func boots() {
        let m = turbo()
        #expect(m.secondProcessor != nil && m.parasiteMHz == 4)
        #expect(m.runUntilIdle(maxSeconds: 5))
        #expect(screen(m).first == "Acorn TUBE 65C102 Co-Processor", "\(screen(m))")
        // BASIC runs in the parasite.
        m.paste("PRINT PAGE,HIMEM\n")
        #expect(m.runUntilIdle(maxSeconds: 5))
        #expect(screen(m).contains { $0.hasSuffix("2048     32768") }, "\(screen(m))")
    }

    @Test func onlyFitsTheMaster128() {
        #expect(BBCMicro.Coprocessor.masterTurbo.fits(.master128))
        for model in [BBCMicro.Model.modelA, .modelB, .bPlus, .masterCompact] {
            #expect(!BBCMicro.Coprocessor.masterTurbo.fits(model))
            #expect(BBCMicro(configuration: BeebROMs.configuration(for: model, secondProcessor: true,
                                                                    coprocessor: .masterTurbo)).secondProcessor == nil)
        }
    }

    /// The host sees it on the internal Tube (ITU set), the external box
    /// on the external one.
    @Test func isOnTheInternalTube() {
        let m = turbo()
        m.run(seconds: 1)
        m.acccon |= 0x10
        #expect(m.tubeAccessible)
        m.acccon &= ~0x10
        #expect(!m.tubeAccessible)
        let external = BBCMicro(configuration: BeebROMs.configuration(for: .master128, secondProcessor: true))
        external.run(seconds: 1)
        #expect(external.tubeAccessible && external.acccon & 0x10 == 0)
    }

    /// Two parasite cycles each 2MHz host cycle, against the 6502 Second
    /// Processor's three every two.
    @Test func runsAt4MHz() {
        func parasiteCycles(_ m: BBCMicro) -> Int {
            m.run(seconds: 1)
            m.debugger.startProfiling()
            m.run(cycles: 20_000)
            m.debugger.stopProfiling()
            return m.debugger.profileReport(.parasite)?.totalCycles ?? 0
        }
        let fast = parasiteCycles(turbo())
        let slow = parasiteCycles(BBCMicro(configuration: BeebROMs.configuration(for: .master128, secondProcessor: true)))
        #expect(abs(fast - 40_000) < 20 && abs(slow - 30_000) < 20, "\(fast) \(slow)")
    }

    @Test func snapshotsOnlyIntoATurbo() throws {
        let m = turbo()
        m.run(seconds: 1)
        let copy = turbo()
        try copy.restore(m.snapshot())
        m.run(seconds: 0.5)
        copy.run(seconds: 0.5)
        #expect(copy.secondProcessor?.cpu.pc == m.secondProcessor?.cpu.pc)
        let external = BBCMicro(configuration: BeebROMs.configuration(for: .master128, secondProcessor: true))
        #expect(throws: BBCMicro.RestoreError.self) { try external.restore(m.snapshot()) }
    }
}
