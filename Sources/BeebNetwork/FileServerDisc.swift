import BeebCore
import BeebROMs
import Foundation

/// The file server's disc. Acorn's Level 1 file server keeps the network's
/// files on the disc in its drive 0, so the bundled utilities disc (40
/// tracks, nearly full) is copied onto an 80-track one with just the server
/// and the stations' library (&): about 190K and 23 catalogue entries free
/// for directory A, which every station shares.
public enum FileServerDisc {
    /// The directory every station on a Studio network shares.
    public static let sharedDirectory: Character = "A"

    public static func image() throws -> [UInt8] {
        let bundled = BeebROMs.BundledDisc.econetLevel1
        let source = try DiscVolume(disc: Disc.fromImage(bundled.data, format: bundled.format))
        var volume = try DiscVolume(disc: Disc.fromImage(BlankDisc.dfs80.image(title: "FILESERVER"), format: .ssd))
        for item in try source.items(at: .init()) where item.fullName == "$.FS" || item.fullName.hasPrefix("&.") {
            try volume.save(at: .init(), name: item.fullName, loadAddress: item.loadAddress, executionAddress: item.executionAddress,
                            contents: source.contents(of: item, at: .init()), locked: item.locked)
        }
        return volume.image
    }

    /// Puts Mac files in the shared directory of the server's disc: named
    /// and addressed by .inf files beside them where there are any, BASIC
    /// text (.bas) tokenised, whatever directory they were named for.
    /// Returns the names they were given.
    @discardableResult
    public static func add(_ urls: [URL], to volume: inout DiscVolume) throws -> [String] {
        var names: [String] = []
        for url in urls {
            guard var file = try MacFile.read(url, adfs: false) else { continue }
            let leaf = file.name.split(separator: ".").last.map(String.init) ?? file.name
            file.name = "\(sharedDirectory).\(leaf)"
            try file.add(to: &volume, at: .init())
            names.append(file.name)
        }
        return names
    }
}
