// Runs BeebCore's NMOS 6502 side by side with perfect6502, a simulation of
// the real chip's transistors, and checks the address bus, R/W, data bus and
// registers agree on every cycle.
//
// Modelled on b2's visual6502.cpp test.

import Foundation
import Perfect6502
import Testing
@testable import BeebCore

/// Deterministic random numbers (SplitMix64).
struct SplitMix64 {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func byte() -> UInt8 { UInt8(truncatingIfNeeded: next()) }

    /// A random byte that's a documented opcode, for operands that might end
    /// up executed.
    mutating func operand() -> UInt8 {
        let value = byte()
        return documentedOpcodes.contains(value) ? value : 0xEA
    }
}

/// Opcodes allowed in random memory and operands: the documented ones. The
/// undocumented ones are only executed as the instruction under test.
let documentedOpcodes: Set<UInt8> = Set((0...255).map { UInt8($0) }.filter {
    !M6502InstructionInfo.nmos[Int($0)].undocumented
})

/// Undocumented opcodes whose results depend on analogue effects. Not
/// tested here; dp111's timing test covers the SHx ones on a real machine.
let unstableOpcodes: Set<UInt8> = [
    0x8B, 0xAB, // ANE, LXA
    0x93, 0x9F, 0x9C, 0x9E, 0x9B, // SHA, SHY, SHX, SHS
]

/// Undocumented opcodes whose results come from internal bus contention,
/// which perfect6502 resolves differently from real chips (e.g. it leaves A
/// unchanged for ANC). Their bus activity is still checked; their results
/// are checked against real-hardware expectations by the Lorenz suite.
let busOnlyOpcodes: Set<UInt8> = [0x0B, 0x2B, 0x4B, 0x6B, 0xBB] // ANC, ANC, ALR, ARR, LAS

struct PinChange {
    var cycle: Int
    /// Pin level: false asserts the (active low) interrupt.
    var level: Bool
}

struct OracleProgram {
    var memory: [UInt8]
    var cycles: Int
    var compareRegisters = true
    /// Stop (and pass) when the CPU fetches an undocumented opcode, for
    /// random code that might write one.
    var stopAtUndocumented = false
    var irq: [PinChange] = []
    var nmi: [PinChange] = []

    /// Random memory with only documented opcodes, vectors pointing at
    /// $0200 (reset) and $0300 (IRQ/NMI handler: PHA, PLA, RTI).
    static func randomMemory(_ rng: inout SplitMix64) -> [UInt8] {
        var memory = (0..<0x10000).map { _ in rng.byte() }
        for i in memory.indices where !documentedOpcodes.contains(memory[i]) {
            memory[i] = 0xEA
        }
        memory.replaceSubrange(0x0300..<0x0303, with: [0x48, 0x68, 0x40])
        memory.replaceSubrange(0xFFFA..<0x10000, with: [0x00, 0x03, 0x00, 0x02, 0x00, 0x03])
        return memory
    }
}

