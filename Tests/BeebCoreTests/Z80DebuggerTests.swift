// The debugger on a Z80 second processor: breakpoints, stepping, registers,
// disassembly, tracing and going back.

import Testing
@testable import BeebCore
import BeebROMs

struct Z80DebuggerTests {
    /// A Model B with the Z80 booted and idle, then running a test program
    /// at &0100 with interrupts off:
    ///
    ///     0100 LD A,5
    ///     0102 LD (&4000),A
    ///     0105 CALL &0200
    ///     0108 INC A
    ///     0109 JR &0109
    ///     0200 LD B,7
    ///     0202 RET
    func machine(rewind: Bool = false) throws -> BBCMicro {
        let m = BBCMicro(configuration: BeebROMs.configuration(for: .modelB, secondProcessor: true, coprocessor: .z80,
                                                               systemDisc: false))
        if rewind { m.enableRewind(seconds: 5) }
        m.run(seconds: 2)
        let program: [UInt8] = [0x3E, 0x05, 0x32, 0x00, 0x40, 0xCD, 0x00, 0x02, 0x3C, 0x18, 0xFE]
        for (i, byte) in program.enumerated() { m.debugWrite(.parasiteRAM, 0x100 + i, byte) }
        for (i, byte) in [0x06, 0x07, 0xC9].enumerated() { m.debugWrite(.parasiteRAM, 0x200 + i, UInt8(byte)) }
        try m.setRegister("IFF1", cpu: .parasite, to: 0)
        try m.setRegister("SP", cpu: .parasite, to: 0x8000)
        try m.setRegister("B", cpu: .parasite, to: 0)
        try m.setRegister("PC", cpu: .parasite, to: 0x100)
        return m
    }

    @discardableResult
    func run(_ m: BBCMicro, _ command: RunCommand, maxCycles: Int = 100_000) -> StopReason? {
        m.debugger.run(command, cpu: .parasite, maxCycles: maxCycles) { m.run(cycles: $0) }
    }

    func pc(_ m: BBCMicro) -> Int? { m.register("PC", cpu: .parasite) }

    @Test func registers() throws {
        let m = try machine()
        #expect(m.debugCPUKind(.parasite) == .z80 && m.debugCPU(.parasite) == nil)
        #expect(m.registers(.parasite).map(\.name).prefix(8) == ["PC", "AF", "BC", "DE", "HL", "IX", "IY", "SP"])
        try m.setRegister("BC", cpu: .parasite, to: 0x1234)
        #expect(m.register("B", cpu: .parasite) == 0x12 && m.register("C", cpu: .parasite) == 0x34)
        try m.setRegister("CF", cpu: .parasite, to: 1)
        #expect(m.register("F", cpu: .parasite)! & 1 == 1)
        #expect(m.flags(.parasite).first { $0.label == "C" }?.set == true)
        #expect(m.flags(.parasite).first { $0.label == "IFF1" }?.set == false)
        #expect(throws: BBCMicro.RegisterError.self) { try m.setRegister("Q", cpu: .parasite, to: 1) }
        // Expressions see them.
        #expect(try DebugExpression("BC == &1234 && [&0100] == &3E").isTrue(m.debugger.expressionContext(.parasite)))
    }

    @Test func disassemblesZ80() throws {
        let m = try machine()
        let read = { (a: UInt16) in m.debugRead(.cpu(.parasite), Int(a)) ?? 0 }
        #expect(m.disassembler(.parasite).disassemble(at: 0x105, read: read).text == "CALL $0200")
        #expect(m.disassembler(.parasite).disassemble(at: 0x102, read: read).length == 3)
        // The host is still a 6502.
        #expect(m.disassembler(.host) is M6502Disassembler)
    }

    @Test func stepsInstructions() throws {
        let m = try machine()
        // The host stopped it, so the first step runs the instruction at
        // the PC.
        m.debugger.requestStop()
        #expect(run(m, .stepInstruction) == .stepped(.parasite))
        #expect(pc(m) == 0x102 && m.register("A", cpu: .parasite) == 5)
        run(m, .stepInstruction)
        #expect(pc(m) == 0x105 && m.debugRead(.parasiteRAM, 0x4000) == 5)
        // Into the CALL, and out again.
        run(m, .stepInstruction)
        #expect(pc(m) == 0x200 && m.register("SP", cpu: .parasite) == 0x7FFE)
        #expect(m.callStack(.parasite).prefix(2) == [0x200, 0x105], "\(m.callStack(.parasite))")
        #expect(run(m, .stepOut) == .stepped(.parasite))
        #expect(pc(m) == 0x108 && m.register("B", cpu: .parasite) == 7)
    }

    @Test func stepsOverCalls() throws {
        let m = try machine()
        run(m, .runToAddress(0x105))
        #expect(pc(m) == 0x105)
        #expect(run(m, .stepOver) == .stepped(.parasite))
        #expect(pc(m) == 0x108 && m.register("B", cpu: .parasite) == 7)
    }

