import Testing
@testable import BeebCore

/// An ARM with 64K of flat RAM. Accesses at or above `limit` abort.
final class ARMTestMachine: ARMBus {
    var memory = [UInt8](repeating: 0, count: 0x10000)
    var cpu: ARM<ARMTestMachine>!
    var limit: UInt32 = 0x10000

    init() {
        cpu = ARM(bus: self)
    }

    func readWord(_ address: UInt32) -> UInt32 {
        guard address < limit else { cpu.abort(); return 0 }
        let a = Int(address)
        return UInt32(memory[a]) | UInt32(memory[a + 1]) << 8 | UInt32(memory[a + 2]) << 16 | UInt32(memory[a + 3]) << 24
    }

    func readByte(_ address: UInt32) -> UInt8 {
        guard address < limit else { cpu.abort(); return 0 }
        return memory[Int(address)]
    }

    func writeWord(_ address: UInt32, _ value: UInt32) {
        guard address < limit else { cpu.abort(); return }
        for i in 0..<4 { memory[Int(address) + i] = UInt8(truncatingIfNeeded: value >> (8 * i)) }
    }

    func writeByte(_ address: UInt32, _ value: UInt8) {
        guard address < limit else { cpu.abort(); return }
        memory[Int(address)] = value
    }

    func word(_ address: UInt32) -> UInt32 { readWord(address) }

    func load(_ words: [UInt32], at address: UInt32) {
        for (i, w) in words.enumerated() { writeWord(address + UInt32(i * 4), w) }
    }

    /// Loads `program` at `address`, starts there and runs one step per
    /// instruction (or `steps`).
    func run(_ program: [UInt32], at address: UInt32 = 0x1000, steps: Int? = nil) {
        load(program, at: address)
        cpu.pc = address
        for _ in 0..<(steps ?? program.count) { cpu.step() }
    }
}

/// Instruction encoders, enough for the tests.
enum Asm {
    static let al: UInt32 = 0xE
    // Data processing opcodes.
    static let and: UInt32 = 0, eor: UInt32 = 1, sub: UInt32 = 2, rsb: UInt32 = 3, add: UInt32 = 4, adc: UInt32 = 5
    static let sbc: UInt32 = 6, rsc: UInt32 = 7, tst: UInt32 = 8, teq: UInt32 = 9, cmp: UInt32 = 10, cmn: UInt32 = 11
    static let orr: UInt32 = 12, mov: UInt32 = 13, bic: UInt32 = 14, mvn: UInt32 = 15
    // Shift types.
    static let lsl: UInt32 = 0, lsr: UInt32 = 1, asr: UInt32 = 2, ror: UInt32 = 3

    static func imm(_ op: UInt32, s: Bool = false, rd: UInt32 = 0, rn: UInt32 = 0, _ value: UInt32,
                    rotate: UInt32 = 0, cond: UInt32 = al) -> UInt32 {
        cond << 28 | 1 << 25 | op << 21 | (s ? 1 << 20 : 0) | rn << 16 | rd << 12 | rotate << 8 | value
    }

    static func reg(_ op: UInt32, s: Bool = false, rd: UInt32 = 0, rn: UInt32 = 0, rm: UInt32,
                    shift: UInt32 = lsl, amount: UInt32 = 0, rs: UInt32? = nil, cond: UInt32 = al) -> UInt32 {
        let shifter = rs.map { $0 << 8 | shift << 5 | 1 << 4 } ?? (amount << 7 | shift << 5)
        return cond << 28 | op << 21 | (s ? 1 << 20 : 0) | rn << 16 | rd << 12 | shifter | rm
    }

    /// LDR/STR with an immediate offset.
    static func transfer(load: Bool, byte: Bool = false, rd: UInt32, rn: UInt32, offset: UInt32 = 0,
                         up: Bool = true, pre: Bool = true, writeback: Bool = false) -> UInt32 {
        al << 28 | 1 << 26 | (pre ? 1 << 24 : 0) | (up ? 1 << 23 : 0) | (byte ? 1 << 22 : 0)
            | (writeback ? 1 << 21 : 0) | (load ? 1 << 20 : 0) | rn << 16 | rd << 12 | offset
    }

    /// LDR/STR with a register offset shifted by a constant.
    static func transfer(load: Bool, rd: UInt32, rn: UInt32, rm: UInt32, shift: UInt32 = lsl, amount: UInt32 = 0,
                         up: Bool = true, pre: Bool = true, writeback: Bool = false) -> UInt32 {
        transfer(load: load, rd: rd, rn: rn, offset: amount << 7 | shift << 5 | rm, up: up, pre: pre, writeback: writeback) | 1 << 25
    }

