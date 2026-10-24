// Two networks, each its own line with its own BBCs, joined through their
// Internet gateways by a simulated room that delivers each message after a
// delay (in emulated time, so runs repeat exactly). Everything between
// them is Acorn's own network software: DNFS, ANFS and the file servers.

import Foundation
import Testing
@testable import BeebCore
import BeebNetwork
import BeebROMs

final class GatewayRig {
    let sides: [EconetRig]
    let gateways: [EconetGateway]
    /// One-way delay, in cycles.
    var latency: Int
    /// Up to this much more, at random (each direction stays in order, as
    /// one WebSocket over TCP does).
    var jitter = 0
    /// Messages to lose (by their count from the start), as a dropped
    /// connection loses what was in flight.
    var drop: Set<Int> = []
    private var generator = SeededGenerator(seed: 6502)
    private var lastArrival = [0, 0]
    /// Messages in flight: when they arrive, and where.
    private var inFlight: [(at: Int, side: Int, message: EconetGatewayMessage)] = []
    private var now = 0
    /// Every message sent, for checking what crossed.
    private(set) var sent: [(side: Int, message: EconetGatewayMessage)] = []

    /// `latency` in milliseconds, one way.
    init(_ a: [(BBCMicro.Model, Int)], _ b: [(BBCMicro.Model, Int)], latency milliseconds: Double = 0) {
        sides = [EconetRig(a), EconetRig(b)]
        latency = Int(milliseconds * 2000)
        var gateways: [EconetGateway] = []
        for _ in 0..<2 { gateways.append(EconetGateway()) }
        self.gateways = gateways
        for (index, gateway) in gateways.enumerated() {
            gateway.remoteStations = Set(sides[1 - index].machines.compactMap { $0.econet?.station })
            gateway.send = { [unowned self] message in
                sent.append((index, message))
                if drop.contains(sent.count) { return }
                let extra = jitter > 0 ? Int.random(in: 0...jitter, using: &generator) : 0
                let at = max(lastArrival[index], now + self.latency + extra)
                lastArrival[index] = at
                inFlight.append((at, 1 - index, message))
            }
            sides[index].bus.attach(device: gateway)
        }
    }

    /// Runs both networks, quantum by quantum, delivering what's due.
    func run(cycles: Int) {
        let quantum = sides[0].bus.delay
        var left = cycles
        while left > 0 {
            let due = inFlight.filter { $0.at <= now }
            inFlight.removeAll { $0.at <= now }
            for item in due { gateways[item.side].receive(item.message) }
            for side in sides { side.run(cycles: quantum) }
            now += quantum
            left -= quantum
        }
    }

    func run(seconds: Double) { run(cycles: Int(seconds * 2_000_000)) }

    @discardableResult
    func run(until done: () -> Bool, seconds: Double = 30) -> Bool {
        var elapsed = 0.0
        while !done() {
            if elapsed >= seconds { return false }
            run(seconds: 0.01)
            elapsed += 0.01
        }
        run(seconds: 0.2)
        return true
    }

    func screen(_ side: Int, _ index: Int) -> String { sides[side].screen(index) }

    /// Whether a line on the screen starts with `prefix` (not the program
    /// listing, which has it in quotes).
    func shows(_ side: Int, _ index: Int, _ prefix: String) -> Bool {
        sides[side].machines[index].screenText().contains { $0.hasPrefix(prefix) }
    }

    func type(_ side: Int, _ index: Int, _ text: String) {
        sides[side].machines[index].type(text)
        run(until: { !sides[side].machines[index].isTyping }, seconds: 60)
    }

    /// Types a line and waits for the prompt (both networks running).
    func command(_ side: Int, _ index: Int, _ line: String, seconds: Double = 60) {
        type(side, index, line + "\n")
        run(until: { sides[side].lastLines(index, 1) == ">" }, seconds: seconds)
    }

    func runProgram(_ side: Int, _ index: Int, _ program: String) {
        type(side, index, "NEW\n")
        for line in program.split(separator: "\n") { type(side, index, line + "\n") }
        type(side, index, "RUN\n")
    }
}

