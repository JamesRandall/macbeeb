// Tube ULA, the host/parasite interface used by the co-processors.
//
// A port of b2's tube.cpp (Copyright (C) Tom Seddon, GPLv3).
//
// Four FIFOs pass data between the two sides:
//
// - FIFO 1: 24 bytes parasite to host, 1 byte host to parasite. Its status
//   register also shows the control flags.
// - FIFO 2: 1 byte each way.
// - FIFO 3: 2 bytes each way in V (2-byte) mode, otherwise 1. Drives the
//   parasite NMI.
// - FIFO 4: 1 byte each way. Drives the host IRQ and, with FIFO 1, the
//   parasite IRQ.
//
// Each side sees the registers at address & 7: status at even addresses,
// data at odd. Status registers read as bit 7 data available, bit 6 not full.
//
// Writing a 1-byte latch always overwrites it; only FIFO 1 parasite to host
// and FIFO 3 drop bytes once full. A data read with nothing waiting returns
// the latch's old value (FIFOs 1 and 3: the last byte written in the other
// direction).
//
// The machine acts on the P and T control bits after every parasite cycle,
// so the parasite and the Tube stay in reset for as long as they're set.

public struct Tube: Codable, Sendable, Equatable {
    /// Control flags, written via host register 0.
    public enum Status {
        /// Host IRQ from FIFO 4 data.
        public static let q: UInt8 = 0x01
        /// Parasite IRQ from FIFO 1 data.
        public static let i: UInt8 = 0x02
        /// Parasite IRQ from FIFO 4 data.
        public static let j: UInt8 = 0x04
        /// Parasite NMI from FIFO 3.
        public static let m: UInt8 = 0x08
        /// 2-byte FIFO 3.
        public static let v: UInt8 = 0x10
        /// Parasite reset.
        public static let p: UInt8 = 0x20
        /// Clear all Tube registers.
        public static let t: UInt8 = 0x40
        /// Set (1) or clear (0) the flags given in the other bits.
        public static let s: UInt8 = 0x80
    }

    /// FIFO status register bits.
    public enum Flag {
        public static let available: UInt8 = 0x80
        public static let notFull: UInt8 = 0x40
    }

    public static let fifo1Size = 24

    /// Control flags. Bit 7 keeps whatever the last S=1 write left there;
    /// reads mask it off.
    public var status: UInt8 = 0

    // FIFO 1
    var hstatus1: UInt8 = 0
    var pstatus1: UInt8 = 0
    var h2p1: UInt8 = 0
    var p2h1 = [UInt8](repeating: 0, count: Tube.fifo1Size)
    var p2h1WriteIndex = 0
    var p2h1ReadIndex = 0
    var p2h1Count = 0

    // FIFO 2
    var hstatus2: UInt8 = 0
    var pstatus2: UInt8 = 0
    var h2p2: UInt8 = 0
    var p2h2: UInt8 = 0

    // FIFO 3
    var hstatus3: UInt8 = 0
    var pstatus3: UInt8 = 0
    var p2h3: [UInt8] = [0, 0]
    var p2h3Count = 0
    var h2p3: [UInt8] = [0, 0]
    var h2p3Count = 0
    /// Parasite NMI request, before M gates it.
    var pnmi = false

    // FIFO 4
    var hstatus4: UInt8 = 0
    var pstatus4: UInt8 = 0
    var h2p4: UInt8 = 0
    var p2h4: UInt8 = 0

    var lastP2HValue: UInt8 = 0
    var lastH2PValue: UInt8 = 0

    public init() {
        reset()
    }

    // MARK: Outputs

    public var hostIRQ: Bool {
        status & Status.q != 0 && hstatus4 & Flag.available != 0
    }

    public var parasiteIRQ: Bool {
        (status & Status.i != 0 && pstatus1 & Flag.available != 0)
            || (status & Status.j != 0 && pstatus4 & Flag.available != 0)
    }

    /// Level; the parasite CPU takes it edge-triggered.
    public var parasiteNMI: Bool {
        status & Status.m != 0 && pnmi
    }

    /// P bit: hold the parasite in reset (and in boot mode).
    public var parasiteResetRequested: Bool { status & Status.p != 0 }

    /// T bit: hold the Tube in reset (`reset()`).
    public var tubeResetRequested: Bool { status & Status.t != 0 }

    // MARK: Reset

    /// Empties every FIFO. Leaves the control flags alone. FIFO 3 parasite
    /// to host is left holding one byte so PRST doesn't raise an immediate NMI.
    public mutating func reset() {
        let empty = Flag.notFull
        hstatus1 = empty
        pstatus1 = empty
        p2h1WriteIndex = 0
        p2h1ReadIndex = 0
        p2h1Count = 0

        hstatus2 = empty
        pstatus2 = empty

        hstatus3 = Flag.notFull | Flag.available
        pstatus3 = 0
        if p2h3Count == 0 {
            p2h3[0] = lastP2HValue
        }
        p2h3Count = 1
        h2p3Count = 0
        pnmi = false

        hstatus4 = empty
        pstatus4 = empty
    }

    // MARK: Host side (&FEE0-&FEE7)

