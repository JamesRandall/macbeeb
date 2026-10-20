// Z80 CPU core, for the Acorn Z80 Second Processor.
//
// Instruction-level: `step()` runs one instruction (or accepts one
// interrupt) and returns the T-states it took. All the undocumented
// behaviour is emulated: the IXH/IXL/IYH/IYL instructions, SLL, the DDCB/FDCB
// register copies, the ED mirrors, flag bits 3 and 5 (X and Y) everywhere,
// MEMPTR (WZ) and the BIT n,(HL) flags that leak it, the flags of block
// instructions (including the extra ones when a repeat is interrupted), and
// the NMOS Zilog SCF/CCF behaviour (see `q`).
//
// Sources: Sean Young's "The Undocumented Z80 Documented"; the MEMPTR notes
// by boo_boo and Vladimir Kladov; Patrik Rak's SCF/CCF research; David Banks's
// work on interrupted block instructions (as used by MAME). The interface
// with the Acorn Second Processor follows BeebEm (Z80Support.cpp, Copyright
// (C) 2005 Jon Welch, GPL-2.0-or-later); the core itself is new.

/// The Z80's view of the outside world.
public protocol Z80Bus: AnyObject {
    /// A memory read.
    func read(_ address: UInt16) -> UInt8
    /// An opcode fetch (M1 cycle), including prefix bytes. Defaults to `read`.
    func fetchOpcode(_ address: UInt16) -> UInt8
    func write(_ address: UInt16, _ value: UInt8)
    /// An I/O read. `port` is the full 16 bit address: (A or B)<<8 | n or C.
    func input(_ port: UInt16) -> UInt8
    func output(_ port: UInt16, _ value: UInt8)
}

extension Z80Bus {
    public func fetchOpcode(_ address: UInt16) -> UInt8 { read(address) }
}

public final class Z80 {
    // Flag bits.
    public static let flagC: UInt8 = 0x01
    public static let flagN: UInt8 = 0x02
    public static let flagPV: UInt8 = 0x04
    public static let flagX: UInt8 = 0x08
    public static let flagH: UInt8 = 0x10
    public static let flagY: UInt8 = 0x20
    public static let flagZ: UInt8 = 0x40
    public static let flagS: UInt8 = 0x80

    /// The bus isn't retained: the owner of the CPU must keep it alive.
    public unowned(unsafe) var bus: any Z80Bus

    // MARK: Registers

    public var a: UInt8 = 0xFF
    public var f: UInt8 = 0xFF
    public var b: UInt8 = 0
    public var c: UInt8 = 0
    public var d: UInt8 = 0
    public var e: UInt8 = 0
    public var h: UInt8 = 0
    public var l: UInt8 = 0
    /// The alternate register set.
    public var afPrime: UInt16 = 0xFFFF
    public var bcPrime: UInt16 = 0
    public var dePrime: UInt16 = 0
    public var hlPrime: UInt16 = 0
    public var ix: UInt16 = 0xFFFF
    public var iy: UInt16 = 0xFFFF
    public var sp: UInt16 = 0xFFFF
    public var pc: UInt16 = 0
    public var i: UInt8 = 0
    /// Refresh register: the low 7 bits count M1 cycles; bit 7 is only
    /// changed by LD R,A.
    public var r: UInt8 = 0
    public var iff1 = false
    public var iff2 = false
    /// Interrupt mode: 0, 1 or 2.
    public var im: UInt8 = 0
    /// True after HALT, until an interrupt. While halted each step takes 4
    /// T-states and `pc` is the address after the HALT.
    public var halted = false
    /// The internal MEMPTR register, visible in the X/Y flags after
    /// BIT n,(HL).
    public var wz: UInt16 = 0
    /// The flags written by the last instruction, or 0 if it didn't write
    /// them. On an NMOS Zilog Z80, SCF and CCF set X and Y from
    /// ((Q ^ F) | A): from A after a flag-setting instruction, and from A|F
    /// otherwise.
    public var q: UInt8 = 0

    // MARK: Interrupt lines

    /// The maskable interrupt line (level triggered; true = asserted).
    public var irq = false
    /// The byte the interrupting device puts on the data bus during an
    /// interrupt acknowledge: the instruction executed in mode 0 (normally an
    /// RST; other single byte instructions work too), or the low byte of the
    /// vector table address in mode 2.
    public var interruptDataBus: UInt8 = 0xFF
    /// An NMI edge has been seen and not yet accepted. NMI is always
    /// accepted at the start of the next `step()`.
    public var nmiPending = false
    /// The NMI line's level, as last set by `setNMI`.
    public var nmiLine = false
    /// The last instruction was EI, so a maskable interrupt can't be
    /// accepted before the next one.
    public var eiDelay = false
    /// The last instruction was LD A,I or LD A,R. If a maskable interrupt is
    /// accepted now, P/V is cleared (an NMOS bug).
    public var afterLDAIR = false
    /// `q` as it was before the current instruction.
    var lastQ: UInt8 = 0

    public init(bus: any Z80Bus) {
        self.bus = bus
    }

    /// Resets the CPU: PC, I, R, IFF1/2 and IM are cleared; AF and SP are
    /// set to $FFFF. Other registers are left as they are.
    public func reset() {
        pc = 0
        i = 0
        r = 0
        iff1 = false
        iff2 = false
        im = 0
        halted = false
        a = 0xFF
        f = 0xFF
        sp = 0xFFFF
        wz = 0
        q = 0
        eiDelay = false
        afterLDAIR = false
        nmiPending = false
    }

