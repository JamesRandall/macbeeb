// VideoNuLA: RobC's replacement Video ULA, with sixteen programmable 12-bit
// colours. A port of the NuLA part of b2's VideoULA.cpp (Copyright (C) Tom
// Seddon, GPLv3).
//
// It works with the stock ULA's state (its palette, control register and
// the byte being shifted), so its methods take the VideoULA. The machine
// keeps it beside the ULA and only calls it when NuLA is fitted.

/// VideoNuLA's state. Its registers are write-only on the real hardware;
/// this is the emulator's diagnostic copy.
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
    /// The byte being shifted, as fetched (attribute modes use its bits).
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

    /// The colour pixels of logical colour `logical` show now (RGB444),
    /// flashing included: what a NuLA-aware program sees on screen.
    public func colour(logical: Int, ula: VideoULA) -> UInt16 {
        var index = directPalette ? logical : Int(ula.palette[logical])
        if flash[index] && ula.flash {
            index ^= 7
        }
        return outputPalette[index]
    }

    // MARK: Registers

    /// A write to &FE22 (until A1 is disabled): the high nibble picks the
    /// function, the low nibble is its parameter.
    mutating func writeControl(_ value: UInt8, ula: inout VideoULA) {
        guard !disableA1 else {
            ula.writeControl(value)
            updatePixelBufferOffset(fast6845: ula.fast6845)
            return
        }
        let parameter = value & 0x0F
        switch value >> 4 {
        case 1: directPalette = parameter & 1 != 0
        case 2: scrollOffset = parameter & 7
        case 3: blankingSize = parameter
        case 4: resetState()
        case 5: disableA1 = true
        case 6: attributeMode = parameter & 3
        case 7: textAttributeMode = parameter & 1 != 0
        case 8:
            for i in 0..<4 { flash[8 + i] = parameter & (8 >> i) != 0 }
        case 9:
            for i in 0..<4 { flash[12 + i] = parameter & (8 >> i) != 0 }
        default:
            // Unknown functions (0, A-F) are ignored, as b2 does.
            ignoredWrites += 1
        }
        updatePixelBufferOffset(fast6845: ula.fast6845)
    }

    /// A write to &FE23 (until A1 is disabled): the first byte is the index
    /// and red, the second green and blue.
    mutating func writePalette(_ value: UInt8, ula: inout VideoULA) {
        guard !disableA1 else {
            ula.writePalette(value)
            return
        }
        if paletteWritePending {
            let index = Int(paletteWriteBuffer >> 4)
            outputPalette[index] = UInt16(paletteWriteBuffer & 0x0F) << 8 | UInt16(value)
            flash[index] = false
        } else {
            paletteWriteBuffer = value
        }
        paletteWritePending.toggle()
    }

    // MARK: Pixels

    /// Called as each byte is fetched while the display was off (b2's
    /// DisplayEnabled): starts the line's blanking count and scroll.
    mutating func displayEnabled(ula: inout VideoULA) {
        blankingCounter = blankingSize << 1
        for i in 0..<8 { pixelBuffer[i] = 0 }
        if scrollOffset > 0 {
            var scratch = VideoUnit()
            emitPixels(&scratch, ula: &ula)
            if !ula.fast6845 {
                emitPixels(&scratch, ula: &ula)
            }
        }
    }

    /// The displayed part of a unit: NuLA's version of the ULA's
    /// emitPixels.
    mutating func emit(_ unit: inout VideoUnit, ula: inout VideoULA) {
        emitPixels(&unit, ula: &ula)
        ula.cursorPattern >>= ula.fast6845 ? 2 : 1
    }

    /// One shift: the colour index from the byte (by mode, palette mode and
    /// attribute mode), through the palette unless direct, and the flash.
    @inline(__always)
    private mutating func shift(_ ula: inout VideoULA, logical: Bool, attribute: Bool, bpp: Int) -> UInt16 {
        let work = ula.workByte
        var index = work
        if attribute {
            if bpp == 1 {
                index = index >> 7 | (originalByte & 0x03) << 2
            } else {
                index = (originalByte >> 1 & 8) | (originalByte << 2 & 4) | (work >> 6 & 2) | (work >> 3 & 1)
            }
        } else if logical && bpp == 1 {
            index >>= 7
        } else if logical && bpp == 2 {
            index = (index >> 6 & 2) | (index >> 3 & 1)
        } else {
            index = (index >> 4 & 8) | (index >> 3 & 4) | (index >> 2 & 2) | (index >> 1 & 1)
        }
        ula.workByte = work << 1 | 1
        if !logical {
            index = ula.palette[Int(index)]
        }
        if flash[Int(index)] && ula.flash {
            index ^= 7
        }
        return outputPalette[Int(index)]
    }

    /// b2's EmitNuLA: the unit's pixels by the ULA's pixel rate, written
    /// into the scroll buffer at the offset, then the cursor, the left
    /// blanking, and out. In attribute mode the unit is marked as 12MHz
    /// pixels (whatever the rate), and at 4MHz it adds nothing to the
    /// buffer, both as b2 has it.
    private mutating func emitPixels(_ unit: inout VideoUnit, ula: inout VideoULA) {
        let logical = directPalette
        let attribute = attributeMode == 1
        let fast = ula.fast6845
        let o = Int(pixelBufferOffset)
        switch ula.lineWidth {
        case 0:
            if attribute {
                let a = shift(&ula, logical: logical, attribute: true, bpp: 2)
                pixelBuffer[o] = a
                pixelBuffer[o + 1] = a
                for i in 2..<8 { pixelBuffer[o + i] = 0 }
                ula.workByte = 0
                originalByte = 0
            } else {
                let a = shift(&ula, logical: logical, attribute: false, bpp: 4)
                for i in 0..<8 { pixelBuffer[o + i] = a }
            }
        case 1:
            if !attribute {
                let a = shift(&ula, logical: logical, attribute: false, bpp: fast ? 4 : 2)
                for i in 0..<4 { pixelBuffer[o + i] = a }
                let b = shift(&ula, logical: logical, attribute: false, bpp: fast ? 4 : 2)
                for i in 4..<8 { pixelBuffer[o + i] = b }
            }
        case 2:
            if attribute {
                for i in 0..<3 {
                    let a = shift(&ula, logical: logical, attribute: true, bpp: fast ? 2 : 1)
                    pixelBuffer[o + i * 2] = a
                    pixelBuffer[o + i * 2 + 1] = a
                }
            } else {
                for i in 0..<4 {
                    let a = shift(&ula, logical: logical, attribute: false, bpp: fast ? 2 : 1)
                    pixelBuffer[o + i * 2] = a
                    pixelBuffer[o + i * 2 + 1] = a
                }
            }
        default:
            if attribute {
                for i in 0..<6 {
                    pixelBuffer[o + i] = shift(&ula, logical: logical, attribute: true, bpp: 1)
                }
                if !fast {
                    ula.workByte = 0
                }
            } else if fast {
                for i in 0..<8 {
                    pixelBuffer[o + i] = shift(&ula, logical: logical, attribute: false, bpp: 1)
                }
            } else {
                // Still 320 pixels across, as b2 has it.
                for i in 0..<4 {
                    ula.workByte = ula.workByte << 1 | 1
                    let a = shift(&ula, logical: logical, attribute: false, bpp: 1)
                    pixelBuffer[o + i * 2] = a
                    pixelBuffer[o + i * 2 + 1] = a
                }
            }
        }
        if ula.cursorPattern & 1 != 0 {
            for i in 0..<8 { pixelBuffer[o + i] ^= cursorXOR }
        }
        if blankingCounter > 0 {
            blankingCounter -= fast ? min(2, blankingCounter) : 1
            unit.pixels = .zero
        } else {
            var p = SIMD8<UInt16>.zero
            for i in 0..<8 { p[i] = pixelBuffer[i] }
            if attribute {
                p[0] = (p[0] & 0x0FFF) | VideoUnit.Kind.bitmap12MHz.rawValue << 12
            }
            unit.pixels = p
        }
        for i in 0..<24 { pixelBuffer[i] = pixelBuffer[i + 8] }
        for i in 24..<32 { pixelBuffer[i] = 0 }
    }
}
