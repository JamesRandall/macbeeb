// The AMX mouse: its quadrature signals as the user VIA sees them, wired
// for the BBC and for the Master 512, and GEM using it.

import Testing
@testable import BeebCore
import BeebROMs

struct AMXMouseTests {
    /// What a driver sees: the direction bit at each clock's active edge.
    struct Edges: Equatable {
        var x: [Bool] = []
        var y: [Bool] = []
    }

    /// Runs with CB1 and CB2 interrupting on falling edges (PCR 0) and
    /// takes each interrupt, as a driver would: reads the direction bits,
    /// then clears the flags.
    func run(_ m: BBCMicro, cycles: Int, xBit: UInt8, yBit: UInt8) -> Edges {
        m.userVIA.pcr = 0
        var edges = Edges()
        for _ in 0..<cycles {
            m.step()
            let pb = m.userVIA.b.p
            if m.userVIA.ifr & VIA6522.IRQ.cb1 != 0 {
                edges.x.append(pb & xBit != 0)
                m.userVIA.ifr &= ~VIA6522.IRQ.cb1
            }
            if m.userVIA.ifr & VIA6522.IRQ.cb2 != 0 {
                edges.y.append(pb & yBit != 0)
                m.userVIA.ifr &= ~VIA6522.IRQ.cb2
            }
        }
        return edges
    }

    @Test func restsLikeNothingConnected() {
        let m = bootModelB()
        #expect(!m.mouseInUse)
        m.run(seconds: 0.01)
        #expect(m.userVIA.b.p == 0xFF && m.userVIA.b.c1 == 1 && m.userVIA.ifr & 0x18 == 0)
    }

    @Test func signalsMovementOnTheBBC() {
        let m = bootModelB()
        m.moveMouse(dx: 3, dy: 0)
        // Right: PB0 high at CB1's falling edge.
        #expect(run(m, cycles: 20_000, xBit: 0x01, yBit: 0x04) == Edges(x: [true, true, true]))
        m.moveMouse(dx: -2, dy: 2)
        // Left: low. Down: PB2 low at CB2's.
        #expect(run(m, cycles: 20_000, xBit: 0x01, yBit: 0x04) == Edges(x: [false, false], y: [false, false]))
        m.moveMouse(dx: 0, dy: -1)
        #expect(run(m, cycles: 20_000, xBit: 0x01, yBit: 0x04) == Edges(y: [true]))
        // At rest again.
        #expect(m.userVIA.b.p == 0xFF && m.mouse.x.phase == 0 && m.mouse.y.phase == 0)
    }

    @Test func buttonsPullPortBLow() {
        let m = bootModelB()
        m.setMouseButtons([.left, .right])
        m.run(cycles: 4)
        #expect(m.userVIA.b.p == 0xFF & ~0x20 & ~0x80)
        m.setMouseButtons([])
        m.run(cycles: 4)
        #expect(m.userVIA.b.p == 0xFF)
    }

    @Test func waitsForEachInterruptToBeTaken() {
        let m = bootModelB()
        m.userVIA.pcr = 0
        m.moveMouse(dx: 5, dy: 0)
        m.run(cycles: 20_000)
        // Nobody took the first, so the rest wait.
        #expect(m.userVIA.ifr & VIA6522.IRQ.cb1 != 0 && m.mouse.x.pending == 4)
        m.userVIA.ifr = 0
        #expect(run(m, cycles: 20_000, xBit: 0x01, yBit: 0x04).x.count == 4)
    }

    @Test func wiredDifferentlyForTheMaster512() {
        let m = BBCMicro(configuration: BeebROMs.configuration(for: .master128, secondProcessor: true,
                                                               coprocessor: .master512, systemDisc: false))
        m.run(seconds: 0.1)
        m.moveMouse(dx: 1, dy: 1)
        #expect(run(m, cycles: 20_000, xBit: 0x08, yBit: 0x10) == Edges(x: [true], y: [false]))
        m.setMouseButtons(.left)
        m.run(cycles: 4)
        #expect(m.userVIA.b.p & 0x07 == 0x06)
    }

    @Test func rewindsWithTheMachine() throws {
        let m = bootModelB()
        m.enableRewind(seconds: 5)
        m.userVIA.pcr = 0
        m.run(seconds: 0.5)
        let start = m.cycles
        m.moveMouse(dx: 1000, dy: -1000)
        m.setMouseButtons(.middle)
        m.run(seconds: 0.5)
        let mouse = m.mouse, via = m.userVIA.ifr
        try m.rewinder!.seek(to: start)
        m.run(seconds: 0.5)
        #expect(m.mouse == mouse && m.userVIA.ifr == via)
    }

    #if DEBUG
    /// Booting GEM takes minutes unoptimised.
    static let optimised = false
    #else
    static let optimised = true
    #endif

    /// GEM on the Master 512: the pointer follows. (Run with
    /// `swift test -c release`.)
    @Test(.enabled(if: optimised))
    func drivesGEM() throws {
        let m = BBCMicro(configuration: BeebROMs.configuration(for: .master128, secondProcessor: true, coprocessor: .master512))
        let gem = BeebROMs.BundledDisc.gemApplications
        m.insertDisc(try Disc.fromImage(gem.data, format: gem.format), drive: 1)
        let tv = TVOutput()
        m.tv = tv
        #expect(m.runUntilIdle(maxSeconds: 60))
        m.type("B:\rGEM\r")
        #expect(m.runUntilIdle(maxSeconds: 90))
        #expect(m.mouseInUse)
        m.run(seconds: 0.5)
        let before = tv.lastFrame
        for _ in 0..<10 {
            m.moveMouse(dx: 1, dy: 0)
            m.run(seconds: 0.02)
        }
        m.run(seconds: 0.3)
        // About 80 TV pixels right (4 of GEM's per count).
        let changed = before.indices.filter { before[$0] != tv.lastFrame[$0] }.map { $0 % TVOutput.width }
        let span = (changed.max() ?? 0) - (changed.min() ?? 0)
        #expect((70...100).contains(span), "\(span)")
    }
}
