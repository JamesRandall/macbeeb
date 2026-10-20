import Foundation
import Testing
@testable import BeebCore
import BeebROMs

struct DebugExpressionTests {
    func evaluate(_ source: String, registers: [String: Int] = [:], memory: [UInt16: UInt8] = [:],
                  symbols: [String: Int] = [:]) throws -> Int {
        let context = DebugExpression.Context(register: { registers[$0] }, readByte: { memory[$0] ?? 0 },
                                              symbol: { symbols[$0] })
        return try DebugExpression(source).evaluate(context)
    }

    @Test func numbers() throws {
        #expect(try evaluate("&FF") == 255)
        #expect(try evaluate("$1900") == 0x1900)
        #expect(try evaluate("0x10") == 16)
        #expect(try evaluate("%1010") == 10)
        #expect(try evaluate("42") == 42)
    }

    @Test func operators() throws {
        #expect(try evaluate("1 + 2 * 3") == 7)
        #expect(try evaluate("(1 + 2) * 3") == 9)
        #expect(try evaluate("&F0 & &3C") == 0x30)
        #expect(try evaluate("7 % 4") == 3)
        #expect(try evaluate("1 << 4 | 1") == 17)
        #expect(try evaluate("!0 && -1 < 0") == 1)
        #expect(try evaluate("~0 == -1") == 1)
        #expect(try evaluate("2 > 3 || 3 >= 3") == 1)
    }

    @Test func registersMemoryAndSymbols() throws {
        #expect(try evaluate("A == &20 && x > 1", registers: ["A": 0x20, "X": 2]) == 1)
        #expect(try evaluate("[&70] + 1", memory: [0x70: 9]) == 10)
        #expect(try evaluate("{&FFFE}", memory: [0xFFFE: 0x34, 0xFFFF: 0x12]) == 0x1234)
        #expect(try evaluate("[{&70} + Y]", registers: ["Y": 1], memory: [0x70: 0x00, 0x71: 0x30, 0x3001: 7]) == 7)
        #expect(try evaluate("OSWRCH", symbols: ["OSWRCH": 0xFFEE]) == 0xFFEE)
    }

    @Test func errors() {
        #expect(throws: DebugExpression.ParseError.self) { try DebugExpression("1 +") }
        #expect(throws: DebugExpression.ParseError.self) { try DebugExpression("(1") }
        #expect(throws: DebugExpression.ParseError.self) { try DebugExpression("1 2") }
        #expect(throws: DebugExpression.EvaluationError.self) { try evaluate("NOPE") }
        #expect(throws: DebugExpression.EvaluationError.self) { try evaluate("1 / 0") }
    }
}

struct DebuggerTests {
    //   2000 LDA #5 : STA &70 : JSR &2010 : LDX #3 : RTS
    //   2010 LDA &70 : CLC : ADC #1 : STA &71 : RTS
    static let program: [UInt16: [UInt8]] = [
        0x2000: [0xA9, 0x05, 0x85, 0x70, 0x20, 0x10, 0x20, 0xA2, 0x03, 0x60],
        0x2010: [0xA5, 0x70, 0x18, 0x69, 0x01, 0x85, 0x71, 0x60],
    ]

    func machine(_ model: BBCMicro.Model = .modelB, secondProcessor: Bool = false) -> BBCMicro {
        let machine = BBCMicro(configuration: BeebROMs.configuration(for: model, secondProcessor: secondProcessor))
        #expect(machine.runUntilIdle())
        for (address, bytes) in Self.program {
            machine.load(bytes, at: address)
        }
        return machine
    }

    /// Calls the program from BASIC and runs `command` until it stops.
    @discardableResult
    func call(_ machine: BBCMicro, _ command: RunCommand = .continue, cpu: DebugCPU = .host) -> StopReason? {
        machine.paste("CALL &2000\n")
        return run(machine, command, cpu: cpu)
    }

    @discardableResult
    func run(_ machine: BBCMicro, _ command: RunCommand, cpu: DebugCPU = .host) -> StopReason? {
        machine.debugger.run(command, cpu: cpu, maxCycles: 4_000_000) { machine.run(cycles: $0) }
    }

    @Test func executeBreakpointStopsBeforeTheInstruction() throws {
        let m = machine()
        let b = try m.debugger.add(Breakpoint(start: 0x2010))
        #expect(call(m) == .breakpoint(id: b.id, cpu: .host, address: 0x2010, kind: .execute))
        #expect(m.cpu.isAboutToExecute)
        #expect(m.instructionAddress(.host) == 0x2010)
        // LDA #5 and STA &70 have run; LDA &70 hasn't.
        #expect(m.peek(0x70) == 5)
        #expect(m.debugger.breakpoints[0].hitCount == 1)
    }

    @Test func stopsHoldUntilResumed() throws {
        let m = machine()
        try m.debugger.add(Breakpoint(start: 0x2010))
        call(m)
        let cycles = m.cycles
        #expect(m.run(cycles: 1000) == 0)
        #expect(m.cycles == cycles)
        m.debugger.resume()
        #expect(m.run(cycles: 1000) == 1000)
    }

