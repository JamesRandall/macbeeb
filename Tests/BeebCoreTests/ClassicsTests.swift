// The BBC Micro Classics bookshelf: its catalogue, the library of imported
// games, recognising downloads, disc identities and quick saves. Discs are
// synthetic: no game images are used.

import Foundation
import Testing
@testable import BeebCore
@testable import BeebLibrary
import BeebHost
import BeebROMs
import Synchronization

/// A scratch folder, removed afterwards.
final class ScratchFolder {
    let url: URL

    init() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("macbeeb-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    func file(_ name: String, _ data: Data) throws -> URL {
        let file = url.appendingPathComponent(name)
        try data.write(to: file)
        return file
    }
}

/// A formatted DFS disc with `title`: a different disc for each title.
func syntheticDisc(_ title: String) -> Data {
    Data(BlankDisc.dfs40.image(title: title))
}

/// A catalogue of two games whose known discs are synthetic.
func syntheticCatalogue() -> Catalogue {
    let archive = Catalogue.classics.archive
    func game(_ id: String, _ rank: Int, _ disc: String, coprocessor: BBCMicro.Coprocessor? = nil) -> CuratedGame {
        CuratedGame(id: id, rank: rank, title: id.capitalized, editionLabel: nil, archiveGameID: rank,
                    archivePageURL: URL(string: "https://bbcmicro.co.uk/game.php?id=\(rank)")!,
                    publisher: nil, year: nil, authors: nil, description: "",
                    machine: MachineRequirement(model: .modelB, coprocessor: coprocessor, summary: ""),
                    knownDisks: [KnownDiskIdentity(sha256: GameLibrary.sha256(syntheticDisc(disc)), expectedFileName: nil,
                                                   byteCount: nil, variantNotes: nil)])
    }
    return Catalogue(archive: archive, games: [game("alpha", 1, "ALPHA", coprocessor: .mos6502), game("beta", 2, "BETA")])
}

struct ClassicsCatalogueTests {
    let catalogue = Catalogue.classics

    @Test func hasTheTwentyInRankOrder() {
        #expect(catalogue.games.count == 20)
        #expect(catalogue.games.map(\.rank) == Array(1...20))
        #expect(Set(catalogue.games.map(\.id)).count == 20)
        #expect(catalogue.games.map(\.id) == [
            "elite-copro", "chuckie-egg", "repton-3", "exile-64k", "starship-command", "thrust", "citadel", "repton-2",
            "revs", "repton", "imogen", "codename-droid", "firetrack", "arcadians", "mr-ee", "zalaga", "castle-quest",
            "galaforce", "skirmish", "snapper",
        ])
        #expect(catalogue.games.map(\.archiveGameID) == [3471, 25, 425, 709, 35, 432, 290, 298, 267, 266, 512, 564, 598,
                                                         20, 85, 54, 238, 438, 822, 14])
    }

    @Test func hasTheAuthorsPicksInOrder() {
        #expect(catalogue.picks.map(\.archiveGameID) == [3471, 709, 1249, 432, 267, 934, 11, 25, 412, 1385, 757, 1183,
                                                         564, 3286, 812, 3571, 598, 2972, 341, 208])
        #expect(catalogue.picksShelf.count == 21)
        // Seven are also in the top 20: the same games, not copies.
        #expect(catalogue.picks.filter { $0.rank != nil }.map(\.id).sorted() == [
            "chuckie-egg", "codename-droid", "elite-copro", "exile-64k", "firetrack", "revs", "thrust",
        ])
        #expect(catalogue.moreGames.allSatisfy { $0.rank == nil })
        #expect(Set(catalogue.allGames.map(\.id)).count == 33)
    }

    @Test func picksForAMasterGetOne() throws {
        for id in ["holed-out", "uim", "strykers-run-128k"] {
            let game = try #require(catalogue.game(id: id))
            #expect(game.machine.model == .master128 && game.machine.needsSidewaysRAM, "\(id)")
            #expect(ClassicsTestsSupport.hardwareProblem(game) == nil, "\(id)")
        }
        for id in ["doctor-who-mines-of-terror", "repton-infinity"] {
            #expect(try #require(catalogue.game(id: id)).machine.model == .master128, "\(id)")
        }
        #expect(catalogue.game(id: "knight-lore")?.machine.model == .modelB)
    }

    @Test func linksToEachGamesPage() {
        for game in catalogue.allGames {
            #expect(game.archivePageURL.absoluteString == "https://bbcmicro.co.uk/game.php?id=\(game.archiveGameID)")
        }
    }

    @Test func eliteIsTheCoProcessorEdition() throws {
        let elite = try #require(catalogue.game(id: "elite-copro"))
        #expect(elite.archiveGameID == 3471)
        #expect(elite.machine.coprocessor == .mos6502)
        #expect(elite.machine.model.hasTube)
        #expect(ClassicsTestsSupport.hardwareProblem(elite) == nil)
    }

    @Test func exileHasSidewaysRAMOnAMaster() throws {
        let exile = try #require(catalogue.game(id: "exile-64k"))
        #expect(exile.archiveGameID == 709)
        #expect(exile.machine.model == .master128)
        #expect(exile.machine.needsSidewaysRAM)
        #expect(ClassicsTestsSupport.hardwareProblem(exile) == nil)
        // A plain Model B has no sideways RAM, so it would be refused.
        #expect(exile.machine.unavailableReason(sidewaysRAMBanks: []) != nil)
    }

    @Test func zalagaIsNotOnAMaster() throws {
        #expect(try #require(catalogue.game(id: "zalaga")).machine.model == .modelB)
    }

    @Test func fingerprintsAreDistinctDigests() {
        let digests = catalogue.allGames.flatMap(\.knownDisks).map(\.sha256)
        #expect(digests.count == 33)
        #expect(Set(digests).count == digests.count)
        for digest in digests {
            #expect(digest.count == 64 && digest.allSatisfy(\.isHexDigit), "\(digest)")
        }
        for game in catalogue.allGames {
            #expect(catalogue.game(forDigest: game.knownDisks[0].sha256.uppercased())?.id == game.id)
        }
    }

    @Test func archiveBookIsOnTheShelfButNotAGame() {
        let shelf = catalogue.shelf
        #expect(shelf.count == 21)
        guard case .archive(let book) = shelf.last else {
            Issue.record("The archive book should come after the games")
            return
        }
        #expect(book.url.absoluteString == "https://bbcmicro.co.uk/")
        #expect(book.aboutURL.absoluteString == "https://bbcmicro.co.uk/about.php")
        #expect(catalogue.game(id: book.id) == nil)
    }

    @Test func everyGameHasACover() {
        for game in catalogue.games {
            #expect(BeebLibrary.coverURL(for: game) != nil, "\(game.id)")
        }
    }
}

