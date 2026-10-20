// 6850 ACIA (serial and cassette).
//
// After b2's MC6850.cpp (Copyright (C) Tom Seddon, GPLv3), with the receiver
// and status flags brought closer to the Motorola datasheet:
//
// - At divide by 16 or 64 the receiver hunts for the start bit's leading edge
//   on every clock, checks it at mid-bit and samples each bit at its middle
//   (b2 samples on a fixed /16 grid). It checks only the first stop bit.
// - An overrun shows once the good character before it has been read: that
//   read leaves RDRF set and sets OVRN; the next read clears both.
// - DCD going high latches the DCD flag and, with RIE, interrupts; reading
//   the data register clears both (jsbeeb found the status read the datasheet
//   also asks for doesn't matter on a real machine). High DCD holds the
//   receiver idle.
// - The transmit interrupt follows TDRE, which a high CTS inhibits.
//
// Master reset (CR1:0 = 11) holds both halves in reset and reads as just the
// DCD and CTS inputs.
//
// The serial ULA supplies the receive and transmit clocks (`clockReceive`,
// `clockTransmit`) and the DCD and CTS inputs.

public struct MC6850: Codable, Sendable, Equatable {
    public enum Status {
        public static let rdrf: UInt8 = 0x01
        public static let tdre: UInt8 = 0x02
        public static let dcd: UInt8 = 0x04
        public static let cts: UInt8 = 0x08
        public static let fe: UInt8 = 0x10
        public static let ovrn: UInt8 = 0x20
        public static let pe: UInt8 = 0x40
        public static let irq: UInt8 = 0x80
    }

    enum Parity: UInt8, Codable, Sendable { case none, even, odd }

    /// By word select (CR4-2): data bits, parity, stop bits.
    static let wordFormats: [(bits: UInt8, parity: Parity, stopBits: UInt8)] = [
        (7, .even, 2), (7, .odd, 2), (7, .even, 1), (7, .odd, 1),
        (8, .none, 2), (8, .none, 1), (8, .even, 1), (8, .odd, 1),
    ]

    enum ShiftState: UInt8, Codable, Sendable { case idle, startBit, dataBits, parityBit, stopBits }

    public private(set) var control: UInt8 = 0
    /// IRQ output.
    public private(set) var irq = false
    /// DCD input (high: no carrier).
    public private(set) var dcd = false
    /// CTS input (high: not clear to send).
    public private(set) var cts = false

    var rdr: UInt8 = 0
    var tdr: UInt8 = 0
    var tdrEmpty = true
    var rdrf = false
    var framingError = false
    var parityError = false
    var overrun = false
    /// A character was lost; shows as OVRN after the next data read.
    var overrunPending = false
    /// DCD went high since the data register was last read.
    var dcdLatched = false

    var rxState = ShiftState.idle
    /// Receive clocks into the current bit.
    var rxCount: UInt8 = 0
    var rxBit: UInt8 = 0
    var rxData: UInt8 = 0
    var rxParity: UInt8 = 0
    var rxParityError = false

    var txState = ShiftState.idle
    var txCount: UInt8 = 0
    var txBit: UInt8 = 0
    var txData: UInt8 = 0
    var txParity: UInt8 = 0
    /// TxD output.
    public private(set) var txd = true

    public init() {}

    var inReset: Bool { control & 3 == 3 }
    /// Receive/transmit clocks per bit.
    var divide: UInt8 {
        switch control & 3 {
        case 0: 1
        case 1: 16
        default: 64
        }
    }
    var format: (bits: UInt8, parity: Parity, stopBits: UInt8) { Self.wordFormats[Int(control >> 2 & 7)] }
    var transmitIRQEnabled: Bool { control & 0x60 == 0x20 }
    var receiveIRQEnabled: Bool { control & 0x80 != 0 }
    /// RTS output asserted (low): all but transmitter control 10.
    public var rts: Bool { control & 0x60 != 0x40 }

    /// Needs its clocks: something is being sent or received.
    public var isBusy: Bool { rxState != .idle || txState != .idle || !tdrEmpty }

    // MARK: Registers

    /// Reads the status (even address) or data (odd) register.
    public mutating func read(_ address: Int) -> UInt8 {
        if address & 1 == 0 {
            return status
        }
        // The read the overrun waited for shows it, leaving RDRF set; the
        // one after clears both.
        if overrunPending {
            overrunPending = false
            overrun = true
        } else {
            overrun = false
            rdrf = false
        }
        dcdLatched = false
        updateIRQ()
        return rdr
    }

    /// Reads a register without side effects.
    public func peek(_ address: Int) -> UInt8 {
        address & 1 == 0 ? status : rdr
    }