    static func block(load: Bool, rn: UInt32, _ list: [UInt32], up: Bool, pre: Bool,
                      writeback: Bool = false, s: Bool = false) -> UInt32 {
        al << 28 | 4 << 25 | (pre ? 1 << 24 : 0) | (up ? 1 << 23 : 0) | (s ? 1 << 22 : 0)
            | (writeback ? 1 << 21 : 0) | (load ? 1 << 20 : 0) | rn << 16 | list.reduce(0) { $0 | 1 << $1 }
    }

    static func branch(from: UInt32, to: UInt32, link: Bool = false, cond: UInt32 = al) -> UInt32 {
        cond << 28 | 5 << 25 | (link ? 1 << 24 : 0) | ((to &- from &- 8) >> 2) & 0xFF_FFFF
    }

    static func swi(_ comment: UInt32) -> UInt32 { al << 28 | 0xF << 24 | comment }

    static func mul(rd: UInt32, rm: UInt32, rs: UInt32, accumulate rn: UInt32? = nil, s: Bool = false) -> UInt32 {
        al << 28 | (rn != nil ? 1 << 21 : 0) | (s ? 1 << 20 : 0) | rd << 16 | (rn ?? 0) << 12 | rs << 8 | 0x90 | rm
    }

    /// TEQP PC,#psr: sets the PSR (flags, I, F and mode) to `psr`.
    static func setPSR(_ psr: UInt32) -> UInt32 {
        // Bits 31-26 and 1-0 fit in an 8-bit value rotated right by 6.
        precondition(psr & 0x03FF_FFFC == 0)
        return imm(teq, s: true, rd: 15, rn: 15, (psr << 6 | psr >> 26) & 0xFF, rotate: 3)
    }
}

struct ARMTests {
    func machine() -> ARMTestMachine { ARMTestMachine() }

    // MARK: Reset and encoding sanity

    @Test func resetsToSupervisorWithInterruptsOff() {
        let m = machine()
        m.cpu.reset()
        #expect(m.cpu.mode == .supervisor && m.cpu.irqDisabled && m.cpu.fiqDisabled && m.cpu.pc == 0)
        #expect(m.cpu.r15 == 0x0C00_0003)
        #expect(Asm.imm(Asm.mov, rd: 0, 1) == 0xE3A0_0001)
        #expect(Asm.transfer(load: true, rd: 0, rn: 1) == 0xE591_0000)
        #expect(Asm.setPSR(0x0C00_0003) == 0xE33F_F3C3)
    }

    // MARK: Data processing and flags

    @Test func addsAndSubtractsWithFlags() {
        let m = machine()
        m.cpu[1] = 0x7FFF_FFFF
        m.cpu[2] = 1
        m.run([Asm.reg(Asm.add, s: true, rd: 0, rn: 1, rm: 2)])
        #expect(m.cpu[0] == 0x8000_0000 && m.cpu.n && !m.cpu.z && !m.cpu.c && m.cpu.v)

        m.cpu[1] = 0xFFFF_FFFF
        m.run([Asm.reg(Asm.add, s: true, rd: 0, rn: 1, rm: 2)])
        #expect(m.cpu[0] == 0 && !m.cpu.n && m.cpu.z && m.cpu.c && !m.cpu.v)

        // SUB: C is NOT borrow.
        m.cpu[1] = 5
        m.run([Asm.imm(Asm.sub, s: true, rd: 0, rn: 1, 3)])
        #expect(m.cpu[0] == 2 && m.cpu.c && !m.cpu.z)
        m.run([Asm.imm(Asm.sub, s: true, rd: 0, rn: 1, 6)])
        #expect(m.cpu[0] == 0xFFFF_FFFF && !m.cpu.c && m.cpu.n)
        // 0x80000000 - 1 overflows.
        m.cpu[1] = 0x8000_0000
        m.run([Asm.imm(Asm.sub, s: true, rd: 0, rn: 1, 1)])
        #expect(m.cpu[0] == 0x7FFF_FFFF && m.cpu.v && m.cpu.c)

        // CMP and CMN only set flags.
        m.cpu[0] = 1234
        m.cpu[1] = 7
        m.run([Asm.imm(Asm.cmp, s: true, rn: 1, 7)])
        #expect(m.cpu[0] == 1234 && m.cpu.z && m.cpu.c)
        m.run([Asm.imm(Asm.cmn, s: true, rn: 1, 7)])
        #expect(!m.cpu.z && !m.cpu.c && !m.cpu.n)

        // RSB.
        m.cpu[1] = 3
        m.run([Asm.imm(Asm.rsb, rd: 0, rn: 1, 10)])
        #expect(m.cpu[0] == 7)
    }

