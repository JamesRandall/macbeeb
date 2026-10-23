// Cycle-accurate 6502/65C02 core.
//
// A port of b2's 6502 simulator (Copyright (C) Tom Seddon, GPLv3).
//
// The CPU never touches memory itself. Each call to `tick()` runs phase 2 of
// the current cycle and phase 1 of the next, leaving `abus` and `access`
// describing the next bus access. The host then performs it: for a read, it
// puts the value into `dbus`; for a write, it stores `dbus`. Because the host
// sees every cycle, it can stretch cycles (1MHz bus) and keep devices in step.
//
// Most per-cycle sequences are generated (M6502+Generated.swift, from
// M6502GenKit); the irregular ones are in M6502+Special.swift. Each sequence
// does the bus work and calls `execute(op)` for the ALU part.
//
// Interrupts are checked in phase 1 of each instruction's last cycle. A
// pending IRQ/NMI clears `d1x1`, and `nextInstruction()` then starts the
// interrupt sequence instead of fetching an opcode.

public final class M6502 {
    public enum Variant: String, Sendable, CaseIterable {
        /// NMOS 6502 with undocumented instructions (BBC Model B).
        case nmos
        /// CMOS 65C02/65SC12 without the Rockwell bit instructions (Master 128).
        case cmos
        /// Rockwell 65C02 (6502 Second Processor).
        case rockwell
    }

    public enum BusAccess: UInt8, Sendable {
        case write
        case data
        /// Instruction operand fetch.
        case instruction
        /// Indirect address fetch.
        case address
        /// A dummy access whose result is ignored.
        case dummy
        /// Opcode fetch: the CPU is about to execute the instruction at `abus`.
        case opcode
        /// Opcode fetch that's been discarded because an interrupt is due.
        case interrupt
    }

    struct OpcodeEntry {
        var t0: State
        var op: Op
    }

    public let variant: Variant
    public let instructionInfo: [M6502InstructionInfo]

    // MARK: Pins

    /// Address of the pending bus access.
    public var abus: UInt16 = 0
    /// Data for a pending write, or the value read for a pending read.
    public var dbus: UInt8 = 0
    /// Type of the pending bus access.
    public var access: BusAccess = .opcode

    // MARK: Registers

    public var a: UInt8 = 0
    public var x: UInt8 = 0
    public var y: UInt8 = 0
    /// Stack pointer (low byte; the stack is always in page 1).
    public var s: UInt8 = 0
    public var pc: UInt16 = 0

    public var c = false
    public var z = false
    public var i = false
    public var d = false
    public var v = false
    public var n = false

    // MARK: Internal state

    /// Data address.
    var ad: UInt16 = 0
    /// Indirect address.
    var ia: UInt16 = 0
    /// Operand, or result to write.
    var data: UInt8 = 0
    var opcode: UInt8 = 0
    var op: Op = .none
    /// Carry out of the low byte in an indexed address calculation.
    var acarry = false
    /// Low when an interrupt is due. Also the B flag in pushed P.
    var d1x1 = true
    var state: State = .decode
    /// NMOS interrupt sequence: true to use the NMI vector.
    var nmiVector = false
    /// NMOS BRK/IRQ sequence: an NMI edge arrived during the vector fetch,
    /// and is kept if NMI is still asserted a cycle later.
    var nmiRecheck = false

    /// IRQ/NMI requests seen since the last check, one bit per device.
    var irqFlags: UInt8 = 0
    var nmiFlags: UInt8 = 0
    /// Current IRQ/NMI levels, one bit per device.
    var deviceIRQFlags: UInt8 = 0
    var deviceNMIFlags: UInt8 = 0

    /// Address of the last opcode fetched.
    public internal(set) var opcodePC: UInt16 = 0

    let opcodes: UnsafePointer<OpcodeEntry>
    let interruptState: State
    let xaaMagic: UInt8