    @Test func stopsBeforeAnInstruction() throws {
        let m = try machine()
        let b = try m.debugger.add(Breakpoint(cpu: .parasite, start: 0x108))
        #expect(run(m, .continue) == .breakpoint(id: b.id, cpu: .parasite, address: 0x108, kind: .execute))
        #expect(pc(m) == 0x108 && m.register("A", cpu: .parasite) == 5)
        // Resuming runs it (rather than stopping there again), then loops.
        #expect(run(m, .continue, maxCycles: 2000) == nil)
        #expect(m.register("A", cpu: .parasite) == 6 && pc(m) == 0x109)
        #expect(m.debugger.breakpoints[0].hitCount == 1)
    }

    @Test func watchpointsStopAfterTheInstruction() throws {
        let m = try machine()
        let b = try m.debugger.add(Breakpoint(cpu: .parasite, kind: .write, start: 0x4000))
        #expect(run(m, .continue) == .breakpoint(id: b.id, cpu: .parasite, address: 0x4000, kind: .write))
        #expect(pc(m) == 0x105 && m.debugRead(.parasiteRAM, 0x4000) == 5)
        // The CALL's push is a write too.
        let stack = try m.debugger.add(Breakpoint(cpu: .parasite, kind: .write, start: 0x7FFE, end: 0x7FFF))
        #expect(run(m, .continue) == .breakpoint(id: stack.id, cpu: .parasite, address: 0x7FFF, kind: .write))
        #expect(pc(m) == 0x200)
        // A read breakpoint doesn't see opcode or operand fetches.
        m.debugger.removeAllBreakpoints()
        try m.debugger.add(Breakpoint(cpu: .parasite, kind: .read, start: 0x100, end: 0x10A))
        #expect(run(m, .continue, maxCycles: 2000) == nil)
    }

    @Test func conditionsAndLogPoints() throws {
        let m = try machine()
        try m.debugger.add(Breakpoint(cpu: .parasite, start: 0x200, logMessage: "A={A} SP={SP}"))
        let b = try m.debugger.add(Breakpoint(cpu: .parasite, start: 0x108, condition: "B == 7"))
        #expect(run(m, .continue) == .breakpoint(id: b.id, cpu: .parasite, address: 0x108, kind: .execute))
        #expect(m.debugger.log.map(\.text) == ["A=&5 SP=32766"])
    }

    @Test func traces() throws {
        let m = try machine()
        m.debugger.setTracing(capacity: 100)
        try m.debugger.add(Breakpoint(cpu: .parasite, start: 0x108))
        run(m, .continue)
        // Up to the instruction it stopped at.
        let entries = m.debugger.trace(.parasite).last(5)
        #expect(entries.map(\.pc) == [0x102, 0x105, 0x200, 0x202, 0x108])
        #expect(entries[1].z80?.sp == 0x8000 && entries[3].z80.map { $0.bc >> 8 } == 7)
        #expect(entries[1].registerText.hasPrefix("AF=&05"))
        let text = m.disassembler(.parasite).disassemble(at: entries[1].pc) { entries[1].byte(at: $0) }.text
        #expect(text == "CALL $0200")
        // Running on doesn't trace that one again.
        run(m, .stepInstruction)
        #expect(m.debugger.trace(.parasite).last(3).map(\.pc) == [0x202, 0x108, 0x109])
    }

    @Test func profilesTStates() throws {
        let m = try machine()
        m.debugger.startProfiling()
        m.run(cycles: 2000)
        m.debugger.stopProfiling()
        let report = try #require(m.debugger.profileReport(.parasite))
        // 2000 host cycles at 6MHz.
        #expect(abs(report.totalCycles - 6000) < 20)
        #expect(report.hottest.first?.address == 0x109)
    }

    @Test func stepsBack() throws {
        let m = try machine(rewind: true)
        run(m, .runToAddress(0x200))
        run(m, .stepInstruction)
        #expect(pc(m) == 0x202)
        try m.debugger.stepBack(.parasite)
        #expect(m.debugger.stopReason == .stepped(.parasite))
        #expect(pc(m) == 0x200 && m.register("B", cpu: .parasite) != 7)
        try m.debugger.stepBack(.parasite)
        #expect(pc(m) == 0x105)
        // And forwards again from there, as if it had stopped there.
        run(m, .stepInstruction)
        #expect(pc(m) == 0x200)
    }

    @Test func reverseContinues() throws {
        let m = try machine(rewind: true)
        let write = try m.debugger.add(Breakpoint(cpu: .parasite, kind: .write, start: 0x4000))
        run(m, .continue)
        m.debugger.remove(id: write.id)
        let b = try m.debugger.add(Breakpoint(cpu: .parasite, start: 0x200))
        run(m, .continue)
        #expect(pc(m) == 0x200)
        m.debugger.remove(id: b.id)
        let again = try m.debugger.add(Breakpoint(cpu: .parasite, kind: .write, start: 0x4000))
        run(m, .continue, maxCycles: 2000)
        try m.debugger.reverseContinue()
        #expect(m.debugger.stopReason == .breakpoint(id: again.id, cpu: .parasite, address: 0x4000, kind: .write))
        #expect(pc(m) == 0x105)
        // Then forwards to the CALL's target.
        run(m, .stepInstruction)
        #expect(pc(m) == 0x200)
    }
}
