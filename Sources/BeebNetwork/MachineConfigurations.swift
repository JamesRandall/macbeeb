import BeebCore
import Foundation
import Observation

/// A machine set up as the user wanted it, saved under a name: model,
/// second processor, disc interface, boards, ROMs in their sockets,
/// cartridges and VideoNuLA.
public struct SavedMachine: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var setup: MachineSetup
    public var created: Date

    public init(id: UUID = UUID(), name: String, setup: MachineSetup, created: Date = Date()) {
        self.id = id
        self.name = name
        self.setup = setup
        self.created = created
    }
}

/// The user's saved machines, in Application Support/MacBeeb/Machines.json:
/// to start a window with, or add to a network.
@Observable
public final class MachineConfigurations: @unchecked Sendable {
    public static let shared = MachineConfigurations(url: defaultURL)

    /// Unless the MacBeebMachinesFile default says otherwise (self-tests
    /// use their own).
    public static var defaultURL: URL {
        if let path = UserDefaults.standard.string(forKey: "MacBeebMachinesFile") {
            return URL(fileURLWithPath: path)
        }
        return URL.applicationSupportDirectory.appendingPathComponent("MacBeeb/Machines.json")
    }

    public let url: URL
    /// By name.
    public private(set) var machines: [SavedMachine] = []

    public init(url: URL) {
        self.url = url
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        machines = (try? decoder.decode([SavedMachine].self, from: Data(contentsOf: url))) ?? []
        sort()
    }

    public subscript(id: UUID) -> SavedMachine? { machines.first { $0.id == id } }

    /// The saved machine set up exactly as `setup`, if there is one.
    public func matching(_ setup: MachineSetup) -> SavedMachine? {
        machines.first { $0.setup == setup }
    }

    /// Saves `setup` as `name`, replacing a saved machine of that name.
    @discardableResult
    public func save(_ setup: MachineSetup, as name: String) throws -> SavedMachine {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let index = machines.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            machines[index].setup = setup
            try write()
            return machines[index]
        }
        let saved = SavedMachine(name: name, setup: setup)
        machines.append(saved)
        sort()
        try write()
        return saved
    }

    public func rename(_ id: UUID, to name: String) throws {
        guard let index = machines.firstIndex(where: { $0.id == id }) else { return }
        machines[index].name = name
        sort()
        try write()
    }

    public func remove(_ id: UUID) throws {
        machines.removeAll { $0.id == id }
        try write()
    }

    /// A name for a new one that isn't taken: "Master 128", "Master 128 2".
    public func freeName(_ base: String) -> String {
        let names = Set(machines.map { $0.name.lowercased() })
        if !names.contains(base.lowercased()) { return base }
        return (2...).lazy.map { "\(base) \($0)" }.first { !names.contains($0.lowercased()) }!
    }

    private func sort() {
        machines.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func write() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(machines).write(to: url, options: .atomic)
    }
}

extension MachineSetup {
    /// What's fitted, for a list: "6502 Second Processor · InterWord,
    /// Lisp · 32K RAM cartridge · VideoNuLA". Empty for a stock machine.
    public var fittedSummary: String {
        var parts: [String] = []
        if secondProcessor && coprocessor.fits(model) { parts.append(coprocessor.displayName) }
        if model == .modelB && discInterface != .intel8271 { parts.append(discInterface.displayName) }
        if model == .modelB {
            if expansions.board != .none { parts.append(expansions.board.displayName) }
            if expansions.sidewaysRAM != .none && expansions.board.takesSidewaysModule { parts.append(expansions.sidewaysRAM.displayName) }
        }
        if model == .master128 {
            for slot in [0, 1] {
                switch sockets.cartridges[slot] {
                case .ram16, .ram32: parts.append(sockets.cartridges[slot]!.displayName)
                default: break
                }
            }
        }
        // Only the sockets this model has (a Model B's choices stay while
        // it's a Master, for when it's a B again).
        let banks = Set(socketGroups().flatMap(\.sockets).map(\.bank))
        let roms = sockets.roms.filter { banks.contains($0.key) }.sorted { $0.key > $1.key }.compactMap { $0.value.rom?.name }
        if !roms.isEmpty { parts.append(roms.joined(separator: ", ")) }
        if videoNuLA { parts.append("VideoNuLA") }
        return parts.joined(separator: " · ")
    }
}
