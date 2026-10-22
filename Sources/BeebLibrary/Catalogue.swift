import BeebCore
import Foundation

/// BBCMicro.co.uk's top 20, the Author's Picks, and the archive itself: the
/// Game Library's shelves. Bundled data (Data/classics.json), never fetched.
public struct Catalogue: Codable, Sendable {
    public var version: Int
    public var source: String
    public var archive: ArchiveBook
    /// The top 20, in rank order.
    public var games: [CuratedGame]
    /// Games that are only among the Author's Picks, so have no rank.
    public var moreGames: [CuratedGame]
    /// The Author's Picks in order: the IDs of games in `games` or `moreGames`.
    public var authorsPicks: [String]

    enum CodingKeys: CodingKey {
        case version, source, archive, games, moreGames, authorsPicks
    }

    /// The bundled catalogue.
    public static let classics: Catalogue = {
        guard let url = BeebLibrary.bundle.url(forResource: "classics", withExtension: "json", subdirectory: "Data"),
              let data = try? Data(contentsOf: url) else {
            fatalError("MacBeeb: the classics catalogue is missing from the bundle")
        }
        do {
            return try Catalogue(data: data)
        } catch {
            fatalError("MacBeeb: the classics catalogue is unreadable: \(error)")
        }
    }()

    public init(data: Data) throws {
        self = try JSONDecoder().decode(Catalogue.self, from: data)
        games.sort { ($0.rank ?? .max) < ($1.rank ?? .max) }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        source = try c.decode(String.self, forKey: .source)
        archive = try c.decode(ArchiveBook.self, forKey: .archive)
        games = try c.decode([CuratedGame].self, forKey: .games)
        moreGames = try c.decodeIfPresent([CuratedGame].self, forKey: .moreGames) ?? []
        authorsPicks = try c.decodeIfPresent([String].self, forKey: .authorsPicks) ?? []
    }

    public init(version: Int = 1, source: String = "", archive: ArchiveBook, games: [CuratedGame],
                moreGames: [CuratedGame] = [], authorsPicks: [String] = []) {
        self.version = version
        self.source = source
        self.archive = archive
        self.games = games.sorted { ($0.rank ?? .max) < ($1.rank ?? .max) }
        self.moreGames = moreGames
        self.authorsPicks = authorsPicks
    }

    /// Every game on any shelf, each once.
    public var allGames: [CuratedGame] { games + moreGames }

    public func game(id: String) -> CuratedGame? {
        allGames.first { $0.id == id }
    }

    /// The Author's Picks, in order.
    public var picks: [CuratedGame] {
        authorsPicks.compactMap(game(id:))
    }

    /// The game a disc image is, by its SHA-256 (lowercase hex). Only a
    /// verified digest identifies a game; names and sizes are only hints.
    public func game(forDigest digest: String) -> CuratedGame? {
        let digest = digest.lowercased()
        return allGames.first { game in game.knownDisks.contains { $0.sha256.lowercased() == digest } }
    }

    /// The shelf: the games in rank order, then the archive.
    public var shelf: [ShelfEntry] {
        games.map(ShelfEntry.game) + [.archive(archive)]
    }

    /// The Author's Picks shelf: the picks in order, then the archive.
    public var picksShelf: [ShelfEntry] {
        picks.map(ShelfEntry.game) + [.archive(archive)]
    }
}

public struct CuratedGame: Codable, Sendable, Identifiable, Hashable {
    /// Stable, independent of the title: "elite-copro", "exile-64k".
    public let id: String
    /// 1...20 in the top 20; nil for a game that's only an Author's Pick.
    public let rank: Int?
    public let title: String
    public let editionLabel: String?
    public let archiveGameID: Int
    public let archivePageURL: URL
    public let publisher: String?
    public let year: Int?
    public let authors: String?
    public let description: String
    public let machine: MachineRequirement
    public let knownDisks: [KnownDiskIdentity]

    /// The cover's name in the bundle (Covers/<id>.jpg).
    public var artworkAssetName: String { id }
}

/// A disc image known to be a game: a verified download from the archive.
public struct KnownDiskIdentity: Codable, Sendable, Hashable {
    public let sha256: String
    /// A hint only.
    public let expectedFileName: String?
    public let byteCount: Int64?
    public let variantNotes: String?
}

/// The machine a game's set up to run on when it's played.
public struct MachineRequirement: Codable, Sendable, Hashable {
    public let model: BBCMicro.Model
    /// A second processor it needs, if any.
    public let coprocessor: BBCMicro.Coprocessor?
    /// Whether it wants sideways RAM (for an enhanced version).
    public let needsSidewaysRAM: Bool
    /// For people: "BBC Model B with a 6502 Second Processor".
    public let summary: String

    enum CodingKeys: CodingKey {
        case model, coprocessor, needsSidewaysRAM, summary
    }

    public init(model: BBCMicro.Model, coprocessor: BBCMicro.Coprocessor? = nil, needsSidewaysRAM: Bool = false,
                summary: String) {
        self.model = model
        self.coprocessor = coprocessor
        self.needsSidewaysRAM = needsSidewaysRAM
        self.summary = summary
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        model = try c.decode(BBCMicro.Model.self, forKey: .model)
        coprocessor = try c.decodeIfPresent(BBCMicro.Coprocessor.self, forKey: .coprocessor)
        needsSidewaysRAM = try c.decodeIfPresent(Bool.self, forKey: .needsSidewaysRAM) ?? false
        summary = try c.decode(String.self, forKey: .summary)
    }

    /// Why MacBeeb can't provide this machine, or nil if it can. `ramBanks`
    /// is the sideways RAM the standard configuration of `model` has.
    public func unavailableReason(sidewaysRAMBanks ramBanks: Set<Int>) -> String? {
        if let coprocessor, !coprocessor.fits(model) {
            return "MacBeeb can't fit a \(coprocessor.displayName) to a \(model.displayName)."
        }
        if needsSidewaysRAM && ramBanks.isEmpty {
            return "MacBeeb's \(model.displayName) has no sideways RAM, which this edition needs."
        }
        return nil
    }
}

/// The special book on the shelf: a link to the whole archive. Not a game,
/// never ranked, installed or missing.
public struct ArchiveBook: Codable, Sendable, Hashable {
    public let id: String
    public let title: String
    public let subtitle: String
    public let pitch: String
    public let about: String
    public let url: URL
    public let aboutURL: URL
}

public enum ShelfEntry: Sendable, Hashable, Identifiable {
    case game(CuratedGame)
    case archive(ArchiveBook)

    public var id: String {
        switch self {
        case .game(let game): game.id
        case .archive(let book): book.id
        }
    }
}

public enum BeebLibrary {
    /// The resource bundle. In an app it's in Contents/Resources (as
    /// BeebROMs.bundle); elsewhere Bundle.module finds it.
    public static let bundle: Bundle = {
        let name = "macbeeb_BeebLibrary.bundle"
        if let url = Bundle.main.resourceURL?.appendingPathComponent(name),
           let bundle = Bundle(url: url) {
            return bundle
        }
        return Bundle.module
    }()

    /// A game's bundled cover, if it has one.
    public static func coverURL(for game: CuratedGame) -> URL? {
        bundle.url(forResource: game.artworkAssetName, withExtension: "jpg", subdirectory: "Covers")
    }
}
