// The Distributed Mandelbrot demo, run as its guide says: a file server
// with the programs, workers that boot into WBOOT, and a coordinator
// typing *CLUSTER and *MANDEL. Everything between the machines goes over
// the emulated Econet through Acorn's NFS; the picture on the
// coordinator's screen is checked against the reference, pixel by pixel.

import Foundation
import Testing
@testable import BeebCore
import BeebNetwork
import BeebROMs

extension EconetRig {
    /// Starts Level 1 on machine `index` with the Mandelbrot server disc.
    func startMandelbrotServer(_ index: Int, clients: [Int]) throws {
        try startLevel1FileServer(index, clients: clients, directories: clients.map { _ in "A" },
                                  disc: Disc.fromImage(MandelbrotNetwork.fileServerDisc(), format: .ssd))
    }

    /// Boots machine `index` from the network as the Studio does: logs on
    /// as BOOT and types what the server's !BOOT says.
    func bootFromNetwork(_ index: Int, server: Int = 0) {
        let commands = FileServerDisc.bootCommands(on: machines[server].drives[0].disc!) ?? []
        type(index, (["*NET", "*I AM BOOT"] + commands).map { $0 + "\n" }.joined())
    }

    /// Machine `index`'s MODE 5 screen, a logical colour a pixel.
    func mode5Colours(_ index: Int) -> [UInt8] {
        (0..<256).flatMap { y in
            (0..<160).map { x -> UInt8 in
                let byte = machines[index].peek(UInt16(0x5800 + y / 8 * 320 + x / 4 * 8 + y % 8))
                let p = x % 4
                return (byte >> (7 - p) & 1) << 1 | (byte >> (3 - p) & 1)
            }
        }
    }

    /// What a worker's screen says it's done.
    func tilesDone(_ index: Int) -> Int {
        screen(index).split(separator: "\n").first { $0.contains("Tiles done") }
            .flatMap { Int($0.split(separator: " ").last ?? "") } ?? 0
    }
}

struct MandelbrotNetworkTests {
    static let picture = MandelbrotReference.image().map { UInt8(MandelbrotReference.colour(Int($0), max: 64)) }

