// ARM CPU core (ARM1/ARM2 class), for the Acorn ARM Second Processor.
//
// The 26-bit architecture: R15 holds the PC in bits 2-25 and the PSR around
// it (NZCV in 31-28, I and F in 27-26, the mode in 1-0). User, FIQ, IRQ and
// supervisor modes, with R13-R14 banked in each and R8-R14 in FIQ mode.
// Instruction-level: `step()` runs one instruction (or takes an interrupt)
// and returns roughly the cycles it took (S, N and I cycles counted alike).
//
// Implemented: all the data processing instructions with every shift
// (including RRX and register-specified shifts, where R15 reads 4 further
// on), the TSTP/TEQP/CMPP/CMNP forms that write the PSR, LDR/STR (byte and
// word, rotated unaligned word loads), LDM/STM (with writeback and the S
// bit: user bank, or PSR restore when R15 is loaded), B, BL, SWI, and the
// ARM2's MUL/MLA. There's no coprocessor, so its instructions take the
// undefined instruction trap. A bus can make an access abort with `abort()`;
// addresses beyond 26 bits take the address exception.
//
// A port of the semantics of Tarmac's ARM core (Copyright (C) 2001 David
// Sharp, GPL-2.0-or-later) as used by BeebEm (Arm.cpp); the code is new.
// Where Tarmac departs from the ARM datasheets (it ignores the I and F bits
// when taking interrupts, reads unaligned words byte by byte, and treats
// coprocessor data transfers as address exceptions), this follows the
// hardware.

/// The ARM's view of the outside world. Word accesses are given an aligned
/// address.
public protocol ARMBus: AnyObject {
    func readWord(_ address: UInt32) -> UInt32
    func readByte(_ address: UInt32) -> UInt8
    func writeWord(_ address: UInt32, _ value: UInt32)
    func writeByte(_ address: UInt32, _ value: UInt8)
    /// An instruction fetch. Defaults to `readWord`.
    func fetch(_ address: UInt32) -> UInt32
}

extension ARMBus {
    public func fetch(_ address: UInt32) -> UInt32 { readWord(address) }
}

/// The processor modes, as in R15's bottom two bits.
public enum ARMMode: UInt32, Codable, Sendable {
    case user = 0, fiq = 1, irq = 2, supervisor = 3
}

/// Generic over the bus, so its accesses are direct calls.
public final class ARM<Bus: ARMBus> {
    public typealias Mode = ARMMode

    // PSR bits, as they appear in R15.
    public static var flagN: UInt32 { 1 << 31 }
    public static var flagZ: UInt32 { 1 << 30 }
    public static var flagC: UInt32 { 1 << 29 }
    public static var flagV: UInt32 { 1 << 28 }
    public static var flagI: UInt32 { 1 << 27 }
    public static var flagF: UInt32 { 1 << 26 }
    /// The PC's bits in R15.
    public static var pcMask: UInt32 { 0x03FF_FFFC }

    // Exception vectors.
    public static var resetVector: UInt32 { 0x00 }
    public static var undefinedVector: UInt32 { 0x04 }
    public static var swiVector: UInt32 { 0x08 }
    public static var prefetchAbortVector: UInt32 { 0x0C }
    public static var dataAbortVector: UInt32 { 0x10 }
    public static var addressExceptionVector: UInt32 { 0x14 }
    public static var irqVector: UInt32 { 0x18 }
    public static var fiqVector: UInt32 { 0x1C }

    /// The bus isn't retained: the owner of the CPU must keep it alive.
    public var bus: Bus { busReference.takeUnretainedValue() }
    let busReference: Unmanaged<Bus>

    /// The visible registers (0-15), then the banked copies: user R8-R14
    /// (16-22), FIQ R8-R14 (23-29), IRQ R13-R14 (30-31) and supervisor
    /// R13-R14 (32-33). The banks hold the registers of modes not current.
    /// R15 is the PC alone; between instructions it's the address of the
    /// next, and while one runs, that address plus 8.
    let regs: UnsafeMutablePointer<UInt32>
    static var registerCount: Int { 34 }

