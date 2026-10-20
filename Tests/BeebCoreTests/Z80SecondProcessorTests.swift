// The Acorn Z80 Second Processor. CP/M runs only when BeebEm's CP/M
// Utilities disc is in reference/ (it isn't redistributed here).

import Foundation
import Testing
@testable import BeebCore
import BeebROMs

struct Z80SecondProcessorTests {
    static let cpmDisc = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("reference/beebem-windows/UserData/DiscIms/CPM_Utilities_Disc.dsd")
    static var cpmAvailable: Bool { FileManager.default.fileExists(atPath: cpmDisc.path) }

    func machine(_ model: BBCMicro.Model = .modelB) -> BBCMicro {
        BBCMicro(configuration: BeebROMs.configuration(for: model, secondProcessor: true, coprocessor: .z80))
    }

    func screen(_ m: BBCMicro) -> [String] { m.screenText().filter { !$0.isEmpty } }

    @Test(arguments: [BBCMicro.Model.modelB, .master128])
    func boots(_ model: BBCMicro.Model) {
        let m = machine(model)
        #expect(m.z80Processor != nil && m.secondProcessor == nil)
        m.run(seconds: 2)
        let text = screen(m)
        #expect(text.first == "Acorn TUBE Z80 64K 1.21", "\(text)")
        #expect(text.contains("Insert CP/M System disc in drive A"), "\(text)")
        // The client ROM copied itself up and paged itself out.
        #expect(m.z80Processor?.inROM == false)
    }

    @Test func breakRestartsIt() {
        let m = machine()
        m.run(seconds: 2)
        m.pressBreak()
        m.run(seconds: 2)
        #expect(screen(m).first == "Acorn TUBE Z80 64K 1.21")
    }

    @Test func snapshotsAndRewind() throws {
        let m = machine()
        m.enableRewind(seconds: 5)
        m.run(seconds: 1)
        let snapshot = m.snapshot()
        let copy = machine()
        try copy.restore(snapshot)
        let middle = m.cycles
        m.run(seconds: 1)
        copy.run(seconds: 1)
        #expect(copy.z80Processor?.cpu.pc == m.z80Processor?.cpu.pc && screen(copy) == screen(m))
        let pc = m.z80Processor?.cpu.pc
        try m.rewinder!.seek(to: middle)
        m.run(seconds: 1)
        #expect(m.z80Processor?.cpu.pc == pc && m.z80Processor?.state.ram == copy.z80Processor?.state.ram)
        // A 6502-second-processor machine can't take a Z80's state.
        let other = BBCMicro(configuration: BeebROMs.configuration(for: .modelB, secondProcessor: true))
        #expect(throws: BBCMicro.RestoreError.self) { try other.restore(snapshot) }
    }

    @Test(.enabled(if: cpmAvailable))
    func runsCPM() throws {
        let m = machine()
        m.insertDisc(try Disc.fromDSD([UInt8](Data(contentsOf: Self.cpmDisc))))
        m.run(seconds: 8)
        #expect(screen(m).suffix(2) == ["Acorn CP/M 2.2 - Bios 1.20", "A>"], "\(screen(m))")
        m.type("DIR\n")
        m.run(seconds: 4)
        let text = screen(m)
        #expect(text.contains { $0.contains("PIP      COM") }, "\(text)")
        #expect(text.last == "A>")
    }
}