    @Test func carryingArithmetic() {
        let m = machine()
        // A 64-bit add: (R1:R0) + (R3:R2).
        m.cpu[0] = 0xFFFF_FFFF; m.cpu[1] = 1
        m.cpu[2] = 1; m.cpu[3] = 2
        m.run([Asm.reg(Asm.add, s: true, rd: 4, rn: 0, rm: 2), Asm.reg(Asm.adc, rd: 5, rn: 1, rm: 3)])
        #expect(m.cpu[4] == 0 && m.cpu[5] == 4)
        // SBC subtracts the borrow (NOT C).
        m.cpu.c = false
        m.cpu[1] = 10
        m.run([Asm.imm(Asm.sbc, rd: 0, rn: 1, 3)])
        #expect(m.cpu[0] == 6)
        m.cpu.c = true
        m.run([Asm.imm(Asm.sbc, rd: 0, rn: 1, 3)])
        #expect(m.cpu[0] == 7)
        m.cpu.c = false
        m.run([Asm.imm(Asm.rsc, rd: 0, rn: 1, 20)])
        #expect(m.cpu[0] == 9)
    }

    @Test func logicalOpsKeepVAndTakeTheShifterCarry() {
        let m = machine()
        m.cpu.v = true
        m.cpu.c = false
        // MOVS R0,#&80000000 (2 ROR 2): C is bit 31 of the rotated value.
        m.run([Asm.imm(Asm.mov, s: true, rd: 0, 2, rotate: 1)])
        #expect(m.cpu[0] == 0x8000_0000 && m.cpu.c && m.cpu.n && m.cpu.v)
        // An unrotated immediate leaves C alone.
        m.run([Asm.imm(Asm.mov, s: true, rd: 0, 0)])
        #expect(m.cpu.z && m.cpu.c && m.cpu.v)
        m.cpu[1] = 0xF0F0; m.cpu[2] = 0xFF00
        m.run([Asm.reg(Asm.and, rd: 3, rn: 1, rm: 2), Asm.reg(Asm.eor, rd: 4, rn: 1, rm: 2),
               Asm.reg(Asm.orr, rd: 5, rn: 1, rm: 2), Asm.reg(Asm.bic, rd: 6, rn: 1, rm: 2),
               Asm.reg(Asm.mvn, rd: 7, rm: 2)])
        #expect(m.cpu[3] == 0xF000 && m.cpu[4] == 0x0FF0 && m.cpu[5] == 0xFFF0 && m.cpu[6] == 0x00F0 && m.cpu[7] == 0xFFFF_00FF)
        // TST/TEQ without S do nothing.
        m.cpu.z = false
        m.run([Asm.imm(Asm.tst, s: false, rn: 1, 0)])
        #expect(!m.cpu.z)
        m.run([Asm.imm(Asm.tst, s: true, rn: 1, 0)])
        #expect(m.cpu.z)
        m.run([Asm.reg(Asm.teq, s: true, rn: 1, rm: 1)])
        #expect(m.cpu.z)
    }

    // MARK: Shifts

    @Test func immediateShifts() {
        let m = machine()
        m.cpu[1] = 0x8000_0001
        m.run([Asm.reg(Asm.mov, s: true, rd: 0, rm: 1, shift: Asm.lsl, amount: 1)])
        #expect(m.cpu[0] == 2 && m.cpu.c)
        m.run([Asm.reg(Asm.mov, s: true, rd: 0, rm: 1, shift: Asm.lsr, amount: 1)])
        #expect(m.cpu[0] == 0x4000_0000 && m.cpu.c)
        m.run([Asm.reg(Asm.mov, s: true, rd: 0, rm: 1, shift: Asm.asr, amount: 4)])
        #expect(m.cpu[0] == 0xF800_0000 && !m.cpu.c)
        m.run([Asm.reg(Asm.mov, s: true, rd: 0, rm: 1, shift: Asm.ror, amount: 4)])
        #expect(m.cpu[0] == 0x1800_0000 && !m.cpu.c)
        // LSR #0 is LSR #32, ASR #0 is ASR #32.
        m.run([Asm.reg(Asm.mov, s: true, rd: 0, rm: 1, shift: Asm.lsr, amount: 0)])
        #expect(m.cpu[0] == 0 && m.cpu.c && m.cpu.z)
        m.run([Asm.reg(Asm.mov, s: true, rd: 0, rm: 1, shift: Asm.asr, amount: 0)])
        #expect(m.cpu[0] == 0xFFFF_FFFF && m.cpu.c)
        // LSL #0 leaves C alone.
        m.cpu.c = false
        m.run([Asm.reg(Asm.mov, s: true, rd: 0, rm: 1)])
        #expect(m.cpu[0] == 0x8000_0001 && !m.cpu.c)
    }

