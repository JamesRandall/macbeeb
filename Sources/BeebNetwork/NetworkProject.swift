import BeebCore
import Foundation

/// A network of BBC Micros as saved: its machines and what they're for,
/// their hardware, discs and places on the canvas. Configuration only; the
/// machines' running state isn't saved.
public struct NetworkProject: Codable, Sendable, Equatable {
    /// The manifest's format. Older manifests are migrated on load (see
    /// `NetworkPackage`); newer ones are refused rather than half-read.
    public static let currentSchemaVersion = 1

    public var schemaVersion = Self.currentSchemaVersion
    public var id = UUID()
    public var name: String
    /// The Econet's network number: 0, the local network.
    public var networkNumber = 0
    public var nodes: [NetworkNode] = []
    public var canvas = CanvasLayout()
    public var workspace = Workspace()

    public init(name: String, nodes: [NetworkNode] = []) {
        self.name = name
        self.nodes = nodes
    }

    public subscript(id: UUID) -> NetworkNode? {
        get { nodes.first { $0.id == id } }
        set {
            guard let index = nodes.firstIndex(where: { $0.id == id }) else { return }
            if let newValue {
                nodes[index] = newValue
            } else {
                nodes.remove(at: index)
            }
        }
    }

    /// The machines (everything but the clock), in station number order.
    public var stations: [NetworkNode] {
        nodes.filter(\.isMachine).sorted { ($0.stationNumber ?? 0, $0.name) < ($1.stationNumber ?? 0, $1.name) }
    }

    public var hasClock: Bool {
        nodes.contains { $0.kind == .clock }
    }

    /// The lowest station number that's free, from `start`.
    public func freeStationNumber(from start: Int = 1) -> Int? {
        let used = Set(nodes.compactMap(\.stationNumber))
        return (start...254).first { !used.contains($0) } ?? (1...254).first { !used.contains($0) }
    }

    /// A name like "BBC 3" that isn't taken.
    public func freeName(_ base: String) -> String {
        let names = Set(nodes.map(\.name))
        if !names.contains(base) { return base }
        return (2...).lazy.map { "\(base) \($0)" }.first { !names.contains($0) }!
    }

    // MARK: Problems

    /// What's wrong with the network as set up, for the canvas to show.
    public var problems: [NetworkProblem] {
        var problems: [NetworkProblem] = []
        let machines = nodes.filter(\.isMachine)
        for (number, group) in Dictionary(grouping: machines.filter { $0.stationNumber != nil }, by: { $0.stationNumber! })
        where group.count > 1 {
            problems.append(.duplicateStation(number, group.map(\.id)))
        }
        for node in machines {
            if let number = node.stationNumber, !NetworkNode.validStationNumbers.contains(number) {
                problems.append(.reservedStation(number, node.id))
            }
        }
        if machines.count > 1 && !hasClock {
            problems.append(.noClock)
        }
        if nodes.filter({ $0.kind == .clock }).count > 1 {
            problems.append(.twoClocks)
        }
        return problems
    }

    /// Why `number` can't be station `node`'s, if it can't.
    public func stationNumberProblem(_ number: Int, for node: UUID) -> String? {
        guard NetworkNode.validStationNumbers.contains(number) else {
            return "Station numbers go from 1 to 254: 0 and 255 are for broadcasts"
        }
        if let other = nodes.first(where: { $0.id != node && $0.stationNumber == number }) {
            return "\(other.name) is station \(number)"
        }
        return nil
    }
}

/// Something about the network a real one wouldn't work with.
public enum NetworkProblem: Sendable, Equatable, Hashable {
    case duplicateStation(Int, [UUID])
    case reservedStation(Int, UUID)
    case noClock
    case twoClocks

    public var message: String {
        switch self {
        case .duplicateStation(let number, let ids): "\(ids.count) machines are station \(number): each needs its own number"
        case .reservedStation(let number, _): "Station \(number) is reserved: use 1 to 254"
        case .noClock: "No clock: an Econet needs one to carry anything"
        case .twoClocks: "Two clocks: a network has one"
        }
    }

    /// The nodes it's about.
    public var nodes: [UUID] {
        switch self {
        case .duplicateStation(_, let ids): ids
        case .reservedStation(_, let id): [id]
        case .noClock, .twoClocks: []
        }
    }
}

/// One thing on the network: a BBC Micro (an ordinary station, or one that
/// serves files or a printer), or the network's clock.
public struct NetworkNode: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case station, fileServer, printServer, clock

        public var displayName: String {
            switch self {
            case .station: "BBC Micro"
            case .fileServer: "File Server"
            case .printServer: "Printer Server"
            case .clock: "Network Clock"
            }
        }

        /// The usual station number for a server.
        public var conventionalStation: Int? {
            switch self {
            case .fileServer: 254
            case .printServer: 235
            case .station, .clock: nil
            }
        }
    }

    public static let validStationNumbers = 1...254

    /// Stable whatever the station number becomes.
    public var id = UUID()
    public var kind: Kind
    public var name: String
    /// Nil for the clock.
    public var stationNumber: Int?
    /// Nil for the clock.
    public var setup: MachineSetup?
    /// The discs in its drives, by drive.
    public var discs: [Int: MediaReference] = [:]
    /// Its place on the canvas, in canvas points.
    public var position = CanvasPoint()
    /// Whether it's switched on when the network opens.
    public var poweredOn = true
    /// The clock's rate, in bits per second (the clock only).
    public var clockRate: Int?

    public var isMachine: Bool { kind != .clock }

    public init(kind: Kind, name: String, stationNumber: Int?, setup: MachineSetup?, position: CanvasPoint = CanvasPoint()) {
        self.kind = kind
        self.name = name
        self.stationNumber = stationNumber
        self.setup = setup
        self.position = position
        if kind == .clock {
            clockRate = Self.defaultClockRate
        }
    }

    public static func clock(at position: CanvasPoint) -> NetworkNode {
        NetworkNode(kind: .clock, name: "Clock", stationNumber: nil, setup: nil, position: position)
    }

    /// A typical school network's clock: 200 kbit/s.
    public static let defaultClockRate = 200_000
}

/// A disc a station's drive holds: a copy kept in the network's package
/// (so the BBCs never write to the user's own file), and where it came
/// from.
public struct MediaReference: Codable, Sendable, Equatable {
    /// The copy's name in the package's Media folder.
    public var storedName: String
    /// What it was called when it was added.
    public var displayName: String
    /// The original's path, for reference only.
    public var originalPath: String?

    public init(storedName: String, displayName: String, originalPath: String? = nil) {
        self.storedName = storedName
        self.displayName = displayName
        self.originalPath = originalPath
    }
}

public struct CanvasPoint: Codable, Sendable, Equatable, Hashable {
    public var x: Double
    public var y: Double

    public init(x: Double = 0, y: Double = 0) {
        self.x = x
        self.y = y
    }
}

/// How the canvas was last shown.
public struct CanvasLayout: Codable, Sendable, Equatable {
    public var zoom = 1.0
    /// The canvas point at the centre of the view.
    public var centre = CanvasPoint()
    public var snapToGrid = true

    public init() {}
}

/// The tiled workspace: which stations, how many columns.
public struct Workspace: Codable, Sendable, Equatable {
    public var tiles: [UUID] = []
    /// 0 for as many as fit.
    public var columns = 0

    public init() {}
}
