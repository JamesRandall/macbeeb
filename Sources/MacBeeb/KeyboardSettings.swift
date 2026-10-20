import AppKit
import BeebCore
import BeebHost
import Observation

/// How Mac keys become BBC keys, shared by all windows and saved.
@MainActor
@Observable
final class KeyboardSettings {
    static let shared = KeyboardSettings()

    /// A Mac key the user has assigned to a BBC key.
    struct Mapping: Codable, Hashable, Identifiable {
        /// macOS virtual key code.
        var keyCode: UInt16
        /// The Mac key's name when it was recorded, e.g. "F13" or "§".
        var macKeyName: String
        var beebKey: UInt8

        var id: UInt16 { keyCode }
        var key: BeebKey { BeebKey(rawValue: beebKey) }
    }

    var mode: KeyboardMode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: Self.modeKey) }
    }

    /// Sorted by Mac key name.
    private(set) var mappings: [Mapping] {
        didSet {
            if let data = try? JSONEncoder().encode(mappings) {
                UserDefaults.standard.set(data, forKey: Self.mappingsKey)
            }
        }
    }

    private static let modeKey = "MacBeebKeyboardMode"
    private static let mappingsKey = "MacBeebKeyMappings"

    private init() {
        let defaults = UserDefaults.standard
        mode = defaults.string(forKey: Self.modeKey).flatMap(KeyboardMode.init(rawValue:)) ?? .physical
        mappings = defaults.data(forKey: Self.mappingsKey)
            .flatMap { try? JSONDecoder().decode([Mapping].self, from: $0) } ?? []
    }

    func setMapping(keyCode: UInt16, macKeyName: String, to key: BeebKey) {
        mappings.removeAll { $0.keyCode == keyCode }
        mappings.append(Mapping(keyCode: keyCode, macKeyName: macKeyName, beebKey: key.rawValue))
        mappings.sort { $0.macKeyName.localizedStandardCompare($1.macKeyName) == .orderedAscending }
    }

    func removeMapping(keyCode: UInt16) {
        mappings.removeAll { $0.keyCode == keyCode }
    }

    func removeAllMappings() {
        mappings = []
    }

    /// A translator set up with the current mode and mappings.
    var translator: KeyboardTranslator {
        KeyboardTranslator(mode: mode, customKeys: Dictionary(mappings.map { ($0.keyCode, $0.key) }) { _, last in last })
    }

    /// A name for a Mac key, for the settings list.
    static func name(of event: NSEvent) -> String {
        if let name = MacKeyMap.names[event.keyCode] {
            return name
        }
        if let characters = event.charactersIgnoringModifiers?.uppercased(),
           let scalar = characters.unicodeScalars.first, !CharacterSet.controlCharacters.contains(scalar) {
            return characters
        }
        return "Key \(event.keyCode)"
    }
}

extension KeyboardMode: Identifiable {
    public var id: Self { self }

    var name: String {
        switch self {
        case .physical: "BBC layout (by key position)"
        case .macLayout: "Mac layout (by character typed)"
        }
    }
}

extension KeyboardTranslator.Modifiers {
    init(_ flags: NSEvent.ModifierFlags) {
        self = []
        if flags.contains(.shift) { insert(.shift) }
        if flags.contains(.control) { insert(.control) }
        if flags.contains(.option) { insert(.option) }
        if flags.contains(.command) { insert(.command) }
        if flags.contains(.capsLock) { insert(.capsLock) }
    }
}
