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