enum ClassicsTestsSupport {
    static func hardwareProblem(_ game: CuratedGame) -> String? {
        game.machine.unavailableReason(sidewaysRAMBanks: BeebROMs.configuration(for: game.machine.model).sidewaysRAMBanks)
    }
}

struct GameLibraryTests {
    let scratch = ScratchFolder()
    var root: URL { scratch.url.appendingPathComponent("Library") }

    func library() -> GameLibrary {
        GameLibrary(root: root, catalogue: syntheticCatalogue())
    }

    @Test func recognisesADiscByItsContentsNotItsName() async throws {
        let original = try scratch.file("renamed download.ssd", syntheticDisc("BETA"))
        let lib = library()
        let result = try await lib.importDisk(at: original, source: .downloadsFolder)
        guard case .installed(let record, let already) = result else {
            Issue.record("Expected it installed, got \(result)")
            return
        }
        #expect(!already)
        #expect(record.gameID == "beta")
        #expect(record.verified)
        // The library's copy, not the original.
        let copy = await lib.pristineURL(record)
        #expect(copy.path.hasPrefix(root.path))
        #expect(try Data(contentsOf: copy) == syntheticDisc("BETA"))
        #expect(FileManager.default.fileExists(atPath: original.path))
    }

    @Test func importingTheSameDiscAgainChangesNothing() async throws {
        let lib = library()
        let first = try await lib.importDisk(at: scratch.file("a.ssd", syntheticDisc("ALPHA")), source: .filePicker)
        let second = try await lib.importDisk(at: scratch.file("b.ssd", syntheticDisc("ALPHA")), source: .dragAndDrop)
        guard case .installed(let one, false) = first, case .installed(let two, true) = second else {
            Issue.record("\(first) \(second)")
            return
        }
        #expect(one == two)
        #expect(await lib.installed.count == 1)
    }

    @Test func unknownDiscsAreNotGuessed() async throws {
        let lib = library()
        // Named like a game, but not its disc.
        let result = try await lib.importDisk(at: scratch.file("Beta.ssd", syntheticDisc("OTHER")), source: .downloadsFolder)
        guard case .unrecognised(let candidate) = result else {
            Issue.record("Expected unrecognised, got \(result)")
            return
        }
        #expect(candidate.fileName == "Beta.ssd")
        #expect(await lib.installed.isEmpty)
    }

    @Test func theUserCanSayWhatAnUnknownDiscIs() async throws {
        let lib = library()
        let result = try await lib.importDisk(at: scratch.file("mine.ssd", syntheticDisc("OTHER")), as: "beta",
                                              source: .filePicker)
        guard case .installed(let record, _) = result else {
            Issue.record("\(result)")
            return
        }
        #expect(record.gameID == "beta")
        #expect(!record.verified)
    }

