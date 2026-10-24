import Foundation

// Which Internet Econet service MacBeeb uses: the official one, built in,
// or one the user runs (any compatible deployment of cloudflare-econet).

public enum InternetEconetService {
    /// The official service. (Release configuration: change it here.)
    public static let officialURL = URL(string: "https://econet.acornplayground.org")!
    static let customKey = "MacBeebInternetEconetService"

    /// The service in use: the user's own, if they've set one, else the
    /// official one.
    public static var current: URL {
        get {
            UserDefaults.standard.string(forKey: customKey).flatMap { URL(string: $0) } ?? officialURL
        }
        set {
            if newValue == officialURL {
                UserDefaults.standard.removeObject(forKey: customKey)
            } else {
                UserDefaults.standard.set(newValue.absoluteString, forKey: customKey)
            }
        }
    }

    public static var isOfficial: Bool { current == officialURL }

    public enum AddressProblem: Error, CustomStringConvertible, Equatable {
        case notAnAddress
        case notSecure
        case hasPath

        public var description: String {
            switch self {
            case .notAnAddress: "That isn't a web address. It should look like https://econet.example.org"
            case .notSecure: "The service must use https (http only for a service on this Mac, localhost, while developing)"
            case .hasPath: "Just the service's address, without a path: https://econet.example.org"
            }
        }
    }

    /// A typed address, made a service origin: https, or http for localhost
    /// (a developer's own service, run with `npm run dev`).
    public static func validate(_ typed: String) -> Result<URL, AddressProblem> {
        var text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") { text = "https://" + text }
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), let host = url.host, !host.isEmpty else {
            return .failure(.notAnAddress)
        }
        guard url.path.isEmpty || url.path == "/" else { return .failure(.hasPath) }
        let local = host == "localhost" || host == "127.0.0.1" || host == "::1"
        guard scheme == "https" || (scheme == "http" && local) else { return .failure(.notSecure) }
        return .success(url)
    }

    /// Whether `url` is a local developer service (http, localhost).
    public static func isLocalDevelopment(_ url: URL) -> Bool {
        url.scheme == "http"
    }

    /// A service's origin, as credentials are kept by.
    public static func origin(_ url: URL) -> String {
        var components = URLComponents()
        components.scheme = url.scheme?.lowercased()
        components.host = url.host?.lowercased()
        components.port = url.port
        return components.string ?? url.absoluteString
    }
}

/// What a service says about itself (GET /.well-known/acorn-econet).
public struct ServiceInfo: Codable, Sendable, Equatable {
    public var service: String
    public var name: String
    public var origin: String
    public var apiVersion: Int
    public var protocolVersions: [Int]
    public var minimumProtocolVersion: Int
    public var features: Features
    public var limits: Limits

    public struct Features: Codable, Sendable, Equatable {
        public var privateRooms: Bool
        public var joinCodes: Bool
        public var publicDirectory: Bool
    }

    public struct Limits: Codable, Sendable, Equatable {
        public var maxStationsPerRoom: Int
        public var maxFrameBytes: Int
    }

    /// The protocol version MacBeeb speaks.
    public static let protocolVersion = 1

    /// Why MacBeeb can't use it, if it can't.
    public var incompatibility: String? {
        guard service == "acorn-internet-econet" else { return "It isn't an Internet Econet service" }
        guard protocolVersions.contains(Self.protocolVersion) else {
            return minimumProtocolVersion > Self.protocolVersion
                ? "It needs a newer MacBeeb (protocol \(minimumProtocolVersion) or later)"
                : "It speaks protocol \(protocolVersions.map(String.init).joined(separator: ", ")), and this MacBeeb speaks \(Self.protocolVersion)"
        }
        return nil
    }
}