    public init(variant: Variant) {
        self.variant = variant
        switch variant {
        case .nmos:
            opcodes = M6502.nmosTable
            interruptState = .Interrupt_0
            xaaMagic = 0xEE
            instructionInfo = M6502InstructionInfo.nmos
        case .cmos:
            opcodes = M6502.cmosTable
            interruptState = .InterruptCMOS_0
            xaaMagic = 0
            instructionInfo = M6502InstructionInfo.cmos
        case .rockwell:
            opcodes = M6502.rockwellTable
            interruptState = .InterruptCMOS_0
            xaaMagic = 0
            instructionInfo = M6502InstructionInfo.rockwell
        }
        reset()
    }

    nonisolated(unsafe) static let nmosTable = makeTable(nmosOpcodes)
    nonisolated(unsafe) static let cmosTable = makeTable(cmosOpcodes)
    nonisolated(unsafe) static let rockwellTable = makeTable(rockwellOpcodes)

    private static func makeTable(_ entries: [OpcodeEntry]) -> UnsafePointer<OpcodeEntry> {
        precondition(entries.count == 256)
        let table = UnsafeMutablePointer<OpcodeEntry>.allocate(capacity: 256)
        table.initialize(from: entries, count: 256)
        return UnsafePointer(table)
    }

    // MARK: Control

    /// Starts the reset sequence. It sets I (and on CMOS clears D); the other
    /// registers are left as they are, as on the real chip.
    public func reset() {
        d1x1 = true
        state = .Reset_0
    }

    /// Puts the CPU in the state it would be in after executing a HLT/KIL
    /// instruction.
    public func halt() {
        abus = 0xFFFF
        access = .dummy
        state = .HLT_4
    }

    /// True when the pending access is an opcode fetch: the previous
    /// instruction has finished and `abus` is the address of the next one.
    @inline(__always)
    public var isAboutToExecute: Bool { access == .opcode }

    /// Abandons whatever the CPU was doing and sets up an opcode fetch from
    /// `address`, as if an instruction had just finished there. Any pending
    /// interrupt is forgotten. On return, `abus` is `address` and `access`
    /// is `.opcode`.
    public func start(at address: UInt16) {
        d1x1 = true
        pc = address
        nextInstruction()
    }

    /// Restarts execution at `address`. Only valid when `isAboutToExecute`.
    public func jump(to address: UInt16) {
        precondition(isAboutToExecute)
        pc = address
        nextInstruction()
    }

    /// Asserts or releases IRQ for the devices in `mask`.
    public func setIRQ(_ mask: UInt8, _ asserted: Bool) {
        precondition(mask != 0)
        if asserted {
            deviceIRQFlags |= mask
        } else {
            deviceIRQFlags &= ~mask
        }
        irqFlags = deviceIRQFlags
    }

    /// Asserts or releases NMI for the devices in `mask`. NMI is edge
    /// triggered: only a device going from released to asserted causes one.
    public func setNMI(_ mask: UInt8, _ asserted: Bool) {
        precondition(mask != 0)
        if asserted {
            nmiFlags |= ~deviceNMIFlags & mask
            deviceNMIFlags |= mask
        } else {
            deviceNMIFlags &= ~mask
        }
    }

    /// The status register as the CPU would push it with PHP.
    public var p: UInt8 {
        get {
            var value: UInt8 = 0x20
            if n { value |= 0x80 }
            if v { value |= 0x40 }
            if d1x1 { value |= 0x10 }
            if d { value |= 0x08 }
            if i { value |= 0x04 }
            if z { value |= 0x02 }
            if c { value |= 0x01 }
            return value
        }
        set {
            setP(newValue)
        }
    }

    // MARK: Helpers for the state machine

    @inline(__always)
    func setP(_ value: UInt8) {
        n = value & 0x80 != 0
        v = value & 0x40 != 0
        d = value & 0x08 != 0
        i = value & 0x04 != 0
        z = value & 0x02 != 0
        c = value & 0x01 != 0
    }