/// Runs a program on both CPUs. Returns nil if they agree, or a description
/// of the first divergence with a trace leading up to it.
func compareWithPerfect6502(_ program: OracleProgram) -> String? {
    let chipMemory = p6502_memory()!
    for (i, byte) in program.memory.enumerated() {
        chipMemory[i] = byte
    }
    guard let chip = p6502_create() else { return "couldn't create perfect6502" }
    defer { p6502_destroy(chip) }

    // Run to the equivalent of the simulator's initial state: just after the
    // reset vector fetch.
    var guardSteps = 0
    while p6502_address_bus(chip) != 0xFFFD {
        p6502_half_step(chip)
        guardSteps += 1
        if guardSteps > 100 { return "perfect6502 didn't fetch the reset vector" }
    }
    p6502_half_step(chip)

    var memory = program.memory
    let cpu = M6502(variant: .nmos)
    cpu.a = p6502_a(chip)
    cpu.x = p6502_x(chip)
    cpu.y = p6502_y(chip)
    cpu.s = p6502_sp(chip)
    cpu.p = p6502_p(chip)
    cpu.start(at: UInt16(memory[0xFFFC]) | UInt16(memory[0xFFFD]) << 8)

    var trace: [String] = []
    var wasSync = false

    for cycle in 0..<program.cycles {
        var problems: [String] = []

        let irqChange = program.irq.first { $0.cycle == cycle }
        let nmiChange = program.nmi.first { $0.cycle == cycle }
        if let irqChange { p6502_set_irq(chip, irqChange.level) }
        if let nmiChange { p6502_set_nmi(chip, nmiChange.level) }

        p6502_half_step(chip)
        if p6502_clk0(chip) { return "perfect6502 clock out of phase at cycle \(cycle)" }
        let phase1Address = p6502_address_bus(chip)
        p6502_half_step(chip)
        if !p6502_clk0(chip) || p6502_address_bus(chip) != phase1Address {
            return "perfect6502 clock out of phase at cycle \(cycle)"
        }

        if wasSync && program.compareRegisters {
            func check(_ name: String, _ mine: Int, _ real: Int, width: Int = 2) {
                if mine != real {
                    problems.append("\(name): mine=\(hexString(mine, width)) perfect6502=\(hexString(real, width))")
                }
            }
            check("A", Int(cpu.a), Int(p6502_a(chip)))
            check("X", Int(cpu.x), Int(p6502_x(chip)))
            check("Y", Int(cpu.y), Int(p6502_y(chip)))
            check("S", Int(cpu.s), Int(p6502_sp(chip)))
            check("PC", Int(cpu.pc), Int(p6502_pc(chip)), width: 4)
            // B and bit 5 aren't real flags.
            check("P", Int(cpu.p & 0xCF), Int(p6502_p(chip) & 0xCF))
        }

        if let irqChange { cpu.setIRQ(1, !irqChange.level) }
        if let nmiChange { cpu.setNMI(1, !nmiChange.level) }

        let stateBefore = cpu.state
        if cycle > 0 {
            cpu.tick()
        }
        if cpu.access == .write {
            memory[Int(cpu.abus)] = cpu.dbus
        } else {
            cpu.dbus = memory[Int(cpu.abus)]
        }

        let realAddress = p6502_address_bus(chip)
        let realRead = p6502_rw(chip)
        let realData = p6502_data_bus(chip)
        let mineRead = cpu.access != .write
        if cpu.abus != realAddress {
            problems.append("address: mine=\(hexString(Int(cpu.abus), 4)) perfect6502=\(hexString(Int(realAddress), 4))")
        }
        if mineRead != realRead {
            problems.append("R/W: mine=\(mineRead ? "R" : "W") perfect6502=\(realRead ? "R" : "W")")
        }
        if cpu.dbus != realData {
            problems.append("data: mine=\(hexString(Int(cpu.dbus), 2)) perfect6502=\(hexString(Int(realData), 2))")
        }

        trace.append(String(format: "%4d  p6502 %04X %@ %02X  PC=%04X A=%02X X=%02X Y=%02X S=%02X P=%02X IR=%02X | mine %04X %@ %02X %@ (from %@)",
                            cycle,
                            realAddress, realRead ? "R" : "W", realData,
                            p6502_pc(chip), p6502_a(chip), p6502_x(chip), p6502_y(chip), p6502_sp(chip), p6502_p(chip), p6502_ir(chip),
                            cpu.abus, mineRead ? "R" : "W", cpu.dbus, String(describing: cpu.access), String(describing: stateBefore)))

        if !problems.isEmpty {
            let context = trace.suffix(24).joined(separator: "\n")
            let pins = (program.irq.map { "IRQ \($0.level ? "high" : "low") at \($0.cycle)" }
                + program.nmi.map { "NMI \($0.level ? "high" : "low") at \($0.cycle)" })
            return "diverged at cycle \(cycle): \(problems.joined(separator: "; "))\npins: \(pins.joined(separator: ", "))\n\(context)"
        }

        wasSync = p6502_sync(chip)
        if wasSync && program.stopAtUndocumented && !documentedOpcodes.contains(realData) {
            return nil
        }
    }
    return nil
}

private func hexString(_ value: Int, _ width: Int) -> String {
    let s = String(value, radix: 16, uppercase: true)
    return "$" + String(repeating: "0", count: max(0, width - s.count)) + s
}

// perfect6502 keeps its memory in a global, so these can't run in parallel.
@Suite(.serialized)
struct Perfect6502OracleTests {
    static let seedsPerOpcode = 8

