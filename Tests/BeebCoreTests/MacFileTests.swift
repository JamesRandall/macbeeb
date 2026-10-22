// Mac files and folders going onto discs: .inf files, BASIC text, text
// files and folders.

import Foundation
import Testing
@testable import BeebCore
import BeebROMs

struct MacFileTests {
    let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("MacFileTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    func write(_ name: String, _ bytes: [UInt8]) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    @Test func infFilesNameAndAddress() throws {
        let file = try write("anything", [1, 2, 3])
        _ = try write("anything.inf", Array("W.LOADER FF1900 FF8023 3 L\n".utf8))
        let read = try #require(try MacFile.read(file, adfs: false))
        #expect(read.name == "W.LOADER" && read.loadAddress == 0xFFFF_1900 && read.locked)
        // NAME.ext with NAME.inf; ADFS takes the leaf.
        let game = try write("Game.bin", [9])
        _ = try write("Game.inf", Array("$.Game 3000 3000\n".utf8))
        #expect(try MacFile.read(game, adfs: true)?.name == "Game")
        #expect(try MacFile.read(folder.appendingPathComponent("Game.inf"), adfs: true) == nil)
    }

    @Test func namesFromMacNames() {
        #expect(MacFile.bbcName("ELITE", adfs: false) == "ELITE")
        #expect(MacFile.bbcName("W.DATA", adfs: false) == "W.DATA")
        #expect(MacFile.bbcName("loader.bin", adfs: false) == "loader")
        #expect(MacFile.bbcName("A long name.txt", adfs: true) == "A_long_nam")
        #expect(MacFile.bbcName("MY:PROG", adfs: false) == "MY/PROG")
    }

    /// A .bas file of text becomes a program a Model B CHAINs; a .txt
    /// file's lines end in CRs, so *TYPE shows them a line each.
    @Test func basicAndTextFiles() throws {
        let bas = try write("LOOP.bas", Array("10 FOR I=1 TO 3\n20 PRINT \"LINE \";I\n30 NEXT\n".utf8))
        let txt = try write("README.txt", Array("FIRST\r\nSECOND\nTHIRD".utf8))
        var volume = DiscVolume.dfs([try DFSDisc(side: BlankDisc.dfs80.image())])
        for url in [bas, txt] {
            try #require(try MacFile.read(url, adfs: false)).add(to: &volume, at: .init())
        }
        let items = try volume.items(at: .init())
        #expect(items.first { $0.name == "README" }.map { volume.contents(of: $0, at: .init()) }
                == Array("FIRST\rSECOND\rTHIRD".utf8))

        let machine = try bootModelBWithDFS()
        machine.insertDisc(try Disc.fromImage(volume.image, format: .ssd))
        let screen = command(machine, "CHAIN \"LOOP\"")
        #expect(screen.contains("LINE 3"), "\(screen)")
        let typed = command(machine, "*TYPE README")
        #expect(typed.contains("SECOND") && typed.contains("THIRD"), "\(typed)")
    }

    @Test func foldersBecomeADFSDirectories() throws {
        let sub = folder.appendingPathComponent("Games")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: sub.appendingPathComponent("Elite"))
        var volume = DiscVolume.adfs(try ADFSDisc(image: BlankDisc.adfsM.image()))
        try #require(try MacFile.read(sub, adfs: true)).add(to: &volume, at: .init())
        let games = try #require(try volume.items(at: .init()).first)
        #expect(games.name == "Games" && games.isDirectory)
        let inner = DiscVolume.Location(directory: games.startSector)
        #expect(try volume.items(at: inner).map(\.name) == ["Elite"])
        // And DFS won't take folders.
        #expect(try MacFile.read(sub, adfs: false) == nil)
    }
}