    @Test func rrx() {
        let m = machine()
        m.cpu[1] = 0x0000_0003
        m.cpu.c = true
        // ROR #0 is RRX: C into bit 31, bit 0 out to C.
        m.run([Asm.reg(Asm.mov, s: true, rd: 0, rm: 1, shift: Asm.ror, amount: 0)])
        #expect(m.cpu[0] == 0x8000_0001 && m.cpu.c)
        m.cpu.c = false
        m.cpu[1] = 2
        m.run([Asm.reg(Asm.mov, s: true, rd: 0, rm: 1, shift: Asm.ror, amount: 0)])
        #expect(m.cpu[0] == 1 && !m.cpu.c)
    }

    @Test func registerSpecifiedShifts() {
        let m = machine()
        m.cpu[1] = 0x8000_0001
        func shift(_ type: UInt32, by amount: UInt32) {
            m.cpu[2] = amount
            m.run([Asm.reg(Asm.mov, s: true, rd: 0, rm: 1, shift: type, rs: 2)])
        }
        // A zero amount changes nothing, not even C.
        m.cpu.c = true
        shift(Asm.lsr, by: 0)
        #expect(m.cpu[0] == 0x8000_0001 && m.cpu.c)
        m.cpu.c = false
        shift(Asm.lsl, by: 0x100)  // only the bottom byte counts
        #expect(m.cpu[0] == 0x8000_0001 && !m.cpu.c)
        shift(Asm.lsl, by: 32)
        #expect(m.cpu[0] == 0 && m.cpu.c)
        shift(Asm.lsl, by: 33)
        #expect(m.cpu[0] == 0 && !m.cpu.c)
        shift(Asm.lsr, by: 32)
        #expect(m.cpu[0] == 0 && m.cpu.c)
        shift(Asm.lsr, by: 33)
        #expect(m.cpu[0] == 0 && !m.cpu.c)
        shift(Asm.asr, by: 40)
        #expect(m.cpu[0] == 0xFFFF_FFFF && m.cpu.c)
        shift(Asm.ror, by: 32)
        #expect(m.cpu[0] == 0x8000_0001 && m.cpu.c)
        shift(Asm.ror, by: 36)
        #expect(m.cpu[0] == 0x1800_0000 && !m.cpu.c)
        shift(Asm.lsl, by: 31)
        #expect(m.cpu[0] == 0x8000_0000 && !m.cpu.c)
    }

    // MARK: R15

    @Test func pcReadsEightAhead() {
        let m = machine()
        m.cpu.reset()
        // MOV R0,PC: PC+8 with the PSR (supervisor, I and F set).
        m.run([Asm.reg(Asm.mov, rd: 0, rm: 15)], at: 0x1000)
        #expect(m.cpu[0] == 0x0C00_1008 | 3)
        // As Rn the PSR isn't included.
        m.run([Asm.imm(Asm.add, rd: 0, rn: 15, 0)], at: 0x1000)
        #expect(m.cpu[0] == 0x1008)
        // With a register-specified shift, R15 is read 12 ahead.
        m.cpu[1] = 0
        m.run([Asm.reg(Asm.mov, rd: 0, rm: 15, rs: 1)], at: 0x1000)
        #expect(m.cpu[0] == 0x0C00_100C | 3)
        m.run([Asm.reg(Asm.add, rd: 0, rn: 15, rm: 1, rs: 1)], at: 0x1000)
        #expect(m.cpu[0] == 0x100C)
        // STR PC stores PC+12 (with the PSR).
        m.cpu[1] = 0x2000
        m.run([Asm.transfer(load: false, rd: 15, rn: 1)], at: 0x1000)
        #expect(m.word(0x2000) == 0x0C00_100C | 3)
        // A PC-relative load.
        m.load([0xCAFE_F00D], at: 0x1010)
        m.run([Asm.transfer(load: true, rd: 0, rn: 15, offset: 8)], at: 0x1000)
        #expect(m.cpu[0] == 0xCAFE_F00D)
    }

    @Test func writingPCBranchesAndKeepsThePSR() {
        let m = machine()
        m.cpu.reset()
        m.cpu[1] = 0xFC00_2003  // PSR bits are masked off
        m.run([Asm.reg(Asm.mov, rd: 15, rm: 1)])
        #expect(m.cpu.pc == 0x2000 && m.cpu.mode == .supervisor && !m.cpu.n)
        // MOVS PC,R14 restores the PSR from R14.
        m.cpu[14] = 0x8000_3000  // N set, user mode
        m.run([Asm.reg(Asm.mov, s: true, rd: 15, rm: 14)])
        #expect(m.cpu.pc == 0x3000 && m.cpu.mode == .user && m.cpu.n && !m.cpu.irqDisabled)
    }

    // MARK: Branches