    @Test func aKnownDiscCantBeAnotherGame() async throws {
        let lib = library()
        await #expect(throws: ImportError.belongsToAnotherGame(fileName: "a.ssd", game: "Beta")) {
            try await lib.importDisk(at: scratch.file("a.ssd", syntheticDisc("BETA")), as: "alpha", source: .filePicker)
        }
        #expect(await lib.installed.isEmpty)
    }

    @Test func refusesWhatIsntADiscImage() async throws {
        let lib = library()
        await #expect(throws: ImportError.notADiscImage("junk.ssd")) {
            try await lib.importDisk(at: scratch.file("junk.ssd", Data([1, 2, 3])), source: .filePicker)
        }
        await #expect(throws: ImportError.unsupportedType("notes.txt")) {
            try await lib.importDisk(at: scratch.file("notes.txt", syntheticDisc("ALPHA")), source: .filePicker)
        }
        await #expect(throws: ImportError.tooLarge("huge.ssd")) {
            try await lib.importDisk(at: scratch.file("huge.ssd", Data(count: Int(GameLibrary.maxImageSize) + 1)),
                                     source: .filePicker)
        }
        let missing = scratch.url.appendingPathComponent("gone.ssd")
        await #expect(throws: ImportError.self) {
            try await lib.importDisk(at: missing, source: .filePicker)
        }
    }

    @Test func survivesRelaunchAndLosingTheOriginal() async throws {
        let original = try scratch.file("a.ssd", syntheticDisc("ALPHA"))
        _ = try await library().importDisk(at: original, source: .filePicker)
        try FileManager.default.removeItem(at: original)
        let relaunched = library()
        try await relaunched.reconcile()
        #expect(await relaunched.installed(gameID: "alpha") != nil)
    }

    @Test func forgetsGamesWhoseCopiesHaveGone() async throws {
        let lib = library()
        guard case .installed(let record, _) = try await lib.importDisk(at: scratch.file("a.ssd", syntheticDisc("ALPHA")),
                                                                         source: .filePicker) else { return }
        try FileManager.default.removeItem(at: await lib.pristineURL(record))
        let dropped = try await lib.reconcile()
        #expect(dropped.map(\.gameID) == ["alpha"])
        #expect(await lib.installed.isEmpty)
    }

    @Test func removingDeletesOnlyTheLibrarysCopy() async throws {
        let original = try scratch.file("a.ssd", syntheticDisc("ALPHA"))
        let lib = library()
        guard case .installed(let record, _) = try await lib.importDisk(at: original, source: .filePicker) else { return }
        let working = try await lib.prepareWorkingCopy(record)
        try await lib.remove(gameID: "alpha")
        #expect(await lib.installed.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: await lib.pristineURL(record).path))
        #expect(!FileManager.default.fileExists(atPath: working.path))
        #expect(try Data(contentsOf: original) == syntheticDisc("ALPHA"))
        // Watching Downloads won't bring it back by itself.
        #expect(await lib.wasRemoved(digest: record.diskSHA256))
        // Importing it on purpose does.
        _ = try await lib.importDisk(at: original, source: .filePicker)
        #expect(await !lib.wasRemoved(digest: record.diskSHA256))
    }

    @Test func pendingDownloadsPersistAndExpire() async throws {
        let now = Date()
        let lib = library()
        try await lib.addPending(gameID: "alpha", at: now)
        try await lib.addPending(gameID: "beta", at: now.addingTimeInterval(-PendingDownload.lifetime - 1))
        // Asking again doesn't make two.
        try await lib.addPending(gameID: "alpha", at: now)
        let relaunched = library()
        #expect(await relaunched.pending(now: now).map(\.gameID) == ["alpha"])
        try await relaunched.cancelPending(gameID: "alpha")
        #expect(await relaunched.pending(now: now).isEmpty)
    }

    @Test func installingClearsItsPendingDownloadOnly() async throws {
        let lib = library()
        try await lib.addPending(gameID: "alpha")
        try await lib.addPending(gameID: "beta")
        // Two downloads, matched by contents, whatever order they arrive in.
        _ = try await lib.importDisk(at: scratch.file("x.ssd", syntheticDisc("BETA")), source: .downloadsFolder)
        #expect(await lib.pending().map(\.gameID) == ["alpha"])
        _ = try await lib.importDisk(at: scratch.file("y.ssd", syntheticDisc("ALPHA")), source: .downloadsFolder)
        #expect(await lib.pending().isEmpty)
        #expect(Set(await lib.installed.map(\.gameID)) == ["alpha", "beta"])
    }

    @Test func theWorkingCopyCanBeReverted() async throws {
        let lib = library()
        guard case .installed(let record, _) = try await lib.importDisk(at: scratch.file("a.ssd", syntheticDisc("ALPHA")),
                                                                         source: .filePicker) else { return }
        let working = try await lib.prepareWorkingCopy(record)
        #expect(await !lib.workingCopyIsModified(record))
        try syntheticDisc("CHANGED").write(to: working)
        #expect(await lib.workingCopyIsModified(record))
        #expect(await lib.installedGame(workingURL: working) == record)
        try await lib.revertWorkingCopy(record)
        #expect(await !lib.workingCopyIsModified(record))
        // The pristine copy was never touched.
        #expect(try Data(contentsOf: await lib.pristineURL(record)) == syntheticDisc("ALPHA"))
    }
}

