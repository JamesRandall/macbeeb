import Foundation

/// Decides which files in a watched folder are finished downloads worth
/// looking at. It's given listings (one folder, not recursive) and says
/// which files are ready: plausible disc images whose size and date have
/// held still for a while. Each file is offered once until it changes.
///
/// Folder events are only hints to list again; nothing here relies on
/// seeing every one.
public struct DownloadScanner: Sendable {
    public struct FileInfo: Sendable, Equatable {
        public var url: URL
        public var size: Int64
        public var modified: Date
        public var isRegularFile: Bool

        public init(url: URL, size: Int64, modified: Date, isRegularFile: Bool = true) {
            self.url = url
            self.size = size
            self.modified = modified
            self.isRegularFile = isRegularFile
        }

        var signature: Signature { Signature(size: size, modified: modified) }
    }

    struct Signature: Sendable, Equatable {
        var size: Int64
        var modified: Date
    }

    /// How long a file must keep its size and date before it's taken to be
    /// finished.
    public var stabilityWindow: TimeInterval
    /// Files bigger than this are ignored.
    public var maxSize: Int64

    /// Candidates being watched settle: when each was first seen as it is.
    private var settling: [String: (signature: Signature, since: Date)] = [:]
    /// Files already offered, as they were then.
    private var offered: [String: Signature] = [:]
    /// Bounds the memory of offered files in a huge folder.
    public static let memoryLimit = 2_000

    public init(stabilityWindow: TimeInterval = 1.5, maxSize: Int64 = GameLibrary.maxImageSize) {
        self.stabilityWindow = stabilityWindow
        self.maxSize = maxSize
    }

    /// Whether a file name could be a finished disc image download: .ssd or
    /// .dsd, not hidden, and not a browser's partial download.
    public static func isCandidateName(_ name: String) -> Bool {
        // Partial downloads (Elite.ssd.download, .part, .crdownload) have
        // their own extensions.
        guard !name.hasPrefix("."), !name.hasPrefix("~") else { return false }
        let ext = (name.lowercased() as NSString).pathExtension
        return ext == "ssd" || ext == "dsd"
    }

    public struct Result: Sendable, Equatable {
        /// Files ready to read, oldest change first.
        public var ready: [FileInfo]
        /// Whether some candidates are still settling (list again soon).
        public var settling: Bool
    }

    /// Takes a listing made at `now`.
    public mutating func update(listing: [FileInfo], now: Date) -> Result {
        var ready: [FileInfo] = []
        var present = Set<String>()
        for file in listing where file.isRegularFile && file.size > 0 && file.size <= maxSize
            && Self.isCandidateName(file.url.lastPathComponent) {
            let key = file.url.standardizedFileURL.path
            present.insert(key)
            if offered[key] == file.signature { continue }
            if let seen = settling[key], seen.signature == file.signature {
                // Held still long enough, both since we first saw it so and
                // since it was last written?
                if now.timeIntervalSince(seen.since) >= stabilityWindow
                    && now.timeIntervalSince(file.modified) >= stabilityWindow {
                    ready.append(file)
                }
            } else {
                settling[key] = (file.signature, now)
            }
        }
        // Forget files that have gone.
        settling = settling.filter { present.contains($0.key) }
        offered = offered.filter { present.contains($0.key) }
        for file in ready {
            settling[file.url.standardizedFileURL.path] = nil
        }
        return Result(ready: ready.sorted { $0.modified < $1.modified }, settling: !settling.isEmpty)
    }

    /// Records that `file` has been dealt with (imported, ignored or
    /// failed), so it isn't offered again unless it changes.
    public mutating func markHandled(_ file: FileInfo) {
        if offered.count >= Self.memoryLimit {
            offered.removeAll()
        }
        offered[file.url.standardizedFileURL.path] = file.signature
    }

    /// Lists `folder` (not its subfolders) for `update`.
    public static func list(_ folder: URL) throws -> [FileInfo] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .isSymbolicLinkKey]
        let urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants,
                                                                          .skipsPackageDescendants])
        return urls.compactMap { url in
            // Only names that could matter cost a stat.
            guard isCandidateName(url.lastPathComponent),
                  let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return FileInfo(url: url, size: Int64(values.fileSize ?? 0),
                            modified: values.contentModificationDate ?? .distantPast,
                            isRegularFile: values.isRegularFile == true && values.isSymbolicLink != true)
        }
    }
}
