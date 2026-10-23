import Foundation

/// A network on disc: a `.macbeebnet` package (a folder Finder shows as one
/// file) with `manifest.json`, the project, and `Media`, the copies of its
/// discs.
public enum NetworkPackage {
    public static let fileExtension = "macbeebnet"
    static let manifestName = "manifest.json"
    static let mediaFolder = "Media"

    public enum LoadError: Error, CustomStringConvertible {
        case notANetwork
        case newerVersion(Int)

        public var description: String {
            switch self {
            case .notANetwork: "This isn't a MacBeeb network: it has no manifest."
            case .newerVersion(let version): "This network was saved by a newer MacBeeb (format \(version)). Update MacBeeb to open it."
            }
        }
    }

    public static func load(from url: URL) throws -> NetworkProject {
        let manifest = url.appendingPathComponent(manifestName)
        guard FileManager.default.fileExists(atPath: manifest.path) else { throw LoadError.notANetwork }
        let data = try Data(contentsOf: manifest)
        let version = try JSONDecoder().decode(Versioned.self, from: data).schemaVersion
        guard version <= NetworkProject.currentSchemaVersion else { throw LoadError.newerVersion(version) }
        // Migrations from older versions go here, by version.
        return try JSONDecoder().decode(NetworkProject.self, from: data)
    }

    /// Writes the manifest (atomically) and makes the package if it's new.
    public static func save(_ project: NetworkProject, to url: URL) throws {
        try FileManager.default.createDirectory(at: mediaURL(in: url), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(project).write(to: url.appendingPathComponent(manifestName), options: .atomic)
    }

    public static func mediaURL(in package: URL) -> URL {
        package.appendingPathComponent(mediaFolder, isDirectory: true)
    }

    /// Copies a disc image into the package, under a new name, so the
    /// network's machines write to the copy.
    public static func importMedia(_ source: URL, into package: URL) throws -> MediaReference {
        let folder = mediaURL(in: package)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = UUID().uuidString.prefix(8) + "-" + source.lastPathComponent
        try FileManager.default.copyItem(at: source, to: folder.appendingPathComponent(String(name)))
        return MediaReference(storedName: String(name), displayName: source.lastPathComponent, originalPath: source.path)
    }

    public static func url(of media: MediaReference, in package: URL) -> URL {
        mediaURL(in: package).appendingPathComponent(media.storedName)
    }

    /// Media the manifest no longer mentions.
    public static func unusedMedia(of project: NetworkProject, in package: URL) -> [URL] {
        let used = Set(project.nodes.flatMap { $0.discs.values.map(\.storedName) })
        let files = (try? FileManager.default.contentsOfDirectory(at: mediaURL(in: package), includingPropertiesForKeys: nil)) ?? []
        return files.filter { !used.contains($0.lastPathComponent) }
    }

    private struct Versioned: Decodable {
        var schemaVersion: Int
    }
}
