// The Z80 and the Master 512 start with their bundled system discs, and
// what power cycles do with them.

import Testing
@testable import BeebCore
import BeebHost
import BeebROMs

struct SystemDiscTests {
    func configuration(_ model: BBCMicro.Model, _ coprocessor: BBCMicro.Coprocessor) -> BBCMicro.Configuration {
        BeebROMs.configuration(for: model, secondProcessor: true, coprocessor: coprocessor)
    }

    @Test func eachNeedsOne() throws {
        #expect(BeebROMs.SystemDisc(for: .z80) == .cpm && BeebROMs.SystemDisc(for: .master512) == .dosPlus)
        #expect(BeebROMs.SystemDisc(for: .mos6502) == nil && BeebROMs.SystemDisc(for: .arm) == nil)
        for disc in BeebROMs.SystemDisc.allCases {
            _ = try Disc.fromImage(disc.data, format: disc.format)
        }
        #expect(configuration(.modelB, .arm).startupDisc == nil)
        #expect(BeebROMs.configuration(for: .modelB).startupDisc == nil)
        // No Tube, no co-processor, no disc.
        #expect(BeebROMs.configuration(for: .masterCompact, secondProcessor: true, coprocessor: .z80).startupDisc == nil)
    }

    @Test func notSavedWithTheConfiguration() throws {
        let m = BBCMicro(configuration: configuration(.modelB, .z80))
        let file = SaveStateFile(m)
        let restored = try SaveStateFile(data: file.data()).makeMachine()
        #expect(restored.configuration.startupDisc == nil && restored.startupDisc == nil)
        // The disc came back with the state.
        #expect(restored.drives[0].disc != nil)
    }

    @Test func powerCycles() throws {
        let session = HeadlessSession { BBCMicro(configuration: self.configuration(.master128, .z80)) }
        let cpm = try #require(session.machine.startupDisc)
        #expect(session.machine.drives[0].disc === cpm)

        // The same machine keeps the same disc (and anything written to it).
        session.powerCycle()
        #expect(session.machine.drives[0].disc === cpm)

        // A different co-processor gets its own.
        session.powerCycle(configuration: configuration(.master128, .master512))
        let dos = try #require(session.machine.startupDisc)
        #expect(dos !== cpm && session.machine.drives[0].disc === dos)

        // One without a system disc gets an empty drive.
        session.powerCycle(configuration: configuration(.master128, .arm))
        #expect(session.machine.drives[0].disc == nil)

        // A disc of your own stays where it is.
        session.powerCycle(configuration: configuration(.master128, .z80))
        let mine = try Disc.fromSSD([UInt8](repeating: 0, count: 200 * 1024))
        session.machine.insertDisc(mine)
        session.powerCycle(configuration: configuration(.master128, .master512))
        #expect(session.machine.drives[0].disc === mine)

        // An empty drive gets the system disc back.
        session.machine.insertDisc(nil)
        session.powerCycle()
        #expect(session.machine.drives[0].disc === session.machine.startupDisc && session.machine.startupDisc != nil)
    }
}
