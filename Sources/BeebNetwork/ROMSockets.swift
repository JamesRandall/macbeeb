import BeebCore
import BeebROMs
import Foundation

// The sockets a machine has for sideways ROMs, as the real hardware has
// them, and what the user has put in them.
//
// - Model A and B: the four motherboard sockets, 12 (left) to 15 (right):
//   BASIC in 15 and the DFS in 14 as standard, which can come out. With
//   the Aries B12 their ROMs move to its sockets 9-12, and its sockets 1-8
//   are free.
// - B+: five sockets that each take a 32K chip, two banks: IC35 (banks 2
//   and 3), IC44 (4, 5), IC57 (6, 7), IC62 (8, 9) and IC68 (10, 11); BASIC
//   and the DFS in 15 and 14. (The B+ manual; the banks each socket takes
//   are as the B+ user community documents them.)
// - Master 128: the front cartridge slot (banks 0 and 1) and the rear (2
//   and 3), each holding a ROM cartridge or a sideways RAM cartridge; and
//   with link LK19 East, IC37 (4 and 5), with LK18 East, IC41 (6 and 7), in
//   place of that sideways RAM. (The Master Service Manual.)
// - Master Compact: no sockets MacBeeb models.

/// A ROM in a socket: which (from the ROM library, or a network's copy) and
/// how it's laid out.
public struct PluggedROM: Codable, Sendable, Hashable {
    /// The image's SHA-256, as `UserROM.id`.
    public var id: String
    public var name: String
    public var layout: ROMLayout

    public init(id: String, name: String, layout: ROMLayout) {
        self.id = id
        self.name = name
        self.layout = layout
    }
}

/// A socket's contents, in place of its standard ROM.
public enum SocketContent: Codable, Sendable, Hashable {
    /// Nothing: the standard ROM taken out.
    case empty
    case rom(PluggedROM)

    public var rom: PluggedROM? {
        if case .rom(let rom) = self { return rom }
        return nil
    }
}

/// What's in one of the Master's cartridge slots.
public enum Cartridge: String, Codable, Sendable, Hashable, CaseIterable {
    /// A ROM cartridge: sockets for its two banks.
    case roms
    /// A sideways RAM cartridge, 16K (the slot's lower bank) or 32K (both).
    case ram16
    case ram32

    public var displayName: String {
        switch self {
        case .roms: "ROM Cartridge"
        case .ram16: "16K Sideways RAM Cartridge"
        case .ram32: "32K Sideways RAM Cartridge"
        }
    }
}

/// The user's ROMs, cartridges and links.
public struct SocketSetup: Codable, Sendable, Hashable {
    /// By the socket's standard bank number. A socket that isn't here has
    /// its standard ROM (or is empty, if it hasn't one). A two-bank ROM is
    /// under its lower bank.
    public var roms: [Int: SocketContent]
    /// The Master's cartridges: 0 the front slot, 1 the rear.
    public var cartridges: [Int: Cartridge]
    /// The Master's links set East, making ROM sockets of sideways RAM
    /// banks: 4 (LK19: IC37, banks 4 and 5) and 6 (LK18: IC41, 6 and 7).
    public var romLinks: Set<Int>

    public static let standard = SocketSetup()

    public init(roms: [Int: SocketContent] = [:], cartridges: [Int: Cartridge] = [:], romLinks: Set<Int> = []) {
        self.roms = roms
        self.cartridges = cartridges
        self.romLinks = romLinks
    }

    public var isStandard: Bool { roms.isEmpty && cartridges.isEmpty && romLinks.isEmpty }

    enum CodingKeys: CodingKey { case roms, cartridges, romLinks }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        roms = try c.decodeIfPresent([Int: SocketContent].self, forKey: .roms) ?? [:]
        cartridges = try c.decodeIfPresent([Int: Cartridge].self, forKey: .cartridges) ?? [:]
        romLinks = try c.decodeIfPresent(Set<Int>.self, forKey: .romLinks) ?? []
    }

    /// The Master's sideways RAM banks the cartridges add.
    public var cartridgeRAMBanks: Set<Int> {
        var banks: Set<Int> = []
        for (slot, cartridge) in cartridges where slot == 0 || slot == 1 {
            switch cartridge {
            case .roms: break
            case .ram16: banks.insert(slot * 2)
            case .ram32: banks.formUnion([slot * 2, slot * 2 + 1])
            }
        }
        return banks
    }

    /// The Master's sideways RAM banks the links take away.
    public var linkedROMBanks: Set<Int> {
        Set(romLinks.filter { $0 == 4 || $0 == 6 }.flatMap { [$0, $0 + 1] })
    }
}