    @inline(__always)
    func checkForInterrupts() {
        if irqFlags != 0 && !i {
            d1x1 = false
        } else if nmiFlags != 0 {
            // nmiFlags is reset by the interrupt sequence.
            d1x1 = false
        }
    }

    /// Phase 1 of T0: fetch the next opcode, or start an interrupt.
    @inline(__always)
    func nextInstruction() {
        abus = pc
        if !d1x1 {
            access = .interrupt
            state = interruptState
        } else {
            pc &+= 1
            opcodePC = abus
            access = .opcode
            state = .decode
        }
    }

    @inline(__always)
    private func setNZ(_ value: UInt8) {
        n = value & 0x80 != 0
        z = value == 0
    }

    @inline(__always)
    private func compare(_ reg: UInt8) {
        c = reg >= data
        z = reg == data
        n = (reg &- data) & 0x80 != 0
    }

    @inline(__always)
    private func asl(_ value: UInt8) -> UInt8 {
        c = value & 0x80 != 0
        let result = value << 1
        setNZ(result)
        return result
    }

    @inline(__always)
    private func lsr(_ value: UInt8) -> UInt8 {
        c = value & 1 != 0
        let result = value >> 1
        setNZ(result)
        return result
    }

    @inline(__always)
    private func rol(_ value: UInt8) -> UInt8 {
        let result = value << 1 | (c ? 1 : 0)
        c = value & 0x80 != 0
        setNZ(result)
        return result
    }

    @inline(__always)
    private func ror(_ value: UInt8) -> UInt8 {
        let result = value >> 1 | (c ? 0x80 : 0)
        c = value & 1 != 0
        setNZ(result)
        return result
    }

    @inline(__always)
    private func adcBinary() {
        let result = UInt16(a) + UInt16(data) + (c ? 1 : 0)
        let low = UInt8(truncatingIfNeeded: result)
        setNZ(low)
        c = result > 0xFF
        v = ~(a ^ data) & (a ^ low) & 0x80 != 0
        a = low
    }

    @inline(__always)
    private func sbcBinary() {
        let result = UInt16(a) + UInt16(~data) + (c ? 1 : 0)
        let low = UInt8(truncatingIfNeeded: result)
        setNZ(low)
        c = result > 0xFF
        v = (a ^ data) & (a ^ low) & 0x80 != 0
        a = low
    }

    private func adcNMOS() {
        guard d else { return adcBinary() }
        let carry: UInt32 = c ? 1 : 0
        let a = UInt32(self.a), data = UInt32(self.data)
        var tmp = (a & 0xF) + (data & 0xF) + carry
        if tmp > 9 {
            tmp += 6
        }
        if tmp <= 0xF {
            tmp = (tmp & 0xF) + (a & 0xF0) + (data & 0xF0)
        } else {
            tmp = (tmp & 0xF) + (a & 0xF0) + (data & 0xF0) + 0x10
        }
        z = (a + data + carry) & 0xFF == 0
        n = tmp & 0x80 != 0
        v = (a ^ tmp) & 0x80 != 0 && (a ^ data) & 0x80 == 0
        if tmp & 0x1F0 > 0x90 {
            tmp += 0x60
        }
        c = tmp & 0xFF0 > 0xF0
        self.a = UInt8(truncatingIfNeeded: tmp)
    }

    private func adcCMOS() {
        guard d else { return adcBinary() }
        let a = UInt32(self.a), data = UInt32(self.data)
        var tmp = (a & 0xF) + (data & 0xF) + (c ? 1 : 0)
        if tmp > 9 {
            tmp += 6
        }
        if tmp <= 0xF {
            tmp = (tmp & 0xF) + (a & 0xF0) + (data & 0xF0)
        } else {
            tmp = (tmp & 0xF) + (a & 0xF0) + (data & 0xF0) + 0x10
        }
        v = (a ^ tmp) & (~a ^ data) & 0x80 != 0
        c = false
        if tmp & 0x1F0 > 0x90 {
            tmp += 0x60
            c = true
        }
        self.a = UInt8(truncatingIfNeeded: tmp)
        setNZ(self.a)
    }