struct DownloadScannerTests {
    let folder = URL(fileURLWithPath: "/Downloads")
    let start = Date(timeIntervalSince1970: 1_000_000)

    func file(_ name: String, size: Int64 = 102_400, modified: Date? = nil) -> DownloadScanner.FileInfo {
        DownloadScanner.FileInfo(url: folder.appendingPathComponent(name), size: size, modified: modified ?? start)
    }

    @Test func onlyFinishedDiscImagesAreCandidates() {
        #expect(DownloadScanner.isCandidateName("Disc999-EliteSNG45.ssd"))
        #expect(DownloadScanner.isCandidateName("Exile.DSD"))
        for name in ["Elite.ssd.download", "Elite.ssd.part", "Elite.ssd.crdownload", "Elite.tmp", ".Elite.ssd",
                     "~Elite.ssd", "Elite.zip", "Elite"] {
            #expect(!DownloadScanner.isCandidateName(name), "\(name)")
        }
    }

    @Test func aFileIsReadyOnceItsHeldStill() {
        var scanner = DownloadScanner(stabilityWindow: 1.5)
        let elite = file("Elite.ssd")
        #expect(scanner.update(listing: [elite], now: start.addingTimeInterval(0.1)) == .init(ready: [], settling: true))
        #expect(scanner.update(listing: [elite], now: start.addingTimeInterval(1)).ready.isEmpty)
        #expect(scanner.update(listing: [elite], now: start.addingTimeInterval(2)).ready == [elite])
    }

    @Test func aGrowingFileIsntReady() {
        var scanner = DownloadScanner(stabilityWindow: 1.5)
        _ = scanner.update(listing: [file("Elite.ssd", size: 1000)], now: start)
        let grown = file("Elite.ssd", size: 50_000, modified: start.addingTimeInterval(1.8))
        #expect(scanner.update(listing: [grown], now: start.addingTimeInterval(2)).ready.isEmpty)
        #expect(scanner.update(listing: [grown], now: start.addingTimeInterval(3)).ready.isEmpty)
        #expect(scanner.update(listing: [grown], now: start.addingTimeInterval(4)).ready == [grown])
    }

    @Test func aRenamedPartialDownloadIsSeenUnderItsFinalName() {
        var scanner = DownloadScanner(stabilityWindow: 1.5)
        let partial = file("Elite.ssd.download")
        #expect(scanner.update(listing: [partial], now: start) == .init(ready: [], settling: false))
        let done = file("Elite.ssd", modified: start.addingTimeInterval(1))
        _ = scanner.update(listing: [done], now: start.addingTimeInterval(1.2))
        #expect(scanner.update(listing: [done], now: start.addingTimeInterval(3)).ready == [done])
    }

    @Test func eachFileIsOfferedOnceUntilItChanges() {
        var scanner = DownloadScanner(stabilityWindow: 1)
        let elite = file("Elite.ssd")
        _ = scanner.update(listing: [elite], now: start.addingTimeInterval(1))
        #expect(scanner.update(listing: [elite], now: start.addingTimeInterval(3)).ready == [elite])
        scanner.markHandled(elite)
        #expect(scanner.update(listing: [elite], now: start.addingTimeInterval(5)) == .init(ready: [], settling: false))
        // Downloaded again over the top.
        let again = file("Elite.ssd", modified: start.addingTimeInterval(10))
        _ = scanner.update(listing: [again], now: start.addingTimeInterval(11))
        #expect(scanner.update(listing: [again], now: start.addingTimeInterval(13)).ready == [again])
    }

    @Test func twoDownloadsAreBothOffered() {
        var scanner = DownloadScanner(stabilityWindow: 1)
        let a = file("A.ssd", modified: start)
        let b = file("B.ssd", modified: start.addingTimeInterval(0.5))
        _ = scanner.update(listing: [b, a], now: start.addingTimeInterval(1))
        #expect(scanner.update(listing: [b, a], now: start.addingTimeInterval(3)).ready == [a, b])
    }