struct EconetGatewayTests {
    /// OSWORD &10 on one network to OSWORD &11 on the other: the full
    /// handshake, through both gateways, at Internet latencies.
    @Test(arguments: [0.0, 20, 80, 250])
    func sendAndReceiveAcrossTheInternet(latency: Double) {
        let rig = GatewayRig([(.modelB, 1)], [(.modelB, 2)], latency: latency)
        rig.run(seconds: 1.5)
        rig.runProgram(1, 0, econetReceiver)
        #expect(rig.run(until: { rig.screen(1, 0).contains("OPEN") }), "\(rig.screen(1, 0))")
        rig.runProgram(0, 0, econetSender(to: 2))
        #expect(rig.run(until: { rig.shows(0, 0, "RESULT ") }), "\(rig.screen(0, 0))")
        #expect(rig.screen(0, 0).contains("RESULT 0"), "\(rig.screen(0, 0))")
        #expect(rig.run(until: { rig.shows(1, 0, "FROM ") }), "\(rig.screen(1, 0))")
        #expect(rig.screen(1, 0).contains("FROM 1 GOT HELLO ECONET"), "\(rig.screen(1, 0))")
        // Four frames crossed, two each way.
        let frames = rig.sent.filter { if case .frame = $0.message { true } else { false } }
        #expect(frames.map(\.side) == [0, 1, 0, 1], "\(rig.sent)")
    }

    /// Nobody listening on the far side: the sender's told so, as it would
    /// be on one network.
    @Test func notListeningAcrossTheInternet() {
        let rig = GatewayRig([(.modelB, 1)], [(.modelB, 2)], latency: 40)
        rig.run(seconds: 1.5)
        rig.runProgram(0, 0, econetSender(to: 2))
        #expect(rig.run(until: { rig.shows(0, 0, "RESULT ") }), "\(rig.screen(0, 0))")
        #expect(rig.screen(0, 0).contains("RESULT 66"), "\(rig.screen(0, 0))")
    }
}

/// Immediate operations and a file server, across.
struct EconetGatewayServiceTests {
    /// POKE then JSR across the Internet: NFS on the far BBC does them, as
    /// Distributed Mandelbrot's CLUSTER starts its workers.
    @Test func pokeAndJSRAcross() {
        let rig = GatewayRig([(.modelB, 1)], [(.modelB, 2)], latency: 80)
        rig.run(seconds: 1.5)
        rig.runProgram(0, 0, """
        10 S%=&3000:FOR I%=0 TO 9:READ D%:S%?I%=D%:NEXT
        20 DATA &A9,&8A,&A2,0,&A0,&41,&20,&F4,&FF,&60
        30 C%=&3100:C%?1=0:C%?2=2:C%?3=0:C%!12=&A00
        40 ?C%=&82:C%!4=&FFFF3000:C%!8=&FFFF300A:PROCgo
        50 ?C%=&83:C%!4=&FFFF3000:C%!8=&FFFF3001:PROCgo
        60 END
        70 DEF PROCgo:X%=C%:Y%=C%DIV256:A%=&10:CALL &FFF1
        80 REPEAT A%=&32:U%=USR&FFF4:UNTIL (U%AND&8000)=0
        90 PRINT "RESULT ";(U% DIV 256) AND 255:ENDPROC
        """)
        #expect(rig.run(until: { rig.screen(0, 0).components(separatedBy: "\nRESULT 0").count == 3 }), "\(rig.screen(0, 0))")
        #expect((0..<10).map { rig.sides[1].machines[0].peek(UInt16(0xA00 + $0)) } == [0xA9, 0x8A, 0xA2, 0, 0xA0, 0x41, 0x20, 0xF4, 0xFF, 0x60])
        #expect(rig.run(until: { rig.sides[1].lastLines(0, 1) == ">A" }, seconds: 2), "\(rig.screen(1, 0))")
    }

    /// PEEK and machine type: two frames each, the answer carrying data.
    @Test func peekAndMachineTypeAcross() {
        let rig = GatewayRig([(.modelB, 1)], [(.master128, 2)], latency: 80)
        rig.run(seconds: 1.5)
        rig.sides[1].machines[0].poke(0x2000, 0x5A)
        rig.sides[1].machines[0].poke(0x2001, 0xC3)
        rig.runProgram(0, 0, """
        10 C%=&3100:C%?1=0:C%?2=2:C%?3=0
        20 ?C%=&81:C%!4=&FFFF3000:C%!8=&FFFF3002:C%!12=&FFFF2000:PROCgo
        30 PRINT "PEEK ";~?&3000;" ";~?&3001
        40 ?C%=&88:C%!4=&FFFF3000:C%!8=&FFFF3004:PROCgo
        50 PRINT "TYPE ";~!&3000
        60 END
        70 DEF PROCgo:X%=C%:Y%=C%DIV256:A%=&10:CALL &FFF1
        80 REPEAT A%=&32:U%=USR&FFF4:UNTIL (U%AND&8000)=0
        90 PRINT "RESULT ";(U% DIV 256) AND 255:ENDPROC
        """)
        #expect(rig.run(until: { rig.shows(0, 0, "TYPE ") }), "\(rig.screen(0, 0))")
        #expect(rig.shows(0, 0, "PEEK 5A C3"), "\(rig.screen(0, 0))")
        // The Master answers as one (ANFS's machine type).
        #expect(!rig.shows(0, 0, "TYPE 0"), "\(rig.screen(0, 0))")
        #expect(rig.screen(0, 0).components(separatedBy: "\nRESULT 0").count == 3, "\(rig.screen(0, 0))")
    }