    /// Launch, render, launch again, list and stop, from the Guide (station
    /// 1): workers on 2 and 3, and station 4 at BASIC, not prepared.
    @Test func launchRenderAndStop() throws {
        let rig = EconetRig([(.modelB, 254), (.modelB, 1), (.modelB, 2), (.modelB, 3), (.modelB, 4)])
        try rig.startMandelbrotServer(0, clients: [1, 2, 3, 4])
        rig.machines[1].insertDisc(try Disc.fromImage(MandelbrotNetwork.guideDisc(), format: .ssd), drive: 0)
        rig.machines[1].shiftBreak()
        for worker in [2, 3] { rig.bootFromNetwork(worker) }
        #expect(rig.run(until: { [2, 3].allSatisfy { rig.screen($0).contains("Waiting for *CLUSTER") } }), "\(rig.screen(2))")
        #expect(rig.screen(1).contains("DISTRIBUTED MANDELBROT") && rig.screen(1).contains("*CLUSTER"), "\(rig.screen(1))")

        rig.type(1, "*CLUSTER\n")
        #expect(rig.run(until: { rig.screen(1).contains("failed.") }, seconds: 60), "\(rig.screen(1))")
        let launched = rig.screen(1).replacingOccurrences(of: "\n", with: "")
        #expect(launched.contains("02   BOOTSTRAP READY -> START  -> RUNNING"), "\(rig.screen(1))")
        #expect(launched.contains("03   BOOTSTRAP READY -> START  -> RUNNING"), "\(rig.screen(1))")
        #expect(launched.contains("Not prepared: 04 05"), "\(rig.screen(1))")
        #expect(launched.contains("2 workers started. 0 failed."), "\(rig.screen(1))")
        #expect(rig.screen(2).contains("MANDELBROT WORKER") && rig.screen(2).contains("registering"), "\(rig.screen(2))")

        rig.type(1, "*MANDEL\n")
        #expect(rig.run(until: { [2, 3].allSatisfy { rig.screen($0).contains("run complete") } }, seconds: 150),
                "\(rig.screen(2))\n\(rig.screen(3))")
        #expect(rig.mode5Colours(1) == Self.picture)
        // Both did some; between them, all 320.
        #expect(rig.tilesDone(2) > 0 && rig.tilesDone(3) > 0 && rig.tilesDone(2) + rig.tilesDone(3) == 320,
                "\(rig.screen(2))\n\(rig.screen(3))")
        rig.type(1, " ")
        #expect(rig.run(until: { rig.screen(1).contains("Iterations in all  580816") }), "\(rig.screen(1))")
        #expect(rig.screen(1).contains("320 of 320 tiles"), "\(rig.screen(1))")

        // Again: the workers are running already, and stay so.
        rig.type(1, "*CLUSTER\n")
        #expect(rig.run(until: { rig.screen(1).contains("already running.") }, seconds: 60), "\(rig.screen(1))")
        #expect(rig.screen(1).components(separatedBy: "WORKER ALREADY RUNNING").count == 3, "\(rig.screen(1))")
        #expect(rig.screen(1).contains("0 workers started. 0 failed.") && rig.screen(1).contains("2 already running."))
        rig.type(1, "*WORKERS\n")
        #expect(rig.run(until: { rig.screen(1).contains("2 running, 0 waiting.") }, seconds: 60), "\(rig.screen(1))")

        // Stopped: back to their bootstraps, from the file server.
        rig.type(1, "*STOPWK\n")
        #expect(rig.run(until: { rig.screen(1).contains("2 stopped.") }, seconds: 60), "\(rig.screen(1))")
        #expect(rig.run(until: { [2, 3].allSatisfy { rig.screen($0).contains("Worker bootstrap (WBOOT)") } }),
                "\(rig.screen(2))")
    }

    /// A worker switched off part way: its tile goes to the other after
    /// the timeout. Switched on again and booted, MANDEL starts it and it
    /// joins in. The picture's still right.
    @Test func workerLostAndJoining() throws {
        let rig = EconetRig([(.modelB, 254), (.modelB, 1), (.modelB, 2), (.modelB, 3)])
        try rig.startMandelbrotServer(0, clients: [1, 2, 3])
        for worker in [2, 3] { rig.bootFromNetwork(worker) }
        #expect(rig.run(until: { [2, 3].allSatisfy { rig.screen($0).contains("Waiting for *CLUSTER") } }))
        rig.type(1, "*NET\n")
        rig.type(1, "*CLUSTER\n")
        #expect(rig.run(until: { rig.screen(1).contains("2 workers started.") }, seconds: 60), "\(rig.screen(1))")
        rig.type(1, "*MANDEL\n")
        #expect(rig.run(until: { rig.tilesDone(3) >= 20 }, seconds: 90), "\(rig.screen(3))")
        rig.powerOff(3)
        rig.run(seconds: 2)
        rig.powerOn(3)
        rig.run(seconds: 1.5)
        rig.bootFromNetwork(3)
        #expect(rig.run(until: { rig.screen(2).contains("run complete") }, seconds: 150), "\(rig.screen(2))")
        #expect(rig.mode5Colours(1) == Self.picture)
        // The new one was recruited and did some.
        #expect(rig.tilesDone(3) > 0, "\(rig.screen(3))")
        rig.type(1, " ")
        #expect(rig.run(until: { rig.screen(1).contains("Iterations in all") }), "\(rig.screen(1))")
        #expect(rig.screen(1).contains("320 of 320 tiles"), "\(rig.screen(1))")
    }
}

/// How long a render takes, in emulated time, by the number of workers
/// (MANDELBROT_BENCH=1; for docs/network-studio's figures).
struct MandelbrotBenchmark {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MANDELBROT_BENCH"] != nil),
          arguments: [1, 2, 4, 8])
    func render(workers: Int) throws {
        let stations = Array(2..<(2 + workers))
        let rig = EconetRig([(.modelB, 254), (.modelB, 1)] + stations.map { (.modelB, $0) })
        try rig.startMandelbrotServer(0, clients: [1] + stations)
        for index in 2..<(2 + workers) { rig.bootFromNetwork(index) }
        rig.run(until: { (2..<(2 + workers)).allSatisfy { rig.screen($0).contains("Waiting for *CLUSTER") } }, seconds: 60)
        rig.type(1, "*NET\n")
        rig.type(1, "*CLUSTER\n")
        rig.run(until: { rig.screen(1).contains("failed.") }, seconds: 120)
        rig.type(1, "*MANDEL\n")
        let wall = Date()
        #expect(rig.run(until: { rig.screen(2).contains("run complete") }, seconds: 600))
        rig.type(1, " ")
        rig.run(until: { rig.screen(1).contains("Iterations in all") })
        let line = rig.screen(1).split(separator: "\n").first { $0.contains("of 320 tiles") } ?? ""
        print("BENCH \(workers) workers: \(line.trimmingCharacters(in: .whitespaces)) (\(Int(Date().timeIntervalSince(wall)))s wall)")
    }
}