    @Test func ignoresDirectoriesAndOversizedFiles() {
        var scanner = DownloadScanner(stabilityWindow: 0)
        var folderNamedLikeADisc = file("Folder.ssd")
        folderNamedLikeADisc.isRegularFile = false
        let huge = file("Huge.ssd", size: GameLibrary.maxImageSize + 1)
        let empty = file("Empty.ssd", size: 0)
        _ = scanner.update(listing: [folderNamedLikeADisc, huge, empty], now: start)
        #expect(scanner.update(listing: [folderNamedLikeADisc, huge, empty], now: start.addingTimeInterval(5)).ready.isEmpty)
    }

    @Test func listsAFolderWithoutDescending() throws {
        let scratch = ScratchFolder()
        _ = try scratch.file("Game.ssd", syntheticDisc("GAME"))
        _ = try scratch.file("notes.txt", Data("hello".utf8))
        let sub = scratch.url.appendingPathComponent("Sub.ssd")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try syntheticDisc("DEEP").write(to: sub.appendingPathComponent("Deep.ssd"))
        let listing = try DownloadScanner.list(scratch.url)
        #expect(Set(listing.map(\.url.lastPathComponent)) == ["Game.ssd", "Sub.ssd"])
        #expect(listing.first { $0.url.lastPathComponent == "Sub.ssd" }?.isRegularFile == false)
    }
}

struct MediaRegistryTests {
    let scratch = ScratchFolder()

    @Test func aDiscKeepsItsIdentityThroughWritesAndRenames() throws {
        let registry = MediaRegistry(url: scratch.url.appendingPathComponent("Media.json"))
        let disc = try scratch.file("game.ssd", syntheticDisc("GAME"))
        let id = registry.identity(forFileAt: disc, digest: GameLibrary.sha256(syntheticDisc("GAME")))
        // Written to by the BBC.
        registry.noteWritten(id: id, digest: GameLibrary.sha256(syntheticDisc("SAVED")))
        #expect(registry.identity(forFileAt: disc, digest: GameLibrary.sha256(syntheticDisc("SAVED"))) == id)
        // Renamed.
        let renamed = scratch.url.appendingPathComponent("renamed.ssd")
        try FileManager.default.moveItem(at: disc, to: renamed)
        let reloaded = MediaRegistry(url: scratch.url.appendingPathComponent("Media.json"))
        #expect(reloaded.identity(forFileAt: renamed, digest: GameLibrary.sha256(syntheticDisc("SAVED"))) == id)
    }

    @Test func aCopyBesideTheOriginalIsADifferentDisc() throws {
        let registry = MediaRegistry(url: scratch.url.appendingPathComponent("Media.json"))
        let digest = GameLibrary.sha256(syntheticDisc("GAME"))
        let one = registry.identity(forFileAt: try scratch.file("one.ssd", syntheticDisc("GAME")), digest: digest)
        let two = registry.identity(forFileAt: try scratch.file("two.ssd", syntheticDisc("GAME")), digest: digest)
        #expect(one != two)
    }
}

struct SnapshotStoreTests {
    let scratch = ScratchFolder()

    func store() -> SnapshotStore {
        SnapshotStore(root: scratch.url.appendingPathComponent("Snapshots"))
    }

    /// A Model B with DFS, booted, with a blank disc in drive 0.
    func machine() -> BBCMicro {
        let machine = BBCMicro(configuration: BeebROMs.configuration(for: .modelB))
        machine.insertDisc(try? Disc.fromImage(BlankDisc.dfs40.image(title: "SAVES"), format: .ssd))
        machine.runUntilIdle()
        return machine
    }

    func manifest(_ owner: UUID, _ machine: BBCMicro) -> SnapshotManifest {
        SnapshotManifest(owner: owner, gameID: nil, title: "Test", model: machine.model, coprocessor: nil,
                         drives: [.init(drive: 0, media: owner, name: "saves.ssd", managed: false)])
    }

    func run(_ machine: BBCMicro, _ text: String) {
        machine.paste(text)
        #expect(machine.runUntilIdle(maxSeconds: 20))
    }

    func files(_ machine: BBCMicro) throws -> [String] {
        let disc = try #require(machine.drives[0].disc)
        return try DFSDisc(side: disc.toImage(.ssd)).files.map(\.name)
    }

