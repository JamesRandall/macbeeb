import AppKit
import BeebCore
import BeebHost
import BeebROMs

/// The Model B's expansions: choosing the board (a power cycle), and
/// loading, clearing and saving sideways RAM in the running machine.
extension MachineController {
    /// What the Hardware Expansions window shows of the running machine.
    struct HardwareSnapshot: Sendable, Equatable {
        var model: BBCMicro.Model
        var expansions: BBCMicro.Expansions
        var slots: [BBCMicro.SidewaysSlot]
        var romsel: UInt8
        var watfordMapping: BBCMicro.WatfordMapping?
        var aries: BBCMicro.AriesState?
    }

    /// The hardware being chosen in the Hardware Expansions window: the
    /// board, and any controller ROMs in place of the bundled ones.
    struct HardwareDraft: Equatable {
        var expansions: BBCMicro.Expansions
        var controllerROMPaths: [BBCMicro.MemoryBoard: String]

        /// The controller ROM the board would use.
        var controllerROMPath: String? { controllerROMPaths[expansions.board] }
    }

    var hardwareDraft: HardwareDraft {
        HardwareDraft(expansions: expansions, controllerROMPaths: controllerROMPaths)
    }

    static var savedExpansions: BBCMicro.Expansions {
        guard let data = UserDefaults.standard.data(forKey: expansionsKey),
              let saved = try? JSONDecoder().decode(BBCMicro.Expansions.self, from: data),
              saved.problem == nil else { return .none }
        return saved
    }

    static var savedPowerOnImagePaths: [Int: String] {
        guard let saved = UserDefaults.standard.dictionary(forKey: powerOnImagesKey) as? [String: String] else { return [:] }
        return Dictionary(uniqueKeysWithValues: saved.compactMap { key, path in Int(key).map { ($0, path) } })
    }

    /// The images to put in sideways RAM at power on; files that have gone
    /// or are too big are left out.
    static func images(at paths: [Int: String]) -> [Int: [UInt8]] {
        paths.compactMapValues { path in
            guard let data = FileManager.default.contents(atPath: path), !data.isEmpty, data.count <= 0x4000 else { return nil }
            return [UInt8](data)
        }
    }

    static var savedControllerROMPaths: [BBCMicro.MemoryBoard: String] {
        guard let saved = UserDefaults.standard.dictionary(forKey: controllerROMsKey) as? [String: String] else { return [:] }
        return Dictionary(uniqueKeysWithValues: saved.compactMap { key, path in BBCMicro.MemoryBoard(rawValue: key).map { ($0, path) } })
    }

    /// The user's controller ROM for `board`, if they've chosen one and it's
    /// still there (otherwise the bundled one is used).
    static func controllerROM(for board: BBCMicro.MemoryBoard, paths: [BBCMicro.MemoryBoard: String]) -> [UInt8]? {
        guard let path = paths[board], let data = FileManager.default.contents(atPath: path) else { return nil }
        let bytes = [UInt8](data)
        switch Firmware.identify(bytes, for: board) {
        case .known(let firmware): return bytes.count == firmware.size ? bytes : Array(bytes[..<firmware.size])
        case .unknown: return bytes
        case .wrongSize, .anotherBoard: return nil
        }
    }

    private static let expansionsKey = "MacBeebExpansions"
    private static let controllerROMsKey = "MacBeebControllerROMs"
    private static let powerOnImagesKey = "MacBeebSidewaysPowerOnImages"

    /// Fits a different board (or changes its wiring or controller ROM),
    /// which power cycles a Model B. On other models it's remembered for
    /// when it's a B again.
    func apply(_ draft: HardwareDraft) {
        guard draft != hardwareDraft, draft.expansions.problem == nil else { return }
        setExpansionsValue(draft.expansions)
        if let data = try? JSONEncoder().encode(draft.expansions) {
            UserDefaults.standard.set(data, forKey: Self.expansionsKey)
        }
        setControllerROMPathsValue(draft.controllerROMPaths)
        UserDefaults.standard.set(Dictionary(uniqueKeysWithValues: draft.controllerROMPaths.map { ($0.key.rawValue, $0.value) }),
                                  forKey: Self.controllerROMsKey)
        if model == .modelB {
            restartWithHardware()
        }
    }

    func setExpansions(_ new: BBCMicro.Expansions) {
        var draft = hardwareDraft
        draft.expansions = new
        apply(draft)
    }

    /// Switches to a Model B with `new` (one power cycle).
    func switchToModelB(with new: BBCMicro.Expansions) {
        setExpansionsValue(new)
        if let data = try? JSONEncoder().encode(new) {
            UserDefaults.standard.set(data, forKey: Self.expansionsKey)
        }
        if model == .modelB {
            restartWithHardware()
        } else {
            setModel(.modelB)
        }
    }

    /// A file to put in a sideways RAM bank at every power on (nil: none).
    /// Takes effect at the next power cycle.
    func setPowerOnImage(_ url: URL?, bank: Int) {
        var paths = powerOnImagePaths
        paths[bank] = url?.path
        setPowerOnImagePathsValue(paths)
        UserDefaults.standard.set(Dictionary(uniqueKeysWithValues: paths.map { (String($0.key), $0.value) }),
                                  forKey: Self.powerOnImagesKey)
    }

    /// The running machine's hardware.
    func hardwareSnapshot() async -> HardwareSnapshot? {
        try? await host.performAsync { session in
            let m = session.machine
            return HardwareSnapshot(model: m.model, expansions: m.configuration.fittedExpansions,
                                    slots: m.sidewaysSlots, romsel: m.romsel,
                                    watfordMapping: m.watfordFitted ? m.watfordMapping : nil,
                                    aries: m.ariesFitted ? m.aries : nil)
        }
    }

    /// Puts a ROM image file into a sideways RAM bank of the running
    /// machine (the BBC finds it at the next Break).
    func loadSidewaysImage(_ url: URL, bank: Int) async throws {
        let image = [UInt8](try Data(contentsOf: url))
        try await host.performAsync { session in try session.machine.loadSidewaysImage(image, bank: bank) }
        noteHardwareChanged()
        showToast("Loaded \(url.lastPathComponent) into bank \(bank). Press Break for the BBC to find it.")
    }

    func clearSidewaysBank(_ bank: Int) async throws {
        try await host.performAsync { session in try session.machine.clearSidewaysBank(bank) }
        noteHardwareChanged()
        showToast("Cleared bank \(bank)")
    }

    func saveSidewaysBank(_ bank: Int, to url: URL) async throws {
        let contents = try await host.performAsync { session in session.machine.sidewaysBankContents(bank) }
        guard let contents else { return }
        try Data(contents).write(to: url)
    }
}