    /// Every documented and stable undocumented NMOS opcode, with random
    /// flags (including decimal mode), registers, operands and memory.
    @Test(arguments: (0...255).map { UInt8($0) }.filter { !unstableOpcodes.contains($0) })
    func opcodeMatchesPerfect6502(_ opcode: UInt8) {
        for seed in 0..<Self.seedsPerOpcode {
            var rng = SplitMix64(state: UInt64(opcode) << 32 | UInt64(seed))
            var memory = OracleProgram.randomMemory(&rng)
            let program: [UInt8] = [
                0xA2, rng.byte(), 0x9A,   // LDX #s, TXS
                0xA9, rng.byte(), 0x48, 0x28, // LDA #p, PHA, PLP
                0xA9, rng.byte(),         // LDA #a
                0xA2, rng.byte(),         // LDX #x
                0xA0, rng.byte(),         // LDY #y
                opcode, rng.operand(), rng.operand(),
                0xEA, 0xEA, 0xEA, 0xEA, 0xEA, 0xEA,
                0x4C, 0x00, 0x02,         // JMP $0200
            ]
            memory.replaceSubrange(0x0200..<0x0200 + program.count, with: program)
            let oracle = OracleProgram(memory: memory, cycles: 70, compareRegisters: !busOnlyOpcodes.contains(opcode))
            if let problem = compareWithPerfect6502(oracle) {
                Issue.record("opcode $\(String(format: "%02X", opcode)) seed \(seed): \(problem)")
                return
            }
        }
    }

    /// A mix of instructions where interrupt timing is subtle: CLI/SEI
    /// latency, page-crossing reads, taken/untaken and page-crossing
    /// branches, BRK, RMW.
    static func interruptProgram(seed: UInt64) -> [UInt8] {
        var rng = SplitMix64(state: seed)
        var memory = OracleProgram.randomMemory(&rng)
        let main: [UInt8] = [
            0xA2, 0xFF, 0x9A,       // $0200 LDX #$FF, TXS
            0xA9, 0x00, 0x48, 0x28, // $0203 LDA #0, PHA, PLP (I and D clear)
            0xA2, 0x01,             // $0207 LDX #1
            0xBD, 0xFF, 0x12,       // $0209 LDA $12FF,X (page crossing)
            0x58,                   // $020C CLI
            0x78,                   // $020D SEI
            0x58,                   // $020E CLI
            0xD0, 0x02,             // $020F BNE +2
            0xEA, 0xEA,             // $0211
            0xF0, 0x00,             // $0213 BEQ +0
            0xE6, 0x10,             // $0215 INC $10
            0x00, 0xEA,             // $0217 BRK
            0x20, 0x30, 0x02,       // $0219 JSR $0230
            0x08, 0x28,             // $021C PHP, PLP
            0x4C, 0xF0, 0x02,       // $021E JMP $02F0
        ]
        memory.replaceSubrange(0x0200..<0x0200 + main.count, with: main)
        memory[0x0230] = 0x60                                                // RTS
        memory.replaceSubrange(0x02F0..<0x02F3, with: [0x18, 0x90, 0x20])   // CLC, BCC $0313
        memory.replaceSubrange(0x0313..<0x0316, with: [0x4C, 0x07, 0x02])   // JMP $0207
        return memory
    }

    @Test(arguments: 0..<130)
    func irqTimingMatchesPerfect6502(_ assertCycle: Int) {
        let program = OracleProgram(
            memory: Self.interruptProgram(seed: 1),
            cycles: 200,
            irq: [PinChange(cycle: assertCycle, level: false), PinChange(cycle: assertCycle + 24, level: true)]
        )
        if let problem = compareWithPerfect6502(program) {
            Issue.record("IRQ at cycle \(assertCycle): \(problem)")
        }
    }

    @Test(arguments: 0..<130)
    func nmiTimingMatchesPerfect6502(_ assertCycle: Int) {
        let program = OracleProgram(
            memory: Self.interruptProgram(seed: 2),
            cycles: 200,
            nmi: [PinChange(cycle: assertCycle, level: false), PinChange(cycle: assertCycle + 4, level: true)]
        )
        if let problem = compareWithPerfect6502(program) {
            Issue.record("NMI at cycle \(assertCycle): \(problem)")
        }
    }

