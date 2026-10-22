import BeebCore
import Foundation

/// What a quick save is: whose it is, when, and on what machine. Written
/// last, so a snapshot without one was never finished.
public struct SnapshotManifest: Codable, Sendable, Equatable, Identifiable {
    public static let currentFormat = 1

    public var format = Self.currentFormat
    /// The core's snapshot version (BBCMicro.Snapshot.currentVersion).
    public var coreVersion: Int
    public var id: UUID
    /// The disc the history belongs to: a library game's library ID, or a
    /// disc file's media ID.
    public var owner: UUID
    /// The curated game, if it's one.
    public var gameID: String?
    /// What to call it: the game's or disc's name.
    public var title: String
    public var created: Date
    /// Increases with each save for an owner.
    public var sequence: Int
    public var model: BBCMicro.Model
    public var coprocessor: BBCMicro.Coprocessor?
    /// The discs in the drives, which the state contains as they were.
    public var drives: [DriveMedia]
    public var stateFile = "state.beebstate"
    public var stateSHA256: String
    public var stateByteCount: Int
    public var thumbnailFile: String?

    public struct DriveMedia: Codable, Sendable, Equatable {
        public var drive: Int
        public var media: UUID?
        public var name: String
        /// A disc that lives in the library, so its file can follow the
        /// restored disc.
        public var managed: Bool

        public init(drive: Int, media: UUID?, name: String, managed: Bool) {
            self.drive = drive
            self.media = media
            self.name = name
            self.managed = managed
        }
    }

    public init(id: UUID = UUID(), owner: UUID, gameID: String?, title: String, created: Date = Date(), sequence: Int = 0,
                model: BBCMicro.Model, coprocessor: BBCMicro.Coprocessor?, drives: [DriveMedia]) {
        coreVersion = BBCMicro.Snapshot.currentVersion
        self.id = id
        self.owner = owner
        self.gameID = gameID
        self.title = title
        self.created = created
        self.sequence = sequence
        self.model = model
        self.coprocessor = coprocessor
        self.drives = drives
        stateSHA256 = ""
        stateByteCount = 0
    }
}

public enum SnapshotError: LocalizedError, Equatable {
    case notFound
    case damaged
    case incompatible(String)
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notFound: "The snapshot can’t be found. It may have been deleted."
        case .damaged: "The snapshot is damaged and can’t be restored."
        case .incompatible(let why): "The snapshot can’t be restored: \(why)"
        case .writeFailed(let why): "The snapshot couldn’t be saved: \(why)"
        }
    }
}