    @Test func branches() {
        let m = machine()
        m.cpu.reset()
        m.run([Asm.branch(from: 0x1000, to: 0x1100)], at: 0x1000)
        #expect(m.cpu.pc == 0x1100)
        m.run([Asm.branch(from: 0x1100, to: 0x0F00)], at: 0x1100)
        #expect(m.cpu.pc == 0x0F00)
        // BL: R14 is the return address with the PSR.
        m.run([Asm.branch(from: 0x1000, to: 0x4000, link: true)], at: 0x1000)
        #expect(m.cpu.pc == 0x4000 && m.cpu[14] == 0x0C00_1004 | 3)
        // Not taken.
        m.cpu.z = false
        m.run([Asm.branch(from: 0x1000, to: 0x4000, cond: 0x0)], at: 0x1000)
        #expect(m.cpu.pc == 0x1004)
    }

    // MARK: Conditions

    @Test func conditionCodes() {
        // Tarmac's table: each row is a condition, each column NZCV (N the
        // most significant).
        let table: [[UInt8]] = [
            [0, 0, 0, 0, 1, 1, 1, 1, 0, 0, 0, 0, 1, 1, 1, 1], // EQ
            [1, 1, 1, 1, 0, 0, 0, 0, 1, 1, 1, 1, 0, 0, 0, 0], // NE
            [0, 0, 1, 1, 0, 0, 1, 1, 0, 0, 1, 1, 0, 0, 1, 1], // CS
            [1, 1, 0, 0, 1, 1, 0, 0, 1, 1, 0, 0, 1, 1, 0, 0], // CC
            [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1], // MI
            [1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0], // PL
            [0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1], // VS
            [1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0], // VC
            [0, 0, 1, 1, 0, 0, 0, 0, 0, 0, 1, 1, 0, 0, 0, 0], // HI
            [1, 1, 0, 0, 1, 1, 1, 1, 1, 1, 0, 0, 1, 1, 1, 1], // LS
            [1, 0, 1, 0, 1, 0, 1, 0, 0, 1, 0, 1, 0, 1, 0, 1], // GE
            [0, 1, 0, 1, 0, 1, 0, 1, 1, 0, 1, 0, 1, 0, 1, 0], // LT
            [1, 0, 1, 0, 0, 0, 0, 0, 0, 1, 0, 1, 0, 0, 0, 0], // GT
            [0, 1, 0, 1, 1, 1, 1, 1, 1, 0, 1, 0, 1, 1, 1, 1], // LE
            [1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1], // AL
            [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0], // NV
        ]
        let m = machine()
        for cond in 0..<16 {
            for flags in 0..<16 {
                m.cpu.n = flags & 8 != 0
                m.cpu.z = flags & 4 != 0
                m.cpu.c = flags & 2 != 0
                m.cpu.v = flags & 1 != 0
                m.cpu[0] = 0
                m.run([Asm.imm(Asm.mov, rd: 0, 1, cond: UInt32(cond))])
                #expect(m.cpu[0] == UInt32(table[cond][flags]), "condition \(cond) flags \(flags)")
            }
        }
    }

    // MARK: LDR/STR

    @Test func singleTransfers() {
        let m = machine()
        m.cpu[1] = 0x2000
        m.cpu[0] = 0x1122_3344
        // STR R0,[R1,#4]!
        m.run([Asm.transfer(load: false, rd: 0, rn: 1, offset: 4, writeback: true)])
        #expect(m.word(0x2004) == 0x1122_3344 && m.cpu[1] == 0x2004)
        // LDR R2,[R1],#-4 (post-indexed: always writes back).
        m.run([Asm.transfer(load: true, rd: 2, rn: 1, offset: 4, up: false, pre: false)])
        #expect(m.cpu[2] == 0x1122_3344 && m.cpu[1] == 0x2000)
        // Bytes.
        m.run([Asm.transfer(load: true, byte: true, rd: 3, rn: 1, offset: 5)])
        #expect(m.cpu[3] == 0x33)
        m.cpu[4] = 0xAB
        m.run([Asm.transfer(load: false, byte: true, rd: 4, rn: 1, offset: 7)])
        #expect(m.word(0x2004) == 0xAB22_3344)
        // An unaligned word load rotates the addressed byte to the bottom.
        m.run([Asm.transfer(load: true, rd: 5, rn: 1, offset: 5)])
        #expect(m.cpu[5] == 0x44AB_2233)
        // Register offsets, shifted.
        m.cpu[6] = 1
        m.run([Asm.transfer(load: true, rd: 7, rn: 1, rm: 6, shift: Asm.lsl, amount: 2)])
        #expect(m.cpu[7] == 0xAB22_3344)
        // A loaded base wins over writeback.
        m.cpu[1] = 0x2004
        m.load([0x5555], at: 0x2008)
        m.run([Asm.transfer(load: true, rd: 1, rn: 1, offset: 4, writeback: true)])
        #expect(m.cpu[1] == 0x5555)
        // Loading the PC branches; the PSR is untouched.
        m.load([0xF000_3000], at: 0x2100)
        m.cpu[1] = 0x2100
        m.cpu.reset()
        m.cpu[1] = 0x2100
        m.run([Asm.transfer(load: true, rd: 15, rn: 1)])
        #expect(m.cpu.pc == 0x3000 && !m.cpu.n && m.cpu.mode == .supervisor)
    }

