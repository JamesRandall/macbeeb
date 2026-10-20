/// A key on the BBC keyboard: its position in the matrix, row << 4 | column.
public struct BeebKey: RawRepresentable, Hashable, Sendable {
    public var rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public var row: Int { Int(rawValue >> 4) }
    public var column: Int { Int(rawValue & 0x0F) }

    public static let space = BeebKey(rawValue: 0x62)
    public static let comma = BeebKey(rawValue: 0x66)
    public static let minus = BeebKey(rawValue: 0x17)
    public static let stop = BeebKey(rawValue: 0x67)
    public static let slash = BeebKey(rawValue: 0x68)
    public static let digit0 = BeebKey(rawValue: 0x27)
    public static let digit1 = BeebKey(rawValue: 0x30)
    public static let digit2 = BeebKey(rawValue: 0x31)
    public static let digit3 = BeebKey(rawValue: 0x11)
    public static let digit4 = BeebKey(rawValue: 0x12)
    public static let digit5 = BeebKey(rawValue: 0x13)
    public static let digit6 = BeebKey(rawValue: 0x34)
    public static let digit7 = BeebKey(rawValue: 0x24)
    public static let digit8 = BeebKey(rawValue: 0x15)
    public static let digit9 = BeebKey(rawValue: 0x26)
    public static let colon = BeebKey(rawValue: 0x48)
    public static let semicolon = BeebKey(rawValue: 0x57)
    public static let at = BeebKey(rawValue: 0x47)
    public static let a = BeebKey(rawValue: 0x41)
    public static let b = BeebKey(rawValue: 0x64)
    public static let c = BeebKey(rawValue: 0x52)
    public static let d = BeebKey(rawValue: 0x32)
    public static let e = BeebKey(rawValue: 0x22)
    public static let f = BeebKey(rawValue: 0x43)
    public static let g = BeebKey(rawValue: 0x53)
    public static let h = BeebKey(rawValue: 0x54)
    public static let i = BeebKey(rawValue: 0x25)
    public static let j = BeebKey(rawValue: 0x45)
    public static let k = BeebKey(rawValue: 0x46)
    public static let l = BeebKey(rawValue: 0x56)
    public static let m = BeebKey(rawValue: 0x65)
    public static let n = BeebKey(rawValue: 0x55)
    public static let o = BeebKey(rawValue: 0x36)
    public static let p = BeebKey(rawValue: 0x37)
    public static let q = BeebKey(rawValue: 0x10)
    public static let r = BeebKey(rawValue: 0x33)
    public static let s = BeebKey(rawValue: 0x51)
    public static let t = BeebKey(rawValue: 0x23)
    public static let u = BeebKey(rawValue: 0x35)
    public static let v = BeebKey(rawValue: 0x63)
    public static let w = BeebKey(rawValue: 0x21)
    public static let x = BeebKey(rawValue: 0x42)
    public static let y = BeebKey(rawValue: 0x44)
    public static let z = BeebKey(rawValue: 0x61)
    public static let leftSquareBracket = BeebKey(rawValue: 0x38)
    public static let backslash = BeebKey(rawValue: 0x78)
    public static let rightSquareBracket = BeebKey(rawValue: 0x58)
    public static let caret = BeebKey(rawValue: 0x18)
    public static let underline = BeebKey(rawValue: 0x28)
    public static let escape = BeebKey(rawValue: 0x70)
    public static let tab = BeebKey(rawValue: 0x60)
    public static let capsLock = BeebKey(rawValue: 0x40)
    public static let ctrl = BeebKey(rawValue: 0x01)
    public static let shiftLock = BeebKey(rawValue: 0x50)
    public static let shift = BeebKey(rawValue: 0x00)
    public static let delete = BeebKey(rawValue: 0x59)
    public static let copy = BeebKey(rawValue: 0x69)
    public static let returnKey = BeebKey(rawValue: 0x49)
    public static let up = BeebKey(rawValue: 0x39)
    public static let down = BeebKey(rawValue: 0x29)
    public static let left = BeebKey(rawValue: 0x19)
    public static let right = BeebKey(rawValue: 0x79)
    public static let f0 = BeebKey(rawValue: 0x20)
    public static let f1 = BeebKey(rawValue: 0x71)
    public static let f2 = BeebKey(rawValue: 0x72)
    public static let f3 = BeebKey(rawValue: 0x73)
    public static let f4 = BeebKey(rawValue: 0x14)
    public static let f5 = BeebKey(rawValue: 0x74)
    public static let f6 = BeebKey(rawValue: 0x75)
    public static let f7 = BeebKey(rawValue: 0x16)
    public static let f8 = BeebKey(rawValue: 0x76)
    public static let f9 = BeebKey(rawValue: 0x77)
    /// Not a key: resets the CPU when released.
    public static let breakKey = BeebKey(rawValue: 0x7F)

