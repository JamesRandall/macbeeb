// Network projects: templates, validation, the .macbeebnet package, and
// a runtime that runs a project's machines.

import Foundation
import Testing
import BeebCore
import BeebHost
import BeebNetwork
import BeebROMs

func temporaryPackage() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("net-\(UUID().uuidString).\(NetworkPackage.fileExtension)")
}

struct NetworkProjectTests {
    @Test(arguments: NetworkTemplate.allCases)
    func templatesAreSound(template: NetworkTemplate) {
        let project = template.makeProject()
        #expect(project.problems.isEmpty, "\(project.problems)")
        #expect(project.hasClock)
        #expect(project.name == template.title)
    }

    @Test func schoolClassroomHasTheUsualServers() {
        let project = NetworkTemplate.schoolClassroom.makeProject()
        #expect(project.stations.filter { $0.kind == .station }.map(\.stationNumber) == [1, 2, 3, 4])
        #expect(project.nodes.first { $0.kind == .fileServer }?.stationNumber == 254)
        #expect(project.nodes.first { $0.kind == .printServer }?.stationNumber == 235)
        #expect(project.workspace.tiles.count == 4)
    }

    @Test func problemsAreFound() {
        var project = NetworkTemplate.twoBBCs.makeProject()
        let second = project.stations[1].id
        project[second]?.stationNumber = 1
        #expect(project.problems.contains { if case .duplicateStation(1, _) = $0 { true } else { false } })
        #expect(project.stationNumberProblem(1, for: second) == "BBC 1 is station 1")
        #expect(project.stationNumberProblem(255, for: second) != nil)
        #expect(project.stationNumberProblem(3, for: second) == nil)
        project.nodes.removeAll { $0.kind == .clock }
        #expect(project.problems.contains(.noClock))
        #expect(project.freeStationNumber() == 2)
        #expect(project.freeName("BBC 1") == "BBC 1 2")
    }

    @Test func packageRoundTrips() throws {
        let url = temporaryPackage()
        defer { try? FileManager.default.removeItem(at: url) }
        var project = NetworkTemplate.bbcAndMaster.makeProject()
        project.canvas.zoom = 0.75
        project.nodes[0].setup?.expansions = .init(board: .watford32K)
        try NetworkPackage.save(project, to: url)
        #expect(try NetworkPackage.load(from: url) == project)
        #expect(FileManager.default.fileExists(atPath: NetworkPackage.mediaURL(in: url).path))
    }

    @Test func newerAndBrokenPackagesAreRefused() throws {
        let url = temporaryPackage()
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: NetworkPackage.LoadError.self) { try NetworkPackage.load(from: url) }
        var project = NetworkTemplate.empty.makeProject()
        project.schemaVersion = NetworkProject.currentSchemaVersion + 1
        try NetworkPackage.save(project, to: url)
        #expect {
            try NetworkPackage.load(from: url)
        } throws: { error in
            "\(error)".contains("newer MacBeeb")
        }
    }

    /// A station writes to the package's copy of its disc, never the user's
    /// original.
    @Test func stationsWriteToThePackagesCopy() throws {
        let url = temporaryPackage()
        defer { try? FileManager.default.removeItem(at: url) }
        let original = FileManager.default.temporaryDirectory.appendingPathComponent("orig-\(UUID().uuidString).ssd")
        defer { try? FileManager.default.removeItem(at: original) }
        let blank = BlankDisc.dfs80.image(title: "NET")
        try Data(blank).write(to: original)

        var project = NetworkTemplate.twoBBCs.makeProject()
        try NetworkPackage.save(project, to: url)
        let media = try NetworkPackage.importMedia(original, into: url)
        project.nodes[0].discs[0] = media
        try NetworkPackage.save(project, to: url)

        let runtime = NetworkRuntime(packageURL: url, clockRate: NetworkRuntime.clockRate(of: project))
        runtime.network.setSpeedLimited(false)
        let host = try #require(runtime.powerOn(project.nodes[0]))
        runtime.powerOn(project.nodes[1])
        runtime.start()
        defer { runtime.stop() }
        #expect(waitFor { screen(host).contains(">") })
        try host.perform { $0.machine.type("SAVE \"PROG\"\n") }
        let copy = NetworkPackage.url(of: media, in: url)
        #expect(waitFor { (try? Data(contentsOf: copy)) != Data(blank) })
        #expect(try Data(contentsOf: original) == Data(blank))
        #expect(NetworkPackage.unusedMedia(of: project, in: url).isEmpty)
        runtime.powerOff(project.nodes[0].id)
        #expect(runtime.stations.count == 1)
    }
}

/// Where new machines go: along the trunk, not on top of each other.
struct NetworkPlacingTests {
    @Test func newStationsExtendTheTopRow() {
        var project = NetworkTemplate.schoolClassroom.makeProject()
        var placed: [CanvasPoint] = []
        for _ in 0..<5 {
            let point = project.nextPosition(for: .station)
            placed.append(point)
            project.nodes.append(NetworkNode(kind: .station, name: "New", stationNumber: project.freeStationNumber(),
                                             setup: MachineSetup(), position: point))
        }
        let topRow = project.nodes.first { $0.name == "BBC 1" }!.position.y
        #expect(placed.allSatisfy { $0.y == topRow })
        #expect(zip(placed, placed.dropFirst()).allSatisfy { $1.x - $0.x == NetworkProject.columnSpacing })
        let rightmost = project.nodes.filter { $0.name.hasPrefix("BBC") }.map(\.position.x).max()!
        #expect(placed[0].x == rightmost + NetworkProject.columnSpacing)
    }