/// A group of sockets as the hardware has them: a chip socket or cartridge
/// slot taking one or two banks.
public struct ROMSocketGroup: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        case motherboard
        case board
        case cartridge(Int)
        case link(Int)
    }

    public var id: String { name }
    public var kind: Kind
    /// "Motherboard", "IC35", "Front Cartridge".
    public var name: String
    /// What it is, for the window: "Banks 2 and 3: a 32K chip, or 16K".
    public var detail: String
    public var sockets: [ROMSocket]
    /// Whether a 32K two-bank chip fits (its sockets are its two banks).
    public var takesPairs: Bool
}

/// One bank's place in a socket.
public struct ROMSocket: Sendable, Hashable, Identifiable {
    /// The standard bank number: the key in `SocketSetup.roms`.
    public var bank: Int
    /// The bank it answers to (an Aries board renumbers them).
    public var answersAs: Int
    /// What's in it as standard: "BASIC 2", or nil.
    public var standard: String?
    /// Hardware that has it, so nothing can be put in: "Sideways RAM
    /// module", "DNFS 3.60 (Econet)".
    public var takenBy: String?
    public var id: Int { bank }
}

extension MachineSetup {
    /// The sockets this machine has, and what has them; with an Econet
    /// module (a network's station), its filing system's ROM takes one.
    public func socketGroups(econet: Bool = false) -> [ROMSocketGroup] {
        let standard = Self.standardROMNames(model: model, discInterface: discInterface)
        func socket(_ bank: Int, answersAs: Int? = nil, takenBy: String? = nil) -> ROMSocket {
            ROMSocket(bank: bank, answersAs: answersAs ?? bank, standard: standard[bank], takenBy: takenBy)
        }
        switch model {
        case .modelA:
            return [ROMSocketGroup(kind: .motherboard, name: "Motherboard",
                                   detail: "Four sockets, 12 on the left to 15 on the right.",
                                   sockets: (12...15).map { socket($0) }, takesPairs: false)]
        case .modelB:
            let e = expansions
            var taken: [Int: String] = [:]
            if e.sidewaysRAM != .none && e.board.takesSidewaysModule {
                taken[e.sidewaysRAMSocket] = e.sidewaysRAM == .ram32 ? "32K sideways RAM module" : "16K sideways RAM module"
            }
            if e.board == .watford32K, let bank = e.controllerROMBank {
                taken[bank] = "The Watford board's ROM"
            }
            if econet {
                taken[discInterface == .intel8271 ? 14 : 13] = "DNFS (Econet), with DFS 1.20"
            }
            if e.board == .ariesB32B12 {
                return [
                    ROMSocketGroup(kind: .board, name: "Aries B12",
                                   detail: "Its cable takes the motherboard's sockets: their ROMs move to its sockets 9 to 12. Sockets 1 to 8 are free; bank 0 is its RAM.",
                                   sockets: (1...8).map { socket($0) } + (12...15).map { socket($0, answersAs: $0 - 3, takenBy: taken[$0]) },
                                   takesPairs: false),
                ]
            }
            return [ROMSocketGroup(kind: .motherboard, name: "Motherboard",
                                   detail: e.board == .ariesB32
                                       ? "Four sockets, left to right; with the Aries B32 they answer as banks 12, 9, 10 and 11."
                                       : "Four sockets, 12 on the left to 15 on the right.",
                                   sockets: (12...15).map { socket($0, answersAs: e.bank(ofSocket: $0), takenBy: taken[$0]) },
                                   takesPairs: false)]
        case .bPlus:
            let chips = [("IC35", 2), ("IC44", 4), ("IC57", 6), ("IC62", 8), ("IC68", 10)]
            return chips.map { name, bank in
                ROMSocketGroup(kind: .motherboard, name: name, detail: "Banks \(bank) and \(bank + 1): a 32K chip, or a 16K one in either.",
                               sockets: [socket(bank), socket(bank + 1)], takesPairs: true)
            } + [ROMSocketGroup(kind: .motherboard, name: "BASIC and DFS", detail: "Banks 14 and 15.",
                                sockets: [socket(14), socket(15)], takesPairs: true)]
        case .master128:
            var groups: [ROMSocketGroup] = []
            for (slot, name) in [(0, "Front Cartridge"), (1, "Rear Cartridge")] {
                let banks = [slot * 2, slot * 2 + 1]
                let cartridge = sockets.cartridges[slot]
                let detail = switch cartridge {
                case nil: "Empty. Banks \(banks[0]) and \(banks[1])."
                case .roms: "A ROM cartridge: banks \(banks[0]) and \(banks[1])."
                case .ram16: "16K of sideways RAM in bank \(banks[0])."
                case .ram32: "32K of sideways RAM in banks \(banks[0]) and \(banks[1])."
                }
                groups.append(ROMSocketGroup(kind: .cartridge(slot), name: name, detail: detail,
                                             sockets: cartridge == .roms ? banks.map { socket($0) } : [], takesPairs: true))
            }
            for (link, chip, bank) in [("LK19", "IC37", 4), ("LK18", "IC41", 6)] {
                let on = sockets.romLinks.contains(bank)
                groups.append(ROMSocketGroup(kind: .link(bank), name: chip,
                                             detail: on ? "\(link) East: a ROM socket for banks \(bank) and \(bank + 1), in place of their sideways RAM."
                                                 : "\(link) West: banks \(bank) and \(bank + 1) are sideways RAM.",
                                             sockets: on ? [socket(bank), socket(bank + 1)] : [], takesPairs: true))
            }
            return groups
        case .masterCompact:
            return []
        }
    }