    @Test func keepsTheNewestFive() async throws {
        let snapshots = store()
        let owner = UUID()
        let m = machine()
        var saved: [UUID] = []
        for _ in 0..<6 {
            let draft = manifest(owner, m)
            saved.append(draft.id)
            let history = try await snapshots.save(SaveStateFile(m), thumbnailPNG: nil, manifest: draft)
            #expect(history.count == min(saved.count, 5))
        }
        let history = await snapshots.history(owner: owner)
        #expect(history.map(\.id) == saved.reversed().prefix(5).map { $0 })
        #expect(history.map(\.sequence) == [6, 5, 4, 3, 2])

        // Restoring an old one deletes nothing; the next save goes on the front.
        _ = try await snapshots.load(history[2])
        #expect(await snapshots.history(owner: owner).count == 5)
        let next = manifest(owner, m)
        try await snapshots.save(SaveStateFile(m), thumbnailPNG: nil, manifest: next)
        #expect(await snapshots.history(owner: owner).map(\.id) == [next.id] + history.prefix(4).map(\.id))
    }

    @Test func gamesHaveTheirOwnHistories() async throws {
        let snapshots = store()
        let m = machine()
        let a = UUID(), b = UUID()
        for _ in 0..<5 {
            try await snapshots.save(SaveStateFile(m), thumbnailPNG: nil, manifest: manifest(a, m))
        }
        try await snapshots.save(SaveStateFile(m), thumbnailPNG: Data([0x89]), manifest: manifest(b, m))
        #expect(await snapshots.history(owner: a).count == 5)
        let other = await snapshots.history(owner: b)
        #expect(other.count == 1)
        let thumbnail = try #require(await snapshots.thumbnailURL(other[0]))
        #expect(try Data(contentsOf: thumbnail) == Data([0x89]))
        try await snapshots.deleteAll(owner: b)
        #expect(await snapshots.history(owner: b).isEmpty)
        #expect(await snapshots.history(owner: a).count == 5)
    }

    @Test func restoresMemoryAndTheDiscTogether() async throws {
        let snapshots = store()
        let owner = UUID()
        let m = machine()
        run(m, "X%=42\n*SAVE A 3000 3100\n")
        let a = try await snapshots.save(SaveStateFile(m), thumbnailPNG: nil, manifest: manifest(owner, m))[0]
        run(m, "X%=99\n*SAVE B 3000 3100\n")
        try await snapshots.save(SaveStateFile(m), thumbnailPNG: nil, manifest: manifest(owner, m))
        #expect(try files(m).sorted() == ["A", "B"])

        // Relaunched: a new store over the same folder.
        let restored = try await SnapshotStore(root: snapshots.root).load(a).makeMachine()
        #expect(try files(restored) == ["A"])
        // And it carries on from there.
        run(restored, "PRINT X%*2\n")
        #expect(restored.teletextScreenText()?.contains { $0.contains("84") } == true)
    }

    @Test func aDamagedSnapshotIsRefusedAndTheOthersKept() async throws {
        let snapshots = store()
        let owner = UUID()
        let m = machine()
        let good = manifest(owner, m)
        try await snapshots.save(SaveStateFile(m), thumbnailPNG: nil, manifest: good)
        let bad = manifest(owner, m)
        try await snapshots.save(SaveStateFile(m), thumbnailPNG: nil, manifest: bad)
        let state = snapshots.root.appendingPathComponent(owner.uuidString).appendingPathComponent(bad.id.uuidString)
            .appendingPathComponent("state.beebstate")
        var data = try Data(contentsOf: state)
        data[data.count / 2] ^= 0xFF
        try data.write(to: state)
        let history = await snapshots.history(owner: owner)
        await #expect(throws: SnapshotError.damaged) { try await snapshots.load(history[0]) }
        _ = try await snapshots.load(history[1])

        try FileManager.default.removeItem(at: state)
        await #expect(throws: SnapshotError.notFound) { try await snapshots.load(history[0]) }
    }

    @Test func refusesSnapshotsFromAnotherCoreVersion() async throws {
        let snapshots = store()
        let m = machine()
        let draft = manifest(UUID(), m)
        let history = try await snapshots.save(SaveStateFile(m), thumbnailPNG: nil, manifest: draft)
        var newer = history[0]
        newer.coreVersion += 1
        await #expect(throws: SnapshotError.self) { try await snapshots.load(newer) }
    }

    @Test func interruptedSavesAreClearedUp() async throws {
        let snapshots = store()
        let owner = UUID()
        let m = machine()
        try await snapshots.save(SaveStateFile(m), thumbnailPNG: nil, manifest: manifest(owner, m))
        let partial = snapshots.root.appendingPathComponent(owner.uuidString).appendingPathComponent(".partial-\(UUID())")
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
        try Data([1]).write(to: partial.appendingPathComponent("state.beebstate"))
        #expect(await snapshots.history(owner: owner).count == 1)
        await snapshots.recover()
        #expect(!FileManager.default.fileExists(atPath: partial.path))
        #expect(await snapshots.history(owner: owner).count == 1)
    }