    @Test func writeBreakpointStopsOnTheWrite() throws {
        let m = machine()
        let b = try m.debugger.add(Breakpoint(kind: .write, start: 0x71))
        #expect(call(m) == .breakpoint(id: b.id, cpu: .host, address: 0x71, kind: .write))
        // Mid STA &71, on its write cycle.
        #expect(m.cpu.abus == 0x71 && m.cpu.access == .write)
        #expect(m.peek(0x71) == 6)
        #expect(m.instructionAddress(.host) == 0x2015)
    }

    @Test func readBreakpoint() throws {
        let m = machine()
        let b = try m.debugger.add(Breakpoint(kind: .read, start: 0x70, end: 0x70))
        #expect(call(m) == .breakpoint(id: b.id, cpu: .host, address: 0x70, kind: .read))
        #expect(m.instructionAddress(.host) == 0x2010)
    }

    @Test func conditionsHitCountsAndLogPoints() throws {
        let m = machine()
        // A log point at the subroutine's ADC: A is 5 there.
        try m.debugger.add(Breakpoint(start: 0x2013, logMessage: "A={A} [&70]={[&70]}"))
        // Never true.
        try m.debugger.add(Breakpoint(start: 0x2000, condition: "A == &99"))
        // Stops on the second call only.
        let second = try m.debugger.add(Breakpoint(start: 0x2007, hitTarget: 2))
        call(m)
        #expect(m.debugger.log.map(\.text) == ["A=&5 [&70]=&5"])
        #expect(m.debugger.stopReason == nil)
        #expect(m.runUntilIdle())
        #expect(call(m) == .breakpoint(id: second.id, cpu: .host, address: 0x2007, kind: .execute))
        #expect(m.debugger.log.count == 2)
        #expect(throws: DebugExpression.ParseError.self) { try m.debugger.add(Breakpoint(start: 0, condition: "A ==")) }
    }

    @Test func stepping() throws {
        let m = machine()
        try m.debugger.add(Breakpoint(start: 0x2000))
        call(m)
        m.debugger.removeAllBreakpoints()
        #expect(run(m, .stepInstruction) == .stepped(.host))
        #expect(m.instructionAddress(.host) == 0x2002)
        #expect(m.cpu.a == 5)
        run(m, .stepInstruction)
        #expect(m.instructionAddress(.host) == 0x2004)
        // Over the JSR: the subroutine runs.
        run(m, .stepOver)
        #expect(m.instructionAddress(.host) == 0x2007)
        #expect(m.peek(0x71) == 6)
        // Into a subroutine, then out of it.
        m.poke(0x71, 0)
        try m.setRegister("PC", cpu: .host, to: 0x2004)
        run(m, .stepInstruction)
        #expect(m.instructionAddress(.host) == 0x2010)
        run(m, .stepOut)
        #expect(m.instructionAddress(.host) == 0x2007)
        #expect(m.peek(0x71) == 6)
        // Over a non-JSR is a single step.
        run(m, .stepOver)
        #expect(m.instructionAddress(.host) == 0x2009 && m.cpu.x == 3)
    }

    @Test func runToAddressAndCycleSteps() throws {
        let m = machine()
        try m.debugger.add(Breakpoint(start: 0x2000))
        call(m)
        m.debugger.removeAllBreakpoints()
        #expect(run(m, .runToAddress(0x2015)) == .stepped(.host))
        #expect(m.instructionAddress(.host) == 0x2015)
        let cycles = m.cycles
        run(m, .stepCycle)
        #expect(m.cycles == cycles + 1)
    }

    @Test func framesScanlinesAndInterrupts() throws {
        let m = machine()
        #expect(run(m, .nextFrame) == .frame)
        #expect(m.crtcLastOutput.vsync)
        #expect(run(m, .nextScanline) == .scanline)
        #expect(m.crtcLastOutput.hsync)
        // The OS's 100Hz timer interrupts the idle loop.
        #expect(run(m, .nextInterrupt) == .interrupt(.host))
        #expect(m.cpu.access == .interrupt)
        run(m, .stepInstruction)
        // Into the IRQ handler, via IRQ1V.
        #expect(m.instructionAddress(.host) == UInt16(m.peek(0xFFFE)) | UInt16(m.peek(0xFFFF)) << 8)
    }

    @Test func settingRegisters() throws {
        let m = machine()
        try m.debugger.add(Breakpoint(start: 0x2010))
        call(m)
        try m.setRegister("A", cpu: .host, to: 0x40)
        try m.setRegister("C", cpu: .host, to: 1)
        try m.setRegister("PC", cpu: .host, to: 0x2012)
        m.debugger.removeAllBreakpoints()
        run(m, .stepInstruction)
        // CLC ran from &2012.
        #expect(m.instructionAddress(.host) == 0x2013 && !m.cpu.c && m.cpu.a == 0x40)
        #expect(throws: BBCMicro.RegisterError.self) { try m.setRegister("Q", cpu: .host, to: 0) }
        #expect(throws: BBCMicro.RegisterError.self) { try m.setRegister("A", cpu: .parasite, to: 0) }
    }