/// Quick saves: up to `limit` complete machine states per disc, newest
/// first, in Application Support/MacBeeb/Snapshots:
///
///     <owner>/<snapshot id>/manifest.json, state.beebstate, thumbnail.png
///
/// A save is written to a ".partial-" folder, checked, then renamed into
/// place; only then does the oldest beyond the limit go. Leftover partial
/// folders (from a crash) are cleared out.
public actor SnapshotStore {
    public nonisolated let root: URL
    public nonisolated let limit: Int
    private let fileManager = FileManager.default

    public init(root: URL, limit: Int = 5) {
        self.root = root
        self.limit = limit
    }

    public static var defaultRoot: URL {
        URL.applicationSupportDirectory.appendingPathComponent("MacBeeb/Snapshots", isDirectory: true)
    }

    private func folder(_ owner: UUID) -> URL {
        root.appendingPathComponent(owner.uuidString, isDirectory: true)
    }

    /// Saves a state, then trims the history to the limit. Returns the
    /// history, newest first.
    @discardableResult
    public func save(_ state: SaveStateFile, thumbnailPNG: Data?, manifest draft: SnapshotManifest) throws -> [SnapshotManifest] {
        let ownerFolder = folder(draft.owner)
        let existing = history(owner: draft.owner)
        var manifest = draft
        manifest.sequence = (existing.first?.sequence ?? 0) + 1
        let partial = ownerFolder.appendingPathComponent(".partial-\(manifest.id.uuidString)", isDirectory: true)
        let final = ownerFolder.appendingPathComponent(manifest.id.uuidString, isDirectory: true)
        do {
            try fileManager.createDirectory(at: partial, withIntermediateDirectories: true)
            let data = try state.data()
            let stateURL = partial.appendingPathComponent(manifest.stateFile)
            try data.write(to: stateURL, options: .atomic)
            // Read back what's on disc before it counts.
            guard let written = try? Data(contentsOf: stateURL), written == data else {
                throw SnapshotError.writeFailed("it didn’t read back as written")
            }
            manifest.stateSHA256 = GameLibrary.sha256(data)
            manifest.stateByteCount = data.count
            if let thumbnailPNG {
                manifest.thumbnailFile = "thumbnail.png"
                try thumbnailPNG.write(to: partial.appendingPathComponent("thumbnail.png"), options: .atomic)
            }
            try JSONEncoder.library.encode(manifest).write(to: partial.appendingPathComponent("manifest.json"), options: .atomic)
            try fileManager.moveItem(at: partial, to: final)
        } catch let error as SnapshotError {
            try? fileManager.removeItem(at: partial)
            throw error
        } catch {
            try? fileManager.removeItem(at: partial)
            throw SnapshotError.writeFailed(error.localizedDescription)
        }
        var history = [manifest] + existing
        for old in history.dropFirst(limit) {
            try? fileManager.removeItem(at: ownerFolder.appendingPathComponent(old.id.uuidString))
        }
        history = Array(history.prefix(limit))
        return history
    }

    /// An owner's finished snapshots, newest first.
    public func history(owner: UUID) -> [SnapshotManifest] {
        let ownerFolder = folder(owner)
        guard let entries = try? fileManager.contentsOfDirectory(at: ownerFolder, includingPropertiesForKeys: nil) else {
            return []
        }
        return entries.compactMap { entry -> SnapshotManifest? in
            guard !entry.lastPathComponent.hasPrefix("."),
                  let data = try? Data(contentsOf: entry.appendingPathComponent("manifest.json")),
                  let manifest = try? JSONDecoder.library.decode(SnapshotManifest.self, from: data),
                  manifest.owner == owner, manifest.id.uuidString == entry.lastPathComponent else { return nil }
            return manifest
        }
        .sorted { $0.sequence > $1.sequence }
    }

    /// Reads and checks a snapshot's state, without touching any machine.
    public func load(_ manifest: SnapshotManifest) throws -> SaveStateFile {
        guard manifest.format <= SnapshotManifest.currentFormat else {
            throw SnapshotError.incompatible("it was saved by a newer version of MacBeeb.")
        }
        guard manifest.coreVersion == BBCMicro.Snapshot.currentVersion else {
            throw SnapshotError.incompatible("it was saved by a different version of MacBeeb’s emulator.")
        }
        let url = folder(manifest.owner).appendingPathComponent(manifest.id.uuidString)
            .appendingPathComponent(manifest.stateFile)
        guard let data = try? Data(contentsOf: url) else { throw SnapshotError.notFound }
        guard data.count == manifest.stateByteCount, GameLibrary.sha256(data) == manifest.stateSHA256 else {
            throw SnapshotError.damaged
        }
        let file: SaveStateFile
        do {
            file = try SaveStateFile(data: data)
        } catch {
            throw SnapshotError.damaged
        }
        guard file.snapshot.version == BBCMicro.Snapshot.currentVersion else {
            throw SnapshotError.incompatible("it was saved by a different version of MacBeeb’s emulator.")
        }
        guard file.configuration.model == manifest.model else { throw SnapshotError.damaged }
        return file
    }

    public func thumbnailURL(_ manifest: SnapshotManifest) -> URL? {
        manifest.thumbnailFile.map {
            folder(manifest.owner).appendingPathComponent(manifest.id.uuidString).appendingPathComponent($0)
        }
    }

    public func delete(_ manifest: SnapshotManifest) throws {
        try fileManager.removeItem(at: folder(manifest.owner).appendingPathComponent(manifest.id.uuidString))
    }

    public func deleteAll(owner: UUID) throws {
        let ownerFolder = folder(owner)
        if fileManager.fileExists(atPath: ownerFolder.path) {
            try fileManager.removeItem(at: ownerFolder)
        }
    }

    /// Clears out saves that were interrupted. Finished snapshots are left
    /// alone.
    public func recover() {
        guard let owners = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for owner in owners {
            guard let entries = try? fileManager.contentsOfDirectory(at: owner, includingPropertiesForKeys: nil) else { continue }
            for entry in entries where entry.lastPathComponent.hasPrefix(".partial-") {
                try? fileManager.removeItem(at: entry)
            }
        }
    }
}