    private func sbcNMOS() {
        guard d else { return sbcBinary() }
        let a = UInt32(self.a), data = UInt32(self.data)
        let result = a + UInt32(~self.data) + (c ? 1 : 0)
        var tmp = (a & 0xF) &- (data & 0xF) &- (c ? 0 : 1)
        if tmp & 0x10 != 0 {
            tmp = ((tmp &- 6) & 0xF) | ((a & 0xF0) &- (data & 0xF0) &- 0x10)
        } else {
            tmp = (tmp & 0xF) | ((a & 0xF0) &- (data & 0xF0))
        }
        if tmp & 0x100 != 0 {
            tmp &-= 0x60
        }
        let low = UInt8(truncatingIfNeeded: result)
        setNZ(low)
        c = result > 0xFF
        v = (a ^ UInt32(low)) & 0x80 != 0 && (a ^ data) & 0x80 != 0
        self.a = UInt8(truncatingIfNeeded: tmp)
    }

    private func sbcCMOS() {
        guard d else { return sbcBinary() }
        let a = Int(self.a), data = Int(self.data), borrow = c ? 0 : 1
        let al = (a & 0xF) - (data & 0xF) - borrow
        var result = a - data - borrow
        v = (a ^ data) & (a ^ (result & 0xFF)) & 0x80 != 0
        c = result & 0x100 == 0
        if result < 0 {
            result -= 0x60
        }
        if al < 0 {
            result -= 0x06
        }
        self.a = UInt8(truncatingIfNeeded: result)
        setNZ(self.a)
    }

    private func arr() {
        // From 64doc; passes the Lorenz test suite.
        if d {
            let t = a & data
            let ah = t >> 4, al = t & 15
            a = t >> 1 | (c ? 0x80 : 0)
            setNZ(a)
            v = (a ^ t) & 0x40 != 0
            if al + (al & 1) > 5 {
                a = (a & 0xF0) | ((a &+ 6) & 0x0F)
            }
            c = ah + (ah & 1) > 5
            if c {
                a &+= 0x60
            }
        } else {
            a &= data
            a = ror(a)
            c = a & 0x40 != 0
            v = ((a >> 6) ^ (a >> 5)) & 1 != 0
        }
    }

    /// Bit number for the Rockwell bit instructions.
    @inline(__always)
    private var opcodeBit: UInt8 { 1 << (opcode >> 4 & 7) }

