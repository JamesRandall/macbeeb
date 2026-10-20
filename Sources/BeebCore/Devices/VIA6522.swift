// 6522 VIA.
//
// A port of b2's 6522.cpp (Copyright (C) Tom Seddon, GPLv3).
//
// The VIA runs from the 1MHz clock, phi1 then phi2:
//
// phi2->phi1 (`updatePhi2TrailingEdge`): writes complete, timers update
// (including reload), PB7 goes low due to timer load.
//
// phi1->phi2 (`updatePhi2LeadingEdge`): IRQ output goes low, PB7 toggles due
// to timer timeout, PB6 sampled for pulse counting.
//
// The phase discrepancy between timer writes/updates and the IRQ output is
// why the initial timeout period is N+1.5 cycles.
//
// Port pins are inputs pulled high: after each trailing edge, `a.p`/`b.p`,
// C1 and (input mode) C2 return to 1, and the machine then pulls low
// whatever its devices are driving.

public struct VIA6522: Codable, Sendable {
    public struct Port: Codable, Sendable {
        /// Output register.
        var or: UInt8 = 0
        var ddr: UInt8 = 0
        /// Pin levels.
        public var p: UInt8 = 0xFF
        var pLatch: UInt8 = 0xFF
        public var c1: UInt8 = 0
        var oldC1: UInt8 = 0
        public var c2: UInt8 = 0
        var oldC2: UInt8 = 0
        var pulse: UInt8 = 0
    }

    public enum IRQ {
        public static let ca2: UInt8 = 0x01
        public static let ca1: UInt8 = 0x02
        public static let sr: UInt8 = 0x04
        public static let cb2: UInt8 = 0x08
        public static let cb1: UInt8 = 0x10
        public static let t2: UInt8 = 0x20
        public static let t1: UInt8 = 0x40
    }

    /// Cx2 control modes (PCR bits 1-3 / 5-7).
    private enum Cx2Control {
        static let inputNegEdge: UInt8 = 0
        static let inputIndIRQNegEdge: UInt8 = 1
        static let inputPosEdge: UInt8 = 2
        static let inputIndIRQPosEdge: UInt8 = 3
        static let outputHandshake: UInt8 = 4
        static let outputPulse: UInt8 = 5
        static let outputLow: UInt8 = 6
        static let outputHigh: UInt8 = 7
    }

    public var a = Port()
    public var b = Port()
    public var ifr: UInt8 = 0
    public var ier: UInt8 = 0

    var t1ll: UInt8 = 250
    var t1lh: UInt8 = 202
    var t2ll: UInt8 = 0
    var t2lh: UInt8 = 0
    var sr: UInt8 = 0
    var acr: UInt8 = 0
    var pcr: UInt8 = 0
    var t1: UInt16 = 0
    var t1Reload = false
    var t1Pending = false
    var t1Timeout = false
    var t2: UInt16 = 0
    var t2Reload = false
    var t2Pending = false
    var t2Timeout = false
    var t2Count = true
    /// T1-driven output value for PB7.
    var t1PB7: UInt8 = 0
    /// Old port B value, for counting PB6 pulses.
    var oldPB: UInt8 = 0

    public init() {}

    // MARK: ACR/PCR fields

    private var paLatching: Bool { acr & 0x01 != 0 }
    private var pbLatching: Bool { acr & 0x02 != 0 }
    private var t2CountPB6: Bool { acr & 0x20 != 0 }
    private var t1Continuous: Bool { acr & 0x40 != 0 }
    private var t1OutputPB7: Bool { acr & 0x80 != 0 }
    private var ca2Mode: UInt8 { pcr >> 1 & 7 }
    private var cb2Mode: UInt8 { pcr >> 5 & 7 }

    // MARK: Register access

