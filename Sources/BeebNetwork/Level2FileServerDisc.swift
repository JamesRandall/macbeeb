import BeebCore
import BeebROMs
import Foundation

/// A disc for Acorn's Level 2 file server: its own filing system ("AFS0"),
/// not DFS, on an 80-track double-sided disc (1600 sectors, 400K). Made and
/// changed here as the server's disc manager (DSCMGR, on the bundled
/// utilities disc) and the server itself would, so a network can start
/// with users, directories and programs already on it. The format, as
/// DSCMGR writes it and the server keeps it:
///
/// - Sector 0 (and a copy in 10): "AFS0", the disc's name, the root
///   directory's sector, the date, where the map's two copies are.
/// - The map, twice (13 sectors each, in the middle of side 0): a sequence
///   number, the free sectors' count and chain, then two bytes a sector. A
///   used sector's entry has W (&8000), S at a file's first sector
///   (&2000), and the next sector; or at its last E (&4000) and the bytes
///   it holds (0 for 256). An empty file's one sector is &7000. The server
///   writes the copies in turn; the one with the later sequence number
///   (also in its last byte) is current.
/// - Directories: two sectors, a cycle number (first and last byte), the
///   name, 19 entries of 26 bytes kept in alphabetical order by a chain
///   (and a chain of free ones): name, load and execution addresses,
///   access, date, and the object's first sector.
/// - $.PASSWORDS: 17 bytes a user (name, password, and flags: &80 in use,
///   &40 system privilege, the boot option in the bottom two bits).
///
/// Sectors are numbered across both sides: side 0's 800, then side 1's.
public struct Level2FileServerDisc: Sendable, Equatable {
    public static let sectorCount = 1600
    static let sectorsPerSide = 800
    static let sectorSize = 256
    /// Where DSCMGR puts the map's two copies.
    static let mapSectors = 13
    static let mapA = 387
    static let mapB = 400
    /// A directory's entries.
    public static let directoryEntries = 19
    public static let maxNameLength = 10
    public static let maxPasswordLength = 6

    /// The sectors, side 0's then side 1's.
    private var sectors: [UInt8]
    /// The current map (written to both copies whenever it changes).
    private var map: Map

    // MARK: Users, access, dates

    /// What the network filing system does with the user's !BOOT when they
    /// log on (*OPT 4).
    public enum BootOption: Int, Sendable, CaseIterable, Codable {
        case off, load, run, exec
    }

    public struct User: Sendable, Equatable {
        public var name: String
        public var password: String
        public var bootOption: BootOption
        /// System privilege: may make and remove users, and owns $.
        public var isSystem: Bool

        public init(_ name: String, password: String = "", bootOption: BootOption = .off, isSystem: Bool = false) {
            self.name = name
            self.password = password
            self.bootOption = bootOption
            self.isSystem = isSystem
        }
    }

