// SAA5050 teletext character generator (Mode 7).
//
// A port of b2's teletext.cpp (Copyright (C) Tom Seddon, GPLv3). Glyphs are
// 6 pixels wide, scaled to 12 with the chip's character rounding, and two
// output rows are produced per scanline (one per interlaced field).
//
// The data sheet says LOSE to display is "typically" 2.6us, modelled by a
// buffer that delays output by 4 units (2us).

public struct SAA5050: Codable, Sendable {
    enum Charset: Int, Codable {
        case alpha = 0, contiguousGraphics, separatedGraphics
    }

    struct Output: Codable {
        var fg: UInt8 = 0
        var bg: UInt8 = 0
        var data0: UInt8 = 0
        var data1: UInt8 = 0
    }

    static let flashOffFrames: UInt8 = 16
    static let flashCycleFrames: UInt8 = 64

    var rasterLine: UInt8 = 0
    var frame: UInt8 = 0
    var output = InlineArray<8, Output>(repeating: Output())
    var writeIndex = 4
    var readIndex = 0
    var charset = Charset.alpha
    var graphicsCharset = Charset.contiguousGraphics
    var fg: UInt8 = 0
    var bg: UInt8 = 0
    var lastGraphicsData0: UInt16 = 0
    var lastGraphicsData1: UInt16 = 0
    var rasterShift: UInt8 = 0
    var rasterOffset: UInt8 = 0
    var anyDoubleHeight = false
    var conceal = false
    var hold = false
    var textVisible = false
    var frameFlashVisible = false

    public init() {
        // Cheaty reset.
        endOfLine()
        rasterLine = 0
    }

    @inline(__always)
    mutating func byte(_ input: UInt8, dispen: Bool) {
        let value = input & 0x7F
        var data0: UInt16 = 0
        var data1: UInt16 = 0
        let fgForOutput = fg

        if value < 32 {
            if !conceal && hold {
                data0 = lastGraphicsData0
                data1 = lastGraphicsData1
            }
            switch value {
            case 0x01...0x07: // alpha colour
                fg = value
                charset = .alpha
                conceal = false
                lastGraphicsData0 = 0
                lastGraphicsData1 = 0
            case 0x08: // flash
                textVisible = frameFlashVisible
            case 0x09: // steady
                textVisible = true
            case 0x0C: // normal height; the change clears held graphics
                if rasterShift != 0 {
                    data0 = 0
                    data1 = 0
                    lastGraphicsData0 = 0
                    lastGraphicsData1 = 0
                }
                rasterShift = 0
            case 0x0D: // double height
                if rasterShift != 1 {
                    data0 = 0
                    data1 = 0
                    lastGraphicsData0 = 0
                    lastGraphicsData1 = 0
                }
                anyDoubleHeight = true
                rasterShift = 1
            case 0x11...0x17: // graphics colour
                fg = value & 7
                conceal = false
                charset = graphicsCharset
            case 0x18: // conceal display
                conceal = true
                (data0, data1) = glyph(value)
            case 0x19: // contiguous graphics
                graphicsCharset = .contiguousGraphics
                if charset == .separatedGraphics {
                    charset = graphicsCharset
                }
            case 0x1A: // separated graphics
                graphicsCharset = .separatedGraphics
                if charset == .contiguousGraphics {
                    charset = graphicsCharset
                }
            case 0x1C: // black background
                bg = 0
            case 0x1D: // new background
                bg = fg
            case 0x1E: // hold graphics
                hold = true
                data0 = lastGraphicsData0
                data1 = lastGraphicsData1
            case 0x1F: // release graphics
                hold = false
            default:
                break
            }
            // (Conceal is displayed like a character, so skips this.)
            if !hold && value != 0x18 {
                lastGraphicsData0 = 0
                lastGraphicsData1 = 0
            }
        } else {
            (data0, data1) = glyph(value)
        }

        if !dispen {
            data0 = 0
            data1 = 0
        }

        output[writeIndex] = Output(fg: fgForOutput, bg: bg,
                                    data0: UInt8(truncatingIfNeeded: data0),
                                    data1: UInt8(truncatingIfNeeded: data1))
        output[writeIndex + 1] = Output(fg: fgForOutput, bg: bg,
                                        data0: UInt8(truncatingIfNeeded: data0 >> 6),
                                        data1: UInt8(truncatingIfNeeded: data1 >> 6))
        writeIndex = (writeIndex + 2) & 7
    }