    @Test func registerShiftedOffsetsAreUndefined() {
        let m = machine()
        m.cpu.reset()
        // Bit 4 set in a register-offset LDR is the undefined instruction.
        m.run([Asm.transfer(load: true, rd: 0, rn: 1, rm: 2) | 0x10], at: 0x1000)
        #expect(m.cpu.pc == ARM<ARMTestMachine>.undefinedVector && m.cpu[14] & ARM<ARMTestMachine>.pcMask == 0x1004)
    }

    // MARK: LDM/STM

    @Test func blockTransfersWithWriteback() {
        let m = machine()
        m.cpu[13] = 0x3000
        for r in 0...3 { m.cpu[r] = 0x100 + UInt32(r) }
        m.cpu[14] = 0x1234
        // STMFD R13!,{R0-R3,R14}
        m.run([Asm.block(load: false, rn: 13, [0, 1, 2, 3, 14], up: false, pre: true, writeback: true)])
        #expect(m.cpu[13] == 0x3000 - 20)
        #expect(m.word(0x2FEC) == 0x100 && m.word(0x2FF8) == 0x103 && m.word(0x2FFC) == 0x1234)
        // LDMFD R13!,{R4-R7,PC}
        m.run([Asm.block(load: true, rn: 13, [4, 5, 6, 7, 15], up: true, pre: false, writeback: true)])
        #expect(m.cpu[13] == 0x3000 && m.cpu[4] == 0x100 && m.cpu[7] == 0x103 && m.cpu.pc == 0x1234)
        // IB and DA.
        m.cpu[0] = 0x4000
        m.run([Asm.block(load: false, rn: 0, [1, 2], up: true, pre: true, writeback: true)])
        #expect(m.word(0x4004) == 0x101 && m.word(0x4008) == 0x102 && m.cpu[0] == 0x4008)
        m.run([Asm.block(load: true, rn: 0, [5, 6], up: false, pre: false, writeback: true)])
        #expect(m.cpu[5] == 0x101 && m.cpu[6] == 0x102 && m.cpu[0] == 0x4000)
    }

    @Test func storingTheBase() {
        let m = machine()
        // The base first in the list: the original value is stored.
        m.cpu[1] = 0x5000
        m.cpu[2] = 0x22
        m.run([Asm.block(load: false, rn: 1, [1, 2], up: true, pre: false, writeback: true)])
        #expect(m.word(0x5000) == 0x5000 && m.cpu[1] == 0x5008)
        // Not first: the written-back value.
        m.cpu[0] = 0x11
        m.cpu[1] = 0x6000
        m.run([Asm.block(load: false, rn: 1, [0, 1], up: true, pre: false, writeback: true)])
        #expect(m.word(0x6004) == 0x6008)
    }

    @Test func blockTransfersWithTheSBit() {
        let m = machine()
        m.cpu.reset()
        // Give user mode its own R13/R14.
        m.cpu.setRegister(13, mode: .user, 0xAAAA)
        m.cpu.setRegister(14, mode: .user, 0xBBBB)
        m.cpu[13] = 0x7000
        m.cpu[14] = 0xCCCC
        // STMIA R0,{R13,R14}^ in supervisor mode stores the user ones.
        m.cpu[0] = 0x7100
        m.run([Asm.block(load: false, rn: 0, [13, 14], up: true, pre: false, s: true)])
        #expect(m.word(0x7100) == 0xAAAA && m.word(0x7104) == 0xBBBB)
        // LDMIA R0,{R13,R14}^ loads them.
        m.load([0x1111, 0x2222], at: 0x7200)
        m.cpu[0] = 0x7200
        m.run([Asm.block(load: true, rn: 0, [13, 14], up: true, pre: false, s: true)])
        #expect(m.cpu.register(13, mode: .user) == 0x1111 && m.cpu.register(14, mode: .user) == 0x2222)
        #expect(m.cpu[13] == 0x7000 && m.cpu[14] == 0xCCCC)
        // With PC in the list, the PSR comes back too: a return to user
        // mode with the flags.
        m.load([0x9, 0x6000_4000], at: 0x7300)
        m.cpu[0] = 0x7300
        m.run([Asm.block(load: true, rn: 0, [1, 15], up: true, pre: false, s: true)])
        #expect(m.cpu.pc == 0x4000 && m.cpu.mode == .user && m.cpu.z && m.cpu.c && !m.cpu.irqDisabled)
        #expect(m.cpu[1] == 9 && m.cpu[13] == 0x1111)
    }

