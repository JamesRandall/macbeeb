import BeebCore

/// Maps Mac keys to BBC keys by position (macOS virtual key codes, which are
/// positions on an ANSI/ISO keyboard regardless of layout).
public enum MacKeyMap {
    public static let physical: [UInt16: BeebKey] = [
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

        // Keypad (the Master's; the Model B uses the main keys).
        0x52: .keypad0, 0x53: .keypad1, 0x54: .keypad2, 0x55: .keypad3, 0x56: .keypad4,
        0x57: .keypad5, 0x58: .keypad6, 0x59: .keypad7, 0x5B: .keypad8, 0x5C: .keypad9,
        0x41: .keypadStop, 0x43: .keypadStar, 0x45: .keypadPlus, 0x4E: .keypadMinus,
        0x4B: .keypadSlash, 0x4C: .keypadReturn, 0x51: .keypadHash, 0x47: .keypadDelete,
    ]

    /// Caps Lock: macOS reports it as a toggle, not as presses.
    public static let capsLock: UInt16 = 0x39

    /// The main block's character keys: number row, letters, punctuation
    /// and space. (In Mac layout mode these go by the character typed.)
    public static func typesCharacter(_ keyCode: UInt16) -> Bool {
        characterKeys.contains(keyCode)
    }

    private static let characterKeys: Set<UInt16> = [
        0x32, 0x0A, 0x12, 0x13, 0x14, 0x15, 0x17, 0x16, 0x1A, 0x1C, 0x19, 0x1D, 0x1B, 0x18,
        0x0C, 0x0D, 0x0E, 0x0F, 0x11, 0x10, 0x20, 0x22, 0x1F, 0x23, 0x21, 0x1E,
        0x00, 0x01, 0x02, 0x03, 0x05, 0x04, 0x26, 0x28, 0x25, 0x29, 0x27, 0x2A,
        0x06, 0x07, 0x08, 0x09, 0x0B, 0x2D, 0x2E, 0x2B, 0x2F, 0x2C, 0x31,
    ]

    /// Names of keys that don't type a character.
    public static let names: [UInt16: String] = [
        0x24: "Return", 0x30: "Tab", 0x31: "Space", 0x33: "Delete", 0x35: "Escape",
        0x37: "Command", 0x36: "Right Command", 0x38: "Shift", 0x3C: "Right Shift",
        0x3A: "Option", 0x3D: "Right Option", 0x3B: "Control", 0x3E: "Right Control",
        0x39: "Caps Lock", 0x3F: "Fn",
        0x7A: "F1", 0x78: "F2", 0x63: "F3", 0x76: "F4", 0x60: "F5", 0x61: "F6", 0x62: "F7",
        0x64: "F8", 0x65: "F9", 0x6D: "F10", 0x67: "F11", 0x6F: "F12", 0x69: "F13", 0x6B: "F14",
        0x71: "F15", 0x6A: "F16", 0x40: "F17", 0x4F: "F18", 0x50: "F19", 0x5A: "F20",
        0x7B: "Left Arrow", 0x7C: "Right Arrow", 0x7D: "Down Arrow", 0x7E: "Up Arrow",
        0x73: "Home", 0x77: "End", 0x74: "Page Up", 0x79: "Page Down", 0x75: "Forward Delete",
        0x72: "Help",
        0x52: "Keypad 0", 0x53: "Keypad 1", 0x54: "Keypad 2", 0x55: "Keypad 3", 0x56: "Keypad 4",
        0x57: "Keypad 5", 0x58: "Keypad 6", 0x59: "Keypad 7", 0x5B: "Keypad 8", 0x5C: "Keypad 9",
        0x41: "Keypad .", 0x43: "Keypad *", 0x45: "Keypad +", 0x4E: "Keypad -", 0x4B: "Keypad /",
        0x4C: "Keypad Enter", 0x51: "Keypad =", 0x47: "Keypad Clear",
    ]
}
