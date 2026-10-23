import BeebCore
import Foundation

/// Ready-made networks to start from.
public enum NetworkTemplate: String, CaseIterable, Sendable, Identifiable {
    case econetDemo, twoBBCs, schoolClassroom, bbcAndMaster, empty

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .econetDemo: "Econet Demo"
        case .twoBBCs: "Two BBCs"
        case .schoolClassroom: "School Classroom"
        case .bbcAndMaster: "BBC and Master"
        case .empty: "Empty Network"
        }
    }

    public var summary: String {
        switch self {
        case .econetDemo: "A classroom ready to try: a welcome screen, and programs on the file server to chat, sign a shared visitors' book and print."
        case .twoBBCs: "The smallest network: two Model Bs, stations 1 and 2, and a clock."
        case .schoolClassroom: "Four Model Bs, a file server on station 254 and a printer server on 235, as a 1980s school had."
        case .bbcAndMaster: "A Model B and a Master 128 side by side, sharing a file server."
        case .empty: "Just the clock. Add machines from the palette."
        }
    }

    public var symbolName: String {
        switch self {
        case .econetDemo: "sparkles"
        case .twoBBCs: "rectangle.on.rectangle"
        case .schoolClassroom: "building.columns"
        case .bbcAndMaster: "rectangle.split.2x1"
        case .empty: "square.dashed"
        }
    }

    /// Canvas spacing between machines.
    static let spacing = 260.0

    public func makeProject() -> NetworkProject {
        let modelB = MachineSetup(model: .modelB)
        func station(_ name: String, _ number: Int, _ x: Double, _ y: Double, setup: MachineSetup = modelB) -> NetworkNode {
            NetworkNode(kind: .station, name: name, stationNumber: number, setup: setup, position: CanvasPoint(x: x, y: y))
        }
        func server(_ kind: NetworkNode.Kind, _ x: Double, _ y: Double) -> NetworkNode {
            NetworkNode(kind: kind, name: kind.displayName, stationNumber: kind.conventionalStation, setup: modelB,
                        position: CanvasPoint(x: x, y: y))
        }
        let s = Self.spacing
        var project = NetworkProject(name: title)
        switch self {
        case .econetDemo:
            var welcome = station("Welcome", 1, -1.5 * s, 0)
            welcome.bootsDisc = true
            project.nodes = [welcome, station("BBC 2", 2, -0.5 * s, 0), station("BBC 3", 3, 0.5 * s, 0),
                             station("Master 4", 4, 1.5 * s, 0, setup: MachineSetup(model: .master128)),
                             server(.fileServer, -s / 2, 330), server(.printServer, s / 2, 330), .clock(at: CanvasPoint(x: 1.5 * s + 40, y: 330))]
        case .twoBBCs:
            project.nodes = [station("BBC 1", 1, -s / 2, 0), station("BBC 2", 2, s / 2, 0), .clock(at: CanvasPoint(x: 0, y: 200))]
        case .schoolClassroom:
            project.nodes = (0..<4).map { station("BBC \($0 + 1)", $0 + 1, (Double($0) - 1.5) * s, 0) }
                + [server(.fileServer, -s / 2, 330), server(.printServer, s / 2, 330), .clock(at: CanvasPoint(x: 1.5 * s + 40, y: 330))]
        case .bbcAndMaster:
            project.nodes = [station("BBC", 1, -s / 2, 0), station("Master", 2, s / 2, 0, setup: MachineSetup(model: .master128)),
                             server(.fileServer, 0, 330), .clock(at: CanvasPoint(x: s, y: 330))]
        case .empty:
            project.nodes = [.clock(at: CanvasPoint())]
        }
        project.workspace.tiles = project.stations.filter { $0.kind == .station }.map(\.id)
        return project
    }

    /// The discs a template's machines start with, for `NetworkPackage`
    /// to put in the package: (node, drive, file name, image).
    public func discs(for project: NetworkProject) throws -> [(node: UUID, drive: Int, name: String, image: [UInt8])] {
        guard self == .econetDemo else { return [] }
        var discs: [(UUID, Int, String, [UInt8])] = []
        if let welcome = project.nodes.first(where: { $0.bootsDisc == true }) {
            discs.append((welcome.id, 0, "Welcome.ssd", try DemoNetwork.welcomeDisc()))
        }
        if let server = project.nodes.first(where: { $0.kind == .fileServer }) {
            discs.append((server.id, 0, "File Server.ssd", try DemoNetwork.fileServerDisc()))
        }
        return discs
    }
}