    /// Performs the ALU part of an instruction.
    ///
    /// Read instructions take their operand from `data`; write instructions
    /// put the value to write in `data`; RMW instructions modify `data`;
    /// branches set `data` non-zero if the branch is taken.
    @inline(__always)
    func execute(_ op: Op) {
        switch op {
        case .none, .nop:
            break

        // Implied.
        case .clc: c = false
        case .cld: d = false
        case .cli: i = false
        case .clv: v = false
        case .sec: c = true
        case .sed: d = true
        case .sei: i = true
        case .tax: x = a; setNZ(x)
        case .tay: y = a; setNZ(y)
        case .tsx: x = s; setNZ(x)
        case .txa: a = x; setNZ(a)
        case .txs: s = x
        case .tya: a = y; setNZ(a)
        case .inx: x &+= 1; setNZ(x)
        case .iny: y &+= 1; setNZ(y)
        case .dex: x &-= 1; setNZ(x)
        case .dey: y &-= 1; setNZ(y)

        // Read.
        case .adc: adcNMOS()
        case .adcCMOS: adcCMOS()
        case .sbc: sbcNMOS()
        case .sbcCMOS: sbcCMOS()
        case .and: a &= data; setNZ(a)
        case .eor: a ^= data; setNZ(a)
        case .ora: a |= data; setNZ(a)
        case .bit:
            z = a & data == 0
            n = data & 0x80 != 0
            v = data & 0x40 != 0
        case .bitCMOS:
            // BIT immediate only affects Z.
            z = a & data == 0
        case .cmp: compare(a)
        case .cpx: compare(x)
        case .cpy: compare(y)
        case .lda: a = data; setNZ(a)
        case .ldx: x = data; setNZ(x)
        case .ldy: y = data; setNZ(y)

        // Read-modify-write.
        case .asl: data = asl(data)
        case .aslA: a = asl(a)
        case .lsr: data = lsr(data)
        case .lsrA: a = lsr(a)
        case .rol: data = rol(data)
        case .rolA: a = rol(a)
        case .ror: data = ror(data)
        case .rorA: a = ror(a)
        case .inc: data &+= 1; setNZ(data)
        case .incA: a &+= 1; setNZ(a)
        case .dec: data &-= 1; setNZ(data)
        case .decA: a &-= 1; setNZ(a)
        case .trb:
            z = data & a == 0
            data &= ~a
        case .tsb:
            z = data & a == 0
            data |= a

        // Write.
        case .sta: data = a
        case .stx: data = x
        case .sty: data = y
        case .stz: data = 0

        // Branches.
        case .bcc: data = c ? 0 : 1
        case .bcs: data = c ? 1 : 0
        case .beq: data = z ? 1 : 0
        case .bne: data = z ? 0 : 1
        case .bmi: data = n ? 1 : 0
        case .bpl: data = n ? 0 : 1
        case .bvc: data = v ? 0 : 1
        case .bvs: data = v ? 1 : 0
        case .bra: data = 1

        // Stack.
        case .pha: data = a
        case .php: data = p
        case .phx: data = x
        case .phy: data = y
        case .pla: a = data; setNZ(a)
        case .plp: setP(data)
        case .plx: x = data; setNZ(x)
        case .ply: y = data; setNZ(y)

        // Undocumented NMOS.
        case .slo: data = asl(data); a |= data; setNZ(a)
        case .rla: data = rol(data); a &= data; setNZ(a)
        case .sre: data = lsr(data); a ^= data; setNZ(a)
        case .rra: data = ror(data); adcNMOS()
        case .dcp: data &-= 1; compare(a)
        case .isb: data &+= 1; sbcNMOS()
        case .lax: a = data; x = data; setNZ(a)
        case .sax: data = a & x
        case .asr: a &= data; a = lsr(a)
        case .arr: arr()
        case .ane:
            a = (a | xaaMagic) & x & data
            setNZ(a)
        case .lxa:
            a = (a | xaaMagic) & data
            x = a
            setNZ(a)
        case .sbx:
            let lhs = a & x
            x = lhs &- data
            compare(lhs)
        case .sha: data = a & x & (UInt8(truncatingIfNeeded: ad >> 8) &+ 1)
        case .shx: data = x & (UInt8(truncatingIfNeeded: ad >> 8) &+ 1)
        case .shy: data = y & (UInt8(truncatingIfNeeded: ad >> 8) &+ 1)
        case .shs:
            s = a & x
            data = a & x & (UInt8(truncatingIfNeeded: ad >> 8) &+ 1)
        case .anc:
            a &= data
            setNZ(a)
            c = n
        case .lds:
            s &= data
            a = s
            x = s
            setNZ(a)

        // Rockwell.
        case .rmb: data &= ~opcodeBit
        case .smb: data |= opcodeBit
        case .bbr: data = ~data & opcodeBit
        case .bbs: data &= opcodeBit
        }
    }
}

// MARK: - Instruction info

public enum M6502AddressingMode: String, Sendable {
    case imp, acc, imm, rel, zpg, zpx, zpy, inx, iny, abs, abx, aby, ind, inz, indx, zpgRelRockwell
}

public struct M6502InstructionInfo: Sendable {
    public var mnemonic: String
    public var mode: M6502AddressingMode
    /// Length in bytes, including the opcode.
    public var length: Int
    public var undocumented: Bool
}
