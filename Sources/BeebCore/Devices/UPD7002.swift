// uPD7002 analogue to digital converter (joysticks).
//
// A port of b2's adc.cpp (Copyright (C) Tom Seddon, GPLv3).

public struct UPD7002 {
    static let conversionTime10Bit: UInt16 = 10_000
    static let conversionTime8Bit: UInt16 = 4_000

    /// Channel inputs, 0-1023. (1023 is what b2 uses with nothing
    /// connected.)
    public var channels = InlineArray<4, UInt16>(repeating: 1023)

    // Status: channel (bits 0-1), flag (2), 10-bit (3), MSBs (4-5),
    // not busy (6), not end of conversion (7).
    var status: UInt8 = 0xC0
    var analogue: UInt16 = 0
    /// Result of the previous conversion, left-justified.
    var digital: UInt16 = 0
    /// Microseconds left in the current conversion.
    var timer: UInt16 = 0

    public init() {}

    public mutating func read(_ register: Int) -> UInt8 {
        switch register & 3 {
        case 0:
            return status
        case 1:
            status |= 0x80
            return UInt8(truncatingIfNeeded: digital >> 8)
        default:
            return UInt8(truncatingIfNeeded: digital)
        }
    }

    public func peek(_ register: Int) -> UInt8 {
        switch register & 3 {
        case 0: return status
        case 1: return UInt8(truncatingIfNeeded: digital >> 8)
        default: return UInt8(truncatingIfNeeded: digital)
        }
    }

    public mutating func write(_ register: Int, _ value: UInt8) {
        // Only register 0 (start conversion) does anything.
        guard register & 3 == 0 else { return }
        status = value & 0x0F
        timer = value & 0x08 != 0 ? Self.conversionTime10Bit : Self.conversionTime8Bit
        status |= UInt8(truncatingIfNeeded: digital >> 14) << 4
        // Busy; end of conversion not yet.
        status |= 0x80
        analogue = channels[Int(value & 3)]
    }

    /// Advances 1us. Returns the inverted end-of-conversion signal.
    @inline(__always)
    public mutating func update() -> Bool {
        if timer > 0 {
            timer -= 1
            if timer == 0 {
                digital = analogue << 6
                status = (status & 0x0F) | UInt8(truncatingIfNeeded: digital >> 14) << 4 | 0x40
            }
        }
        return status & 0x80 != 0
    }
}