    /// The glyph rows for a displayable character (or a conceal code).
    @inline(__always)
    private mutating func glyph(_ value: UInt8) -> (UInt16, UInt16) {
        var data0: UInt16 = 0
        var data1: UInt16 = 0
        let glyphRaster = (rasterLine &+ rasterOffset) >> rasterShift
        if glyphRaster < 20 && !conceal && textVisible {
            let base = (charset.rawValue * 96 + Int(value) - 32) * 20
            data0 = Self.font[base + Int(glyphRaster)]
            data1 = Self.font[base + Int(glyphRaster) + (rasterShift == 0 ? 1 : 0)]
        }
        if value & 0x20 != 0 && charset != .alpha && !conceal {
            lastGraphicsData0 = data0
            lastGraphicsData1 = data1
        }
        return (data0, data1)
    }

    /// One char is 2 units wide.
    @inline(__always)
    mutating func emitPixels(_ unit: inout VideoUnit) {
        let o = output[readIndex]
        unit.pixels[0] = VideoULA.outputPalette[Int(o.bg)] | VideoUnit.Kind.teletext.rawValue << 12
        unit.pixels[1] = VideoULA.outputPalette[Int(o.fg)]
        unit.pixels[2] = UInt16(o.data0)
        unit.pixels[3] = UInt16(o.data1)
        readIndex = (readIndex + 1) & 7
    }

    mutating func startOfLine() {
        conceal = false
        fg = 7
        bg = 0
        graphicsCharset = .contiguousGraphics
        charset = .alpha
        lastGraphicsData0 = 0
        lastGraphicsData1 = 0
        hold = false
        textVisible = true
        rasterShift = 0
        readIndex = 0
        writeIndex = 4
        output = InlineArray(repeating: Output())
    }

    mutating func endOfLine() {
        bg = 0
        rasterLine &+= 2
        if rasterLine >= 20 {
            rasterLine -= 20
            if anyDoubleHeight && rasterOffset == 0 {
                // Use second row of double height.
                rasterOffset = 20
            } else {
                rasterOffset = 0
            }
            anyDoubleHeight = false
        }
    }

    mutating func vsync() {
        rasterLine = 0
        frame &+= 1
        if frame >= Self.flashCycleFrames {
            frame = 0
        }
        frameFlashVisible = frame >= Self.flashOffFrames
        anyDoubleHeight = false
        rasterOffset = 0
    }

    // MARK: Font

    /// 12-pixel-wide rounded glyph rows, [charset][char - 32][row 0..<20].
    static let font: [UInt16] = {
        var font = [UInt16](repeating: 0, count: 3 * 96 * 20)
        for charset in 0..<3 {
            for ch in 32..<128 {
                for y in 0..<20 {
                    font[(charset * 96 + ch - 32) * 20 + y] = roundedRow(Charset(rawValue: charset)!, UInt8(ch), y)
                }
            }
        }
        return font
    }()

    private static func fontByte(_ charset: Charset, _ ch: UInt8, _ y: Int) -> UInt8 {
        if charset == .alpha || ch & 0x20 == 0 {
            return teletextAlphaFont[(Int(ch) - 32) * 10 + y]
        }
        let separated = charset == .separatedGraphics
        if separated && [2, 6, 9].contains(y) {
            return 0
        }
        let (lmask, rmask): (UInt8, UInt8) = y < 3 ? (0x01, 0x02) : y < 7 ? (0x04, 0x08) : (0x10, 0x40)
        var byte: UInt8 = 0
        if ch & lmask != 0 { byte |= 7 }
        if ch & rmask != 0 { byte |= 7 << 3 }
        return separated ? byte & ~(1 << 0 | 1 << 3) : byte
    }

    private static func wideRow(_ charset: Charset, _ ch: UInt8, _ y: Int) -> UInt16 {
        guard y >= 0 && y < 20 else { return 0 }
        let byte = fontByte(charset, ch, y / 2)
        var w: UInt16 = 0
        for i in 0..<6 where byte & 1 << i != 0 {
            w |= 3 << (2 * i)
        }
        return w
    }

    /// Character rounding: fills in diagonals using the neighbouring row.
    private static func roundedRow(_ charset: Charset, _ ch: UInt8, _ y: Int) -> UInt16 {
        let a = wideRow(charset, ch, y)
        let shouldRound = charset == .alpha || ch & 0x20 == 0
        guard shouldRound else { return a }
        let b = wideRow(charset, ch, y - 1 + y % 2 * 2)
        return a | (a >> 1 & b & ~(b >> 1)) | (a << 1 & b & ~(b << 1))
    }
}
