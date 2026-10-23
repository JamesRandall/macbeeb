import Foundation

// Hardware expansions for the Model B: a memory board (sideways RAM, or
// shadow RAM boards in later phases) in the machine's configuration. A
// machine without one is the stock Model B, unchanged.
//
// Sideways RAM boards follow the BeebMaster 32K Sideways RAM module's
// documented wiring: it plugs into one of the motherboard's four ROM
// sockets (banks 12-15), which is its first bank; a flying lead to IC76
// (the ROMSEL latch) makes a second bank, four below the first (lead on pin
// 12, banks 8-11) or eight below (pin 11, banks 4-7). Its write enable is
// wired to the CPU's R/W line, so the RAM is written whenever its bank is
// selected. A 16K module is one bank in a socket. MacBeeb doesn't model the
// Model B's partial ROMSEL decoding (on a real B, banks 0-11 alias the four
// sockets), so each bank appears only at its own number.

extension BBCMicro {
    /// A memory expansion board. Only one can be fitted.
    public enum MemoryBoard: String, Codable, Sendable, CaseIterable {
        /// The stock Model B.
        case none
        /// One 16K bank of sideways RAM in a ROM socket.
        case sidewaysRAM16
        /// Two 16K banks: a BeebMaster-style 32K module.
        case sidewaysRAM32
        /// Watford Electronics' 32K RAM board: shadow RAM for &3000-&7FFF
        /// (or the whole 32K), switched by writes to &FFFC-&FFFF, with its
        /// ROM (Shadow RAM OS) in a motherboard socket.
        case watford32K
        /// Aries B32: 32K shared between shadow RAM (&3000-&7FFF) and
        /// sideways RAM banks 13 and 14, with its ROM in bank 15 and the
        /// motherboard's sockets renumbered 12, 9, 10, 11.
        case ariesB32
        /// Aries B32 with the Aries B12 ROM board: sockets 1-12 and 16K of
        /// RAM in bank 0, in place of the motherboard's sockets.
        case ariesB32B12

        public var displayName: String {
            switch self {
            case .none: "None (stock Model B)"
            case .sidewaysRAM16: "Sideways RAM 16K"
            case .sidewaysRAM32: "Sideways RAM 32K"
            case .watford32K: "Watford Electronics 32K Shadow RAM"
            case .ariesB32: "Aries B32"
            case .ariesB32B12: "Aries B32 + B12"
            }
        }

        /// Its extra RAM, in bytes.
        public var extraRAM: Int {
            switch self {
            case .none: 0
            case .sidewaysRAM16: 0x4000
            case .sidewaysRAM32: 0x8000
            case .watford32K: 0x8000
            case .ariesB32: 0x8000
            case .ariesB32B12: 0xC000
            }
        }

        public var isAries: Bool { self == .ariesB32 || self == .ariesB32B12 }

        public var isSidewaysRAM: Bool { self == .sidewaysRAM16 || self == .sidewaysRAM32 }

        /// The bank its controller ROM goes in, if it has one.
        public var controllerROMBank: Int? {
            switch self {
            case .none, .sidewaysRAM16, .sidewaysRAM32: nil
            // The manual: the DFS in the lowest-priority socket and the
            // board's ROM next to it, BASIC in the highest.
            case .watford32K: 13
            // The B32's own socket.
            case .ariesB32, .ariesB32B12: 15
            }
        }
    }

    /// The Model B's expansions. On other models it's ignored.
    public struct Expansions: Codable, Sendable, Hashable {
        public var board: MemoryBoard
        /// Sideways RAM boards: the socket the module's in, as a bank: 12
        /// or 13, the standard Model B's free sockets.
        public var sidewaysRAMSocket: Int
        /// The 32K module's second bank: 4 or 8 below the first (its lead
        /// on IC76 pin 12 or 11).
        public var secondBankBelow: Int

        public static let none = Expansions()

        /// Aries B32: the start-up link is fitted (shadow RAM on at power
        /// on and Ctrl-Break), as the board comes.
        public var ariesStartUpLink: Bool