    /// An object's access, as *ACCESS sets it ("WR/R").
    public struct Access: OptionSet, Sendable, Hashable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }

        public static let publicRead = Access(rawValue: 0x01)
        public static let publicWrite = Access(rawValue: 0x02)
        public static let ownerRead = Access(rawValue: 0x04)
        public static let ownerWrite = Access(rawValue: 0x08)
        public static let locked = Access(rawValue: 0x10)
        public static let directory = Access(rawValue: 0x20)

        /// What SAVE gives a file: WR/.
        public static let saved: Access = [.ownerRead, .ownerWrite]
        /// WR/R: anyone can load it.
        public static let shared: Access = [.ownerRead, .ownerWrite, .publicRead]
        /// What *CDIR gives a directory: DL/.
        public static let newDirectory: Access = [.directory, .locked]

        /// As *CAT shows it: "WR/R", "DL/".
        public var text: String {
            var owner = ""
            if contains(.directory) { owner += "D" }
            if contains(.locked) { owner += "L" }
            if contains(.ownerWrite) { owner += "W" }
            if contains(.ownerRead) { owner += "R" }
            var others = ""
            if contains(.publicWrite) { others += "W" }
            if contains(.publicRead) { others += "R" }
            return owner + "/" + others
        }
    }

    /// A date as the server keeps it: 1981 to 1996.
    public struct Date: Sendable, Equatable {
        public var day: Int
        public var month: Int
        public var year: Int

        public init(day: Int, month: Int, year: Int) {
            self.day = day
            self.month = month
            self.year = year
        }

        /// Today's day and month in 1988 (a leap year, so any day is one):
        /// the server can't hold this century's years.
        public static var today: Date {
            let parts = Calendar(identifier: .gregorian).dateComponents([.day, .month], from: Foundation.Date())
            return Date(day: parts.day ?? 1, month: parts.month ?? 1, year: 1988)
        }

        /// As DSCMGR packs it: the year since 1981 in the top four bits,
        /// then the month, then the day.
        var encoded: UInt16 {
            UInt16(truncatingIfNeeded: (min(max(year, 1981), 1996) - 1981) << 12 | (month & 15) << 8 | (day & 255))
        }

        init(encoded: UInt16) {
            self.init(day: Int(encoded & 0xFF), month: Int(encoded >> 8 & 15), year: 1981 + Int(encoded >> 12))
        }

        /// As the server asks for it at start-up: "23/10/88".
        public var text: String { String(format: "%02d/%02d/%02d", day, month, year % 100) }
    }

    /// A directory's entry: a file or a directory.
    public struct Entry: Sendable, Equatable {
        public var name: String
        public var loadAddress: UInt32
        public var executionAddress: UInt32
        public var access: Access
        public var date: Date
        /// Its first sector (the server's System Internal Name).
        public var sector: Int
        /// The bytes it holds (a directory's two sectors).
        public var length: Int

        public var isDirectory: Bool { access.contains(.directory) }
    }

    // MARK: Making a disc

    /// A newly initialised disc, as DSCMGR leaves one (byte for byte, given
    /// the same answers): a password file with SYST (system privileged) and
    /// `users`, a directory in $ for each, and nothing else. Names start
    /// with a letter; DSCMGR takes up to 13.
    public init(name: String = "FILESERVER", users: [String], date: Date = .today) throws {
        guard !name.isEmpty, Self.isValidName(name, length: 16) else { throw DiscEditError.badName(name) }
        for user in users where user.first?.isLetter != true || !Self.isValidName(user, length: Self.maxNameLength) {
            throw DiscEditError.badName(user)
        }
        if let repeated = users.first(where: { user in users.filter { Self.same($0, user) }.count > 1 || Self.same(user, "SYST") }) {
            throw DiscEditError.fileExists(repeated)
        }
        // As FORM80 leaves the disc: every sector E5s, and on each side a
        // DFS catalogue saying it's full (so DFS won't write to it).
        sectors = [UInt8](repeating: 0xE5, count: Self.sectorCount * Self.sectorSize)
        for side in 0..<2 {
            let first = side * Self.sectorsPerSide
            sectors.replaceSubrange(first * Self.sectorSize..<(first + 1) * Self.sectorSize,
                                    with: [UInt8](repeating: 0x80, count: Self.sectorSize))
            var catalogue = [UInt8](repeating: 0, count: Self.sectorSize)
            catalogue[5] = 0xF8
            catalogue[6] = UInt8(Self.sectorsPerSide >> 8)
            catalogue[7] = UInt8(Self.sectorsPerSide & 0xFF)
            sectors.replaceSubrange((first + 1) * Self.sectorSize..<(first + 2) * Self.sectorSize, with: catalogue)
        }

        // The map: every sector free in one chain, but for the disc's
        // information (0 and its copy in 10), sector 1 of each side (the
        // DFS catalogue), and the map's own two copies.
        var map = Map(sequence: 0, free: Self.sectorCount - 3 - 2 * Self.mapSectors - 1, freeHead: 2,
                      entries: [UInt16](repeating: 0, count: Self.sectorCount))
        map.entries[0] = Map.w | Map.e | Map.s
        map.entries[Self.sectorCount - 1] = Map.e
        for sector in 2...(Self.sectorCount - 2) {
            map.entries[sector] = UInt16(sector + 1)
        }
        map.entries[9] = 11
        map.entries[10] = Map.w | Map.e | Map.s
        map.entries[1] = Map.w | Map.e | Map.s
        map.entries[Self.sectorsPerSide] = UInt16(Self.sectorsPerSide + 2)
        map.entries[Self.sectorsPerSide + 1] = Map.w | Map.e | Map.s
        for copy in [Self.mapB, Self.mapA] {
            let last = copy + Self.mapSectors - 1
            map.entries[copy - 1] = map.entries[last] & Map.next
            map.entries[copy] |= Map.s
            map.entries[last] = map.entries[last] & (Map.s | Map.w) | Map.e
            for sector in copy...last { map.entries[sector] |= Map.w }
        }
        self.map = map

        // The password file, SYST first; then a directory for each user,
        // and the password file, in alphabetical order; then $.
        var passwords = [UInt8](repeating: 0, count: Self.sectorSize)
        for (index, user) in ([User("SYST", isSystem: true)] + users.map { User($0) }).enumerated() {
            passwords.replaceSubrange(index * 17..<index * 17 + 17, with: Self.passwordEntry(user))
        }
        let encodedDate = date.encoded
        var root = Self.emptyDirectory(named: "$")
        for object in (users + ["PASSWORDS"]).sorted(by: Self.precedes) {
            if object == "PASSWORDS" {
                let first = self.map.allocate()
                self.map.entries[first] = Map.w | Map.e | Map.s
                write(sector: first, passwords)
                try Self.addEntry(to: &root, name: object, load: 0, exec: 0, access: [], date: encodedDate, sector: first)
            } else {
                let first = allocateDirectory()
                writeDirectory(Self.emptyDirectory(named: object), at: first)
                try Self.addEntry(to: &root, name: object, load: 0, exec: 0, access: .newDirectory, date: encodedDate, sector: first)
            }
        }
        // (DSCMGR leaves a new directory's cycle number at 0.)
        let rootFirst = allocateDirectory()
        writeDirectory(root, at: rootFirst)

        var info = [UInt8](repeating: 0, count: Self.sectorSize)
        for index in stride(from: 0, to: Self.sectorSize, by: 4) { info[index] = 0x80 }
        info.replaceSubrange(0..<4, with: Array("AFS0".utf8))
        info.replaceSubrange(4..<21, with: Array(name.utf8) + [UInt8](repeating: 0x20, count: 17 - name.utf8.count))
        Self.put(&info, at: 20, UInt32(Self.sectorsPerSide), bytes: 2)
        Self.put(&info, at: 22, UInt32(rootFirst), bytes: 3)
        Self.put(&info, at: 25, UInt32(encodedDate), bytes: 2)
        Self.put(&info, at: 27, UInt32(Self.mapA), bytes: 3)
        Self.put(&info, at: 30, UInt32(Self.mapB), bytes: 3)
        Self.put(&info, at: 33, UInt32(Self.mapSectors * Self.sectorSize), bytes: 3)
        write(sector: 0, info)
        write(sector: 10, info)
        // DSCMGR writes copy A as sequence 0, then B as 1.
        writeMap(sequences: (0, 1))
    }

    /// The disc the Studio gives a new Level 2 file server: SYST (no
    /// password), BOOT, whose !BOOT (a *CAT) is EXECed when it logs on
    /// (boot option 3, so Shift-Break runs it), GUEST, and an empty
    /// library, $.LIBRARY, which the server gives everyone at log-on.
    public static func standard(date: Date = .today) throws -> Level2FileServerDisc {
        var disc = try Level2FileServerDisc(name: "FILESERVER", users: ["BOOT", "GUEST"], date: date)
        try disc.createDirectory("$.LIBRARY", date: date)
        try disc.setBootOption(.exec, for: "BOOT")
        try disc.save("$.BOOT.!BOOT", contents: Array("*CAT\r".utf8), access: .shared, date: date)
        return disc
    }

    // MARK: Starting the server

    /// The drive the bundled utilities disc goes in (the server's disc is
    /// in drive 0, and stays there).
    public static let utilitiesDrive = 1

    /// The utilities disc: the server (FS, which runs in the Second
    /// Processor), the disc manager, and formatters.
    public static var utilities: (data: [UInt8], format: Disc.ImageFormat) {
        let bundled = BeebROMs.BundledDisc.econetLevel2
        return (bundled.data, bundled.format)
    }

    /// What the server's machine types to start it, as its manual says:
    /// *RUN FS (from the utilities disc), then the date, one drive, S to
    /// start, and the most stations it'll have logged on at once. The
    /// server takes its answers from the keyboard buffer in turn.
    public static func startup(stations: Int, date: Date = .today) -> String {
        "*RUN :\(utilitiesDrive).FS\n\(date.text)\n1\nS\n\(min(max(stations, 1), maxStations))\n"
    }

    /// The most logged-on stations the server is asked for (it refuses 50).
    public static let maxStations = 30

    /// A disc from a .dsd image (its sides interleaved, a track at a time).
    public init(image: [UInt8]) throws {
        var sectors = [UInt8](repeating: 0, count: Self.sectorCount * Self.sectorSize)
        for sector in 0..<Self.sectorCount {
            let offset = Self.imageOffset(of: sector)
            guard offset + Self.sectorSize <= image.count else { continue }
            sectors.replaceSubrange(sector * Self.sectorSize..<(sector + 1) * Self.sectorSize,
                                    with: image[offset..<offset + Self.sectorSize])
        }
        guard Self.isLevel2(sectors), let map = Self.readMap(sectors) else { throw DiscEditError.notFormatted }
        self.sectors = sectors
        self.map = map
    }

    /// The disc as a .dsd image (80 tracks, both sides).
    public var image: [UInt8] {
        var image = [UInt8](repeating: 0, count: Self.sectorCount * Self.sectorSize)
        for sector in 0..<Self.sectorCount {
            let offset = Self.imageOffset(of: sector)
            image.replaceSubrange(offset..<offset + Self.sectorSize, with: read(sector: sector))
        }
        return image
    }

    /// Whether an image (or its first sector) is a Level 2 file server's
    /// disc.
    public static func isLevel2(_ image: [UInt8]) -> Bool {
        image.count >= 4 && Array(image[0..<4]) == Array("AFS0".utf8)
    }

    // MARK: Reading

    /// The disc's name.
    public var name: String {
        String(decoding: sectors[4..<20], as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }

    /// Sectors free.
    public var freeSectors: Int { map.free }

    /// The password file's users, in its order.
    public var users: [User] {
        guard let bytes = try? passwordFile() else { return [] }
        return stride(from: 0, to: bytes.count - 16, by: 17).compactMap { offset in
            let flags = bytes[offset + 16]
            guard flags & 0x80 != 0 else { return nil }
            return User(Self.text(bytes[offset..<offset + 10]), password: Self.text(bytes[offset + 10..<offset + 16]),
                        bootOption: BootOption(rawValue: Int(flags & 3)) ?? .off, isSystem: flags & 0x40 != 0)
        }
    }

    /// What's in a directory ("$", "$.BOOT"), in its order (alphabetical).
    public func entries(in path: String) throws -> [Entry] {
        let bytes = readDirectory(at: try directorySector(path))
        var entries: [Entry] = []
        var offset = Self.link(bytes, 0)
        while offset != 0, entries.count < Self.directoryEntries, offset + 26 <= bytes.count {
            entries.append(entry(in: bytes, at: offset))
            offset = Self.link(bytes, offset)
        }
        return entries
    }

    /// A file or directory by its path from $.
    public func entry(at path: String) throws -> Entry {
        let (parent, leaf) = try split(path)
        guard let found = try entries(in: parent).first(where: { Self.same($0.name, leaf) }) else {
            throw DiscEditError.notFound(path)
        }
        return found
    }

    /// A file's bytes.
    public func contents(of entry: Entry) -> [UInt8] {
        Array(chain(from: entry.sector).flatMap { read(sector: $0) }.prefix(entry.length))
    }

    public func contents(of path: String) throws -> [UInt8] {
        contents(of: try entry(at: path))
    }

    // MARK: Changing

    /// Saves a file (in place of one there already, unless it's locked),
    /// as SAVE or *SAVE would: `path` from $ ("$.BOOT.!BOOT", or
    /// "BOOT.!BOOT"), its directory already there.
    public mutating func save(_ path: String, loadAddress: UInt32 = 0, executionAddress: UInt32 = 0, contents: [UInt8],
                              access: Access = .saved, date: Date = .today) throws {
        let (parent, leaf) = try split(path)
        guard Self.isValidName(leaf, length: Self.maxNameLength) else { throw DiscEditError.badName(path) }
        let directory = try directorySector(parent)
        var bytes = readDirectory(at: directory)
        let existing = Self.find(leaf, in: bytes)
        var freeing: [Int] = []
        if let existing {
            let old = entry(in: bytes, at: existing)
            if old.isDirectory { throw DiscEditError.fileExists(path) }
            if old.access.contains(.locked) { throw DiscEditError.locked(path) }
            freeing = chain(from: old.sector)
        } else if Self.freeSlot(in: bytes) == nil {
            throw DiscEditError.catalogueFull
        }
        guard map.free + freeing.count >= Self.sectorsFor(contents.count) else { throw DiscEditError.discFull }
        if let existing {
            map.release(freeing)
            Self.removeEntry(at: existing, from: &bytes)
        }
        let first = writeChain(contents)
        try Self.addEntry(to: &bytes, name: leaf, load: loadAddress, exec: executionAddress, access: access,
                          date: date.encoded, sector: first)
        Self.changed(&bytes)
        writeDirectory(bytes, at: directory)
        writeMapCopies()
    }

    /// Makes a directory, as *CDIR would (DL/).
    public mutating func createDirectory(_ path: String, date: Date = .today) throws {
        let (parent, leaf) = try split(path)
        guard Self.isValidName(leaf, length: Self.maxNameLength) else { throw DiscEditError.badName(path) }
        let directory = try directorySector(parent)
        var bytes = readDirectory(at: directory)
        if Self.find(leaf, in: bytes) != nil { throw DiscEditError.fileExists(path) }
        guard Self.freeSlot(in: bytes) != nil else { throw DiscEditError.catalogueFull }
        guard map.free >= 2 else { throw DiscEditError.discFull }
        let first = allocateDirectory()
        writeDirectory(Self.emptyDirectory(named: leaf), at: first)
        try Self.addEntry(to: &bytes, name: leaf, load: 0, exec: 0, access: .newDirectory, date: date.encoded, sector: first)
        Self.changed(&bytes)
        writeDirectory(bytes, at: directory)
        writeMapCopies()
    }

    /// Adds a user, as *NEWUSER would, and (unless `directory` is false)
    /// a directory for them in $, as the manager then makes with *CDIR.
    public mutating func addUser(_ user: User, directory: Bool = true, date: Date = .today) throws {
        guard user.name.first?.isLetter == true, Self.isValidName(user.name, length: Self.maxNameLength),
              Self.isValidName(user.password, length: Self.maxPasswordLength)
        else { throw DiscEditError.badName(user.name) }
        guard !users.contains(where: { Self.same($0.name, user.name) }) else { throw DiscEditError.fileExists(user.name) }
        if directory, (try? entry(at: "$." + user.name)) == nil {
            try createDirectory("$." + user.name, date: date)
        }
        var file = try passwordFile()
        let slots = stride(from: 0, to: file.count - 16, by: 17)
        let free = slots.first { file[$0 + 16] & 0x80 == 0 } ?? {
            // A sector more (as Acorn's EXTENDPWF does).
            let next = (file.count + 16) / 17 * 17
            file += [UInt8](repeating: 0, count: Self.sectorSize)
            return next
        }()
        file.replaceSubrange(free..<free + 17, with: Self.passwordEntry(user))
        try writePasswordFile(file)
    }

    /// Sets what logging on does with the user's !BOOT, as *OPT 4 would.
    public mutating func setBootOption(_ option: BootOption, for user: String) throws {
        try changeUser(user) { $0.bootOption = option }
    }

    /// Sets a user's password, as *PASS would ("" for none).
    public mutating func setPassword(_ password: String, for user: String) throws {
        guard Self.isValidName(password, length: Self.maxPasswordLength) else { throw DiscEditError.badName(password) }
        try changeUser(user) { $0.password = password }
    }

    /// Puts Mac files in a directory ($.LIBRARY by default), shared (WR/R)
    /// so every user can load them: named and addressed by .inf files beside
    /// them where there are any, BASIC text (.bas) tokenised; folders become
    /// directories. Returns the paths they were given.
    @discardableResult
    public mutating func add(_ urls: [URL], to directory: String = "$.LIBRARY") throws -> [String] {
        var paths: [String] = []
        for url in urls {
            guard let file = try MacFile.read(url, adfs: true) else { continue }
            try add(file, to: directory, paths: &paths)
        }
        return paths
    }

    private mutating func add(_ file: MacFile, to directory: String, paths: inout [String]) throws {
        let leaf = String((file.name.split(separator: ".").last.map(String.init) ?? file.name).prefix(Self.maxNameLength))
        let path = directory + "." + leaf
        if let contents = file.contents {
            var access = Access.shared
            if file.locked { access.insert(.locked) }
            try save(path, loadAddress: file.loadAddress, executionAddress: file.executionAddress, contents: contents, access: access)
            paths.append(path)
            return
        }
        if (try? entry(at: path))?.isDirectory != true {
            try createDirectory(path)
        }
        for child in file.children {
            try add(child, to: path, paths: &paths)
        }
    }

    // MARK: Sectors

    private static func imageOffset(of sector: Int) -> Int {
        let side = sector / sectorsPerSide
        let track = sector % sectorsPerSide / 10
        return ((track * 2 + side) * 10 + sector % 10) * sectorSize
    }

    private static func sectorsFor(_ length: Int) -> Int {
        max(1, (length + sectorSize - 1) / sectorSize)
    }

    private func read(sector: Int) -> [UInt8] {
        Array(sectors[sector * Self.sectorSize..<(sector + 1) * Self.sectorSize])
    }

    private mutating func write(sector: Int, _ bytes: [UInt8]) {
        sectors.replaceSubrange(sector * Self.sectorSize..<(sector + 1) * Self.sectorSize, with: bytes)
    }

    /// The sectors of an object from its first, as the map chains them.
    private func chain(from first: Int) -> [Int] {
        var result: [Int] = []
        var sector = first
        while sector < Self.sectorCount, result.count < Self.sectorCount {
            result.append(sector)
            let entry = map.entries[sector]
            if entry & Map.e != 0 { break }
            sector = Int(entry & Map.next)
        }
        return result
    }

    /// Writes `contents` to newly allocated sectors, chained in the map.
    /// Returns the first.
    private mutating func writeChain(_ contents: [UInt8]) -> Int {
        let count = Self.sectorsFor(contents.count)
        let allocated = (0..<count).map { _ in map.allocate() }
        for (index, sector) in allocated.enumerated() {
            let start = index * Self.sectorSize
            let chunk = contents.count > start ? Array(contents[start..<min(contents.count, start + Self.sectorSize)]) : []
            write(sector: sector, chunk + [UInt8](repeating: 0, count: Self.sectorSize - chunk.count))
            var value: UInt16 = index == count - 1 ? Map.e | UInt16(contents.count % Self.sectorSize) : UInt16(allocated[index + 1])
            if index == 0 { value |= Map.s }
            value |= contents.isEmpty ? Map.empty : Map.w
            map.entries[sector] = value
        }
        return allocated[0]
    }

    /// Two sectors for a directory, chained. Returns the first.
    private mutating func allocateDirectory() -> Int {
        let first = map.allocate()
        let second = map.allocate()
        map.entries[first] = Map.w | Map.s | UInt16(second)
        map.entries[second] = Map.w | Map.e
        return first
    }

    // MARK: The map

    struct Map: Equatable, Sendable {
        static let w: UInt16 = 0x8000
        static let e: UInt16 = 0x4000
        static let s: UInt16 = 0x2000
        /// An empty file's sector (with E and S, not W).
        static let empty: UInt16 = 0x1000
        static let next: UInt16 = 0x0FFF

        var sequence: UInt8
        var free: Int
        var freeHead: Int
        var entries: [UInt16]

        /// The free chain's first sector, taken.
        mutating func allocate() -> Int {
            let sector = freeHead
            freeHead = Int(entries[sector] & Self.next)
            free -= 1
            return sector
        }

        /// Sectors back at the head of the free chain.
        mutating func release(_ sectors: [Int]) {
            for sector in sectors {
                entries[sector] = UInt16(freeHead)
                freeHead = sector
                free += 1
            }
        }
    }

    /// The current copy of the map: the one with the later sequence
    /// number, of those written in full.
    private static func readMap(_ sectors: [UInt8]) -> Map? {
        func copy(at first: Int) -> ArraySlice<UInt8>? {
            let bytes = sectors[first * sectorSize..<(first + mapSectors) * sectorSize]
            // A copy written in full starts and ends with its sequence number.
            return bytes.first == bytes.last ? bytes : nil
        }
        let current: ArraySlice<UInt8>
        switch (copy(at: mapA), copy(at: mapB)) {
        case (let a?, let b?): current = Int8(bitPattern: b.first! &- a.first!) > 0 ? b : a
        case (let a?, nil): current = a
        case (nil, let b?): current = b
        case (nil, nil): return nil
        }
        let base = current.startIndex
        let entries = (0..<sectorCount).map { UInt16(current[base + 5 + $0 * 2]) | UInt16(current[base + 6 + $0 * 2]) << 8 }
        let map = Map(sequence: current[base], free: Int(current[base + 1]) | Int(current[base + 2]) << 8,
                      freeHead: Int(current[base + 3]) | Int(current[base + 4]) << 8, entries: entries)
        return map.freeHead < sectorCount ? map : nil
    }

    /// Writes the changed map to both copies, B the later, so the server
    /// reads the same whichever it takes.
    private mutating func writeMapCopies() {
        let sequence = map.sequence &+ 1
        writeMap(sequences: (sequence, sequence &+ 1))
    }

    private mutating func writeMap(sequences: (UInt8, UInt8)) {
        var bytes = [UInt8](repeating: 0, count: Self.mapSectors * Self.sectorSize)
        Self.put(&bytes, at: 1, UInt32(map.free), bytes: 2)
        Self.put(&bytes, at: 3, UInt32(map.freeHead), bytes: 2)
        for (index, entry) in map.entries.enumerated() {
            Self.put(&bytes, at: 5 + index * 2, UInt32(entry), bytes: 2)
        }
        for (first, sequence) in [(Self.mapA, sequences.0), (Self.mapB, sequences.1)] {
            bytes[0] = sequence
            bytes[bytes.count - 1] = sequence
            for index in 0..<Self.mapSectors {
                write(sector: first + index, Array(bytes[index * Self.sectorSize..<(index + 1) * Self.sectorSize]))
            }
        }
        map.sequence = sequences.1
    }

    // MARK: Directories

    private func readDirectory(at first: Int) -> [UInt8] {
        chain(from: first).prefix(2).flatMap { read(sector: $0) }
    }

    private mutating func writeDirectory(_ bytes: [UInt8], at first: Int) {
        for (index, sector) in chain(from: first).prefix(2).enumerated() {
            write(sector: sector, Array(bytes[index * Self.sectorSize..<(index + 1) * Self.sectorSize]))
        }
    }

    /// An empty directory, as DSCMGR makes one: every entry free, chained
    /// from the last.
    private static func emptyDirectory(named name: String) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 2 * sectorSize)
        let title = Array(name.utf8.prefix(maxNameLength))
        bytes.replaceSubrange(3..<13, with: title + [UInt8](repeating: 0x20, count: maxNameLength - title.count))
        var previous = 0
        for offset in stride(from: 0x11, to: 0x11 + directoryEntries * 26, by: 26) {
            put(&bytes, at: offset, UInt32(previous), bytes: 2)
            previous = offset
        }
        put(&bytes, at: 13, UInt32(previous), bytes: 2)
        return bytes
    }

    /// The two-byte offset at `offset`: an entry's next, or (at 0) the
    /// first entry.
    private static func link(_ bytes: [UInt8], _ offset: Int) -> Int {
        Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
    }

    private func entry(in bytes: [UInt8], at offset: Int) -> Entry {
        let sector = Int(bytes[offset + 23]) | Int(bytes[offset + 24]) << 8 | Int(bytes[offset + 25]) << 16
        let access = Access(rawValue: bytes[offset + 20])
        return Entry(name: Self.text(bytes[offset + 2..<offset + 12]),
                     loadAddress: Self.get(bytes, at: offset + 12), executionAddress: Self.get(bytes, at: offset + 16),
                     access: access, date: Date(encoded: UInt16(bytes[offset + 21]) | UInt16(bytes[offset + 22]) << 8),
                     sector: sector, length: access.contains(.directory) ? 2 * Self.sectorSize : length(from: sector))
    }

    private func length(from first: Int) -> Int {
        guard first < Self.sectorCount else { return 0 }
        let sectors = chain(from: first)
        let last = map.entries[sectors.last!]
        if last & Map.empty != 0 && last & Map.w == 0 { return 0 }
        let tail = Int(last & 0xFF)
        return (sectors.count - 1) * Self.sectorSize + (tail == 0 ? Self.sectorSize : tail)
    }

    /// The offset of the entry called `name`, if there is one.
    private static func find(_ name: String, in bytes: [UInt8]) -> Int? {
        var offset = link(bytes, 0)
        var steps = 0
        while offset != 0, steps < directoryEntries {
            if same(text(bytes[offset + 2..<offset + 12]), name) { return offset }
            offset = link(bytes, offset)
            steps += 1
        }
        return nil
    }

    private static func freeSlot(in bytes: [UInt8]) -> Int? {
        let free = link(bytes, 13)
        return free == 0 ? nil : free
    }

    /// Takes a free entry and links it into the alphabetical chain.
    private static func addEntry(to bytes: inout [UInt8], name: String, load: UInt32, exec: UInt32, access: Access,
                                 date: UInt16, sector: Int) throws {
        guard isValidName(name, length: maxNameLength) else { throw DiscEditError.badName(name) }
        guard let slot = freeSlot(in: bytes) else { throw DiscEditError.catalogueFull }
        put(&bytes, at: 13, UInt32(link(bytes, slot)), bytes: 2)
        // After the last entry that comes before it.
        var previous = 0
        var next = link(bytes, 0)
        while next != 0, precedes(text(bytes[next + 2..<next + 12]), name) {
            previous = next
            next = link(bytes, next)
        }
        put(&bytes, at: slot, UInt32(next), bytes: 2)
        put(&bytes, at: previous, UInt32(slot), bytes: 2)
        let title = Array(name.utf8)
        bytes.replaceSubrange(slot + 2..<slot + 12, with: title + [UInt8](repeating: 0x20, count: maxNameLength - title.count))
        put(&bytes, at: slot + 12, load, bytes: 4)
        put(&bytes, at: slot + 16, exec, bytes: 4)
        bytes[slot + 20] = access.rawValue
        put(&bytes, at: slot + 21, UInt32(date), bytes: 2)
        put(&bytes, at: slot + 23, UInt32(sector), bytes: 3)
        bytes[15] = bytes[15] &+ 1
    }

    /// Unlinks an entry and puts it at the head of the free chain.
    private static func removeEntry(at offset: Int, from bytes: inout [UInt8]) {
        var previous = 0
        var next = link(bytes, 0)
        while next != 0, next != offset {
            previous = next
            next = link(bytes, next)
        }
        put(&bytes, at: previous, UInt32(link(bytes, offset)), bytes: 2)
        put(&bytes, at: offset, UInt32(link(bytes, 13)), bytes: 2)
        put(&bytes, at: 13, UInt32(offset), bytes: 2)
        bytes[15] = bytes[15] &- 1
    }

    /// A new cycle number, at both ends, as the server marks a change.
    private static func changed(_ bytes: inout [UInt8]) {
        bytes[2] = bytes[2] &+ 1
        bytes[bytes.count - 1] = bytes[2]
    }

    /// The first sector of the directory at `path` ("$", "$.BOOT").
    private func directorySector(_ path: String) throws -> Int {
        var parts = path.split(separator: ".").map(String.init)
        if parts.first == "$" { parts.removeFirst() }
        var sector = Int(sectors[22]) | Int(sectors[23]) << 8 | Int(sectors[24]) << 16
        for part in parts {
            let bytes = readDirectory(at: sector)
            guard let offset = Self.find(part, in: bytes) else { throw DiscEditError.notFound(path) }
            let found = entry(in: bytes, at: offset)
            guard found.isDirectory else { throw DiscEditError.notFound(path) }
            sector = found.sector
        }
        return sector
    }

    /// A path's directory and leaf name.
    private func split(_ path: String) throws -> (String, String) {
        var parts = path.split(separator: ".").map(String.init)
        if parts.first == "$" { parts.removeFirst() }
        guard let leaf = parts.popLast(), !leaf.isEmpty else { throw DiscEditError.badName(path) }
        return ((["$"] + parts).joined(separator: "."), leaf)
    }

    // MARK: Passwords

    private func passwordFile() throws -> [UInt8] {
        try contents(of: "$.PASSWORDS")
    }

    /// Rewrites $.PASSWORDS in place, keeping its entry (and growing its
    /// chain if it must).
    private mutating func writePasswordFile(_ bytes: [UInt8]) throws {
        let file = try entry(at: "$.PASSWORDS")
        var sectors = chain(from: file.sector)
        let needed = Self.sectorsFor(bytes.count)
        guard map.free >= needed - sectors.count else { throw DiscEditError.discFull }
        while sectors.count < needed { sectors.append(map.allocate()) }
        for (index, sector) in sectors.enumerated() {
            let start = index * Self.sectorSize
            let chunk = Array(bytes[start..<min(bytes.count, start + Self.sectorSize)])
            write(sector: sector, chunk + [UInt8](repeating: 0, count: Self.sectorSize - chunk.count))
            var value = index == sectors.count - 1 ? Map.e | UInt16(bytes.count % Self.sectorSize) : UInt16(sectors[index + 1])
            if index == 0 { value |= Map.s }
            map.entries[sector] = value | Map.w
        }
        writeMapCopies()
    }

    private mutating func changeUser(_ name: String, _ change: (inout User) -> Void) throws {
        var file = try passwordFile()
        guard let offset = stride(from: 0, to: file.count - 16, by: 17).first(where: { offset in
            file[offset + 16] & 0x80 != 0 && Self.same(Self.text(file[offset..<offset + 10]), name)
        }) else { throw DiscEditError.notFound(name) }
        let flags = file[offset + 16]
        var user = User(Self.text(file[offset..<offset + 10]), password: Self.text(file[offset + 10..<offset + 16]),
                        bootOption: BootOption(rawValue: Int(flags & 3)) ?? .off, isSystem: flags & 0x40 != 0)
        change(&user)
        var entry = Self.passwordEntry(user)
        // Flags this doesn't know about stay.
        entry[16] |= flags & ~0xC3
        file.replaceSubrange(offset..<offset + 17, with: entry)
        try writePasswordFile(file)
    }

    /// A user's 17 bytes: name and password, each ended by a CR if short,
    /// and flags.
    private static func passwordEntry(_ user: User) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 17)
        let name = Array(user.name.utf8.prefix(maxNameLength))
        bytes.replaceSubrange(0..<name.count, with: name)
        if name.count < maxNameLength { bytes[name.count] = 0x0D }
        let password = Array(user.password.utf8.prefix(maxPasswordLength))
        bytes.replaceSubrange(10..<10 + password.count, with: password)
        if password.count < maxPasswordLength { bytes[10 + password.count] = 0x0D }
        bytes[16] = 0x80 | (user.isSystem ? 0x40 : 0) | UInt8(user.bootOption.rawValue)
        return bytes
    }

    // MARK: Names

    /// Up to `length` printable characters, none of those paths and
    /// wildcards use.
    static func isValidName(_ name: String, length: Int) -> Bool {
        name.utf8.count <= length && name.unicodeScalars.allSatisfy { scalar in
            scalar.value > 32 && scalar.value < 127 && !"\".:*#$&@^".unicodeScalars.contains(scalar)
        }
    }

    /// DSCMGR's order: character by character with bit 5 dropped (so case
    /// doesn't matter), and a name before those it starts.
    static func precedes(_ a: String, _ b: String) -> Bool {
        a.utf8.map { $0 & 0xDF }.lexicographicallyPrecedes(b.utf8.map { $0 & 0xDF })
    }

    static func same(_ a: String, _ b: String) -> Bool {
        a.utf8.map { $0 & 0xDF } == b.utf8.map { $0 & 0xDF }
    }

    /// Text up to a CR (or the field's end), trailing spaces dropped.
    private static func text(_ bytes: ArraySlice<UInt8>) -> String {
        String(decoding: bytes.prefix { $0 != 0x0D && $0 != 0 }, as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }

    private static func get(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        (0..<4).reduce(0) { $0 | UInt32(bytes[offset + $1]) << (8 * $1) }
    }

    private static func put(_ bytes: inout [UInt8], at offset: Int, _ value: UInt32, bytes count: Int) {
        for index in 0..<count {
            bytes[offset + index] = UInt8(value >> (8 * index) & 0xFF)
        }
    }
}
