// Serial ULA (SERPROC): the 6850's clocks, the RS423/cassette switch, the
// cassette tone decoder and the motor relay.
//
// After b2's serproc.cpp (Copyright (C) Tom Seddon, GPLv3), which doesn't
// do the cassette; the carrier detect timing is jsbeeb's (Matt Godbolt et
// al., GPLv3) and BeebEm's, measured on real machines.
//
// The control register (&FE10, write only):
//
// - bits 0-2: transmit rate, bits 3-5: receive rate (RS423 only). The ULA
//   divides its 1.2308MHz (16MHz/13) by 1, 16, 4, 128, 2, 64, 8 or 256 (for
//   values 0-7) to clock the ACIA, which divides again by 64 for 19200 down
//   to 75 baud.
// - bit 6: RS423 (1) or cassette (0).
// - bit 7: cassette motor relay.
//
// With the cassette selected both ACIA clocks are 1.2308MHz/64 (19.2kHz)
// whatever the rate bits say: the OS reads at 1200 baud with the ACIA
// dividing by 16, and at 300 by 64. RxD is the decoded tone (2400Hz: 1,
// 1200Hz: 0, silence: 1, so the receiver idles), CTS is low, and DCD
// pulses high for 210us after 174ms of unbroken high tone: the OS takes
// that interrupt to mean carrier has been found.
//
// With RS423 selected nothing is connected: RxD idles at 1, CTS is high (so
// the ACIA's TDRE reads 0) and DCD is low.
//
// `update()` runs once per 1MHz cycle. With the motor off and the ACIA
// neither sending nor receiving it returns at once.

public struct SerialULA: Codable, Sendable, Equatable {
    /// 16MHz/13 against the 1MHz the ULA is updated at: 16 per update, a
    /// clock every 13 * divider.
    static let clockStep = 16
    static let clockPeriod = 13
    /// ULA clock dividers by rate field (b2's SERPROC_BAUD_RATES, at /64).
    static let dividers = [1, 16, 4, 128, 2, 64, 8, 256]
    static let cassetteDivider = 64
    /// Unbroken high tone before DCD rises (jsbeeb's measurement), and how
    /// long it stays up.
    static let carrierDetectCycles = 174_000
    static let dcdPulseCycles = 210

    public private(set) var acia = MC6850()
    public private(set) var control: UInt8 = 0

    private var txPeriod = clockPeriod * cassetteDivider
    private var rxPeriod = clockPeriod * cassetteDivider
    private var txPhase = 0
    private var rxPhase = 0
    /// Decoded cassette input.
    private var cassetteRxD = true
    /// Microseconds of unbroken high tone, up to `carrierDetectCycles`.
    private var carrierCycles = 0
    private var dcdPulse = 0
    /// Something needs clocking: see `update()`.
    private var active = false

    /// The last character the ACIA sent (to the cassette or RS423).
    public private(set) var lastTransmitted: UInt8?
    /// Characters the ACIA has sent.
    public private(set) var transmitCount = 0

    public init() {
        writeControl(0)
    }

    public var motorOn: Bool { control & 0x80 != 0 }
    public var rs423Selected: Bool { control & 0x40 != 0 }
    /// The ACIA's IRQ output.
    public var irq: Bool { acia.irq }

    /// Writes the control register. Returns true when the motor relay
    /// switched.
    @discardableResult
    public mutating func writeControl(_ value: UInt8) -> Bool {
        let relay = (value ^ control) & 0x80 != 0
        control = value
        if !motorOn {
            // The tape stops: no tone.
            carrierCycles = 0
            cassetteRxD = true
        }
        if rs423Selected {
            txPeriod = Self.clockPeriod * Self.dividers[Int(value & 7)]
            rxPeriod = Self.clockPeriod * Self.dividers[Int(value >> 3 & 7)]
            carrierCycles = 0
            dcdPulse = 0
            acia.setCTS(true)
            acia.setDCD(false)
        } else {
            txPeriod = Self.clockPeriod * Self.cassetteDivider
            rxPeriod = txPeriod
            acia.setCTS(false)
        }
        txPhase = min(txPhase, txPeriod - 1)
        rxPhase = min(rxPhase, rxPeriod - 1)
        updateActive()
        return relay
    }

    // MARK: ACIA

    public mutating func readACIA(_ address: Int) -> UInt8 {
        acia.read(address)
    }

    public func peekACIA(_ address: Int) -> UInt8 {
        acia.peek(address)
    }

    public mutating func writeACIA(_ address: Int, _ value: UInt8) {
        acia.write(address, value)
        updateActive()
    }

    // MARK: Update

    /// One 1MHz cycle. `tape` plays while the motor is on.
    @inline(__always)
    public mutating func update(tape: Tape?) {
        if active {
            step(tape)
        }
    }

    private mutating func step(_ tape: Tape?) {
        var signal = Tape.Signal.silence
        if motorOn, let tape {
            _ = tape.tick()
            signal = tape.signal
        }
        cassetteRxD = signal != .low
        if !rs423Selected {
            detectCarrier(signal)
        }

        txPhase += Self.clockStep
        while txPhase >= txPeriod {
            txPhase -= txPeriod
            if let byte = acia.clockTransmit() {
                lastTransmitted = byte
                transmitCount += 1
            }
        }
        rxPhase += Self.clockStep
        while rxPhase >= rxPeriod {
            rxPhase -= rxPeriod
            acia.clockReceive(rs423Selected || cassetteRxD)
        }
        updateActive()
    }

    @inline(__always)
    private mutating func detectCarrier(_ signal: Tape.Signal) {
        if dcdPulse > 0 {
            dcdPulse -= 1
            if dcdPulse == 0 {
                acia.setDCD(false)
            }
        }
        if signal == .high {
            if carrierCycles < Self.carrierDetectCycles {
                carrierCycles += 1
                if carrierCycles == Self.carrierDetectCycles {
                    dcdPulse = Self.dcdPulseCycles
                    acia.setDCD(true)
                }
            }
        } else {
            carrierCycles = 0
        }
    }

    private mutating func updateActive() {
        active = motorOn || dcdPulse > 0 || acia.isBusy
    }
}
