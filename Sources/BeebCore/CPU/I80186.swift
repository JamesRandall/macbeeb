// Intel 80186 CPU core, for the Acorn Master 512 co-processor.
//
// Instruction-level: `step()` runs one instruction (or one iteration of a
// repeated string instruction, or accepts one interrupt) and returns the
// clocks it took, from the 80186 data sheet's timings (which, unlike the
// 8086's, include the effective address calculation). The 80186's additions
// to the 8086 are here: PUSHA/POPA, BOUND, ENTER/LEAVE, PUSH immediate, IMUL
// by an immediate, shifts and rotates by an immediate, INS/OUTS, the
// undefined-opcode trap (type 6) and the 5 bit masking of shift counts.
//
// Where the two chips agree, behaviour (including the undocumented opcodes
// and the flags Intel leaves undefined) is checked against Daniel Balsom's
// SingleStepTests 8086 suite, taken from a real 80C86 (see the tests).
//
// The integrated peripherals (interrupt controller, timers, DMA, chip
// selects) aren't part of the core: the board that uses it decides which it
// needs (see `Master512`). The INTR line takes the interrupt type from
// `interruptType`, which is what the 80186's interrupt controller supplies.
//
// The instruction set semantics follow Intel's iAPX 86/88, 186/188 User's
// Manual; the timings and the Master 512 conventions follow BeebEm's
// Master512CoPro.cpp (Copyright (C) 2020 Chris Needham, Carl and MAME
// contributors, BSD-3-Clause), itself derived from MAME's i86/i186 core by
// Bryan McPhail, Oliver Bergmann, Fabrice Frances and David Hedley.

/// The 80186's view of the outside world: a 1MB memory space (addresses are
/// 20 bit) and a 64K I/O space. Word accesses are made as two byte
/// accesses, low byte first.
public protocol I80186Bus: AnyObject {
    func read(_ address: Int) -> UInt8
    func write(_ address: Int, _ value: UInt8)
    func input(_ port: UInt16) -> UInt8
    func output(_ port: UInt16, _ value: UInt8)
}

public final class I80186 {
    // Flag bits.
    public static let flagC: UInt16 = 0x0001
    public static let flagP: UInt16 = 0x0004
    public static let flagA: UInt16 = 0x0010
    public static let flagZ: UInt16 = 0x0040
    public static let flagS: UInt16 = 0x0080
    public static let flagT: UInt16 = 0x0100
    public static let flagI: UInt16 = 0x0200
    public static let flagD: UInt16 = 0x0400
    public static let flagO: UInt16 = 0x0800
    /// The bits that exist; the others read as 1 (bits 1 and 12-15) or 0.
    static let flagsMask: UInt16 = 0x0FD5

    /// Interrupt types the CPU raises itself.
    public enum Interrupt {
        public static let divideError: UInt8 = 0
        public static let singleStep: UInt8 = 1
        public static let nmi: UInt8 = 2
        public static let breakpoint: UInt8 = 3
        public static let overflow: UInt8 = 4
        public static let bound: UInt8 = 5
        public static let undefinedOpcode: UInt8 = 6
    }

    /// The bus isn't retained: the owner of the CPU must keep it alive.
    public unowned(unsafe) var bus: any I80186Bus

    // MARK: Registers

    public var ax: UInt16 = 0
    public var cx: UInt16 = 0
    public var dx: UInt16 = 0
    public var bx: UInt16 = 0
    public var sp: UInt16 = 0
    public var bp: UInt16 = 0
    public var si: UInt16 = 0
    public var di: UInt16 = 0
    public var es: UInt16 = 0
    public var cs: UInt16 = 0xFFFF
    public var ss: UInt16 = 0
    public var ds: UInt16 = 0
    public var ip: UInt16 = 0
    /// The flags, as stored: only the bits in `flagsMask`.
    var f: UInt16 = 0

    /// The flags register as PUSHF sees it.
    public var flags: UInt16 {
        get { f & I80186.flagsMask | 0xF002 }
        set { f = newValue & I80186.flagsMask }
    }