    /// Writes the control (even address) or transmit data (odd) register.
    public mutating func write(_ address: Int, _ value: UInt8) {
        if address & 1 == 0 {
            control = value
            if inReset {
                reset()
            }
        } else {
            tdr = value
            tdrEmpty = false
        }
        updateIRQ()
    }

    public var status: UInt8 {
        var value: UInt8 = (dcd ? Status.dcd : 0) | (cts ? Status.cts : 0)
        if inReset {
            return value
        }
        if rdrf { value |= Status.rdrf }
        if tdrEmpty && !cts { value |= Status.tdre }
        if dcdLatched { value |= Status.dcd }
        if framingError { value |= Status.fe }
        if overrun { value |= Status.ovrn }
        if parityError { value |= Status.pe }
        if irq { value |= Status.irq }
        return value
    }

    private mutating func reset() {
        rxState = .idle
        txState = .idle
        txd = true
        tdrEmpty = true
        rdrf = false
        framingError = false
        parityError = false
        overrun = false
        overrunPending = false
        dcdLatched = false
    }

    private mutating func updateIRQ() {
        if inReset {
            irq = false
            return
        }
        let rx = receiveIRQEnabled && (rdrf || overrun || dcdLatched)
        let tx = transmitIRQEnabled && tdrEmpty && !cts
        irq = rx || tx
    }

    // MARK: Inputs

    public mutating func setDCD(_ high: Bool) {
        if high && !dcd && !inReset {
            dcdLatched = true
        }
        dcd = high
        if high {
            // DCD high inhibits and initialises the receiver.
            rxState = .idle
        }
        updateIRQ()
    }

    public mutating func setCTS(_ high: Bool) {
        cts = high
        updateIRQ()
    }

    // MARK: Clocks

    /// One receive clock, with `rxd` on the RxD input.
    public mutating func clockReceive(_ rxd: Bool) {
        if inReset || dcd {
            return
        }
        let divide = divide
        switch rxState {
        case .idle:
            guard !rxd else { return }
            rxData = 0
            rxParity = 0
            rxBit = 0
            rxCount = 0
            rxParityError = false
            if divide == 1 {
                // Externally synchronised: this clock samples the start bit.
                rxState = .dataBits
            } else {
                rxState = .startBit
            }
        case .startBit:
            rxCount += 1
            if rxCount >= divide / 2 {
                // Mid start bit; a high here was a glitch.
                rxCount = 0
                rxState = rxd ? .idle : .dataBits
            }
        case .dataBits, .parityBit, .stopBits:
            rxCount += 1
            guard rxCount >= divide else { return }
            rxCount = 0
            sampleBit(rxd)
        }
    }

    private mutating func sampleBit(_ rxd: Bool) {
        let format = format
        switch rxState {
        case .dataBits:
            if rxd {
                rxData |= 1 << rxBit
                rxParity ^= 1
            }
            rxBit += 1
            if rxBit == format.bits {
                rxState = format.parity == .none ? .stopBits : .parityBit
            }
        case .parityBit:
            if rxd { rxParity ^= 1 }
            // Even parity: an even number of ones, parity bit included.
            rxParityError = rxParity != (format.parity == .odd ? 1 : 0)
            rxState = .stopBits
        case .stopBits:
            rxState = .idle
            if rdrf {
                overrunPending = true
            } else {
                rdr = rxData
                rdrf = true
                framingError = !rxd
                parityError = rxParityError
            }
            updateIRQ()
        default:
            break
        }
    }

    /// One transmit clock. Returns the character whose stop bit has just
    /// gone out.
    public mutating func clockTransmit() -> UInt8? {
        if inReset {
            return nil
        }
        txCount += 1
        guard txCount >= divide else { return nil }
        txCount = 0
        let format = format
        switch txState {
        case .idle, .startBit:
            if control & 0x60 == 0x60 {
                // Break.
                txd = false
                return nil
            }
            txd = true
            guard !tdrEmpty else { return nil }
            txData = tdr
            tdrEmpty = true
            txParity = format.parity == .odd ? 1 : 0
            txBit = 0
            txState = .dataBits
            txd = false
            updateIRQ()
        case .dataBits:
            let bit = txData >> txBit & 1
            txParity ^= bit
            txd = bit != 0
            txBit += 1
            if txBit == format.bits {
                txState = format.parity == .none ? .stopBits : .parityBit
                txBit = 0
            }
        case .parityBit:
            txd = txParity != 0
            txState = .stopBits
        case .stopBits:
            txd = true
            txBit += 1
            if txBit == format.stopBits {
                txState = .idle
                return format.bits == 8 ? txData : txData & 0x7F
            }
        }
        return nil
    }
}
