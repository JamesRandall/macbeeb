// Changing discs' files from outside the BBC: DFS and ADFS take the result
// as their own.

import Foundation
import Testing
@testable import BeebCore
import BeebROMs

extension BBCMicro {
    /// Runs until the disc in drive 0 can be changed from outside.
    func waitForIdleDisc() {
        for _ in 0..<200 where !discIsIdle(drive: 0) {
            run(seconds: 0.1)
        }
        #expect(discIsIdle(drive: 0))
    }
}

struct DiscEditingTests {
    func bytes(_ count: Int, _ seed: Int) -> [UInt8] {
        (0..<count).map { UInt8(truncatingIfNeeded: $0 * 13 + seed) }
    }

    // MARK: DFS

    @Test func dfsSavesDeletesAndRenames() throws {
        var side = try DFSDisc(side: BlankDisc.dfs80.image(title: "EDITS"))
        try side.save(name: "ONE", loadAddress: 0x1900, executionAddress: 0x8023, contents: bytes(600, 1))
        try side.save(directory: "W", name: "TWO", loadAddress: 0xFFFF_3000, executionAddress: 0xFFFF_3000,
                      contents: bytes(300, 2), locked: true)
        try side.save(name: "THREE", loadAddress: 0x2_0000, executionAddress: 0, contents: bytes(10, 3))
        side = try DFSDisc(side: side.image)
        #expect(side.files.count == 3)
        let two = try #require(side.file(named: "W.TWO"))
        #expect(two.loadAddress == 0xFFFF_3000 && two.locked && side.contents(of: two) == bytes(300, 2))
        #expect(side.file(named: "THREE")?.loadAddress == 0x2_0000)
        #expect(side.freeSectors == 800 - 2 - 3 - 2 - 1)

        #expect(throws: DiscEditError.locked("W.TWO")) { try side.delete(two) }
        try side.update(two, loadAddress: 0x3000, executionAddress: 0x3000, locked: false)
        try side.rename(side.file(named: "W.TWO")!, directory: "$", name: "DUO")
        try side.delete(side.file(named: "ONE")!)
        #expect(throws: DiscEditError.fileExists("$.duo")) {
            try side.rename(side.file(named: "THREE")!, directory: "$", name: "duo")
        }
        side = try DFSDisc(side: side.image)
        #expect(side.files.map(\.fullName).sorted() == ["$.DUO", "$.THREE"])
        #expect(side.contents(of: side.file(named: "DUO")!) == bytes(300, 2))
        #expect(side.title == "EDITS")
    }

    @Test func dfsFillsGapsThenCompacts() throws {
        var side = try DFSDisc(side: BlankDisc.dfs40.image())
        // 398 sectors free: fill them in 2-sector files, then free every
        // other one, leaving only 2-sector gaps.
        for n in 0..<31 {
            try side.save(name: "F\(n)", loadAddress: 0, executionAddress: 0, contents: bytes(512, n))
        }
        #expect(throws: DiscEditError.catalogueFull) {
            try side.save(name: "MORE", loadAddress: 0, executionAddress: 0, contents: [])
        }
        for n in stride(from: 0, to: 31, by: 2) {
            try side.delete(side.file(named: "F\(n)")!)
        }
        // A 1-sector file goes in the first gap.
        try side.save(name: "SMALL", loadAddress: 0, executionAddress: 0, contents: bytes(10, 99))
        #expect(side.file(named: "SMALL")?.startSector == 2)
        // One bigger than any gap but smaller than all the free space:
        // compacted to make room, and nothing else is disturbed.
        let free = side.freeSectors
        try side.save(name: "BIG", loadAddress: 0, executionAddress: 0, contents: bytes((free - 1) * 256, 7))
        side = try DFSDisc(side: side.image)
        for n in stride(from: 1, to: 31, by: 2) {
            #expect(side.contents(of: side.file(named: "F\(n)")!) == bytes(512, n))
        }
        #expect(side.contents(of: side.file(named: "BIG")!) == bytes((free - 1) * 256, 7))
        #expect(throws: DiscEditError.discFull) {
            try side.save(name: "HUGE", loadAddress: 0, executionAddress: 0, contents: bytes(512, 0))
        }
    }

    @Test func dfsDoubleSidedImages() throws {
        var sides = try DFSDisc.sides(ofImage: BlankDisc.dfsDoubleSided80.image(title: "BOTH"), doubleSided: true)
        try sides[1].save(name: "BACK", loadAddress: 0, executionAddress: 0, contents: bytes(5000, 4))
        let image = DFSDisc.image(sides: sides)
        let read = try DFSDisc.sides(ofImage: image, doubleSided: true)
        #expect(read[0].files.isEmpty)
        #expect(read[1].contents(of: read[1].file(named: "BACK")!) == bytes(5000, 4))
    }

    /// A file saved from outside, *LOADed and *TYPEd by the BBC; then the
    /// BBC saves alongside it.
    @Test func dfsTheBBCReadsItsFiles() throws {
        var side = try DFSDisc(side: BlankDisc.dfs80.image(title: "OUTSIDE"))
        try side.save(name: "TEXT", loadAddress: 0, executionAddress: 0, contents: Array("HELLO FROM OUTSIDE\r".utf8))
        try side.save(name: "DATA", loadAddress: 0x3000, executionAddress: 0x3000, contents: [42, 43, 44], locked: true)
        let machine = try bootModelBWithDFS()
        machine.insertDisc(try Disc.fromImage(side.image, format: .ssd))
        #expect(command(machine, "*TYPE TEXT").contains { $0.contains("HELLO FROM OUTSIDE") })
        let loaded = command(machine, "*LOAD DATA\nPRINT ?&3000+?&3002")
        #expect(loaded.contains { $0.contains("86") }, "\(loaded)")
        let deleting = command(machine, "*DELETE DATA")
        #expect(deleting.contains { $0.contains("locked") || $0.contains("Locked") }, "\(deleting)")
        command(machine, "10REM\nSAVE \"PROG\"", maxSeconds: 30)
        let after = try DFSDisc(side: machine.drives[0].disc!.toImage(.ssd))
        #expect(after.files.map(\.name).sorted() == ["DATA", "PROG", "TEXT"])
    }

    // MARK: ADFS

    @Test func adfsSavesDeletesRenamesAndNests() throws {
        var disc = try ADFSDisc(image: BlankDisc.adfsM.image(title: "Edits"))
        let free = disc.freeSectors
        #expect(free == 1280 - 7)
        try disc.save(in: ADFSDisc.rootSector, name: "Zebra", loadAddress: 0xFFFF_1900, executionAddress: 0xFFFF_8023,
                      contents: bytes(1000, 1))
        try disc.createDirectory(in: ADFSDisc.rootSector, name: "Games")
        let games = try #require(disc.directory(at: ADFSDisc.rootSector).entries.first { $0.name == "Games" })
        try disc.save(in: games.startSector, name: "Elite", loadAddress: 0, executionAddress: 0, contents: bytes(20000, 2))
        disc = try ADFSDisc(image: disc.image)

        let root = try disc.directory(at: ADFSDisc.rootSector)
        #expect(root.entries.map(\.name) == ["Games", "Zebra"])
        #expect(root.title == "Edits")
        let sub = try disc.directory(at: games.startSector)
        #expect(sub.name == "Games" && sub.parent == ADFSDisc.rootSector)
        #expect(disc.contents(of: sub.entries[0]) == bytes(20000, 2))
        #expect(disc.freeSectors == free - 4 - 5 - 79)

        #expect(throws: DiscEditError.locked("Games")) { try disc.delete(games, in: ADFSDisc.rootSector) }
        try disc.update(games, in: ADFSDisc.rootSector, loadAddress: 0, executionAddress: 0, locked: false)
        let unlocked = try disc.directory(at: ADFSDisc.rootSector).entries[0]
        #expect(throws: DiscEditError.directoryNotEmpty("Games")) { try disc.delete(unlocked, in: ADFSDisc.rootSector) }
        try disc.delete(sub.entries[0], in: games.startSector)
        try disc.delete(unlocked, in: ADFSDisc.rootSector)
        try disc.rename(root.entries[1], in: ADFSDisc.rootSector, to: "Aardvark")
        disc = try ADFSDisc(image: disc.image)
        #expect(try disc.directory(at: ADFSDisc.rootSector).entries.map(\.name) == ["Aardvark"])
        // Freed space joins up again.
        #expect(disc.free.count == 1 && disc.freeSectors == free - 4)
    }

    /// The BBC has the disc mounted while it's changed from outside (with
    /// the drive stopped, as the app insists): as with a real disc swapped,
    /// ADFS finds a new disc ID and says "Disc changed" rather than trust
    /// what it remembers; after *MOUNT it sees the changes, and its own
    /// saves leave the map whole.
    @Test(arguments: [BBCMicro.Model.master128, .masterCompact])
    func adfsTheBBCSeesChangesAfterMount(_ model: BBCMicro.Model) throws {
        let kind: BlankDisc = model == .masterCompact ? .adfsL : .adfsM
        let machine = BBCMicro(configuration: BeebROMs.configuration(for: model))
        machine.insertDisc(try Disc.fromImage(kind.image(title: "Live"), format: kind.format))
        #expect(machine.runUntilIdle())
        command(machine, model == .masterCompact ? "*MOUNT" : "*ADFS")
        command(machine, "10REM FIRST\nSAVE \"First\"", maxSeconds: 30)
        #expect(!machine.discIsIdle(drive: 0))
        machine.waitForIdleDisc()

        var disc = try ADFSDisc(image: machine.drives[0].disc!.toImage(kind.format))
        try disc.createDirectory(in: ADFSDisc.rootSector, name: "Outside")
        try disc.save(in: ADFSDisc.rootSector, name: "Note", loadAddress: 0, executionAddress: 0,
                      contents: Array("WRITTEN ON A MAC\r".utf8))
        disc.changeDiscID()
        machine.insertDisc(try Disc.fromImage(disc.image, format: kind.format))

        let saving = command(machine, "SAVE \"Stale\"", maxSeconds: 30)
        #expect(saving.contains { $0.contains("Disc changed") }, "\(saving)")
        command(machine, "*MOUNT")
        let catalogue = command(machine, "*CAT")
        #expect(catalogue.contains { $0.contains("Outside") } && catalogue.contains { $0.contains("Note") },
                "\(catalogue)")
        #expect(command(machine, "*TYPE Note").contains { $0.contains("WRITTEN ON A MAC") })
        command(machine, "10REM SECOND\nSAVE \"Outside.Second\"", maxSeconds: 30)

        let after = try ADFSDisc(image: machine.drives[0].disc!.toImage(kind.format))
        let root = try after.directory(at: ADFSDisc.rootSector)
        try #require(root.entries.map(\.name) == ["First", "Note", "Outside"], "\(root.entries)")
        let outside = try after.directory(at: root.entries[2].startSector)
        #expect(outside.entries.map(\.name) == ["Second"])
        // Nothing's both used and free.
        var used = Set(0..<7)
        func claim(_ dir: ADFSDisc.Directory) throws {
            for entry in dir.entries {
                let sectors = Set(entry.startSector..<entry.startSector + (entry.length + 255) / 256)
                #expect(used.isDisjoint(with: sectors), "\(entry.name)")
                used.formUnion(sectors)
                if entry.isDirectory {
                    try claim(after.directory(at: entry.startSector))
                }
            }
        }
        try claim(root)
        #expect(used.count + after.freeSectors == after.totalSectors)
        let free = command(machine, "*FREE")
        #expect(!free.contains { $0.contains("Bad") || $0.contains("Broken") }, "\(free)")
    }

    /// DFS reads the catalogue afresh: a change made while the drive's
    /// stopped shows at once, and the BBC's next save keeps it.
    @Test(arguments: [BBCMicro.Model.modelB, .master128])
    func dfsTheBBCSeesChanges(_ model: BBCMicro.Model) throws {
        let machine = BBCMicro(configuration: BeebROMs.configuration(for: model))
        machine.insertDisc(try Disc.fromImage(BlankDisc.dfs80.image(title: "Live"), format: .ssd))
        #expect(machine.runUntilIdle())
        command(machine, "10REM FIRST\nSAVE \"FIRST\"", maxSeconds: 30)
        #expect(!machine.discIsIdle(drive: 0))
        machine.waitForIdleDisc()

        var side = try DFSDisc(side: machine.drives[0].disc!.toImage(.ssd))
        try side.delete(side.file(named: "FIRST")!)
        try side.save(name: "NOTE", loadAddress: 0, executionAddress: 0, contents: Array("FROM A MAC\r".utf8))
        machine.insertDisc(try Disc.fromImage(side.image, format: .ssd))

        #expect(command(machine, "*TYPE NOTE").contains { $0.contains("FROM A MAC") })
        command(machine, "10REM SECOND\nSAVE \"SECOND\"", maxSeconds: 30)
        let after = try DFSDisc(side: machine.drives[0].disc!.toImage(.ssd))
        #expect(after.files.map(\.name).sorted() == ["NOTE", "SECOND"])
        #expect(after.contents(of: after.file(named: "NOTE")!) == Array("FROM A MAC\r".utf8))
    }
}

struct InfFileTests {
    @Test func readsTheUsualForms() throws {
        let a = try #require(InfFile(text: "$.ELITE   FF1900 FF8023 001234 L CRC=ABCD\n"))
        #expect(a == InfFile(name: "$.ELITE", loadAddress: 0xFFFF_1900, executionAddress: 0xFFFF_8023,
                             length: 0x1234, locked: true))
        let b = try #require(InfFile(text: "Loader 00003000 00003000 Locked"))
        #expect(b.loadAddress == 0x3000 && b.length == nil && b.locked)
        let c = try #require(InfFile(text: "W.DATA 30000 0"))
        #expect(c.loadAddress == 0x3_0000 && c.executionAddress == 0 && !c.locked)
        #expect(InfFile(text: "  \n") == nil)
    }

    @Test func writesWhatItReads() {
        let inf = InfFile(name: "$.PROG", loadAddress: 0xFFFF_1900, executionAddress: 0xFFFF_8023, length: 300, locked: true)
        #expect(inf.text == "$.PROG    FFFF1900 FFFF8023 0000012C L\n")
        #expect(InfFile(text: inf.text) == inf)
    }
}
