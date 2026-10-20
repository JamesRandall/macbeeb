import BeebCore

/// How Mac keys become BBC keys.
public enum KeyboardMode: String, CaseIterable, Sendable, Codable {
    /// Keys by position: the BBC's layout on the Mac's keys (Shift-8 types
    /// the BBC's "(").
    case physical
    /// Characters as the Mac's layout types them (Shift-8 types "*"),
    /// pressing or releasing the BBC's Shift as each key needs. Keys that
    /// don't type characters still go by position, and Option types
    /// characters instead of being Shift Lock.
    case macLayout
}

/// Turns Mac key events (macOS virtual key codes) into BBC key presses,
/// tracking what's held so releases match presses.
public struct KeyboardTranslator: Sendable {
    public struct Modifiers: OptionSet, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let shift = Modifiers(rawValue: 1 << 0)
        public static let control = Modifiers(rawValue: 1 << 1)
        public static let option = Modifiers(rawValue: 1 << 2)
        public static let command = Modifiers(rawValue: 1 << 3)
        public static let capsLock = Modifiers(rawValue: 1 << 4)
    }

    public enum Action: Equatable, Sendable {
        case key(BeebKey, down: Bool)
        /// Press and release Caps Lock (macOS reports it as a toggle).
        case tapCapsLock
    }

    public var mode: KeyboardMode
    /// User mappings: Mac key code -> BBC key. They win in both modes.
    public var customKeys: [UInt16: BeebKey]

    /// BBC keys held, by Mac key, and the Shift state each forces.
    private var held: [UInt16: (key: BeebKey, shift: Bool?)] = [:]
    /// Shift as the user holds it on the Mac.
    private var macShift = false

    public init(mode: KeyboardMode = .physical, customKeys: [UInt16: BeebKey] = [:]) {
        self.mode = mode
        self.customKeys = customKeys
    }

    /// What a press of `keyCode` would do: the BBC key and the Shift state
    /// it needs (nil: as held).
    public func translate(keyCode: UInt16, characters: String?, modifiers: Modifiers) -> (key: BeebKey, shift: Bool?)? {
        if let key = customKeys[keyCode] {
            return (key, nil)
        }
        if mode == .macLayout && !modifiers.contains(.control) && MacKeyMap.typesCharacter(keyCode),
           let characters, characters.count == 1, let character = characters.first,
           let (key, shift) = BeebKey.forCharacter(character) {
            // Letters follow Shift and Caps Lock, as on both machines.
            return (key, character.isLetter ? nil : shift)
        }
        return MacKeyMap.physical[keyCode].map { ($0, nil) }
    }

    public mutating func keyDown(keyCode: UInt16, characters: String?, modifiers: Modifiers, isRepeat: Bool) -> [Action] {
        // The BBC does its own auto-repeat.
        guard !isRepeat, held[keyCode] == nil,
              let (key, shift) = translate(keyCode: keyCode, characters: characters, modifiers: modifiers) else { return [] }
        held[keyCode] = (key, shift)
        var actions: [Action] = []
        if let shift {
            actions.append(.key(.shift, down: shift))
        }
        actions.append(.key(key, down: true))
        return actions
    }

    public mutating func keyUp(keyCode: UInt16) -> [Action] {
        guard let (key, shift) = held.removeValue(forKey: keyCode) else { return [] }
        var actions: [Action] = [.key(key, down: false)]
        if shift != nil {
            actions.append(.key(.shift, down: currentShift))
        }
        return actions
    }

    /// A modifier key (Shift, Control, Option, Command, Caps Lock) changed.
    public mutating func flagsChanged(keyCode: UInt16, modifiers: Modifiers) -> [Action] {
        let flag: Modifiers = switch keyCode {
        case 0x38, 0x3C: .shift
        case 0x3B, 0x3E: .control
        case 0x37, 0x36: .command
        case MacKeyMap.capsLock: .capsLock
        default: .option
        }
        let down = modifiers.contains(flag)

        // Each Caps Lock event is a toggle of the Mac's state.
        if flag == .capsLock && customKeys[keyCode] == nil {
            return [.tapCapsLock]
        }

        let key: BeebKey
        if let custom = customKeys[keyCode] {
            key = custom
        } else {
            if flag == .option && mode == .macLayout { return [] }
            guard let physical = MacKeyMap.physical[keyCode] else { return [] }
            key = physical
        }
        if key == .shift {
            macShift = down
            // A held key's Shift override wins until it's released.
            if held.values.contains(where: { $0.shift != nil }) { return [] }
        }
        return [.key(key, down: down)]
    }

    /// Forget everything held (e.g. when the window loses focus; the
    /// machine releases its keys separately).
    public mutating func reset() {
        held = [:]
        macShift = false
    }

    /// Shift as the BBC should see it now: the last held override, or the
    /// Mac's.
    private var currentShift: Bool {
        held.values.compactMap(\.shift).last ?? macShift
    }
}
