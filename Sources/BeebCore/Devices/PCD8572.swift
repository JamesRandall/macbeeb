// PCD8572 128-byte I2C EEPROM: the Master Compact's CMOS settings, on the
// system VIA's PB5 (clock) and PB4 (data).
//
// A port of b2's PCD8572.cpp (Copyright (C) Tom Seddon, GPLv3), after
// B-em's compactcmos.c.

public struct PCD8572: Codable, Sendable, Equatable {
    enum State: Codable, Sendable, Equatable {
        case idle, startReceiveSlaveAddress, receiveSlaveAddress, sendAcknowledge
        case receiveWordAddress, receiveData, sendData, receiveAcknowledge
    }

    public static let size = 128

    var ram: [UInt8]
    var state = State.idle
    var nextState = State.idle
    var oldClock = false
    var oldData = false
    var value: UInt8 = 0
    var valueMask: UInt8 = 0
    var address: UInt8 = 0
    /// The data line as the EEPROM drives it (pulled up when it isn't).
    public private(set) var dataOutput = true

    /// The Master Compact's defaults, as b2: MODE 7, ADFS, BASIC, and the
    /// valid flag MOS 5.10 looks for.
    public static let defaultMasterCompact: [UInt8] = {
        var ram = [UInt8](repeating: 0, count: size)
        ram[5] = 0xED   // LANG 14, FS 13
        ram[6] = 0xFF   // INSERT 0-7
        ram[7] = 0xFF   // INSERT 8-15
        ram[10] = 0x17  // MODE 7, SHADOW 0, TV 0 1
        ram[11] = 0xE0  // FLOPPY, NODIR, CAPS (b2 has &C0, without CAPS)
        ram[12] = 55    // DELAY 55
        ram[13] = 0x03  // REPEAT 3
        ram[15] = 0x01  // TUBE
        ram[16] = 0x02  // LOUD
        ram[127] = 0xB0
        return ram
    }()

    public init(contents: [UInt8] = defaultMasterCompact) {
        ram = contents.count == Self.size ? contents : Array(contents.prefix(Self.size)) + [UInt8](repeating: 0, count: max(0, Self.size - contents.count))
    }

    public var contents: [UInt8] { ram }

    /// Shifts in a bit on the clock's falling edge; true when a byte's done.
    private mutating func received(clock: Bool, data: Bool) -> Bool {
        guard oldClock && !clock else { return false }
        if valueMask == 0 { valueMask = 0x80 }
        if data { value |= valueMask } else { value &= ~valueMask }
        valueMask >>= 1
        return valueMask == 0
    }

    private mutating func acknowledge(then next: State) {
        state = .sendAcknowledge
        nextState = next
    }

    /// Called when either line changes.
    public mutating func update(clock: Bool, data: Bool) {
        if oldClock && clock {
            if oldData && !data {
                // START.
                valueMask = 0
                state = .startReceiveSlaveAddress
            } else if !oldData && data {
                // STOP.
                state = .idle
            }
        }

        switch state {
        case .idle:
            break
        case .startReceiveSlaveAddress:
            if !clock { state = .receiveSlaveAddress }
        case .receiveSlaveAddress:
            if received(clock: clock, data: data) {
                if value & 0x0E != 0 {
                    // Not addressed to us.
                    state = .idle
                } else if value & 1 != 0 {
                    acknowledge(then: .sendData)
                } else {
                    acknowledge(then: .receiveWordAddress)
                }
            }
        case .sendAcknowledge:
            if clock {
                dataOutput = false
            } else if oldClock {
                state = nextState
                nextState = .idle
            }
        case .receiveWordAddress:
            if received(clock: clock, data: data) {
                address = value
                acknowledge(then: .receiveData)
            }
        case .receiveData:
            if received(clock: clock, data: data) {
                ram[Int(address & 0x7F)] = value
                address &+= 1
                acknowledge(then: .receiveData)
            }
        case .sendData:
            if valueMask == 0 {
                value = ram[Int(address & 0x7F)]
                valueMask = 0x80
            }
            if !oldClock && clock {
                dataOutput = value & valueMask != 0
            }
            if oldClock && !clock {
                valueMask >>= 1
                if valueMask == 0 { state = .receiveAcknowledge }
            }
        case .receiveAcknowledge:
            if oldClock && clock && !data {
                address &+= 1
                state = .sendData
            }
        }
        oldClock = clock
        oldData = data
    }
}
