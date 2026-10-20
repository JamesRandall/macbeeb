import Foundation

/// The bundled ROM images.
public enum BeebROMs {
    public enum Image: String, CaseIterable, Sendable {
        case os12 = "os12"
        case basic2 = "basic2"
        case dfs12 = "dfs12"
        case dfs226 = "dfs226"
    }

    public static func data(_ image: Image) -> [UInt8] {
        guard let url = Bundle.module.url(forResource: image.rawValue, withExtension: "rom", subdirectory: "ROMs"),
              let data = try? Data(contentsOf: url) else {
            preconditionFailure("missing bundled ROM \(image.rawValue)")
        }
        return [UInt8](data)
    }
}