        public init(board: MemoryBoard = .none, sidewaysRAMSocket: Int = 13, secondBankBelow: Int = 4,
                    ariesStartUpLink: Bool = true) {
            self.board = board
            self.sidewaysRAMSocket = sidewaysRAMSocket
            self.secondBankBelow = secondBankBelow
            self.ariesStartUpLink = ariesStartUpLink
        }

        /// The sideways RAM banks the board provides.
        public var sidewaysRAMBanks: [Int] {
            switch board {
            case .none, .watford32K, .ariesB32: []
            // The B12's RAM sockets, 0L and 0H.
            case .ariesB32B12: [0]
            case .sidewaysRAM16: [sidewaysRAMSocket]
            case .sidewaysRAM32: [sidewaysRAMSocket, sidewaysRAMSocket - secondBankBelow]
            }
        }

        /// What a bank is on a Model B with these expansions: its owner,
        /// and whether it's a socket (so empty when nothing's in it) rather
        /// than not fitted at all.
        public func owner(of bank: Int) -> (name: String, isSocket: Bool) {
            if board.isAries {
                switch bank {
                case 13, 14: return ("Aries B32 RAM (shared with shadow RAM)", true)
                case 15: return ("Aries B32 socket", true)
                case 0 where board == .ariesB32B12: return ("Aries B12 RAM (0L and 0H)", true)
                case 1...12 where board == .ariesB32B12: return ("Aries B12 socket", true)
                case 9...12: return ("Motherboard socket", true)
                default: return ("Not fitted", false)
                }
            }
            if sidewaysRAMBanks.contains(bank) {
                return (board == .sidewaysRAM32 ? "32K sideways RAM module" : "16K sideways RAM module", true)
            }
            if board.controllerROMBank == bank {
                return ("\(board == .watford32K ? "Watford board" : "Board")'s ROM, in a motherboard socket", true)
            }
            return (12...15).contains(bank) ? ("Motherboard socket", true) : ("Not fitted", false)
        }

        /// Problems with the settings, if any (e.g. a socket outside 12-15).
        public var problem: String? {
            guard board.isSidewaysRAM else { return nil }
            // 14 and 15 hold DFS and BASIC.
            guard sidewaysRAMSocket == 12 || sidewaysRAMSocket == 13 else {
                return "The module goes in a free motherboard socket: bank 12 or 13 (14 and 15 hold DFS and BASIC)"
            }
            guard secondBankBelow == 4 || secondBankBelow == 8 else { return "The second bank is 4 or 8 below the first" }
            return nil
        }

        enum CodingKeys: CodingKey {
            case board, sidewaysRAMSocket, secondBankBelow, ariesStartUpLink
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            board = try c.decodeIfPresent(MemoryBoard.self, forKey: .board) ?? .none
            sidewaysRAMSocket = try c.decodeIfPresent(Int.self, forKey: .sidewaysRAMSocket) ?? 13
            secondBankBelow = try c.decodeIfPresent(Int.self, forKey: .secondBankBelow) ?? 4
            ariesStartUpLink = try c.decodeIfPresent(Bool.self, forKey: .ariesStartUpLink) ?? true
        }
    }

    /// What the Watford board's latch maps, set by the address of a write
    /// to &FFFC-&FFFF (the data doesn't matter). MAME's we32kram.cpp and
    /// the board's manual ("Direct control").
    public enum WatfordMapping: UInt8, Codable, Sendable {
        /// &FFFC: the board's RAM for all of &0000-&7FFF.
        case all = 0
        /// &FFFE: the BBC's own RAM.
        case bbc = 2
        /// &FFFF: the board's RAM for &3000-&7FFF, the BBC's below.
        case upper = 3

        public var description: String {
            switch self {
            case .all: "board RAM for &0000–&7FFF (&FFFC)"
            case .bbc: "BBC RAM (&FFFE)"
            case .upper: "board RAM for &3000–&7FFF (&FFFF)"
            }
        }
    }

