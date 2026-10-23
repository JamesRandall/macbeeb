import BeebCore
import BeebROMs
import Foundation

/// The hardware a machine is set up with, as the user chose it: what a
/// standalone MacBeeb window remembers in its defaults, and what a network
/// remembers for each station.
public struct MachineSetup: Codable, Sendable, Hashable {
    public var model: BBCMicro.Model
    public var secondProcessor: Bool
    public var coprocessor: BBCMicro.Coprocessor
    /// The Model B's (the others' are built in).
    public var discInterface: BBCMicro.DiscInterface
    /// The Model B's boards and modules.
    public var expansions: BBCMicro.Expansions
    /// Images for sideways RAM at power on, by bank.
    public var powerOnImagePaths: [Int: String]
    /// Controller ROMs chosen in place of the bundled ones, by board.
    public var controllerROMPaths: [BBCMicro.MemoryBoard: String]
    public var videoNuLA: Bool

    public init(model: BBCMicro.Model = .modelB, secondProcessor: Bool = false, coprocessor: BBCMicro.Coprocessor = .mos6502,
                discInterface: BBCMicro.DiscInterface = .intel8271, expansions: BBCMicro.Expansions = .none,
                powerOnImagePaths: [Int: String] = [:], controllerROMPaths: [BBCMicro.MemoryBoard: String] = [:],
                videoNuLA: Bool = false) {
        self.model = model
        self.secondProcessor = secondProcessor
        self.coprocessor = coprocessor
        self.discInterface = discInterface
        self.expansions = expansions
        self.powerOnImagePaths = powerOnImagePaths
        self.controllerROMPaths = controllerROMPaths
        self.videoNuLA = videoNuLA
    }

    /// The machine's configuration, ROMs and all. Images that have gone
    /// are left out.
    public func configuration() -> BBCMicro.Configuration {
        var built = BeebROMs.configuration(for: model, secondProcessor: secondProcessor, coprocessor: coprocessor,
                                           discInterface: discInterface, expansions: expansions,
                                           sidewaysImages: Self.images(at: powerOnImagePaths),
                                           controllerROM: Self.controllerROM(for: expansions.board, paths: controllerROMPaths))
        built.videoNuLA = videoNuLA
        return built
    }

    /// The images to put in sideways RAM at power on; files that have gone
    /// or are too big are left out.
    public static func images(at paths: [Int: String]) -> [Int: [UInt8]] {
        paths.compactMapValues { path in
            guard let data = FileManager.default.contents(atPath: path), !data.isEmpty, data.count <= 0x4000 else { return nil }
            return [UInt8](data)
        }
    }

    /// The user's controller ROM for `board`, if they've chosen one and it's
    /// still there (otherwise the bundled one is used).
    public static func controllerROM(for board: BBCMicro.MemoryBoard, paths: [BBCMicro.MemoryBoard: String]) -> [UInt8]? {
        guard let path = paths[board], let data = FileManager.default.contents(atPath: path) else { return nil }
        let bytes = [UInt8](data)
        switch Firmware.identify(bytes, for: board) {
        case .known(let firmware): return bytes.count == firmware.size ? bytes : Array(bytes[..<firmware.size])
        case .unknown: return bytes
        case .wrongSize, .anotherBoard: return nil
        }
    }

    /// A short description: "BBC Model B", "Master 128 + 6502 Second Processor".
    public var summary: String {
        var text = model.displayName
        if secondProcessor { text += " + " + coprocessor.displayName }
        return text
    }
}
