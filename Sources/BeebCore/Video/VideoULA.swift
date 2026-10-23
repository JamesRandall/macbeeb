// Video ULA: serialises screen bytes into pixels through the palette.
//
// A port of b2's VideoULA.cpp (Copyright (C) Tom Seddon, GPLv3), including
// its VideoNuLA: with `nula` set (the upgrade fitted), &FE22 and &FE23
// (A1 set) are NuLA's control and palette registers; without it they're
// the stock ULA's, as before.

public struct VideoULA: Codable, Sendable {
    /// Control register (&FE20).
    public internal(set) var control: UInt8 = 0
    /// Logical colour -> physical colour (0-15, already XORed with 7).
    var palette = InlineArray<16, UInt8>(repeating: 0)
    /// Cursor bits for the next columns; public because Mode 7 handles the
    /// cursor separately.
    public var cursorPattern: UInt8 = 0
    var workByte: UInt8 = 0
    /// VideoNuLA's state, if it's fitted (nil: the stock Video ULA).
    public internal(set) var nula: VideoNuLA?

    public init() {}

    /// A Video ULA with VideoNuLA fitted, in its power-on state.
    public init(nula: Bool) {
        if nula {
            self.nula = VideoNuLA()
        }
    }

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
        if nula != nil {
            nula!.updatePixelBufferOffset(fast6845: fast6845)
        }
    }

    public mutating func writePalette(_ value: UInt8) {
        palette[Int(value >> 4)] = (value & 0x0F) ^ 7
    }

    /// Logical colour -> physical colour, 0-15. (The OS writes &FE21 with
    /// the physical colour EOR 7, and the ULA inverts it back.)
    public var logicalPalette: [UInt8] {
        (0..<16).map { palette[$0] }
    }

    /// The colour pixels of logical colour `logical` show now (RGB444),
    /// flashing included: what a NuLA-aware program sees on screen.
    public func effectiveColour(logical: Int) -> UInt16 {
        guard let n = nula else {
            let physical = Int(palette[logical])
            return flash ? Self.flashPalette[physical] : Self.outputPalette[physical]
        }
        var index = n.directPalette ? logical : Int(palette[logical])
        if n.flash[index] && flash {
            index ^= 7
        }
        return n.outputPalette[index]
    }

    /// The palette for teletext and output: NuLA's, or the stock one.
    var output: InlineArray<16, UInt16> {
        nula?.outputPalette ?? Self.outputPalette
    }

    // MARK: VideoNuLA

    /// A write to &FE22 with NuLA fitted (until A1 is disabled): the high
    /// nibble picks the function, the low nibble is its parameter.
    public mutating func writeNuLAControl(_ value: UInt8) {
        guard var n = nula, !n.disableA1 else {
            writeControl(value)
            return
        }
        let parameter = value & 0x0F
        switch value >> 4 {
        case 1: n.directPalette = parameter & 1 != 0
        case 2:
            n.scrollOffset = parameter & 7
        case 3: n.blankingSize = parameter
        case 4: n.resetState()
        case 5: n.disableA1 = true
        case 6: n.attributeMode = parameter & 3
        case 7: n.textAttributeMode = parameter & 1 != 0
        case 8:
            for i in 0..<4 { n.flash[8 + i] = parameter & (8 >> i) != 0 }
        case 9:
            for i in 0..<4 { n.flash[12 + i] = parameter & (8 >> i) != 0 }
        default:
            // Unknown functions (0, A-F) are ignored, as b2 does.
            n.ignoredWrites += 1
        }
        n.updatePixelBufferOffset(fast6845: fast6845)
        nula = n
    }

    /// A write to &FE23 with NuLA fitted (until A1 is disabled): the first
    /// byte is the index and red, the second green and blue.
    public mutating func writeNuLAPalette(_ value: UInt8) {
        guard var n = nula, !n.disableA1 else {
            writePalette(value)
            return
        }
        if n.paletteWritePending {
            let index = Int(n.paletteWriteBuffer >> 4)
            n.outputPalette[index] = UInt16(n.paletteWriteBuffer & 0x0F) << 8 | UInt16(value)
            n.flash[index] = false
        } else {
            n.paletteWriteBuffer = value
        }
        n.paletteWritePending.toggle()
        nula = n
    }

    /// Called as each byte is fetched while the display was off (b2's
    /// DisplayEnabled): starts the line's blanking count and scroll.
    @inline(__always)
    mutating func displayEnabled() {
        guard nula != nil else { return }
        nula!.blankingCounter = nula!.blankingSize << 1
        for i in 0..<8 { nula!.pixelBuffer[i] = 0 }
        if nula!.scrollOffset > 0 {
            var scratch = VideoUnit()
            emitNuLA(&scratch)
            if !fast6845 {
                emitNuLA(&scratch)
            }
        }
    }

    @inline(__always)
    mutating func byte(_ value: UInt8, cudisp: Bool) {
        workByte = value
        if nula != nil {
            nula!.originalByte = value
        }
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
        if nula != nil {
            emitNuLA(&unit)
            cursorPattern >>= fast6845 ? 2 : 1
            return
        }
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

    /// One NuLA shift: the colour index from the byte (by mode, palette
    /// mode and attribute mode), through the palette unless direct, and the
    /// flash.
    @inline(__always)
    private mutating func shiftNuLA(logical: Bool, attribute: Bool, bpp: Int) -> UInt16 {
        var index = workByte
        let original = nula!.originalByte
        if attribute {
            if bpp == 1 {
                index = index >> 7 | (original & 0x03) << 2
            } else {
                index = (original >> 1 & 8) | (original << 2 & 4) | (workByte >> 6 & 2) | (workByte >> 3 & 1)
            }
        } else if logical && bpp == 1 {
            index >>= 7
        } else if logical && bpp == 2 {
            index = (index >> 6 & 2) | (index >> 3 & 1)
        } else {
            index = (index >> 4 & 8) | (index >> 3 & 4) | (index >> 2 & 2) | (index >> 1 & 1)
        }
        workByte = workByte << 1 | 1
        if !logical {
            index = palette[Int(index)]
        }
        if nula!.flash[Int(index)] && flash {
            index ^= 7
        }
        return nula!.outputPalette[Int(index)]
    }

    /// b2's EmitNuLA: the unit's pixels by the ULA's pixel rate, written
    /// into the scroll buffer at the offset, then the cursor, the left
    /// blanking, and out. In attribute mode the unit is marked as 12MHz
    /// pixels (whatever the rate), and at 4MHz it adds nothing to the
    /// buffer, both as b2 has it.
    private mutating func emitNuLA(_ unit: inout VideoUnit) {
        let logical = nula!.directPalette
        let attribute = nula!.attributeMode == 1
        let fast = fast6845
        let o = Int(nula!.pixelBufferOffset)
        @inline(__always) func put(_ i: Int, _ value: UInt16) { nula!.pixelBuffer[o + i] = value }
        switch lineWidth {
        case 0:
            if attribute {
                let a = shiftNuLA(logical: logical, attribute: true, bpp: 2)
                put(0, a)
                put(1, a)
                for i in 2..<8 { put(i, 0) }
                workByte = 0
                nula!.originalByte = 0
            } else {
                let a = shiftNuLA(logical: logical, attribute: false, bpp: 4)
                for i in 0..<8 { put(i, a) }
            }
        case 1:
            if !attribute {
                let a = shiftNuLA(logical: logical, attribute: false, bpp: fast ? 4 : 2)
                for i in 0..<4 { put(i, a) }
                let b = shiftNuLA(logical: logical, attribute: false, bpp: fast ? 4 : 2)
                for i in 4..<8 { put(i, b) }
            }
        case 2:
            if attribute {
                for i in 0..<3 {
                    let a = shiftNuLA(logical: logical, attribute: true, bpp: fast ? 2 : 1)
                    put(i * 2, a)
                    put(i * 2 + 1, a)
                }
            } else {
                for i in 0..<4 {
                    let a = shiftNuLA(logical: logical, attribute: false, bpp: fast ? 2 : 1)
                    put(i * 2, a)
                    put(i * 2 + 1, a)
                }
            }
        default:
            if attribute {
                for i in 0..<6 {
                    put(i, shiftNuLA(logical: logical, attribute: true, bpp: 1))
                }
                if !fast {
                    workByte = 0
                }
            } else if fast {
                for i in 0..<8 {
                    put(i, shiftNuLA(logical: logical, attribute: false, bpp: 1))
                }
            } else {
                // Still 320 pixels across, as b2 has it.
                for i in 0..<4 {
                    workByte = workByte << 1 | 1
                    let a = shiftNuLA(logical: logical, attribute: false, bpp: 1)
                    put(i * 2, a)
                    put(i * 2 + 1, a)
                }
            }
        }
        if cursorPattern & 1 != 0 {
            for i in 0..<8 { nula!.pixelBuffer[o + i] ^= cursorXOR }
        }
        if nula!.blankingCounter > 0 {
            nula!.blankingCounter -= fast ? min(2, nula!.blankingCounter) : 1
            unit.pixels = .zero
        } else {
            var p = SIMD8<UInt16>.zero
            for i in 0..<8 { p[i] = nula!.pixelBuffer[i] }
            if attribute {
                p[0] = (p[0] & 0x0FFF) | VideoUnit.Kind.bitmap12MHz.rawValue << 12
            }
            unit.pixels = p
        }
        for i in 0..<24 { nula!.pixelBuffer[i] = nula!.pixelBuffer[i + 8] }
        for i in 24..<32 { nula!.pixelBuffer[i] = 0 }
    }
}