    /// Sets the NMI line. NMI is edge triggered: going from released to
    /// asserted causes one NMI.
    public func setNMI(_ asserted: Bool) {
        if asserted && !nmiLine { nmiPending = true }
        nmiLine = asserted
    }

    // MARK: Register pairs

    public var af: UInt16 {
        get { UInt16(a) << 8 | UInt16(f) }
        set { a = UInt8(newValue >> 8); f = UInt8(truncatingIfNeeded: newValue) }
    }
    public var bc: UInt16 {
        @inline(__always) get { UInt16(b) << 8 | UInt16(c) }
        @inline(__always) set { b = UInt8(newValue >> 8); c = UInt8(truncatingIfNeeded: newValue) }
    }
    public var de: UInt16 {
        @inline(__always) get { UInt16(d) << 8 | UInt16(e) }
        @inline(__always) set { d = UInt8(newValue >> 8); e = UInt8(truncatingIfNeeded: newValue) }
    }
    public var hl: UInt16 {
        @inline(__always) get { UInt16(h) << 8 | UInt16(l) }
        @inline(__always) set { h = UInt8(newValue >> 8); l = UInt8(truncatingIfNeeded: newValue) }
    }

    // MARK: Execution

    /// Runs one instruction, or accepts a pending interrupt, or idles for 4
    /// T-states if halted. Returns the T-states taken.
    @discardableResult
    public func step() -> Int {
        lastQ = q
        q = 0
        if nmiPending { return acceptNMI() }
        if irq && iff1 && !eiDelay { return acceptInterrupt() }
        eiDelay = false
        afterLDAIR = false
        if halted {
            incrementR()
            return 4
        }
        let op = fetchOpcode()
        return execute(op)
    }

    /// Runs instructions until at least `tStates` T-states have passed.
    /// Returns the number that actually passed (which can overshoot by up
    /// to one instruction).
    @discardableResult
    public func run(tStates: Int) -> Int {
        var done = 0
        while done < tStates {
            if halted && !nmiPending && !(irq && iff1) {
                // Idle in one go.
                let n = (tStates - done + 3) >> 2
                r = (r & 0x80) | (UInt8(truncatingIfNeeded: Int(r) + n) & 0x7F)
                lastQ = q
                q = 0
                eiDelay = false
                afterLDAIR = false
                done += n * 4
                break
            }
            done += step()
        }
        return done
    }

    func acceptNMI() -> Int {
        nmiPending = false
        halted = false
        iff1 = false
        eiDelay = false
        afterLDAIR = false
        incrementR()
        push(pc)
        pc = 0x0066
        wz = pc
        return 11
    }

    func acceptInterrupt() -> Int {
        halted = false
        iff1 = false
        iff2 = false
        if afterLDAIR {
            f &= ~Z80.flagPV
            afterLDAIR = false
        }
        incrementR()
        switch im {
        case 2:
            push(pc)
            let vector = UInt16(i) << 8 | UInt16(interruptDataBus)
            pc = read16(vector)
            wz = pc
            return 19
        case 1:
            push(pc)
            pc = 0x0038
            wz = pc
            return 13
        default:
            let op = interruptDataBus
            if op & 0xC7 == 0xC7 {
                push(pc)
                pc = UInt16(op & 0x38)
                wz = pc
                return 13
            }
            // Two wait states are added to the acknowledge cycle.
            return 2 + execute(op)
        }
    }

    // MARK: Bus helpers

    @inline(__always) func read(_ address: UInt16) -> UInt8 { bus.read(address) }
    @inline(__always) func write(_ address: UInt16, _ value: UInt8) { bus.write(address, value) }

    @inline(__always) func read16(_ address: UInt16) -> UInt16 {
        let lo = read(address)
        return UInt16(read(address &+ 1)) << 8 | UInt16(lo)
    }

    @inline(__always) func write16(_ address: UInt16, _ value: UInt16) {
        write(address, UInt8(truncatingIfNeeded: value))
        write(address &+ 1, UInt8(value >> 8))
    }

    /// An M1 fetch: opcode or prefix.
    @inline(__always) func fetchOpcode() -> UInt8 {
        let op = bus.fetchOpcode(pc)
        pc &+= 1
        incrementR()
        return op
    }

    @inline(__always) func fetch() -> UInt8 {
        let v = read(pc)
        pc &+= 1
        return v
    }

    @inline(__always) func fetch16() -> UInt16 {
        let lo = fetch()
        return UInt16(fetch()) << 8 | UInt16(lo)
    }

    /// Fetches a displacement and adds it to `base`.
    @inline(__always) func fetchDisplacement(_ base: UInt16) -> UInt16 {
        base &+ UInt16(bitPattern: Int16(Int8(bitPattern: fetch())))
    }

    @inline(__always) func incrementR() {
        r = (r & 0x80) | ((r &+ 1) & 0x7F)
    }

    @inline(__always) func push(_ value: UInt16) {
        sp &-= 1
        write(sp, UInt8(value >> 8))
        sp &-= 1
        write(sp, UInt8(truncatingIfNeeded: value))
    }

    @inline(__always) func pop() -> UInt16 {
        let lo = read(sp)
        sp &+= 1
        let hi = read(sp)
        sp &+= 1
        return UInt16(hi) << 8 | UInt16(lo)
    }

    /// Sets the flags from an ALU operation (which also sets Q).
    @inline(__always) func setFlags(_ value: UInt8) {
        f = value
        q = value
    }
}