    // MARK: State

    /// After HLT, until an interrupt. While halted each step takes 2 clocks.
    public var halted = false
    /// The maskable interrupt request (level; true = asserted). Taken when
    /// IF is set, as interrupt type `interruptType`.
    public var intr = false
    /// The type the interrupt controller supplies for `intr`.
    public var interruptType: UInt8 = 12
    /// An NMI edge has been seen and not yet taken.
    public var nmiPending = false
    /// The NMI line's level, as last set by `setNMI`.
    public var nmiLine = false
    /// The last instruction loaded a segment register or was STI, so no
    /// interrupt (or single step trap) can be taken before the next.
    public var interruptShadow = false
    /// A repeated string instruction has more iterations to go: `ip` points
    /// back at its first prefix, and the next step continues it (unless an
    /// interrupt comes first, after which it restarts from its prefixes).
    public internal(set) var repeating = false
    /// The ESC trap enable (the relocation register's ET bit): when set,
    /// ESC opcodes raise interrupt 7.
    public var escapeTrap = false

    // Per-instruction decoding state.
    /// The address of the current instruction's first prefix.
    var instructionStart: UInt16 = 0
    /// A segment override prefix's segment register value, if any.
    var overrideSegment: UInt16 = 0
    var hasOverride = false
    /// 0, or the REP prefix (0xF2 or 0xF3).
    var repPrefix: UInt8 = 0
    /// The ModR/M byte, and for a memory operand its segment and offset.
    var modrm: UInt8 = 0
    var eaSegment: UInt16 = 0
    var eaOffset: UInt16 = 0

    public init(bus: any I80186Bus) {
        self.bus = bus
    }

    /// Resets the CPU: CS:IP = FFFF:0000, flags clear, the segment
    /// registers zero. The general registers are left alone.
    public func reset() {
        cs = 0xFFFF
        ip = 0
        ds = 0
        es = 0
        ss = 0
        f = 0
        halted = false
        nmiPending = false
        interruptShadow = false
        repeating = false
        escapeTrap = false
    }

    /// Sets the NMI line. NMI is edge triggered: going from released to
    /// asserted causes one NMI.
    public func setNMI(_ asserted: Bool) {
        if asserted && !nmiLine { nmiPending = true }
        nmiLine = asserted
    }

    /// CS:IP as a 20 bit address.
    public var pc: Int { linear(cs, ip) }

    // MARK: Execution

    /// Runs one instruction, or one iteration of a repeated string
    /// instruction, or accepts a pending interrupt, or idles for 2 clocks if
    /// halted. Returns the clocks taken.
    @discardableResult
    public func step() -> Int {
        let continuing = repeating
        repeating = false
        if !interruptShadow {
            if nmiPending {
                nmiPending = false
                halted = false
                interrupt(Interrupt.nmi)
                return 50
            }
            if intr && f & I80186.flagI != 0 {
                halted = false
                interrupt(interruptType)
                return 45
            }
        }
        interruptShadow = false
        if halted {
            return 2
        }
        let trap = f & I80186.flagT != 0
        instructionStart = ip
        hasOverride = false
        repPrefix = 0
        var clocks = 0
        var op = fetch()
        // Prefixes.
        while true {
            switch op {
            case 0x26: overrideSegment = es; hasOverride = true
            case 0x2E: overrideSegment = cs; hasOverride = true
            case 0x36: overrideSegment = ss; hasOverride = true
            case 0x3E: overrideSegment = ds; hasOverride = true
            case 0xF0: break  // LOCK
            case 0xF2, 0xF3: repPrefix = op
            default:
                clocks += execute(op, continuing: continuing)
                if trap && !interruptShadow && !repeating {
                    interrupt(Interrupt.singleStep)
                    clocks += 45
                }
                return clocks
            }
            if !continuing { clocks += 2 }
            op = fetch()
        }
    }

    /// Runs instructions until at least `clocks` clocks have passed. Returns
    /// the number that actually passed.
    @discardableResult
    public func run(clocks: Int) -> Int {
        var done = 0
        while done < clocks {
            if halted && !nmiPending && !(intr && f & I80186.flagI != 0) {
                return clocks
            }
            done += step()
        }
        return done
    }