    // MARK: Modes

    @Test func modeSwitchesBankRegisters() {
        let m = machine()
        m.cpu.reset()
        for r in 0...14 { m.cpu[r] = 0x100 + UInt32(r) }
        // To FIQ mode: R8-R14 are its own.
        m.run([Asm.setPSR(0x0C00_0001)])
        #expect(m.cpu.mode == .fiq)
        #expect(m.cpu[7] == 0x107 && m.cpu[8] == 0 && m.cpu[14] == 0)
        m.cpu[8] = 0xF8
        m.cpu[13] = 0xFD
        // To IRQ mode: R8-R12 are the user's again, R13-R14 IRQ's.
        m.run([Asm.setPSR(0x0C00_0002)])
        #expect(m.cpu.mode == .irq && m.cpu[8] == 0x108 && m.cpu[12] == 0x10C && m.cpu[13] == 0)
        m.cpu[13] = 0x1D
        // Back to supervisor.
        m.run([Asm.setPSR(0x0C00_0003)])
        #expect(m.cpu[13] == 0x10D && m.cpu[14] == 0x10E)
        #expect(m.cpu.register(8, mode: .fiq) == 0xF8 && m.cpu.register(13, mode: .fiq) == 0xFD)
        #expect(m.cpu.register(13, mode: .irq) == 0x1D && m.cpu.register(8, mode: .irq) == 0x108)
        // To user mode; it can't get back by writing the PSR.
        m.run([Asm.setPSR(0x0000_0000)])
        #expect(m.cpu.mode == .user && !m.cpu.irqDisabled)
        m.run([Asm.setPSR(0xF000_0003)])
        #expect(m.cpu.mode == .user && m.cpu.n && m.cpu.z && m.cpu.c && m.cpu.v && !m.cpu.irqDisabled)
    }

    // MARK: Exceptions

    @Test func swiEntersSupervisorMode() {
        let m = machine()
        m.cpu.reset()
        m.run([Asm.setPSR(0x2000_0000)])  // user mode, C set, interrupts on
        m.run([Asm.swi(0x11)], at: 0x1000)
        #expect(m.cpu.mode == .supervisor && m.cpu.pc == ARM<ARMTestMachine>.swiVector)
        #expect(m.cpu.irqDisabled && !m.cpu.fiqDisabled)
        #expect(m.cpu[14] == 0x2000_1004)
        // MOVS PC,R14 goes back.
        m.run([Asm.reg(Asm.mov, s: true, rd: 15, rm: 14)], at: 0x8)
        #expect(m.cpu.mode == .user && m.cpu.pc == 0x1004 && m.cpu.c && !m.cpu.irqDisabled)
    }

    @Test func interrupts() {
        let m = machine()
        m.cpu.reset()
        m.run([Asm.setPSR(0x0000_0000)], at: 0x1000)  // user mode, interrupts on
        #expect(m.cpu.pc == 0x1004)
        // IRQ: taken before the next instruction.
        m.cpu.irq = true
        m.cpu.step()
        #expect(m.cpu.mode == .irq && m.cpu.pc == ARM<ARMTestMachine>.irqVector && m.cpu.irqDisabled && !m.cpu.fiqDisabled)
        #expect(m.cpu[14] == 0x1008)
        // Held off while I is set.
        m.load([Asm.imm(Asm.mov, rd: 0, 1)], at: 0x18)
        m.cpu.step()
        #expect(m.cpu.pc == 0x1C && m.cpu[0] == 1)
        // FIQ isn't.
        m.cpu.fiq = true
        m.cpu.step()
        #expect(m.cpu.mode == .fiq && m.cpu.pc == ARM<ARMTestMachine>.fiqVector && m.cpu.fiqDisabled)
        #expect(m.cpu[14] == (0x20 | 0x0800_0002))
        // SUBS PC,R14,#4 returns from it to the IRQ handler.
        m.cpu.fiq = false
        m.run([Asm.imm(Asm.sub, s: true, rd: 15, rn: 14, 4)], at: 0x1C)
        #expect(m.cpu.mode == .irq && m.cpu.pc == 0x1C && !m.cpu.fiqDisabled)
        // And from that to the user program.
        m.cpu.irq = false
        m.run([Asm.imm(Asm.sub, s: true, rd: 15, rn: 14, 4)], at: 0x1C)
        #expect(m.cpu.mode == .user && m.cpu.pc == 0x1004 && !m.cpu.irqDisabled)
    }

