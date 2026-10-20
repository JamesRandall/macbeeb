// Video ULA: serialises screen bytes into pixels through the palette.
//
// A port of the non-NuLA part of b2's VideoULA.cpp (Copyright (C) Tom
// Seddon, GPLv3).

public struct VideoULA {
    /// Control register (&FE20).
    public internal(set) var control: UInt8 = 0
    /// Logical colour -> physical colour (0-15, already XORed with 7).
    var palette = InlineArray<16, UInt8>(repeating: 0)
    /// Cursor bits for the next columns; public because Mode 7 handles the
    /// cursor separately.
    public var cursorPattern: UInt8 = 0
    var workByte: UInt8 = 0

    public init() {}

    public var flash: Bool { control & 0x01 != 0 }
    public var teletext: Bool { control & 0x02 != 0 }
    /// 0-3: 2, 4, 8 or 16MHz pixel rate.
    public var lineWidth: UInt8 { control >> 2 & 3 }
    public var fast6845: Bool { control & 0x10 != 0 }
    public var cursorShape: UInt8 { control >> 5 }

    /// The palette for teletext and output: physical colour -> pixel.
    public static let outputPalette: InlineArray<16, UInt16> = [
        0x0000, 0x0F00, 0x00F0, 0x0FF0, 0x000F, 0x0F0F, 0x00FF, 0x0FFF,
        0x0000, 0x0F00, 0x00F0, 0x0FF0, 0x000F, 0x0F0F, 0x00FF, 0x0FFF,
    ]

    /// Physical colour -> pixel, with flashing colours (8-15) in their
    /// second state.
    static let flashPalette: InlineArray<16, UInt16> = [
        0x0000, 0x0F00, 0x00F0, 0x0FF0, 0x000F, 0x0F0F, 0x00FF, 0x0FFF,
        0x0FFF, 0x00FF, 0x0F0F, 0x000F, 0x0FF0, 0x00F0, 0x0F00, 0x0000,
    ]

    /// The cursor pattern is spread over the next 4 displayed columns. Bit 7
    /// of the control register controls the first column, bit 6 the second,
    /// bit 5 the third and fourth. 2 identical bits per column.
    static let cursorPatterns: InlineArray<8, UInt8> = [
        0x00, 0xF0, 0x0C, 0xFC, 0x03, 0xF3, 0x0F, 0xFF,
    ]

    public mutating func writeControl(_ value: UInt8) {
        control = value
    }

    public mutating func writePalette(_ value: UInt8) {
        palette[Int(value >> 4)] = (value & 0x0F) ^ 7
    }

    @inline(__always)
    mutating func byte(_ value: UInt8, cudisp: Bool) {
        workByte = value
        if cudisp {
            cursorPattern = Self.cursorPatterns[Int(cursorShape)]
        }
    }

    @inline(__always)
    private mutating func shift() -> UInt16 {
        let b = workByte
        let index = (b >> 1 & 1) | (b >> 2 & 2) | (b >> 3 & 4) | (b >> 4 & 8)
        workByte = b << 1 | 1
        let physical = Int(palette[Int(index)])
        return flash ? Self.flashPalette[physical] : Self.outputPalette[physical]
    }

    @inline(__always)
    mutating func emitPixels(_ unit: inout VideoUnit) {
        var p = SIMD8<UInt16>.zero
        switch lineWidth {
        case 0:
            p = SIMD8(repeating: shift())
        case 1:
            let a = shift(), b = shift()
            p = SIMD8(a, a, a, a, b, b, b, b)
        case 2:
            let a = shift(), b = shift(), c = shift(), d = shift()
            p = SIMD8(a, a, b, b, c, c, d, d)
        default:
            for i in 0..<8 {
                p[i] = shift()
            }
        }
        if cursorPattern & 1 != 0 {
            p ^= SIMD8(repeating: cursorXOR)
        }
        unit.pixels = p
        cursorPattern >>= fast6845 ? 2 : 1
    }

    @inline(__always)
    mutating func emitBlank(_ unit: inout VideoUnit) {
        unit.pixels = cursorPattern & 1 != 0 ? SIMD8(repeating: cursorXOR) : .zero
        cursorPattern >>= fast6845 ? 2 : 1
    }
}