    @Test func savesTheSecondProcessorToo() async throws {
        let snapshots = store()
        let m = BBCMicro(configuration: BeebROMs.configuration(for: .modelB, secondProcessor: true))
        m.runUntilIdle()
        run(m, "A%=&1234:PRINT ~A%\n")
        let draft = SnapshotManifest(owner: UUID(), gameID: nil, title: "Tube", model: .modelB, coprocessor: .mos6502,
                                     drives: [])
        let history = try await snapshots.save(SaveStateFile(m), thumbnailPNG: nil, manifest: draft)
        let restored = try await snapshots.load(history[0]).makeMachine()
        // BASIC runs in the second processor: its variables come back.
        run(restored, "PRINT ~A%+1\n")
        #expect(restored.teletextScreenText()?.contains { $0.contains("1235") } == true)
    }
}

/// Quick load through the emulation thread, as the app does it.
struct QuickLoadHostTests {
    @Test func restoresTheStateAndWritesTheDiscBack() async throws {
        let host = EmulatorHost {
            let machine = BBCMicro(configuration: BeebROMs.configuration(for: .modelB))
            machine.insertDisc(try? Disc.fromImage(BlankDisc.dfs40.image(title: "HOST"), format: .ssd))
            return machine
        }
        host.start()
        defer { host.stop() }
        try await host.performAsync { session in
            _ = session.advance(until: { false }, maxSeconds: 3)
            session.machine.paste("X%=7\n*SAVE A 3000 3100\n")
            _ = session.machine.runUntilIdle(maxSeconds: 20)
        }
        let saved = try await host.performAsync { SaveStateFile($0.machine) }
        try await host.performAsync { session in
            session.machine.paste("X%=8\n*SAVE B 3000 3100\n")
            _ = session.machine.runUntilIdle(maxSeconds: 20)
        }

        // A state that can't be restored leaves the machine as it is.
        var broken = saved
        broken.snapshot.version = 99
        let refused: Error? = await withCheckedContinuation { continuation in
            host.send(.restoreState(broken, writeBacks: [:], completion: { continuation.resume(returning: $0) }))
        }
        #expect(refused != nil)
        #expect(try await host.performAsync { session in
            try DFSDisc(side: session.machine.drives[0].disc!.toImage(.ssd)).files.map(\.name).sorted()
        } == ["A", "B"])

        let written = Mutex<[UInt8]?>(nil)
        let error: Error? = await withCheckedContinuation { continuation in
            host.send(.restoreState(saved, writeBacks: [0: .init(format: .ssd) { bytes in written.withLock { $0 = bytes } }],
                                    completion: { continuation.resume(returning: $0) }))
        }
        #expect(error == nil)
        // The library's file follows the restored disc.
        let image = try #require(written.withLock { $0 })
        #expect(try DFSDisc(side: image).files.map(\.name) == ["A"])
        let screen = try await host.performAsync { session -> [String] in
            session.machine.paste("PRINT X%*6\n")
            _ = session.machine.runUntilIdle(maxSeconds: 10)
            return session.machine.teletextScreenText() ?? []
        }
        #expect(screen.contains { $0.contains("42") }, "\(screen)")
    }
}

struct MyGamesTests {
    let scratch = ScratchFolder()

    func store() -> MyGames {
        MyGames(root: scratch.url.appendingPathComponent("MyGames"))
    }

    /// A tiny PNG.
    func picture() throws -> Data {
        let base64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
        return try #require(Data(base64Encoded: base64))
    }

    @Test func groupsDiscsWithTheirCovers() {
        let dir = URL(fileURLWithPath: "/drop")
        func url(_ name: String) -> URL { dir.appendingPathComponent(name) }
        // One of each, whatever they're called.
        #expect(MyGames.group([url("cover.png"), url("Game.ssd")]).map { [$0.disc, $0.cover] } == [[url("Game.ssd"), url("cover.png")]])
        // Several: by name; leftover pictures are games without discs.
        let groups = MyGames.group([url("a.ssd"), url("b.dsd"), url("B.jpg"), url("c.png"), url("notes.txt")])
        #expect(groups.map { [$0.disc, $0.cover] } == [[url("a.ssd"), nil], [url("b.dsd"), url("B.jpg")], [nil, url("c.png")]])
        #expect(MyGames.group([url("notes.txt")]).isEmpty)
    }