    /// Random documented code with IRQ and NMI toggling at random times.
    @Test(arguments: 0..<1000)
    func randomCodeWithInterruptsMatchesPerfect6502(_ seed: Int) {
        var rng = SplitMix64(state: 0x1000_0000 | UInt64(seed))
        let memory = OracleProgram.randomMemory(&rng)
        var irq: [PinChange] = []
        var nmi: [PinChange] = []
        var irqLevel = true, nmiLevel = true
        for cycle in stride(from: 10, to: 300, by: 1) where rng.next() % 23 == 0 {
            if rng.next() % 3 == 0 {
                nmiLevel.toggle()
                nmi.append(PinChange(cycle: cycle, level: nmiLevel))
            } else {
                irqLevel.toggle()
                irq.append(PinChange(cycle: cycle, level: irqLevel))
            }
        }
        let program = OracleProgram(memory: memory, cycles: 300, stopAtUndocumented: true, irq: irq, nmi: nmi)
        if let problem = compareWithPerfect6502(program) {
            Issue.record("seed \(seed): \(problem)")
        }
    }

    struct EdgeCase: CustomTestStringConvertible, Sendable {
        enum Kind: String, Sendable { case nmi, irq, brk }
        var kind: Kind
        /// Cycle the second NMI edge arrives, relative to the vector fetch.
        var offset: Int
        var length: Int
        var testDescription: String { "\(kind.rawValue) sequence, NMI edge at V\(offset >= 0 ? "+" : "")\(offset) for \(length)" }
    }

    static let edgeCases: [EdgeCase] = [EdgeCase.Kind.nmi, .irq, .brk].flatMap { kind in
        (-3...3).flatMap { offset in (1...4).map { EdgeCase(kind: kind, offset: offset, length: $0) } }
    }

    /// An NMI edge arriving around the vector fetch of an interrupt sequence:
    /// it may hijack the vector, be absorbed, or wait, depending on the
    /// sequence, when it arrives and how long NMI stays asserted.
    @Test(arguments: edgeCases)
    func nmiEdgeAroundVectorFetchMatchesPerfect6502(_ test: EdgeCase) {
        var memory = [UInt8](repeating: 0xEA, count: 0x10000)
        memory[0x0200] = 0x58 // CLI
        if test.kind == .brk { memory[0x0210] = 0x00 }
        memory[0x0308] = 0x40 // handler: NOPs, RTI
        memory.replaceSubrange(0xFFFA..<0x10000, with: [0x00, 0x03, 0x00, 0x02, 0x00, 0x03])
        // Vector fetch of the first sequence, from perfect6502.
        let vector = [EdgeCase.Kind.nmi: 27, .irq: 27, .brk: 37][test.kind]!
        var irq: [PinChange] = []
        var nmi: [PinChange] = []
        switch test.kind {
        case .nmi: nmi = [PinChange(cycle: 20, level: false), PinChange(cycle: 22, level: true)]
        case .irq: irq = [PinChange(cycle: 20, level: false), PinChange(cycle: 34, level: true)]
        case .brk: break
        }
        let start = vector + test.offset
        nmi += [PinChange(cycle: start, level: false), PinChange(cycle: start + test.length, level: true)]
        if let problem = compareWithPerfect6502(OracleProgram(memory: memory, cycles: 120, irq: irq, nmi: nmi)) {
            Issue.record("\(problem)")
        }
    }

    /// NMI arriving during an IRQ or BRK sequence hijacks its vector.
    @Test(arguments: 20..<110)
    func nmiDuringIRQMatchesPerfect6502(_ irqCycle: Int) {
        for delay in 0..<9 {
            let program = OracleProgram(
                memory: Self.interruptProgram(seed: 3),
                cycles: 200,
                irq: [PinChange(cycle: irqCycle, level: false), PinChange(cycle: irqCycle + 24, level: true)],
                nmi: [PinChange(cycle: irqCycle + delay, level: false), PinChange(cycle: irqCycle + delay + 4, level: true)]
            )
            if let problem = compareWithPerfect6502(program) {
                Issue.record("IRQ at \(irqCycle), NMI \(delay) later: \(problem)")
                return
            }
        }
    }
}