/// VideoNuLA: a Video ULA with sixteen programmable 12-bit colours, and
/// more. Its registers are write-only on the real hardware; this is the
/// emulator's diagnostic copy.
public struct VideoNuLA: Codable, Sendable {
    /// The sixteen colours, RGB444 (0x0RGB), as programmed through &FE23.
    public internal(set) var outputPalette = VideoULA.outputPalette
    /// Which (physical, or in direct mode logical) colours flash.
    public internal(set) var flash = InlineArray<16, Bool>(repeating: false)
    /// The first byte of a two-byte palette write has arrived.
    public internal(set) var paletteWritePending = false
    public internal(set) var paletteWriteBuffer: UInt8 = 0
    /// Function 1: logical colours go straight to the palette.
    public internal(set) var directPalette = false
    /// Function 5: NuLA's registers are off (A1 ignored) until power off.
    public internal(set) var disableA1 = false
    /// Function 2: pixels the display is shifted right by (0-7).
    public internal(set) var scrollOffset: UInt8 = 0
    /// Function 3: columns blanked at the left of each line (0-15).
    public internal(set) var blankingSize: UInt8 = 0
    /// Function 6: attribute mode (0-3; b2 implements 1).
    public internal(set) var attributeMode: UInt8 = 0
    /// Function 7: text attribute mode (not implemented, as in b2).
    public internal(set) var textAttributeMode = false
    /// Writes to &FE22 with a function NuLA doesn't have.
    public internal(set) var ignoredWrites = 0
    var blankingCounter: UInt8 = 0
    var pixelBufferOffset: UInt8 = 0
    var originalByte: UInt8 = 0
    var pixelBuffer = InlineArray<32, UInt16>(repeating: 0)

    public init() {
        resetState()
    }

    /// Function 4, and power on: the standard colours, colours 8-15
    /// flashing, no scroll or blanking, the ULA's palette in use.
    mutating func resetState() {
        for i in 0..<16 {
            outputPalette[i] = (i & 1 != 0 ? 0x0F00 : 0) | (i & 2 != 0 ? 0x00F0 : 0) | (i & 4 != 0 ? 0x000F : 0)
            flash[i] = i >= 8
        }
        scrollOffset = 0
        blankingSize = 0
        directPalette = false
        paletteWritePending = false
        attributeMode = 0
    }

    mutating func updatePixelBufferOffset(fast6845: Bool) {
        pixelBufferOffset = (scrollOffset << 1) >> (fast6845 ? 1 : 0)
    }

    /// Colour `index` as 8-bit RGB (each nibble doubled), e.g. "#FF8800".
    public func rgb888(_ index: Int) -> String {
        let c = outputPalette[index]
        return String(format: "#%02X%02X%02X", Int(c >> 8 & 15) * 17, Int(c >> 4 & 15) * 17, Int(c & 15) * 17)
    }
}