    @Test func aDiscFirstThenACover() async throws {
        let games = store()
        let disc = try MyGames.readDisc(at: scratch.file("Disc012-My_Game.ssd", syntheticDisc("MINE")))
        #expect(disc.suggestedTitle == "My Game")
        let added = try await games.add(PersonalGame(title: disc.suggestedTitle), disc: disc, cover: nil)
        #expect(added.coverFile == nil)
        #expect(try Data(contentsOf: #require(games.discURL(added))) == syntheticDisc("MINE"))

        let withCover = try await games.setCover(scratch.file("art.png", picture()), for: added.id)
        #expect(try Data(contentsOf: #require(games.coverURL(withCover))) == picture())
        // Relaunched (dates are kept to the second).
        let reloaded = try #require(await store().games.first)
        #expect([reloaded.id.uuidString, reloaded.title, reloaded.discFile, reloaded.coverFile]
                == [withCover.id.uuidString, withCover.title, withCover.discFile, withCover.coverFile])
    }

    @Test func aCoverFirstThenADisc() async throws {
        let games = store()
        let added = try await games.add(PersonalGame(title: "Later"), disc: nil, cover: scratch.file("art.png", picture()))
        #expect(added.discFile == nil)
        let disc = try MyGames.readDisc(at: scratch.file("later.ssd", syntheticDisc("LATER")))
        let complete = try await games.setDisc(disc, for: added.id)
        #expect(complete.discSHA256 == disc.digest)
        #expect(complete.coverFile == added.coverFile)
    }

    @Test func bothAtOnceAndReplaced() async throws {
        let games = store()
        let first = try MyGames.readDisc(at: scratch.file("one.ssd", syntheticDisc("ONE")))
        let added = try await games.add(PersonalGame(title: "Both"), disc: first, cover: scratch.file("a.png", picture()))
        let oldCover = try #require(games.coverURL(added))
        let second = try MyGames.readDisc(at: scratch.file("two.dsd", Data(BlankDisc.dfsDoubleSided40.image(title: "TWO"))))
        var changed = try await games.setDisc(second, for: added.id)
        changed = try await games.setCover(scratch.file("b.png", picture()), for: added.id)
        #expect(changed.discFile == "disc.dsd")
        #expect(!FileManager.default.fileExists(atPath: games.root.appendingPathComponent(added.id.uuidString)
            .appendingPathComponent("disc.ssd").path))
        #expect(!FileManager.default.fileExists(atPath: oldCover.path))
        // Details change without touching the files.
        var edited = changed
        edited.title = "Renamed"
        edited.discFile = nil
        try await games.update(edited)
        #expect(await games.game(id: added.id)?.title == "Renamed")
        #expect(await games.game(id: added.id)?.discFile == "disc.dsd")
    }

    @Test func refusesWhatItCantUse() throws {
        #expect(throws: MyGamesError.notAnImage("fake.png")) {
            try MyGames.checkCover(at: scratch.file("fake.png", Data("not a picture".utf8)))
        }
        #expect(throws: MyGamesError.notADisc("notes.txt")) {
            try MyGames.readDisc(at: scratch.file("notes.txt", syntheticDisc("X")))
        }
        #expect(throws: MyGamesError.tooLarge("huge.ssd")) {
            try MyGames.readDisc(at: scratch.file("huge.ssd", Data(count: Int(MyGames.maxDiscSize) + 1)))
        }
    }

    @Test func suggestsAMachineAndAStart() throws {
        let adfs = try MyGames.readDisc(at: scratch.file("x.adf", Data(BlankDisc.adfsS.image(title: "X"))))
        #expect(adfs.suggestedMachine == (.master128, nil))
        // A blank DFS disc's boot option is off.
        let dfs = try MyGames.readDisc(at: scratch.file("x.ssd", syntheticDisc("X")))
        #expect(dfs.suggestedMachine == (.modelB, nil))
        #expect(dfs.suggestedStart == .insertOnly)
    }

    @Test func removingLeavesTheOriginals() async throws {
        let games = store()
        let original = try scratch.file("keep.ssd", syntheticDisc("KEEP"))
        let added = try await games.add(PersonalGame(title: "Gone"), disc: MyGames.readDisc(at: original), cover: nil)
        try await games.remove(id: added.id)
        #expect(await games.games.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: games.root.appendingPathComponent(added.id.uuidString).path))
        #expect(try Data(contentsOf: original) == syntheticDisc("KEEP"))
    }

    @Test func forgetsFilesThatHaveGone() async throws {
        let games = store()
        let added = try await games.add(PersonalGame(title: "Lost"),
                                        disc: MyGames.readDisc(at: scratch.file("l.ssd", syntheticDisc("L"))), cover: nil)
        try FileManager.default.removeItem(at: #require(games.discURL(added)))
        try await games.reconcile()
        #expect(await games.game(id: added.id)?.discFile == nil)
    }
}
