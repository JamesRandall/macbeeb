import Foundation

/// Stable identities for disc image files opened outside the library, so
/// their quick saves stay together when the BBC writes to them or the file
/// is renamed. Kept in Application Support/MacBeeb/Media.json.
public final class MediaRegistry: @unchecked Sendable {
    public struct Record: Codable, Sendable, Equatable {
        public var id: UUID
        public var path: String
        /// The contents when first seen, and as last written.
        public var firstDigest: String
        public var lastDigest: String
        public var lastUsed: Date
    }

    private let url: URL
    private let lock = NSLock()
    private var records: [Record]
    public static let limit = 500

    public init(url: URL) {
        self.url = url
        records = (try? JSONDecoder.library.decode([Record].self, from: Data(contentsOf: url))) ?? []
    }

    public static var defaultURL: URL {
        URL.applicationSupportDirectory.appendingPathComponent("MacBeeb/Media.json")
    }

    /// The identity of the disc image at `fileURL`, whose contents have
    /// `digest`: the one registered for its path, or for a file with the
    /// same contents that's no longer where it was (it was moved or
    /// renamed), or a new one.
    public func identity(forFileAt fileURL: URL, digest: String, now: Date = Date()) -> UUID {
        lock.lock()
        defer { lock.unlock() }
        let path = fileURL.standardizedFileURL.path
        let index = records.firstIndex { $0.path == path }
            ?? records.firstIndex { ($0.lastDigest == digest || $0.firstDigest == digest)
                && !FileManager.default.fileExists(atPath: $0.path) }
        let id: UUID
        if let index {
            records[index].path = path
            records[index].lastDigest = digest
            records[index].lastUsed = now
            id = records[index].id
        } else {
            id = UUID()
            records.append(Record(id: id, path: path, firstDigest: digest, lastDigest: digest, lastUsed: now))
            if records.count > Self.limit {
                records.sort { $0.lastUsed > $1.lastUsed }
                records.removeLast(records.count - Self.limit)
            }
        }
        save()
        return id
    }

    /// Notes new contents (the BBC wrote to the disc).
    public func noteWritten(id: UUID, digest: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let index = records.firstIndex(where: { $0.id == id }), records[index].lastDigest != digest else { return }
        records[index].lastDigest = digest
        save()
    }

    public func record(id: UUID) -> Record? {
        lock.lock()
        defer { lock.unlock() }
        return records.first { $0.id == id }
    }

    private func save() {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder.library.encode(records).write(to: url, options: .atomic)
    }
}
