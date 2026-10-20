import Foundation

/// A save state file (.beebstate): everything needed to bring a machine
/// back exactly, including its ROMs and discs (with any unsaved writes). Binary plist,
/// compressed.
public struct SaveStateFile: Codable, Sendable {
    public static let fileExtension = "beebstate"
    static let magic = "macbeeb save state"

    var format = Self.magic
    public var created: Date
    public var configuration: BBCMicro.Configuration
    public var snapshot: BBCMicro.Snapshot

    public enum FileError: Error {
        case notASaveState
    }

    /// Captures `machine`'s state.
    public init(_ machine: BBCMicro) {
        created = Date()
        configuration = machine.configuration
        snapshot = machine.snapshot()
    }

    /// Builds a machine in this state.
    public func makeMachine() throws -> BBCMicro {
        let machine = BBCMicro(configuration: configuration)
        // The snapshot includes the discs, exactly.
        try machine.restore(snapshot)
        return machine
    }

    public func data() throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try (encoder.encode(self) as NSData).compressed(using: .lzfse) as Data
    }

    public init(data: Data) throws {
        guard let plist = try? (data as NSData).decompressed(using: .lzfse) as Data else {
            throw FileError.notASaveState
        }
        self = try PropertyListDecoder().decode(SaveStateFile.self, from: plist)
        guard format == Self.magic else { throw FileError.notASaveState }
    }
}