    public mutating func read(_ register: Int) -> UInt8 {
        switch register & 15 {
        case 0x0: // IRB
            var value = b.or & b.ddr
            value |= (pbLatching ? b.pLatch : b.p) & ~b.ddr
            // IRB reads always seem to reflect the PB7 output value, when active.
            if t1OutputPB7 {
                value = (value & 0x7F) | t1PB7
            }
            clearPortBIRQs()
            return value
        case 0x1: // IRA
            clearPortAIRQs()
            handshakeA()
            return readIRANoHandshake()
        case 0x2: return b.ddr
        case 0x3: return a.ddr
        case 0x4: // T1C-L
            if !t1Timeout {
                ifr &= ~IRQ.t1
            }
            return UInt8(truncatingIfNeeded: t1)
        case 0x5: return UInt8(truncatingIfNeeded: t1 >> 8)
        case 0x6: return t1ll
        case 0x7: return t1lh
        case 0x8: // T2C-L
            if !t2Timeout {
                ifr &= ~IRQ.t2
            }
            return UInt8(truncatingIfNeeded: t2)
        case 0x9: return UInt8(truncatingIfNeeded: t2 >> 8)
        case 0xA: return sr
        case 0xB: return acr
        case 0xC: return pcr
        case 0xD: // IFR
            var value = ifr & 0x7F
            if ier & ifr & 0x7F != 0 {
                value |= 0x80
            }
            return value
        case 0xE: return ier | 0x80
        default: // 0xF: IRA, no handshake
            return readIRANoHandshake()
        }
    }

    /// Reads a register with no side effects, for debuggers.
    public func peek(_ register: Int) -> UInt8 {
        var copy = self
        return copy.read(register)
    }

    public mutating func write(_ register: Int, _ value: UInt8) {
        switch register & 15 {
        case 0x0: // ORB
            b.or = value
            clearPortBIRQs()
            switch cb2Mode {
            case Cx2Control.outputHandshake:
                b.c2 = 0
            case Cx2Control.outputPulse:
                b.c2 = 0
                b.pulse = 2
            default:
                break
            }
        case 0x1: // ORA
            clearPortAIRQs()
            handshakeA()
            a.or = value
        case 0x2: b.ddr = value
        case 0x3: a.ddr = value
        case 0x4, 0x6: t1ll = value // T1L-L
        case 0x5: // T1C-H
            if !t1Timeout {
                ifr &= ~IRQ.t1
            }
            t1lh = value
            t1Pending = true
            t1Reload = true
            t1PB7 = 0
        case 0x7: // T1L-H
            // See V.TIMERS. b2's notes say Skirmish needs this.
            if !t1Timeout {
                ifr &= ~IRQ.t1
            }
            t1lh = value
        case 0x8: t2ll = value
        case 0x9: // T2C-H
            if !t2Timeout {
                ifr &= ~IRQ.t2
            }
            t2lh = value
            t2Pending = true
            t2Reload = true
        case 0xA: sr = value
        case 0xB:
            acr = value
            if t1Timeout && !t1Continuous {
                t1Pending = false
            }
        case 0xC: pcr = value
        case 0xD:
            // A timer flag set this cycle survives an IFR write, as with
            // T1C-L reads. (b2 lacks this; jsbeeb has it, and VIA.I2 shows
            // a real BBC does too.)
            var clear = value
            if t1Timeout { clear &= ~IRQ.t1 }
            if t2Timeout { clear &= ~IRQ.t2 }
            ifr &= ~clear
        case 0xE:
            if value & 0x80 != 0 {
                ier |= value
            } else {
                ier &= ~value
            }
        default: // 0xF: ORA, no handshake
            a.or = value
        }
    }

    private func readIRANoHandshake() -> UInt8 {
        paLatching ? a.pLatch : a.p
    }

    private mutating func clearPortAIRQs() {
        ifr &= ~IRQ.ca1
        // In the independent interrupt input modes, IRA/ORA access doesn't
        // clear CA2. (b2 has this inverted for port A; the datasheet and
        // jsbeeb agree with this.)
        if ca2Mode & 5 != 1 {
            ifr &= ~IRQ.ca2
        }
    }

