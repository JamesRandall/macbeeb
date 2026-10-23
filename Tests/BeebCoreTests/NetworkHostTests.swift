// Several machines on one NetworkHost: each independent, all in lockstep,
// paused together or one at a time.

import Foundation
import Testing
import BeebCore
import BeebHost
import BeebROMs

/// A network of Model Bs, running as fast as it can.
func modelBNetwork(_ count: Int) -> (NetworkHost, [EmulatorHost]) {
    let network = NetworkHost()
    network.setSpeedLimited(false)
    let configuration = BeebROMs.configuration(for: .modelB)
    let hosts = (0..<count).map { _ in
        network.addStation(id: UUID()) { BBCMicro(configuration: configuration) }
    }
    network.start()
    return (network, hosts)
}

/// Waits (in wall time) until `done`, for up to `seconds`.
func waitFor(_ seconds: Double = 180, _ done: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while !done() {
        if Date() > deadline { return false }
        Thread.sleep(forTimeInterval: 0.01)
    }
    return true
}

func screen(_ host: EmulatorHost) -> String {
    (try? host.perform { $0.machine.screenText().joined(separator: "\n") }) ?? ""
}

struct NetworkHostTests {
    /// Four stations each run their own program and keep their own memory.
    @Test func stationsAreIndependent() throws {
        let (network, hosts) = modelBNetwork(4)
        defer { network.stop() }
        #expect(waitFor { hosts.allSatisfy { screen($0).contains(">") } })
        for (i, host) in hosts.enumerated() {
            try host.perform { $0.machine.type("A%=\(i * 7):?&3000=\(i + 1):PRINT \"STATION \";A%\n") }
        }
        for (i, host) in hosts.enumerated() {
            #expect(waitFor { screen(host).contains("STATION \(i * 7)") }, "\(screen(host))")
            #expect(try host.perform { $0.machine.peek(0x3000) } == UInt8(i + 1))
        }
        // Different machines entirely.
        let ids = try hosts.map { host in try host.perform { ObjectIdentifier($0.machine) } }
        #expect(Set(ids).count == 4)
    }

    /// No station gets more than a quantum ahead of another.
    @Test func stationsRunInLockstep() throws {
        let (network, hosts) = modelBNetwork(3)
        defer { network.stop() }
        #expect(waitFor { network.status.cycles > 0 || hosts[0].cycles > 4_000_000 })
        network.setPaused(true)
        #expect(waitFor { network.status.paused })
        let cycles = try hosts.map { host in try host.perform { $0.machine.cycles } }
        #expect(cycles.max()! - cycles.min()! <= UInt64(network.quantum), "\(cycles)")
        #expect(cycles.min()! > 0)
    }

    /// Pausing the network stops time everywhere; suspending one station
    /// stops only it.
    @Test func pauseAndSuspend() throws {
        let (network, hosts) = modelBNetwork(2)
        defer { network.stop() }
        #expect(waitFor { hosts.allSatisfy { $0.cycles > 2_000_000 } })
        network.setPaused(true)
        #expect(waitFor { network.status.paused })
        let before = try hosts.map { host in try host.perform { $0.machine.cycles } }
        Thread.sleep(forTimeInterval: 0.2)
        let after = try hosts.map { host in try host.perform { $0.machine.cycles } }
        #expect(before == after)

        network.setPaused(false)
        hosts[1].send(.setPaused(true))
        let suspended = try hosts[1].perform { $0.machine.cycles }
        let running = try hosts[0].perform { $0.machine.cycles }
        #expect(waitFor { (try? hosts[0].perform { $0.machine.cycles }) ?? 0 > running + 4_000_000 })
        #expect(try hosts[1].perform { $0.machine.cycles } == suspended)
    }

    /// A debugger stop on one station pauses the whole network, unless
    /// that's turned off.
    @Test func debuggerStopPausesTheNetwork() throws {
        let (network, hosts) = modelBNetwork(2)
        defer { network.stop() }
        #expect(waitFor { hosts.allSatisfy { $0.cycles > 1_000_000 } })
        try hosts[0].perform { $0.machine.debugger.requestStop() }
        #expect(waitFor { network.status.paused && !network.status.stoppedStations.isEmpty })
        let other = try hosts[1].perform { $0.machine.cycles }
        Thread.sleep(forTimeInterval: 0.2)
        #expect(try hosts[1].perform { $0.machine.cycles } == other)

        network.setPauseOnBreakpoint(false)
        #expect(waitFor { (try? hosts[1].perform { $0.machine.cycles }) ?? 0 > other + 2_000_000 })
        try hosts[0].perform { $0.machine.debugger.resume() }
        #expect(waitFor { network.status.stoppedStations.isEmpty })
    }

    /// A station's host can't be started on its own thread as well.
    @Test func stationsDontRunTwice() throws {
        let (network, hosts) = modelBNetwork(1)
        defer { network.stop() }
        hosts[0].start()
        network.setPaused(true)
        #expect(waitFor { network.status.paused })
        let before = try hosts[0].perform { $0.machine.cycles }
        Thread.sleep(forTimeInterval: 0.2)
        #expect(try hosts[0].perform { $0.machine.cycles } == before)
    }

    /// Removing a station stops it; the rest carry on.
    @Test func removeStation() throws {
        let network = NetworkHost()
        network.setSpeedLimited(false)
        let configuration = BeebROMs.configuration(for: .modelB)
        let ids = [UUID(), UUID()]
        let hosts = ids.map { id in network.addStation(id: id) { BBCMicro(configuration: configuration) } }
        network.start()
        defer { network.stop() }
        #expect(waitFor { hosts.allSatisfy { $0.cycles > 1_000_000 } })
        network.removeStation(id: ids[1])
        Thread.sleep(forTimeInterval: 0.05)
        let removed = hosts[1].cycles
        let kept = hosts[0].cycles
        #expect(waitFor { hosts[0].cycles > kept + 2_000_000 })
        #expect(hosts[1].cycles == removed)
    }
}
