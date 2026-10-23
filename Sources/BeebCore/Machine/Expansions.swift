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

        public var displayName: String {
            switch self {
            case .none: "None (stock Model B)"
            case .sidewaysRAM16: "Sideways RAM 16K"
            case .sidewaysRAM32: "Sideways RAM 32K"
            }
        }

        /// Its extra RAM, in bytes.
        public var extraRAM: Int {
            switch self {
            case .none: 0
            case .sidewaysRAM16: 0x4000
            case .sidewaysRAM32: 0x8000
            }
        }

        public var isSidewaysRAM: Bool { self == .sidewaysRAM16 || self == .sidewaysRAM32 }
    }

    /// The Model B's expansions. On other models it's ignored.
    public struct Expansions: Codable, Sendable, Equatable {
        public var board: MemoryBoard
        /// Sideways RAM boards: the socket the module's in, as a bank: 12
        /// or 13, the standard Model B's free sockets.
        public var sidewaysRAMSocket: Int
        /// The 32K module's second bank: 4 or 8 below the first (its lead
        /// on IC76 pin 12 or 11).
        public var secondBankBelow: Int

        public static let none = Expansions()

        public init(board: MemoryBoard = .none, sidewaysRAMSocket: Int = 13, secondBankBelow: Int = 4) {
            self.board = board
            self.sidewaysRAMSocket = sidewaysRAMSocket
            self.secondBankBelow = secondBankBelow
        }

        /// The sideways RAM banks the board provides.
        public var sidewaysRAMBanks: [Int] {
            switch board {
            case .none: []
            case .sidewaysRAM16: [sidewaysRAMSocket]
            case .sidewaysRAM32: [sidewaysRAMSocket, sidewaysRAMSocket - secondBankBelow]
            }
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
            case board, sidewaysRAMSocket, secondBankBelow
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            board = try c.decodeIfPresent(MemoryBoard.self, forKey: .board) ?? .none
            sidewaysRAMSocket = try c.decodeIfPresent(Int.self, forKey: .sidewaysRAMSocket) ?? 13
            secondBankBelow = try c.decodeIfPresent(Int.self, forKey: .secondBankBelow) ?? 4
        }
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
        let boardBanks = Set(configuration.fittedExpansions.sidewaysRAMBanks)
        return (0..<16).map { bank in
            let ram = sidewaysRAMBanks.contains(bank)
            let kind: SidewaysSlot.Kind = sidewaysBanks[bank] == nil ? .empty : ram ? .ram : .rom
            let owner: String
            if boardBanks.contains(bank) {
                owner = board == .sidewaysRAM32 ? "32K sideways RAM module" : "16K sideways RAM module"
            } else if model == .modelB || model == .modelA {
                owner = (12...15).contains(bank) ? "Motherboard socket" : "Not fitted"
            } else {
                owner = kind == .empty ? "Not fitted" : ram ? "Built-in sideways RAM" : "Built-in ROM"
            }
            let header = sidewaysBanks[bank].flatMap { ROMHeader(Array(UnsafeBufferPointer(start: $0, count: 0x100))) }
            return SidewaysSlot(bank: bank, kind: kind, owner: owner,
                                writePolicy: ram ? .whenSelected : .never, header: header)
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
        guard (0..<16).contains(bank), sidewaysRAMBanks.contains(bank), let storage = sidewaysBanks[bank] else {
            throw SidewaysImageError.notRAM(bank)
        }
        guard !image.isEmpty else { throw SidewaysImageError.empty }
        guard image.count <= 0x4000 else { throw SidewaysImageError.tooBig(image.count) }
        storage.update(from: image, count: image.count)
        rewinder?.keyframe()
    }

    /// Clears a sideways RAM bank to zeros, as at power on.
    public func clearSidewaysBank(_ bank: Int) throws {
        guard (0..<16).contains(bank), sidewaysRAMBanks.contains(bank), let storage = sidewaysBanks[bank] else {
            throw SidewaysImageError.notRAM(bank)
        }
        storage.update(repeating: 0, count: 0x4000)
        rewinder?.keyframe()
    }

    /// A sideways bank's 16K, ROM or RAM.
    public func sidewaysBankContents(_ bank: Int) -> [UInt8]? {
        guard (0..<16).contains(bank), let storage = sidewaysBanks[bank] else { return nil }
        return Array(UnsafeBufferPointer(start: storage, count: 0x4000))
    }
}