    /// Whether the machine has any sockets for ROMs.
    public var hasROMSockets: Bool { model != .masterCompact }

    /// The images the sockets hold for `configuration`, from `source`, by
    /// standard bank number; and what's wrong, socket by socket (a ROM
    /// that's gone, or that doesn't fit where it is).
    func socketImages(econet: Bool, source: ROMSource) -> (images: [Int: SocketImage], problems: [Int: String]) {
        var images: [Int: SocketImage] = [:]
        var problems: [Int: String] = [:]
        for group in socketGroups(econet: econet) {
            for socket in group.sockets where socket.takenBy == nil {
                guard let content = sockets.roms[socket.bank] else { continue }
                guard let rom = content.rom else {
                    if images[socket.bank] == nil { images[socket.bank] = .empty }
                    continue
                }
                guard let data = source.data(for: rom.id) else {
                    problems[socket.bank] = "\(rom.name) isn't in the ROM library"
                    continue
                }
                guard rom.layout.fits(size: data.count) else {
                    problems[socket.bank] = "\(rom.name) is \(data.count / 1024)K, which isn't \(rom.layout.displayName)"
                    continue
                }
                switch rom.layout {
                case .single:
                    images[socket.bank] = .rom(Self.filled(data), .standard)
                case .mapped(let mapper):
                    images[socket.bank] = .rom(data, mapper)
                case .pair:
                    let upper = socket.bank + 1
                    guard group.takesPairs, socket.bank % 2 == 0, group.sockets.contains(where: { $0.bank == upper }) else {
                        problems[socket.bank] = "\(rom.name) is two ROMs in one 32K chip: it needs a socket that takes two banks"
                        continue
                    }
                    if sockets.roms[upper] != nil {
                        problems[upper] = "\(rom.name) takes banks \(socket.bank) and \(upper), so bank \(upper) has to be empty"
                    }
                    images[socket.bank] = .rom(Array(data[0..<0x4000]), .standard)
                    images[upper] = .rom(Array(data[0x4000..<0x8000]), .standard)
                }
            }
        }
        return (images, problems)
    }

    /// What's wrong with the ROMs in the sockets, socket by socket.
    public func socketProblems(econet: Bool = false, source: ROMSource = .library) -> [Int: String] {
        socketImages(econet: econet, source: source).problems
    }

    /// A ROM smaller than 16K repeats to fill its bank, as a smaller chip
    /// does (its top address lines aren't connected); an odd size is padded.
    static func filled(_ data: [UInt8]) -> [UInt8] {
        guard data.count < 0x4000 else { return data }
        if 0x4000 % data.count == 0 {
            return Array([[UInt8]](repeating: data, count: 0x4000 / data.count).joined())
        }
        return data + [UInt8](repeating: 0xFF, count: 0x4000 - data.count)
    }

    /// The standard ROMs in the sockets, by bank: "BASIC 2", "DFS 1.20".
    static func standardROMNames(model: BBCMicro.Model, discInterface: BBCMicro.DiscInterface) -> [Int: String] {
        let dfs = switch discInterface {
        case .intel8271: "DFS 1.20"
        case .acorn1770: "DFS 2.26"
        case .watfordDDB2: "Watford DDFS 1.53"
        case .watfordDDB3: "Watford DDFS 1.54T"
        case .opus: "Opus DDOS 3.45"
        }
        return switch model {
        case .modelA: [15: "BASIC 2"]
        case .modelB: [15: "BASIC 2", 14: dfs]
        case .bPlus: [15: "BASIC 2", 14: "DFS 2.26"]
        case .master128, .masterCompact: [:]
        }
    }
}