    /// The key and shift state that types `character` on a UK BBC keyboard,
    /// or nil if it can't be typed.
    public static func forCharacter(_ character: Character) -> (key: BeebKey, shift: Bool)? {
        if character == "£" {
            return (.underline, true)
        }
        guard let ascii = character.asciiValue else { return nil }
        switch ascii {
        case 0x61...0x7A: return (letters[Int(ascii - 0x61)], false)
        case 0x41...0x5A: return (letters[Int(ascii - 0x41)], true)
        case 0x30: return (.digit0, false)
        case 0x31...0x39: return (digits[Int(ascii - 0x31)], false)
        default: break
        }
        return symbols[ascii]
    }

    private static let letters: [BeebKey] = [.a, .b, .c, .d, .e, .f, .g, .h, .i, .j, .k, .l, .m,
                                             .n, .o, .p, .q, .r, .s, .t, .u, .v, .w, .x, .y, .z]
    private static let digits: [BeebKey] = [.digit1, .digit2, .digit3, .digit4, .digit5, .digit6, .digit7, .digit8, .digit9]
    private static let symbols: [UInt8: (BeebKey, Bool)] = [
        0x20: (.space, false), 0x0D: (.returnKey, false), 0x0A: (.returnKey, false),
        0x21: (.digit1, true), 0x22: (.digit2, true), 0x23: (.digit3, true), 0x24: (.digit4, true),
        0x25: (.digit5, true), 0x26: (.digit6, true), 0x27: (.digit7, true), 0x28: (.digit8, true),
        0x29: (.digit9, true), 0x2A: (.colon, true), 0x2B: (.semicolon, true), 0x2C: (.comma, false),
        0x2D: (.minus, false), 0x2E: (.stop, false), 0x2F: (.slash, false), 0x3A: (.colon, false),
        0x3B: (.semicolon, false), 0x3C: (.comma, true), 0x3D: (.minus, true), 0x3E: (.stop, true),
        0x3F: (.slash, true), 0x40: (.at, false), 0x5B: (.leftSquareBracket, false), 0x5C: (.backslash, false),
        0x5D: (.rightSquareBracket, false), 0x5E: (.caret, false), 0x5F: (.underline, false),
        0x60: (.underline, true), 0x7B: (.leftSquareBracket, true), 0x7C: (.backslash, true),
        0x7D: (.rightSquareBracket, true), 0x7E: (.caret, true), 0x1B: (.escape, false), 0x7F: (.delete, false),
    ]
}

extension BeebKey {
    /// Keys by name: "RETURN", "SHIFT", "F1", "A", "1", ":" and so on.
    public static func named(_ name: String) -> BeebKey? {
        let upper = name.uppercased()
        if let key = namedKeys[upper] {
            return key
        }
        if name.count == 1, let (key, _) = forCharacter(Character(name)) {
            return key
        }
        return nil
    }

    public static let namedKeys: [String: BeebKey] = [
        "RETURN": .returnKey, "ENTER": .returnKey, "SPACE": .space, "SHIFT": .shift, "CTRL": .ctrl,
        "CONTROL": .ctrl, "ESCAPE": .escape, "ESC": .escape, "TAB": .tab, "DELETE": .delete,
        "COPY": .copy, "CAPSLOCK": .capsLock, "SHIFTLOCK": .shiftLock, "BREAK": .breakKey,
        "UP": .up, "DOWN": .down, "LEFT": .left, "RIGHT": .right,
        "F0": .f0, "F1": .f1, "F2": .f2, "F3": .f3, "F4": .f4,
        "F5": .f5, "F6": .f6, "F7": .f7, "F8": .f8, "F9": .f9,
    ]
}
