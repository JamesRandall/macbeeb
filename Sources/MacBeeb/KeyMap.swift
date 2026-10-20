import BeebCore

/// Maps Mac keys to BBC keys by position (macOS virtual key codes, which are
/// positions on an ANSI/ISO keyboard regardless of layout).
enum KeyMap {
    static let physical: [UInt16: BeebKey] = [
        // Number row.
        0x32: .underline,          // ` ~
        0x0A: .backslash,          // ISO § key
        0x12: .digit1, 0x13: .digit2, 0x14: .digit3, 0x15: .digit4, 0x17: .digit5,
        0x16: .digit6, 0x1A: .digit7, 0x1C: .digit8, 0x19: .digit9, 0x1D: .digit0,
        0x1B: .minus,              // - =
        0x18: .caret,              // = +  ->  ^ ~
        0x33: .delete,             // backspace

        // Top letter row.
        0x30: .tab,
        0x0C: .q, 0x0D: .w, 0x0E: .e, 0x0F: .r, 0x11: .t, 0x10: .y, 0x20: .u, 0x22: .i, 0x1F: .o, 0x23: .p,
        0x21: .at,                 // [  ->  @
        0x1E: .leftSquareBracket,  // ]  ->  [ {

        // Home row.
        0x00: .a, 0x01: .s, 0x02: .d, 0x03: .f, 0x05: .g, 0x04: .h, 0x26: .j, 0x28: .k, 0x25: .l,
        0x29: .semicolon,          // ; +
        0x27: .colon,              // ' -> : *
        0x2A: .rightSquareBracket, // \ -> ] }
        0x24: .returnKey,

        // Bottom row.
        0x06: .z, 0x07: .x, 0x08: .c, 0x09: .v, 0x0B: .b, 0x2D: .n, 0x2E: .m,
        0x2B: .comma, 0x2F: .stop, 0x2C: .slash,
        0x31: .space,

        // Modifiers.
        0x38: .shift, 0x3C: .shift,
        0x3B: .ctrl, 0x3E: .ctrl,
        0x3A: .shiftLock, 0x3D: .shiftLock, // option

        // Others.
        0x35: .escape,
        0x7B: .left, 0x7C: .right, 0x7D: .down, 0x7E: .up,
        0x77: .copy,               // End
        0x75: .copy,               // forward delete

        // Function keys: F1-F9 are f1-f9, F10 is f0, F12 is Break.
        0x7A: .f1, 0x78: .f2, 0x63: .f3, 0x76: .f4, 0x60: .f5,
        0x61: .f6, 0x62: .f7, 0x64: .f8, 0x65: .f9, 0x6D: .f0,
        0x6F: .breakKey,
    ]

    /// Caps Lock: macOS reports it as a toggle, not as presses.
    static let capsLock: UInt16 = 0x39
}