    @Test func undefinedAndAborts() {
        let m = machine()
        m.cpu.reset()
        // A coprocessor instruction: undefined.
        m.run([0xEE00_0000], at: 0x1000)
        #expect(m.cpu.pc == ARM<ARMTestMachine>.undefinedVector && m.cpu[14] == 0x0C00_1004 | 3)
        // An address beyond 26 bits.
        m.cpu[1] = 0x0400_0000
        m.run([Asm.transfer(load: true, rd: 0, rn: 1)], at: 0x1000)
        #expect(m.cpu.pc == ARM<ARMTestMachine>.addressExceptionVector)
        // A bus abort: a data abort, nothing loaded.
        m.cpu[0] = 7
        m.cpu[1] = 0x2_0000
        m.run([Asm.transfer(load: true, rd: 0, rn: 1)], at: 0x1000)
        #expect(m.cpu.pc == ARM<ARMTestMachine>.dataAbortVector && m.cpu[0] == 7 && m.cpu[14] & ARM<ARMTestMachine>.pcMask == 0x1008)
        // And fetching from there, a prefetch abort.
        m.cpu.pc = 0x2_0000
        m.cpu.step()
        #expect(m.cpu.pc == ARM<ARMTestMachine>.prefetchAbortVector && m.cpu[14] & ARM<ARMTestMachine>.pcMask == 0x2_0004)
    }

    // MARK: Multiply

    @Test func multiply() {
        let m = machine()
        m.cpu[1] = 7; m.cpu[2] = 6; m.cpu[3] = 100
        m.run([Asm.mul(rd: 0, rm: 1, rs: 2)])
        #expect(m.cpu[0] == 42)
        m.run([Asm.mul(rd: 0, rm: 1, rs: 2, accumulate: 3)])
        #expect(m.cpu[0] == 142)
        m.cpu[1] = 0xFFFF_FFFF
        m.run([Asm.mul(rd: 0, rm: 1, rs: 2, s: true)])
        #expect(m.cpu[0] == 0xFFFF_FFFA && m.cpu.n && !m.cpu.z)
    }

    // MARK: Disassembler

    @Test func disassembles() {
        let d = ARMDisassembler()
        func text(_ i: UInt32, at address: UInt32 = 0x1000) -> String {
            d.disassemble(at: address) { _ in i }.text
        }
        #expect(text(Asm.imm(Asm.mov, rd: 0, 1)) == "MOV R0,#1")
        #expect(text(Asm.imm(Asm.add, s: true, rd: 1, rn: 2, 0xFF, cond: 0)) == "ADDEQS R1,R2,#&FF")
        #expect(text(Asm.reg(Asm.mov, rd: 0, rm: 1, shift: Asm.lsl, amount: 2)) == "MOV R0,R1,LSL #2")
        #expect(text(Asm.reg(Asm.mov, rd: 0, rm: 1, shift: Asm.ror, amount: 0)) == "MOV R0,R1,RRX")
        #expect(text(Asm.reg(Asm.orr, rd: 0, rn: 0, rm: 1, shift: Asm.asr, rs: 2)) == "ORR R0,R0,R1,ASR R2")
        #expect(text(Asm.reg(Asm.cmp, s: true, rn: 3, rm: 4)) == "CMP R3,R4")
        #expect(text(Asm.setPSR(0x0C00_0003)) == "TEQP PC,#&0C000003")
        #expect(text(Asm.transfer(load: true, rd: 0, rn: 1, offset: 4, writeback: true)) == "LDR R0,[R1,#4]!")
        #expect(text(Asm.transfer(load: false, byte: true, rd: 2, rn: 3, offset: 0x10, up: false, pre: false)) == "STRB R2,[R3],#-&10")
        #expect(text(Asm.transfer(load: true, rd: 0, rn: 15, offset: 8)) == "LDR R0,&00001010")
        #expect(text(Asm.block(load: false, rn: 13, [0, 1, 2, 3, 14], up: false, pre: true, writeback: true)) == "STMDB R13!,{R0-R3,R14}")
        #expect(text(Asm.block(load: true, rn: 13, [4, 5, 15], up: true, pre: false, writeback: true, s: true)) == "LDMIA R13!,{R4,R5,PC}^")
        #expect(text(Asm.branch(from: 0x1000, to: 0x0F00, link: true)) == "BL &00000F00")
        #expect(text(Asm.swi(0x11)) == "SWI &000011")
        #expect(text(Asm.mul(rd: 0, rm: 1, rs: 2, accumulate: 3, s: true)) == "MLAS R0,R1,R2,R3")
        #expect(d.disassemble(at: 0) { _ in 0 }.length == 4)
    }
}
