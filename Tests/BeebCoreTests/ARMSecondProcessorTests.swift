// The Acorn ARM Second Processor (ARM Evaluation System). ARM BASIC runs
// only when BeebEm's disc 3 is in reference/ (it isn't redistributed here).

import Foundation
import Testing
@testable import BeebCore
import BeebROMs

struct ARMSecondProcessorTests {
    static let basicDisc = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("reference/beebem-windows/UserData/DiscIms/armdisc3.adl")
    static var basicAvailable: Bool { FileManager.default.fileExists(atPath: basicDisc.path) }

    func machine(_ model: BBCMicro.Model = .modelB) -> BBCMicro {
        BBCMicro(configuration: BeebROMs.configuration(for: model, secondProcessor: true, coprocessor: .arm))
    }

    func screen(_ m: BBCMicro) -> [String] {
        m.screenText().map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    @Test(arguments: [BBCMicro.Model.modelB, .master128])
    func boots(_ model: BBCMicro.Model) {
        let m = machine(model)
        #expect(m.armProcessor != nil && m.secondProcessor == nil && m.z80Processor == nil)
        m.run(seconds: 2)
        let text = screen(m)
        #expect(text.first == "Acorn ARM Second Processor 4096K", "\(text)")
        #expect(text.last == "A*", "\(text)")
        // It runs from the copy of the ROM in RAM.
        #expect(m.armProcessor!.cpu.pc < 0x100_0000)
    }

    @Test func helpSupervisor() {
        let m = machine()
        m.run(seconds: 2)
        m.type("*HELP SUPERVISOR\n")
        m.run(seconds: 3)
        let text = screen(m)
        #expect(text.contains { $0.hasPrefix("ShowRegs - show the registers") }, "\(text)")
        #expect(text.contains { $0.hasPrefix("MemoryI  - <address>") }, "\(text)")
        #expect(text.last == "A*", "\(text)")
    }

    @Test func breakRestartsIt() {
        let m = machine()
        m.run(seconds: 2)
        m.type("*HELP SUPERVISOR\n")
        m.run(seconds: 3)
        m.pressBreak()
        m.run(seconds: 2)
        let text = screen(m)
        #expect(text.first == "Acorn ARM Second Processor 4096K" && text.last == "A*", "\(text)")
    }

    @Test func snapshotsAndRewind() throws {
        let m = machine()
        m.enableRewind(seconds: 5)
        m.run(seconds: 1)
        let snapshot = m.snapshot()
        let copy = machine()
        try copy.restore(snapshot)
        let middle = m.cycles
        m.type("*HELP\n")
        copy.type("*HELP\n")
        m.run(seconds: 1)
        copy.run(seconds: 1)
        #expect(copy.armProcessor?.cpu.pc == m.armProcessor?.cpu.pc && screen(copy) == screen(m))
        #expect(copy.armProcessor?.cpu.r15 == m.armProcessor?.cpu.r15)
        let pc = m.armProcessor?.cpu.pc
        try m.rewinder!.seek(to: middle)
        m.run(seconds: 1)
        #expect(m.armProcessor?.cpu.pc == pc && m.armProcessor?.state.ram == copy.armProcessor?.state.ram)
        // Unchanged RAM is shared between save states.
        let a = m.snapshot(), b = m.snapshot()
        #expect(a.arm?.ram.count == ARMSecondProcessor.pageCount)
        #expect(a.arm!.ram[100].withUnsafeBytes { $0.baseAddress } == b.arm!.ram[100].withUnsafeBytes { $0.baseAddress })
        // Other second processors can't take an ARM's state.
        let other = BBCMicro(configuration: BeebROMs.configuration(for: .modelB, secondProcessor: true, coprocessor: .z80))
        #expect(throws: BBCMicro.RestoreError.self) { try other.restore(snapshot) }
        #expect(throws: BBCMicro.RestoreError.self) { try copy.restore(other.snapshot()) }
    }

    @Test(.enabled(if: basicAvailable))
    func runsARMBASIC() throws {
        let m = machine(.master128)
        m.insertDisc(try Disc.fromImage([UInt8](Data(contentsOf: Self.basicDisc)), format: .adl))
        m.run(seconds: 2)
        m.type("ADFS\nMOUNT 4\nAB\n")
        // Loading it over the Tube takes a while.
        for _ in 0..<30 where screen(m).last != ">" {
            m.run(seconds: 1)
        }
        var text = screen(m)
        #expect(text.contains { $0.hasPrefix("ARM BBC Basic V version 1.00") }, "\(text)")
        #expect(text.last == ">", "\(text)")
        m.type("PRINT 2+2\n")
        m.run(seconds: 2)
        text = screen(m)
        #expect(text.suffix(3) == [">PRINT 2+2", "4", ">"], "\(text)")
        // Floating point, and a loop.
        m.type("PRINT SQR(2)\nT=TIME:FOR I=1 TO 10000:NEXT:PRINT \"DONE\";I\n")
        m.run(seconds: 2)
        for _ in 0..<20 where m.isTyping || screen(m).last != ">" {
            m.run(seconds: 1)
        }
        text = screen(m)
        #expect(text.contains("1.41421356") && text.contains("DONE10001"), "\(text)")
        #expect(text.last == ">", "\(text)")
    }
}