    @Test func serversGoAlongTheRowBelow() {
        let project = NetworkTemplate.schoolClassroom.makeProject()
        let point = project.nextPosition(for: .fileServer)
        let serverRow = project.nodes.first { $0.kind == .fileServer }!.position.y
        #expect(point.y == serverRow)
        #expect(!project.nodes.contains { abs($0.position.x - point.x) < 236 && abs($0.position.y - point.y) < 230 })
    }

    @Test func dropsOnACardMoveAlong() {
        let project = NetworkTemplate.twoBBCs.makeProject()
        let first = project.nodes[0].position
        let moved = project.freePosition(near: first)
        #expect(moved.y == first.y && moved.x > first.x)
        #expect(project.freePosition(near: CanvasPoint(x: 5000, y: 5000)) == CanvasPoint(x: 5000, y: 5000))
    }

    @Test func emptyNetwork() {
        let project = NetworkTemplate.empty.makeProject()
        let station = project.nextPosition(for: .station)
        #expect(!project.nodes.contains { abs($0.position.x - station.x) < 236 && abs($0.position.y - station.y) < 230 })
    }
}

struct DemoTemplateTests {
    /// The demo's discs go in its package: the Welcome machine's, which
    /// it boots, and the file server's, with the programs in directory A.
    @Test func demoNetworkHasItsDiscs() throws {
        let url = temporaryPackage()
        defer { try? FileManager.default.removeItem(at: url) }
        let project = try NetworkPackage.create(.econetDemo, at: url)
        #expect(try NetworkPackage.load(from: url) == project)
        let welcome = try #require(project.nodes.first { $0.bootsDisc == true })
        let server = try #require(project.nodes.first { $0.kind == .fileServer })
        for (node, name) in [(welcome, "WELCOME"), (server, "A.CHAT")] {
            let media = try #require(node.discs[0])
            let data = try Data(contentsOf: NetworkPackage.url(of: media, in: url))
            let volume = try DiscVolume(disc: Disc.fromImage([UInt8](data), format: .ssd))
            #expect(try volume.items(at: .init()).contains { $0.name == name }, "\(name)")
        }
        #expect(project.nodes.contains { $0.setup?.model == .master128 })
    }

    /// The Distributed Mandelbrot: a Guide that boots its disc, eight
    /// workers that only switch on (*CLUSTER takes them over), and a Level 2
    /// file server with the programs in its library.
    @Test func mandelbrotNetworkHasItsDiscs() throws {
        let url = temporaryPackage()
        defer { try? FileManager.default.removeItem(at: url) }
        let project = try NetworkPackage.create(.distributedMandelbrot, at: url)
        #expect(try NetworkPackage.load(from: url) == project)
        let workers = project.nodes.filter { $0.kind == .station && $0.bootsDisc != true }
        #expect(workers.compactMap(\.stationNumber) == Array(MandelbrotNetwork.workers))
        #expect(workers.allSatisfy { $0.bootsNetwork != true && $0.discs.isEmpty })
        let guide = try #require(project.nodes.first { $0.bootsDisc == true })
        #expect(guide.stationNumber == 1)
        let server = try #require(project.nodes.first { $0.kind == .fileServer })
        #expect(server.level == .level2 && server.setup?.secondProcessor == true)
        let guideDisc = try Disc.fromImage([UInt8](Data(contentsOf: NetworkPackage.url(of: #require(guide.discs[0]), in: url))), format: .ssd)
        #expect(Set(try DiscVolume(disc: guideDisc).items(at: .init()).map(\.name)) == ["GUIDE", "!BOOT"])
        let disc = try Level2FileServerDisc(image: [UInt8](Data(contentsOf: NetworkPackage.url(of: #require(server.discs[0]), in: url))))
        // Every program, with this network's own CLUSTER (Mandelbrot in
        // Colour's, CLUSTC, isn't on it).
        #expect(Set(try disc.entries(in: "$.LIBRARY").map(\.name)) == Set(MandelbrotGuest.files.map(\.name)).subtracting(["CLUSTC"]))
        let colour = try MandelbrotNetwork.fileServerDisc(for: .mode2)
        let cluster = try #require(MandelbrotGuest.files.first { $0.name == "CLUSTC" })
        #expect(Set(try colour.entries(in: "$.LIBRARY").map(\.name)) == Set(MandelbrotGuest.files.map(\.name)).subtracting(["CLUSTC"]))
        #expect(try colour.contents(of: "$.LIBRARY.CLUSTER") == cluster.contents)
        #expect(disc.users.map(\.name) == ["SYST", "GUEST"])
        #expect(try disc.entries(in: "$.GUEST").map(\.name) == ["GUIDE", "GUIDE2"])
    }
}