    public internal(set) var mode = Mode.supervisor
    public var n = false
    public var z = false
    public var c = false
    public var v = false
    /// IRQs disabled (I).
    public var irqDisabled = true
    /// FIQs disabled (F).
    public var fiqDisabled = true

    // MARK: Interrupt lines

    /// The interrupt request line (level; true = asserted).
    public var irq = false
    /// The fast interrupt request line (level).
    public var fiq = false

    /// Set when R15 was written by the instruction running.
    var branched = false
    /// Set by `abort()` during an access.
    var aborted = false

    public init(bus: Bus) {
        busReference = .passUnretained(bus)
        regs = .allocate(capacity: Self.registerCount)
        regs.initialize(repeating: 0, count: Self.registerCount)
    }

    deinit {
        regs.deallocate()
    }

    /// Resets: supervisor mode, interrupts disabled, PC 0 (the reset
    /// vector). As BeebEm, every register is cleared too.
    public func reset() {
        regs.update(repeating: 0, count: Self.registerCount)
        mode = .supervisor
        irqDisabled = true
        fiqDisabled = true
        n = false; z = false; c = false; v = false
        aborted = false
    }

    // MARK: Registers

    /// The address of the next instruction.
    public var pc: UInt32 {
        get { regs[15] }
        set { regs[15] = newValue & Self.pcMask }
    }

    /// The PSR bits of R15.
    public var psr: UInt32 {
        get {
            (n ? Self.flagN : 0) | (z ? Self.flagZ : 0) | (c ? Self.flagC : 0) | (v ? Self.flagV : 0)
                | (irqDisabled ? Self.flagI : 0) | (fiqDisabled ? Self.flagF : 0) | mode.rawValue
        }
        set {
            setFlags(newValue)
            irqDisabled = newValue & Self.flagI != 0
            fiqDisabled = newValue & Self.flagF != 0
            switchMode(Mode(rawValue: newValue & 3)!)
        }
    }

    /// R15 as the program sees it: PC and PSR.
    public var r15: UInt32 { regs[15] | psr }

    /// A register in the current mode's bank. Setting R15 sets the PC alone.
    public subscript(register: Int) -> UInt32 {
        get { regs[register & 15] }
        set {
            if register & 15 == 15 {
                pc = newValue
            } else {
                regs[register & 15] = newValue
            }
        }
    }

    /// A register as a mode sees it.
    public func register(_ register: Int, mode bank: Mode) -> UInt32 {
        regs[slot(register & 15, bank)]
    }

    public func setRegister(_ register: Int, mode bank: Mode, _ value: UInt32) {
        regs[slot(register & 15, bank)] = register & 15 == 15 ? value & Self.pcMask : value
    }

    /// Where a mode's register is kept.
    @inline(__always)
    func slot(_ register: Int, _ bank: Mode) -> Int {
        if bank == mode { return register }
        switch bank {
        case .fiq where register >= 8 && register <= 14:
            return 23 + register - 8
        case .user, .irq, .supervisor:
            if register >= 13 && register <= 14 {
                return (bank == .user ? 21 : bank == .irq ? 30 : 32) + register - 13
            }
            // R8-R12 are the user's unless FIQ mode is current.
            if mode == .fiq && register >= 8 && register <= 12 { return 16 + register - 8 }
            return register
        default:
            return register
        }
    }

    /// The user mode R8-R14, as LDM/STM with the S bit see them.
    @inline(__always)
    func userSlot(_ register: Int) -> Int {
        switch mode {
        case .user: register
        case .fiq: register >= 8 && register <= 14 ? 16 + register - 8 : register
        case .irq, .supervisor: register >= 13 && register <= 14 ? 16 + register - 8 : register
        }
    }