    /// Takes interrupt `type`: pushes the flags, CS and IP, clears IF and
    /// TF, and jumps through the vector table.
    public func interrupt(_ type: UInt8) {
        let vector = Int(type) * 4
        push(flags)
        f &= ~(I80186.flagI | I80186.flagT)
        push(cs)
        push(ip)
        ip = UInt16(bus.read(vector)) | UInt16(bus.read(vector + 1)) << 8
        cs = UInt16(bus.read(vector + 2)) | UInt16(bus.read(vector + 3)) << 8
    }

    // MARK: Memory

    @inline(__always) func linear(_ segment: UInt16, _ offset: UInt16) -> Int {
        (Int(segment) << 4 + Int(offset)) & 0xFFFFF
    }

    @inline(__always) func read8(_ segment: UInt16, _ offset: UInt16) -> UInt8 {
        bus.read(linear(segment, offset))
    }

    /// The high byte comes from offset+1 within the segment (wrapping at
    /// 64K), as on the 8086.
    @inline(__always) func read16(_ segment: UInt16, _ offset: UInt16) -> UInt16 {
        let lo = bus.read(linear(segment, offset))
        return UInt16(bus.read(linear(segment, offset &+ 1))) << 8 | UInt16(lo)
    }

    @inline(__always) func write8(_ segment: UInt16, _ offset: UInt16, _ value: UInt8) {
        bus.write(linear(segment, offset), value)
    }

    @inline(__always) func write16(_ segment: UInt16, _ offset: UInt16, _ value: UInt16) {
        bus.write(linear(segment, offset), UInt8(truncatingIfNeeded: value))
        bus.write(linear(segment, offset &+ 1), UInt8(value >> 8))
    }

    @inline(__always) func fetch() -> UInt8 {
        let v = bus.read(linear(cs, ip))
        ip &+= 1
        return v
    }

    @inline(__always) func fetch16() -> UInt16 {
        let lo = fetch()
        return UInt16(fetch()) << 8 | UInt16(lo)
    }

    /// A byte immediate, sign extended.
    @inline(__always) func fetchS8() -> UInt16 {
        UInt16(bitPattern: Int16(Int8(bitPattern: fetch())))
    }

    @inline(__always) func push(_ value: UInt16) {
        sp &-= 2
        write16(ss, sp, value)
    }

    @inline(__always) func pop() -> UInt16 {
        let v = read16(ss, sp)
        sp &+= 2
        return v
    }

    /// The data segment, or the override.
    @inline(__always) var dataSegment: UInt16 { hasOverride ? overrideSegment : ds }

    // MARK: Registers by code

    /// Word register by its 3 bit code: AX CX DX BX SP BP SI DI.
    @inline(__always) func reg16(_ code: UInt8) -> UInt16 {
        switch code & 7 {
        case 0: return ax
        case 1: return cx
        case 2: return dx
        case 3: return bx
        case 4: return sp
        case 5: return bp
        case 6: return si
        default: return di
        }
    }

    @inline(__always) func setReg16(_ code: UInt8, _ v: UInt16) {
        switch code & 7 {
        case 0: ax = v
        case 1: cx = v
        case 2: dx = v
        case 3: bx = v
        case 4: sp = v
        case 5: bp = v
        case 6: si = v
        default: di = v
        }
    }

    /// Byte register by its 3 bit code: AL CL DL BL AH CH DH BH.
    @inline(__always) func reg8(_ code: UInt8) -> UInt8 {
        let w = reg16(code & 3)
        return code & 4 == 0 ? UInt8(truncatingIfNeeded: w) : UInt8(w >> 8)
    }

    @inline(__always) func setReg8(_ code: UInt8, _ v: UInt8) {
        let w = reg16(code & 3)
        setReg16(code & 3, code & 4 == 0 ? (w & 0xFF00) | UInt16(v) : (w & 0x00FF) | UInt16(v) << 8)
    }