    /// An expansion board's latches, for save states. Versioned: a field
    /// added later is optional, so older states still load.
    struct ExpansionState: Codable, Sendable {
        static let currentVersion = 1
        var version = Self.currentVersion
        var watfordMapping: WatfordMapping?
        /// Writes to &FFFD seen (the Watford board decodes it, but what it
        /// does isn't known).
        var watfordFFFDWrites: Int?
        var aries: AriesState?
    }

    /// The Aries B32's latches, as its ROM uses them (see
    /// docs/development/expansion-hardware-notes.md for the evidence).
    public struct AriesState: Codable, Sendable, Equatable {
        /// &FE32: the bank writes to &8000-&BFFF go to: 13 or 14 the B32's
        /// RAM, 15 nowhere (its ROM socket), 0-12 the BBC's bus.
        public var ramsel: UInt8 = 0
        /// &FE3F on, &FE3E off: the CPU sees shadow RAM.
        public var shadow = false
        /// &FE3A on, &FE3C off: &3000-&3FFF is shadowed (20K).
        public var shadowLow = false
        /// &FE36 on, &FE34 off: &7000-&7FFF is shadowed.
        public var shadowHigh = false

        /// The shadow RAM the switches give: 20K (&3000-&7FFF), 16K
        /// (&4000-&7FFF), 0K as the ROM uses them, or the combination the
        /// ROM never sets (&3000-&6FFF).
        public var shadowAllocation: String {
            switch (shadowLow, shadowHigh) {
            case (true, true): "20K shadow (&3000–&7FFF) + 12K sideways RAM"
            case (false, true): "16K shadow (&4000–&7FFF) + 16K sideways RAM"
            case (false, false): "no shadow RAM + 32K sideways RAM"
            case (true, false): "16K shadow (&3000–&6FFF)"
            }
        }

        /// The shadow RAM in K, for showing (0, 16 or 20).
        public var shadowK: Int {
            switch (shadowLow, shadowHigh) {
            case (true, true): 20
            case (false, false): 0
            default: 16
            }
        }

        /// What *RWRITE has set.
        public var writeTarget: String {
            switch ramsel & 0x0F {
            case 13, 14: "bank \(ramsel & 0x0F) (*RWRITE \(ramsel & 0x0F))"
            case 15: "nowhere: write-protected (*RWRITE OFF)"
            default: "the BBC's bus: external sideways RAM, or the B12's bank 0 (*RWRITE \(ramsel & 0x0F) or EXTERNAL)"
            }
        }
    }

    /// A write to an expansion board's register, for the debugger.
    public struct ControllerWrite: Sendable, Equatable, Codable {
        public var cycle: UInt64
        public var address: UInt16
        public var value: UInt8
    }

    /// One of the sixteen sideways banks, as the hardware has it.
    public struct SidewaysSlot: Sendable, Equatable, Identifiable {
        public enum Kind: String, Sendable {
            case empty
            case rom
            case ram
        }

        /// When the CPU can write to it.
        public enum WritePolicy: String, Sendable {
            /// ROM, or an empty socket.
            case never
            /// Whenever its bank is selected in ROMSEL (&FE30).
            case whenSelected
            /// While the Aries B32's write register (&FE32, *RWRITE) selects
            /// it, whichever bank ROMSEL reads.
            case whenWriteSelected
        }

        public var bank: Int
        public var kind: Kind
        /// What it's on: "Motherboard socket", "Sideways RAM module", ...
        public var owner: String
        public var writePolicy: WritePolicy
        /// The ROM header's title and version, if the bank holds a valid
        /// sideways ROM image.
        public var header: ROMHeader?
        public var id: Int { bank }
    }

    /// A sideways ROM's header: what the MOS looks at when it scans the
    /// banks (the copyright string must be where byte 7 says).
    public struct ROMHeader: Sendable, Equatable {
        public var title: String
        public var version: String?
        public var copyright: String
        /// Byte 6: bit 7 service entry, bit 6 language entry.
        public var type: UInt8
        public var isLanguage: Bool { type & 0x40 != 0 }

