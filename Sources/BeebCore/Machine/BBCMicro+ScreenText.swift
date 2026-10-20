// Reading text off the screen in any mode.
//
// Mode 7 is read straight from screen memory. In the bitmap modes each
// character cell is decoded and matched against the OS's font, which works
// for anything the OS printed (in any colours) and gives "?" for cells that
// aren't characters. Layout comes from the OS's VDU variables, so this
// assumes OS 1.2 drew the screen.

extension BBCMicro {
    /// The screen's text, one string per row, trailing spaces removed.
    public func screenText() -> [String] {
        if let teletext = teletextScreenText() {
            return teletext
        }

        let mode = Int(peek(0x355))
        let topLeft = UInt16(peek(0x351)) << 8 | UInt16(peek(0x350))
        let bytesPerRow = Int(UInt16(peek(0x353)) << 8 | UInt16(peek(0x352)))
        let bytesPerCharacter = Int(peek(0x34F))
        let screenStart = 0x8000 - Int(peek(0x354)) << 8
        guard [8, 16, 32].contains(bytesPerCharacter), bytesPerRow > 0, screenStart >= 0x1000 else { return [] }
        let columns = bytesPerRow / bytesPerCharacter
        let rows = [3, 6].contains(mode) ? 25 : 32
        let bitsPerPixel = bytesPerCharacter / 8

        // OS font for characters 32-126 is at &C000.
        let font = (0..<95).map { ch in (0..<8).map { peek(0xC000 + UInt16(ch * 8 + $0)) } }
        var glyphs: [[UInt8]: Character] = [:]
        for (index, rows) in font.enumerated() {
            glyphs[rows] = glyphs[rows] ?? Character(UnicodeScalar(UInt8(32 + index)))
        }

        func screenByte(_ address: Int) -> UInt8 {
            // The screen wraps within screen memory (hardware scrolling).
            var a = address
            if a >= 0x8000 {
                a -= 0x8000 - screenStart
            }
            return peek(UInt16(a))
        }

        var lines: [String] = []
        for row in 0..<rows {
            var line = ""
            for column in 0..<columns {
                let base = Int(topLeft) + row * bytesPerRow + column * bytesPerCharacter
                // Logical colour of each pixel, 8x8.
                var pixels = [UInt8](repeating: 0, count: 64)
                for y in 0..<8 {
                    for byteColumn in 0..<bitsPerPixel {
                        let byte = screenByte(base + byteColumn * 8 + y)
                        let perByte = 8 / bitsPerPixel
                        for p in 0..<perByte {
                            // Pixel p's bits are interleaved: 7 (1bpp);
                            // 7,3 (2bpp); 7,5,3,1 (4bpp), each shifted by p.
                            let b = byte << p
                            let value: UInt8 = switch bitsPerPixel {
                            case 1: b >> 7 & 1
                            case 2: (b >> 7 & 1) << 1 | (b >> 3 & 1)
                            default: (b >> 7 & 1) << 3 | (b >> 5 & 1) << 2 | (b >> 3 & 1) << 1 | (b >> 1 & 1)
                            }
                            pixels[y * 8 + byteColumn * perByte + p] = value
                        }
                    }
                }
                line.append(Self.recognise(pixels, glyphs: glyphs))
            }
            while line.last == " " { line.removeLast() }
            lines.append(line)
        }
        return lines
    }

    /// Matches a cell against the font, trying each colour in it as the
    /// background.
    private static func recognise(_ pixels: [UInt8], glyphs: [[UInt8]: Character]) -> Character {
        let colours = Set(pixels)
        if colours.count == 1 {
            return " "
        }
        for background in colours {
            var rows = [UInt8](repeating: 0, count: 8)
            for y in 0..<8 {
                for x in 0..<8 where pixels[y * 8 + x] != background {
                    rows[y] |= 0x80 >> x
                }
            }
            if let character = glyphs[rows] {
                return character
            }
        }
        return "?"
    }
}