    /// Changes mode, swapping the banked registers.
    func switchMode(_ new: Mode) {
        guard new != mode else { return }
        // Put the current mode's registers away.
        if mode == .fiq {
            for i in 8...14 { regs[23 + i - 8] = regs[i] }
            for i in 8...12 { regs[i] = regs[16 + i - 8] }
        } else {
            let bank = bank13(mode)
            regs[bank] = regs[13]
            regs[bank + 1] = regs[14]
        }
        // Bring the new mode's in.
        if new == .fiq {
            for i in 8...12 { regs[16 + i - 8] = regs[i] }
            for i in 8...14 { regs[i] = regs[23 + i - 8] }
        } else {
            let bank = bank13(new)
            regs[13] = regs[bank]
            regs[14] = regs[bank + 1]
        }
        mode = new
    }

    /// Where a mode's R13 is kept while it isn't current (R14 follows).
    @inline(__always)
    func bank13(_ mode: Mode) -> Int {
        switch mode {
        case .user: 21
        case .fiq: 28
        case .irq: 30
        case .supervisor: 32
        }
    }

    @inline(__always)
    func setFlags(_ value: UInt32) {
        n = value & Self.flagN != 0
        z = value & Self.flagZ != 0
        c = value & Self.flagC != 0
        v = value & Self.flagV != 0
    }

    /// Writes the PSR from a result (MOVS PC, the P instructions, LDM^):
    /// the flags always, I, F and the mode only in a privileged mode.
    @inline(__always)
    func writePSR(_ value: UInt32) {
        if mode == .user {
            setFlags(value)
        } else {
            psr = value
        }
    }

    // MARK: Execution

    /// Runs one instruction, or takes an interrupt. Returns the cycles taken.
    @discardableResult
    public func step() -> Int {
        if fiq && !fiqDisabled {
            exception(Self.fiqVector, .fiq, link: regs[15] &+ 4, disableFIQ: true)
            return 3
        }
        if irq && !irqDisabled {
            exception(Self.irqVector, .irq, link: regs[15] &+ 4, disableFIQ: false)
            return 3
        }
        let address = regs[15]
        let instruction = busReference._withUnsafeGuaranteedRef { $0.fetch(address) }
        regs[15] = (address &+ 8) & Self.pcMask
        branched = false
        var cycles = 1
        if aborted {
            aborted = false
            exception(Self.prefetchAbortVector, .supervisor, link: address &+ 4, disableFIQ: false)
            cycles = 3
        } else if condition(instruction >> 28) {
            cycles = execute(instruction, at: address)
        }
        if !branched {
            regs[15] = (address &+ 4) & Self.pcMask
        }
        return cycles
    }

    /// Runs instructions until at least `cycles` have passed. Returns the
    /// number that actually passed.
    @discardableResult
    public func run(cycles: Int) -> Int {
        var done = 0
        while done < cycles {
            done += step()
        }
        return done
    }

    /// Makes the bus access in progress abort (a data abort, or a prefetch
    /// abort for a fetch).
    public func abort() {
        aborted = true
    }

    @inline(__always)
    func condition(_ code: UInt32) -> Bool {
        switch code {
        case 0xE: true
        case 0x0: z
        case 0x1: !z
        case 0x2: c
        case 0x3: !c
        case 0x4: n
        case 0x5: !n
        case 0x6: v
        case 0x7: !v
        case 0x8: c && !z
        case 0x9: !c || z
        case 0xA: n == v
        case 0xB: n != v
        case 0xC: !z && n == v
        case 0xD: z || n != v
        default: false
        }
    }

    /// Enters an exception: saves PC and PSR in the new mode's R14 and jumps
    /// to the vector.
    func exception(_ vector: UInt32, _ newMode: Mode, link: UInt32, disableFIQ: Bool) {
        let saved = (link & Self.pcMask) | psr
        switchMode(newMode)
        irqDisabled = true
        if disableFIQ { fiqDisabled = true }
        regs[14] = saved
        regs[15] = vector
        branched = true
    }
}