    /// Acorn's Level 2 file server on one network; a Model B (DNFS) and a
    /// Master (ANFS) on the other log on, save, catalogue and load, with
    /// 80ms each way.
    @Test func level2FileServerAcross() throws {
        let rig = GatewayRig([(.modelB, 1), (.master128, 2)], [(.modelB, 254)], latency: 80)
        var disc = try Level2FileServerDisc(name: "REMOTE", users: ["ALICE", "BOB"], date: EconetRig.level2Date)
        try disc.setPassword("SECRET", for: "ALICE")
        try rig.sides[1].startLevel2FileServer(0, disc: disc)
        rig.run(seconds: 1.5)
        defer { print("STATION 1:\n\(rig.screen(0, 0))\nSTATION 2:\n\(rig.screen(0, 1))\nSERVER:\n\(rig.screen(1, 0))") }

        rig.command(0, 0, "*NET")
        rig.command(0, 0, "*I AM ALICE")
        #expect(rig.sides[0].lastLines(0, 2) == "Wrong password\n>", "\(rig.screen(0, 0))")
        rig.command(0, 0, "*I AM ALICE SECRET")
        rig.command(0, 0, "10 PRINT \"HELLO ACROSS THE INTERNET\"")
        rig.command(0, 0, "SAVE \"HELLO\"")
        rig.command(0, 0, "*ACCESS HELLO WR/R")
        rig.command(0, 0, "*CAT")
        #expect(rig.screen(0, 0).contains("REMOTE") && rig.screen(0, 0).contains("HELLO"), "\(rig.screen(0, 0))")

        rig.command(0, 1, "*NET")
        rig.command(0, 1, "*I AM BOB")
        rig.command(0, 1, "CHAIN \"$.ALICE.HELLO\"")
        #expect(rig.screen(0, 1).contains("HELLO ACROSS THE INTERNET"), "\(rig.screen(0, 1))")
        rig.command(0, 1, "SAVE \"$.ALICE.NOPE\"")
        #expect(rig.screen(0, 1).contains("Insufficient access"), "\(rig.screen(0, 1))")
    }
}

/// A random number generator that repeats: so do the tests.
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state ^ (state >> 33)
    }
}

/// Printing, and the file server when the Internet's less kind.
struct EconetGatewayConditionsTests {
    /// MacBeeb's printer server on one network, a station on the other
    /// printing with its own NFS (*FX5,4, VDU 2 ... VDU 3).
    @Test func printsAcross() throws {
        let rig = GatewayRig([(.modelB, 1)], [(.modelB, 235)], latency: 80)
        let printed = try rig.sides[1].startPrinterServer(0)
        rig.run(seconds: 1.5)
        rig.type(0, 0, "*FX5,4\n")
        rig.type(0, 0, "VDU 2:PRINT \"PRINTED ACROSS THE INTERNET\":PRINT \"SECOND LINE\":VDU 3\n")
        #expect(rig.run(until: { rig.screen(1, 0).contains("Printed") }, seconds: 90), "\(rig.screen(1, 0))")
        #expect(printed.text == "PRINTED ACROSS THE INTERNET\rSECOND LINE\r", "\(printed.text.debugDescription)")
        #expect(rig.screen(1, 0).contains("Job from station 1"))
    }

