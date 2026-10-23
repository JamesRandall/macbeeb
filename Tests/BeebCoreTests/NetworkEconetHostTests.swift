// Econet through NetworkHost (threads, as the app runs it), not the
// single-threaded rig.

import Foundation
import Testing
@testable import BeebCore
import BeebHost
import BeebROMs

struct NetworkEconetHostTests {
    /// A Master on the network uses its own station number (ANFS takes it
    /// from CMOS RAM), so it doesn't answer for another station: a Model B's
    /// *CAT still works with one there.
    @Test func masterDoesntTakeAnotherStationsNumber() throws {
        let network = NetworkHost(econetClockRate: .some(200_000))
        network.setSpeedLimited(false)
        var hosts: [Int: EmulatorHost] = [:]
        for (station, model) in [(1, BBCMicro.Model.modelB), (254, .modelB), (5, .master128)] {
            let configuration = BeebROMs.configuration(for: model, econetStation: station)
            hosts[station] = network.addStation(id: UUID()) { BBCMicro(configuration: configuration) }
        }
        network.start()
        defer { network.stop() }
        #expect(waitFor { screen(hosts[5]!).contains("BASIC") })
        #expect(!screen(hosts[5]!).contains("Badly configured"), "\(screen(hosts[5]!))")
        let level1 = BeebROMs.BundledDisc.econetLevel1
        hosts[254]!.send(.insertDisc(image: level1.data, format: level1.format, drive: 0, onWrite: nil))
        hosts[254]!.send(.type("CH.\"FS\"\n3\nY\nA\n1\nA\n5\n\n"))
        #expect(waitFor { screen(hosts[254]!).contains("Ready") }, "\(screen(hosts[254]!))")
        hosts[1]!.send(.type("*NET\n*CAT\n"))
        #expect(waitFor { screen(hosts[1]!).contains("Level 1 FS") }, "\(screen(hosts[1]!))")
        // Everything the Master sent was from station 5.
        #expect(network.frames().filter { $0.transmitter == 5 }.allSatisfy { $0.sourceStation == 5 })
    }
}