    public mutating func hostRead(_ register: Int) -> UInt8 {
        switch register & 7 {
        case 1:
            let value = hostPeek(1)
            if p2h1Count > 0 {
                p2h1ReadIndex = (p2h1ReadIndex + 1) % Tube.fifo1Size
                p2h1Count -= 1
                pstatus1 |= Flag.notFull
                if p2h1Count == 0 {
                    hstatus1 &= ~Flag.available
                }
            }
            return value
        case 3:
            Tube.readLatch(&hstatus2, &pstatus2)
            return p2h2
        case 5:
            let value = Tube.readFIFO3(&hstatus3, &pstatus3, &p2h3, &p2h3Count, dummy: lastP2HValue)
            if p2h3Count == 0 {
                pnmi = true
            }
            return value
        case 7:
            Tube.readLatch(&hstatus4, &pstatus4)
            return p2h4
        default:
            return hostPeek(register)
        }
    }

    /// What `hostRead` would return, without side effects.
    public func hostPeek(_ register: Int) -> UInt8 {
        switch register & 7 {
        case 0: hstatus1 | (status & 0x3F)
        case 1: p2h1Count > 0 ? p2h1[p2h1ReadIndex] : lastP2HValue
        case 2: hstatus2
        case 3: p2h2
        case 4: hstatus3
        case 5: p2h3Count > 0 ? p2h3[0] : lastP2HValue
        case 6: hstatus4
        default: p2h4
        }
    }

    public mutating func hostWrite(_ register: Int, _ value: UInt8) {
        switch register & 7 {
        case 0:
            if value & Status.s != 0 {
                status |= value
            } else {
                status &= ~value
            }
        case 1:
            h2p1 = value
            Tube.writeLatch(&hstatus1, &pstatus1)
        case 3:
            h2p2 = value
            Tube.writeLatch(&hstatus2, &pstatus2)
        case 5:
            Tube.writeFIFO3(&hstatus3, &pstatus3, &h2p3, &h2p3Count, value, twoByte: status & Status.v != 0)
            if h2p3Count >= (status & Status.v != 0 ? 2 : 1) {
                pnmi = true
            }
        case 7:
            h2p4 = value
            Tube.writeLatch(&hstatus4, &pstatus4)
        default:
            return
        }
        lastH2PValue = value
    }

    // MARK: Parasite side (&FEF0-&FEF7)

    public mutating func parasiteRead(_ register: Int) -> UInt8 {
        switch register & 7 {
        case 1:
            Tube.readLatch(&pstatus1, &hstatus1)
            return h2p1
        case 3:
            Tube.readLatch(&pstatus2, &hstatus2)
            return h2p2
        case 5:
            let value = Tube.readFIFO3(&pstatus3, &hstatus3, &h2p3, &h2p3Count, dummy: lastH2PValue)
            if h2p3Count == 0 {
                pnmi = false
            }
            return value
        case 7:
            Tube.readLatch(&pstatus4, &hstatus4)
            return h2p4
        default:
            return parasitePeek(register)
        }
    }

    /// What `parasiteRead` would return, without side effects.
    public func parasitePeek(_ register: Int) -> UInt8 {
        switch register & 7 {
        case 0: pstatus1 | (status & 0x3F)
        case 1: h2p1
        case 2: pstatus2
        case 3: h2p2
        // FIFO 3's available flag shows the NMI request.
        case 4: (pstatus3 & ~Flag.available) | (pnmi ? Flag.available : 0)
        case 5: h2p3Count > 0 ? h2p3[0] : lastH2PValue
        case 6: pstatus4
        default: h2p4
        }
    }

    public mutating func parasiteWrite(_ register: Int, _ value: UInt8) {
        switch register & 7 {
        case 1:
            if p2h1Count < Tube.fifo1Size {
                p2h1[p2h1WriteIndex] = value
                p2h1WriteIndex = (p2h1WriteIndex + 1) % Tube.fifo1Size
                p2h1Count += 1
                if p2h1Count == Tube.fifo1Size {
                    pstatus1 &= ~Flag.notFull
                }
                hstatus1 |= Flag.available
            }
        case 3:
            p2h2 = value
            Tube.writeLatch(&pstatus2, &hstatus2)
        case 5:
            Tube.writeFIFO3(&pstatus3, &hstatus3, &p2h3, &p2h3Count, value, twoByte: status & Status.v != 0)
            if status & Status.v == 0 || p2h3Count == 2 {
                pnmi = false
            }
        case 7:
            p2h4 = value
            Tube.writeLatch(&pstatus4, &hstatus4)
        default:
            return
        }
        lastP2HValue = value
    }

    // MARK: Helpers

    private static func readLatch(_ this: inout UInt8, _ other: inout UInt8) {
        if this & Flag.available != 0 {
            this &= ~Flag.available
            other |= Flag.notFull
        }
    }

    private static func writeLatch(_ this: inout UInt8, _ other: inout UInt8) {
        this &= ~Flag.notFull
        other |= Flag.available
    }

    private static func readFIFO3(_ this: inout UInt8, _ other: inout UInt8, _ fifo: inout [UInt8], _ count: inout Int, dummy: UInt8) -> UInt8 {
        var value = dummy
        if count > 0 {
            value = fifo[0]
            fifo[0] = fifo[1]
            count -= 1
        }
        if count == 0 {
            this &= ~Flag.available
            other |= Flag.notFull
        }
        return value
    }

    /// Takes a byte while there's room, even in 1-byte mode.
    private static func writeFIFO3(_ this: inout UInt8, _ other: inout UInt8, _ fifo: inout [UInt8], _ count: inout Int, _ value: UInt8, twoByte: Bool) {
        if count < 2 {
            fifo[count] = value
            count += 1
        }
        if !twoByte || count == 2 {
            writeLatch(&this, &other)
        }
    }
}