    /// 20 to 150ms each way, varying: log on, save, load.
    @Test func level2WithJitter() throws {
        let rig = GatewayRig([(.modelB, 1)], [(.modelB, 254)], latency: 20)
        rig.jitter = 130 * 2000
        let disc = try Level2FileServerDisc(name: "JITTER", users: ["ALICE"], date: EconetRig.level2Date)
        try rig.sides[1].startLevel2FileServer(0, disc: disc)
        rig.run(seconds: 1.5)
        rig.command(0, 0, "*NET")
        rig.command(0, 0, "*I AM ALICE")
        rig.command(0, 0, "FOR I%=0 TO 1023:I%?&3000=(I%*7+3) AND 255:NEXT")
        rig.command(0, 0, "*SAVE DATA 3000+400")
        rig.command(0, 0, "FOR I%=0 TO 1023:I%?&3000=0:NEXT")
        rig.command(0, 0, "*LOAD DATA")
        let machine = rig.sides[0].machines[0]
        let loaded: [UInt8] = (0..<1024).map { machine.peek(UInt16(0x3000 + $0)) }
        let pattern: [UInt8] = (0..<1024).map { UInt8(($0 * 7 + 3) & 255) }
        #expect(loaded == pattern, "\(rig.screen(0, 0))")
    }

    /// A message lost on the way (a connection dropping mid-transaction):
    /// that transaction fails as on a real network (the line goes quiet
    /// after the hold), NFS reports or retries it, and the next works.
    @Test func recoversFromALostMessage() throws {
        let rig = GatewayRig([(.modelB, 1)], [(.modelB, 254)], latency: 40)
        let disc = try Level2FileServerDisc(name: "LOSSY", users: ["ALICE"], date: EconetRig.level2Date)
        try rig.sides[1].startLevel2FileServer(0, disc: disc)
        rig.run(seconds: 1.5)
        rig.command(0, 0, "*NET")
        rig.command(0, 0, "*I AM ALICE")
        // Lose the next message but one.
        rig.drop = [rig.sent.count + 2]
        rig.command(0, 0, "*CAT", seconds: 30)
        rig.command(0, 0, "*CAT", seconds: 30)
        #expect(rig.screen(0, 0).contains("ALICE"), "\(rig.screen(0, 0))")
        #expect(rig.gateways.allSatisfy { $0.activity == .idle })
    }
}

struct EconetGatewayDebug {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ECONET_DEBUG"] != nil))
    func level2LogOn() throws {
        let rig = GatewayRig([(.master128, 2)], [(.modelB, 254)], latency: 80)
        let disc = try Level2FileServerDisc(name: "REMOTE", users: ["ALICE", "BOB"], date: EconetRig.level2Date)
        try rig.sides[1].startLevel2FileServer(0, disc: disc)
        rig.run(seconds: 1.5)
        var log: [String] = []
        var cycles = 0
        for side in 0..<2 {
            let old = rig.gateways[side].send
            rig.gateways[side].send = { m in log.append("\(side) \(m)"); old(m) }
        }
        let traces = [EconetTrace(), EconetTrace()]
        for side in 0..<2 { rig.sides[side].bus.observer = { traces[side].observe($0) } }
        _ = cycles
        rig.command(0, 0, "*NET")
        rig.command(0, 0, "*I AM BOB")
        print(rig.screen(0, 0))
        print(log.joined(separator: "\n"))
        for side in 0..<2 {
            print("SIDE \(side)")
            print(traces[side].frames.map { "\($0.start) \($0.transmitter)->\($0.destinationStation ?? 0) \($0.bytes.count) \($0.status) \($0.bytes.prefix(8).map { String(format: "%02X", $0) }.joined(separator: " "))" }.joined(separator: "\n"))
        }
        print(rig.gateways.map { "\($0.counters)" })
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ECONET_DEBUG"] != nil))
    func slow() {
        let rig = GatewayRig([(.modelB, 1)], [(.modelB, 2)], latency: 250)
        let trace = EconetTrace()
        rig.sides[1].bus.observer = { trace.observe($0) }
        rig.run(seconds: 1.5)
        rig.runProgram(1, 0, econetReceiver)
        rig.run(until: { rig.screen(1, 0).contains("OPEN") })
        rig.runProgram(0, 0, econetSender(to: 2))
        rig.run(until: { rig.screen(0, 0).contains("RESULT") })
        rig.run(seconds: 2)
        print(rig.screen(0, 0)); print(rig.screen(1, 0))
        print(rig.gateways.map { "\($0.activity) \($0.counters)" })
        print(rig.sent)
        print(trace.frames.map { "\($0.start) \($0.transmitter)->\($0.destinationStation ?? 0) \($0.bytes.count) \($0.status)" }.joined(separator: "\n"))
    }
}