        /// Parses the first bytes of a bank; nil if it isn't a ROM image.
        public init?(_ bytes: [UInt8]) {
            guard bytes.count >= 0x40 else { return nil }
            let offset = Int(bytes[7])
            guard offset >= 9, offset + 4 <= bytes.count, bytes[offset] == 0,
                  bytes[offset + 1] == 0x28, bytes[offset + 2] == 0x43, bytes[offset + 3] == 0x29 else { return nil }
            func string(from start: Int) -> (String, Int) {
                var end = start
                while end < offset && bytes[end] != 0 { end += 1 }
                let text = String(bytes[start..<end].map { $0 >= 32 && $0 < 127 ? Character(UnicodeScalar($0)) : "?" })
                return (text, end)
            }
            let (title, titleEnd) = string(from: 9)
            guard !title.isEmpty else { return nil }
            self.title = title
            version = titleEnd < offset ? string(from: titleEnd + 1).0 : nil
            if version?.isEmpty == true { version = nil }
            var end = offset + 1
            while end < bytes.count && bytes[end] != 0 { end += 1 }
            copyright = String(bytes[(offset + 1)..<end].map { $0 >= 32 && $0 < 127 ? Character(UnicodeScalar($0)) : "?" })
            type = bytes[6]
        }

        /// "TITLE VERSION".
        public var name: String { [title, version].compactMap { $0 }.joined(separator: " ") }
    }

    /// The sixteen sideways banks.
    public var sidewaysSlots: [SidewaysSlot] {
        let board = configuration.fittedExpansions.board
        return (0..<16).map { bank in
            let ram = isSidewaysRAM(bank)
            let kind: SidewaysSlot.Kind = sidewaysStorage(bank) == nil ? .empty : ram ? .ram : .rom
            let owner: String
            if model == .modelB {
                owner = configuration.fittedExpansions.owner(of: bank).name
            } else if model == .modelA {
                owner = (12...15).contains(bank) ? "Motherboard socket" : "Not fitted"
            } else {
                owner = kind == .empty ? "Not fitted" : ram ? "Built-in sideways RAM" : "Built-in ROM"
            }
            let header = sidewaysStorage(bank).flatMap { ROMHeader(Array(UnsafeBufferPointer(start: $0, count: 0x100))) }
            return SidewaysSlot(bank: bank, kind: kind, owner: owner,
                                writePolicy: !ram ? .never : board.isAries ? .whenWriteSelected : .whenSelected, header: header)
        }
    }

    public enum SidewaysImageError: Error, CustomStringConvertible, Equatable {
        case notRAM(Int)
        case tooBig(Int)
        case empty

        public var description: String {
            switch self {
            case .notRAM(let bank): "Bank \(bank) isn't sideways RAM"
            case .tooBig(let size): "The image is \(size) bytes: a sideways bank holds 16K (16384 bytes)"
            case .empty: "The image is empty"
            }
        }
    }

    /// Puts an image into a sideways RAM bank from outside the BBC (as if
    /// loaded by a utility), at &8000; the rest of the bank is left as it
    /// was. The MOS sees a new ROM after the next Break.
    public func loadSidewaysImage(_ image: [UInt8], bank: Int) throws {
        guard (0..<16).contains(bank), isSidewaysRAM(bank), let storage = sidewaysStorage(bank) else {
            throw SidewaysImageError.notRAM(bank)
        }
        guard !image.isEmpty else { throw SidewaysImageError.empty }
        guard image.count <= 0x4000 else { throw SidewaysImageError.tooBig(image.count) }
        storage.update(from: image, count: image.count)
        rewinder?.keyframe()
    }

    /// Clears a sideways RAM bank to zeros, as at power on.
    public func clearSidewaysBank(_ bank: Int) throws {
        guard (0..<16).contains(bank), isSidewaysRAM(bank), let storage = sidewaysStorage(bank) else {
            throw SidewaysImageError.notRAM(bank)
        }
        storage.update(repeating: 0, count: 0x4000)
        rewinder?.keyframe()
    }

    /// A sideways bank's 16K, ROM or RAM.
    public func sidewaysBankContents(_ bank: Int) -> [UInt8]? {
        guard (0..<16).contains(bank), let storage = sidewaysStorage(bank) else { return nil }
        return Array(UnsafeBufferPointer(start: storage, count: 0x4000))
    }
}