    private mutating func clearPortBIRQs() {
        ifr &= ~IRQ.cb1
        if cb2Mode & 5 != 1 {
            ifr &= ~IRQ.cb2
        }
    }

    private mutating func handshakeA() {
        switch ca2Mode {
        case Cx2Control.outputHandshake:
            a.c2 = 0
        case Cx2Control.outputPulse:
            a.c2 = 0
            a.pulse = 2
        default:
            break
        }
    }

    // MARK: Clock

    /// Returns non-zero if the VIA is asserting IRQ.
    @inline(__always)
    public mutating func updatePhi2LeadingEdge() -> UInt8 {
        if t1Timeout {
            t1Pending = t1Continuous
            ifr |= IRQ.t1
            t1PB7 ^= 0x80
        }
        if t2Timeout {
            t2Pending = false
            ifr |= IRQ.t2
        }
        if t2CountPB6 {
            t2Count = oldPB & 0x40 & ~(b.p & 0x40) != 0
            oldPB = b.p
        } else {
            t2Count = true
        }
        return ier & ifr & 0x7F
    }

    /// Returns non-zero if the VIA is asserting IRQ.
    @inline(__always)
    public mutating func updatePhi2TrailingEdge() -> UInt8 {
        let irqA = Self.tickControl(&a, latching: paLatching, pcrBits: pcr, cx2Mask: IRQ.ca2)
        let irqB = Self.tickControl(&b, latching: pbLatching, pcrBits: pcr >> 4, cx2Mask: IRQ.cb2)
        ifr |= irqA | irqB

        t1Timeout = false
        if t1Reload {
            t1 = UInt16(t1ll) | UInt16(t1lh) << 8
            t1Reload = false
        } else {
            t1 &-= 1
            t1Reload = t1 == 0xFFFF
            t1Timeout = t1Pending && t1Reload
        }

        t2Timeout = false
        if t2Reload {
            t2 = UInt16(t2ll) | UInt16(t2lh) << 8
            t2Reload = false
        } else if t2Count {
            t2 &-= 1
            t2Timeout = t2Pending && t2 == 0xFFFF
        }

        return ier & ifr & 0x7F
    }

    /// Returns the IFR bits to set.
    @inline(__always)
    private static func tickControl(_ port: inout Port, latching: Bool, pcrBits: UInt8, cx2Mask: UInt8) -> UInt8 {
        var ifr: UInt8 = 0
        // Cx1: active edge set by PCR bit 0.
        let oldC1 = port.oldC1
        port.oldC1 = port.c1
        let code = (port.c1 | oldC1 << 1 | pcrBits << 2) & 7
        if code == 2 || code == 5 {
            // cx2Mask << 1 is the mask for Cx1.
            ifr |= cx2Mask << 1
            if latching {
                port.pLatch = port.p
            }
        }

        // Cx2.
        let oldC2 = port.oldC2
        port.oldC2 = port.c2
        switch pcrBits >> 1 & 7 {
        case Cx2Control.inputIndIRQNegEdge, Cx2Control.inputNegEdge:
            if oldC2 != 0 && port.c2 == 0 {
                ifr |= cx2Mask
            }
            port.c2 = 1
        case Cx2Control.inputIndIRQPosEdge, Cx2Control.inputPosEdge:
            if oldC2 == 0 && port.c2 != 0 {
                ifr |= cx2Mask
            }
            port.c2 = 1
        case Cx2Control.outputPulse:
            if port.pulse > 0 {
                port.pulse -= 1
                if port.pulse == 0 {
                    port.c2 = 1
                }
            }
        case Cx2Control.outputHigh:
            port.c2 = 1
        case Cx2Control.outputLow:
            port.c2 = 0
        default: // output handshake
            if port.c1 == 0 {
                // Data taken -> not data ready.
                port.c2 = 1
            }
        }

        // Cx1 is always an input.
        port.c1 = 1
        port.p = ~port.ddr | (port.or & port.ddr)
        return ifr
    }
}