    /// Segment register by its 2 bit code: ES CS SS DS.
    @inline(__always) func sreg(_ code: UInt8) -> UInt16 {
        switch code & 3 {
        case 0: return es
        case 1: return cs
        case 2: return ss
        default: return ds
        }
    }

    @inline(__always) func setSreg(_ code: UInt8, _ v: UInt16) {
        switch code & 3 {
        case 0: es = v
        case 1: cs = v
        case 2: ss = v
        default: ds = v
        }
    }

    public var al: UInt8 {
        get { UInt8(truncatingIfNeeded: ax) }
        set { ax = (ax & 0xFF00) | UInt16(newValue) }
    }

    public var ah: UInt8 {
        get { UInt8(ax >> 8) }
        set { ax = (ax & 0x00FF) | UInt16(newValue) << 8 }
    }

    // MARK: ModR/M

    /// Fetches a ModR/M byte and, for a memory operand, its displacement,
    /// setting `eaSegment` and `eaOffset`.
    @inline(__always) func decodeModRM() {
        modrm = fetch()
        if modrm < 0xC0 {
            decodeEA()
        }
    }

    @inline(__always) var isRegisterOperand: Bool { modrm >= 0xC0 }
    @inline(__always) var regField: UInt8 { (modrm >> 3) & 7 }

    func decodeEA() {
        let mod = modrm >> 6
        var offset: UInt16
        var segment = ds
        switch modrm & 7 {
        case 0: offset = bx &+ si
        case 1: offset = bx &+ di
        case 2: offset = bp &+ si; segment = ss
        case 3: offset = bp &+ di; segment = ss
        case 4: offset = si
        case 5: offset = di
        case 6:
            if mod == 0 {
                offset = fetch16()
            } else {
                offset = bp
                segment = ss
            }
        default: offset = bx
        }
        if mod == 1 {
            offset &+= fetchS8()
        } else if mod == 2 {
            offset &+= fetch16()
        }
        eaOffset = offset
        eaSegment = hasOverride ? overrideSegment : segment
    }

    @inline(__always) func rm8() -> UInt8 {
        isRegisterOperand ? reg8(modrm) : read8(eaSegment, eaOffset)
    }

    @inline(__always) func setRM8(_ v: UInt8) {
        if isRegisterOperand { setReg8(modrm, v) } else { write8(eaSegment, eaOffset, v) }
    }

    @inline(__always) func rm16() -> UInt16 {
        isRegisterOperand ? reg16(modrm) : read16(eaSegment, eaOffset)
    }

    @inline(__always) func setRM16(_ v: UInt16) {
        if isRegisterOperand { setReg16(modrm, v) } else { write16(eaSegment, eaOffset, v) }
    }

    /// Clocks for a register or memory form.
    @inline(__always) func clocks(_ register: Int, _ memory: Int) -> Int {
        isRegisterOperand ? register : memory
    }

    // MARK: Flags

    @inline(__always) func setFlag(_ flag: UInt16, _ on: Bool) {
        if on { f |= flag } else { f &= ~flag }
    }

    @inline(__always) var carry: Bool { f & I80186.flagC != 0 }
    @inline(__always) var zero: Bool { f & I80186.flagZ != 0 }

    /// Sets S, Z and P from a byte result.
    @inline(__always) func setSZP8(_ r: UInt8) {
        f &= ~(I80186.flagS | I80186.flagZ | I80186.flagP)
        if r & 0x80 != 0 { f |= I80186.flagS }
        if r == 0 { f |= I80186.flagZ }
        if r.nonzeroBitCount & 1 == 0 { f |= I80186.flagP }
    }

    @inline(__always) func setSZP16(_ r: UInt16) {
        f &= ~(I80186.flagS | I80186.flagZ | I80186.flagP)
        if r & 0x8000 != 0 { f |= I80186.flagS }
        if r == 0 { f |= I80186.flagZ }
        if (r & 0xFF).nonzeroBitCount & 1 == 0 { f |= I80186.flagP }
    }
}
