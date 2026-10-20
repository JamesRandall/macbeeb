// The video stream: one `VideoUnit` per 2MHz cycle, i.e. 0.5us of output.
//
// Follows b2's VideoDataUnit encoding. Each of the 8 pixels is 16 bits:
//
//     bits 12-15: x (extra data), 8-11: red, 4-7: green, 0-3: blue
//
// pixels[0].x is the unit type; pixels[1].x holds the sync flags.
//
// Teletext units: pixels[0] is the background colour, pixels[1] the
// foreground, pixels[2] and [3] the glyph bits for the two output rows (6
// pixels each, at 12MHz).

public struct VideoUnit: Sendable {
    public enum Kind: UInt16 {
        case bitmap16MHz = 0
        case bitmap12MHz = 1
        case teletext = 2
    }

    public static let vsyncFlag: UInt16 = 1
    public static let hsyncFlag: UInt16 = 2

    public var pixels: SIMD8<UInt16> = .zero

    public init() {}

    @inline(__always)
    public var kind: Kind { Kind(rawValue: pixels[0] >> 12) ?? .bitmap16MHz }

    @inline(__always)
    public var flags: UInt16 { pixels[1] >> 12 }

    @inline(__always)
    public var vsync: Bool { flags & Self.vsyncFlag != 0 }

    @inline(__always)
    public var hsync: Bool { flags & Self.hsyncFlag != 0 }
}

/// XOR value for a pixel under the cursor (inverts RGB).
let cursorXOR: UInt16 = 0x0FFF