    @Test func tracing() throws {
        let m = machine()
        m.debugger.setTracing(capacity: 100)
        try m.debugger.add(Breakpoint(start: 0x2009))
        call(m)
        // The instruction stopped at is in the trace too.
        let pcs = m.debugger.trace(.host).last(10).map(\.pc)
        #expect(pcs == [0x2000, 0x2002, 0x2004, 0x2010, 0x2012, 0x2013, 0x2015, 0x2017, 0x2007, 0x2009])
        let sta = m.debugger.trace(.host).last(10)[1]
        #expect(sta.a == 5 && sta.bytes.0 == 0x85 && sta.bytes.1 == 0x70)
        // The ring keeps the newest.
        var ring = TraceBuffer(capacity: 3)
        for pc in 0..<5 {
            ring.append(TraceEntry(cycle: 0, pc: UInt16(pc), a: 0, x: 0, y: 0, s: 0, p: 0, bytes: (0, 0, 0), interrupt: false))
        }
        #expect(ring.last(10).map(\.pc) == [2, 3, 4])
    }

    @Test func romBankQualifier() throws {
        let m = machine()
        // BASIC (bank 15) runs from &8000; nothing's in bank 3.
        try m.debugger.add(Breakpoint(start: 0x8000, end: 0xBFFF, romBank: 3))
        let basic = try m.debugger.add(Breakpoint(start: 0x8000, end: 0xBFFF, romBank: 15))
        m.paste("PRINT 1\n")
        #expect(run(m, .continue) == .breakpoint(id: basic.id, cpu: .host, address: m.instructionAddress(.host), kind: .execute))
    }

    @Test func secondProcessorBreakpointsAndStepping() throws {
        let m = machine(secondProcessor: true)
        // In the parasite this time: the code goes in its memory.
        for (address, bytes) in Self.program {
            for (i, byte) in bytes.enumerated() {
                m.debugWrite(.parasiteRAM, Int(address) + i, byte)
            }
        }
        let b = try m.debugger.add(Breakpoint(cpu: .parasite, start: 0x2010))
        #expect(call(m, cpu: .parasite) == .breakpoint(id: b.id, cpu: .parasite, address: 0x2010, kind: .execute))
        let p = try #require(m.secondProcessor)
        #expect(p.cpu.isAboutToExecute && m.instructionAddress(.parasite) == 0x2010)
        #expect(m.register("A", cpu: .parasite) == 5)
        m.debugger.removeAllBreakpoints()
        run(m, .stepOut, cpu: .parasite)
        #expect(m.instructionAddress(.parasite) == 0x2007)
        #expect(m.debugRead(.cpu(.parasite), 0x71) == 6)
    }

    @Test func logOnlyBreakpointsDontChangeExecution() throws {
        func busTrace(debugging: Bool) throws -> Int {
            let m = machine(secondProcessor: true)
            if debugging {
                try m.debugger.add(Breakpoint(kind: [.execute, .read, .write], start: 0, end: 0xFFFF, logMessage: "x"))
                try m.debugger.add(Breakpoint(cpu: .parasite, kind: .execute, start: 0, end: 0xFFFF, logMessage: "x"))
                m.debugger.setTracing(capacity: 10)
            }
            m.paste("FOR I%=1 TO 50:PRINT I%:NEXT\n")
            var hasher = Hasher()
            for _ in 0..<400_000 {
                m.step()
                hasher.combine(m.cpu.abus)
                hasher.combine(m.cpu.dbus)
                hasher.combine(m.secondProcessor!.cpu.abus)
            }
            return hasher.finalize()
        }
        #expect(try busTrace(debugging: true) == busTrace(debugging: false))
    }

    @Test func memorySpaces() throws {
        let m = machine(.master128, secondProcessor: true)
        let names = m.memoryRegions.map(\.space)
        #expect(names.contains(.hazel) && names.contains(.sidewaysBank(12)) && names.contains(.parasiteRAM))
        #expect(!machine().memoryRegions.map(\.space).contains(.shadowRAM))
        // Physical spaces see through the paging.
        #expect(m.debugWrite(.shadowRAM, 0x3000, 0xAA))
        #expect(m.debugRead(.shadowRAM, 0x3000) == 0xAA && m.debugRead(.mainRAM, 0x3000) != 0xAA)
        #expect(m.debugRead(.sidewaysBank(12), 0x8000) == BeebROMs.data(.mos320BASIC4)[0])
        #expect(m.debugRead(.osROM, 0xFFFC) == BeebROMs.data(.mos320)[0x3FFC])
        #expect(m.debugRead(.hazel, 0xBFFF) == nil)
        // ROM can be patched.
        #expect(m.debugWrite(.osROM, 0xC000, 0x12) && m.debugRead(.osROM, 0xC000) == 0x12)
        // I/O is peeked, not read, and not written.
        #expect(m.debugRead(.cpu(.host), 0xFE4D) == m.systemVIA.peek(0xD))
        #expect(!m.debugWrite(.cpu(.host), 0xFE4E, 0))
        #expect(MemorySpace(name: "rom9") == .sidewaysBank(9) && MemorySpace(name: "shadow") == .shadowRAM)
    }
}
