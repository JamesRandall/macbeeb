import Foundation
import Testing
@testable import BeebCore
import BeebROMs

struct RewindTests {
    func machine(_ model: BBCMicro.Model = .modelB, secondProcessor: Bool = false) -> BBCMicro {
        let m = BBCMicro(configuration: BeebROMs.configuration(for: model, secondProcessor: secondProcessor))
        m.tv = TVOutput()
        m.enableRewind(seconds: 10, interval: 0.25)
        return m
    }

    /// A fingerprint of the whole machine: a copy restored from its snapshot,
    /// run on, with every bus access hashed.
    func fingerprint(_ m: BBCMicro) throws -> Int {
        let copy = BBCMicro(configuration: m.configuration)
        try copy.restore(m.snapshot())
        var hasher = Hasher()
        for _ in 0..<40_000 {
            if copy.cycles % 1000 == 0 { copy.processKeyEvents() }
            copy.step()
            hasher.combine(copy.cpu.abus)
            hasher.combine(copy.cpu.dbus)
            if let p = copy.secondProcessor { hasher.combine(p.cpu.abus) }
        }
        return hasher.finalize()
    }

    @Test(arguments: [(BBCMicro.Model.modelB, false), (.master128, true)])
    func seekingReplaysExactly(_ model: BBCMicro.Model, secondProcessor: Bool) throws {
        let m = machine(model, secondProcessor: secondProcessor)
        #expect(m.runUntilIdle())
        m.paste("MODE 1:FOR I%=1 TO 400:PLOT 69,RND(1280),RND(1024):SOUND 1,-10,I%,1:NEXT\n")
        // Keys and joystick moves at odd moments, between runs of odd sizes.
        var generator = SystemRandomNumberGenerator()
        var checkpoints: [(UInt64, Int)] = []
        let keys: [BeebKey] = [.a, .shift, .space, .z, .returnKey, .ctrl]
        for i in 0..<40 {
            m.run(cycles: Int.random(in: 1_000...90_000, using: &generator))
            switch i % 3 {
            case 0: m.setKey(keys.randomElement(using: &generator)!, down: Bool.random(using: &generator))
            case 1: m.setJoystick(0, x: Double.random(in: -1...1, using: &generator), y: 0.5, fire: Bool.random(using: &generator))
            default: if i % 9 == 2 { m.releaseAllKeys() }
            }
            if i % 7 == 3 {
                checkpoints.append((m.cycles, try fingerprint(m)))
            }
        }
        // Back to each checkpoint, in an odd order.
        for (cycle, expected) in checkpoints.reversed() + checkpoints {
            try m.rewinder!.seek(to: cycle)
            #expect(m.cycles == cycle)
            #expect(try fingerprint(m) == expected, "at cycle \(cycle)")
        }
    }

    @Test func historyIsLimited() throws {
        let m = machine()
        m.run(seconds: 13)
        let r = try #require(m.rewinder)
        #expect(r.points.count == r.capacity)
        let earliest = try #require(r.earliestCycle)
        #expect(m.cycles - earliest <= 10 * 2_000_000 + r.interval)
        #expect(throws: Rewinder.SeekError.self) { try r.seek(to: earliest - 1) }
        // Thumbnails of the picture.
        #expect(r.points.last!.thumbnail.count == Rewinder.thumbnailWidth * Rewinder.thumbnailHeight)
    }

    @Test func runningOnAfterASeekStartsANewFuture() throws {
        let m = machine()
        m.run(seconds: 2)
        let r = try #require(m.rewinder)
        let end = m.cycles
        try r.seek(to: end - 1_000_000)
        // Forward again, to the old future: still there.
        try r.seek(to: end - 100)
        #expect(m.cycles == end - 100)
        try r.seek(to: end - 1_000_000)
        m.setKey(.a, down: true)
        m.run(cycles: 10)
        #expect(r.points.allSatisfy { $0.cycle <= m.cycles })
        #expect(throws: Never.self) { try r.seek(to: end - 1_000_000 + 5) }
    }

    @Test func changesFromOutsideAreKept() throws {
        let m = machine()
        m.run(seconds: 1)
        let before = m.cycles
        m.debugWrite(.mainRAM, 0x3000, 0x5A)
        m.load([1, 2, 3], at: 0x3100)
        m.insertDisc(try Disc.fromSSD(testResource("discs/TestTimings.ssd")))
        m.run(seconds: 0.5)
        let after = m.cycles
        try m.rewinder!.seek(to: before + 10)
        #expect(m.peek(0x3000) == 0x5A && m.peek(0x3102) == 3 && m.drives[0].disc != nil)
        try m.rewinder!.seek(to: before - 10)
        #expect(m.peek(0x3000) != 0x5A && m.drives[0].disc == nil)
        try m.rewinder!.seek(to: after)
        #expect(m.peek(0x3000) == 0x5A)
    }

    @Test func externalRestoreStartsANewHistory() throws {
        let m = machine()
        m.run(seconds: 1)
        let snapshot = m.snapshot()
        m.run(seconds: 1)
        try m.restore(snapshot)
        m.run(cycles: 10)
        #expect(m.rewinder!.points.count == 1)
    }

    // MARK: Reverse debugging

    func loadProgram(_ m: BBCMicro) {
        // LDA #5 : STA &70 : JSR &2010 : LDX #3 : RTS / LDA &70 : CLC : ADC #1 : STA &71 : RTS
        m.load([0xA9, 0x05, 0x85, 0x70, 0x20, 0x10, 0x20, 0xA2, 0x03, 0x60], at: 0x2000)
        m.load([0xA5, 0x70, 0x18, 0x69, 0x01, 0x85, 0x71, 0x60], at: 0x2010)
    }

    @Test func stepBack() throws {
        let m = machine()
        #expect(m.runUntilIdle())
        loadProgram(m)
        try m.debugger.add(Breakpoint(start: 0x2015))
        m.paste("CALL &2000\n")
        m.debugger.run(.continue, maxCycles: 4_000_000) { m.run(cycles: $0) }
        #expect(m.instructionAddress(.host) == 0x2015)
        try m.debugger.stepBack()
        #expect(m.debugger.stopReason == .stepped(.host))
        #expect(m.instructionAddress(.host) == 0x2013 && m.cpu.isAboutToExecute)
        // Before the ADC: A is still 5.
        #expect(m.cpu.a == 5)
        try m.debugger.stepBack()
        try m.debugger.stepBack()
        #expect(m.instructionAddress(.host) == 0x2010)
        try m.debugger.stepBack()
        #expect(m.instructionAddress(.host) == 0x2004)
        // And forward again gets the same result.
        m.debugger.removeAllBreakpoints()
        m.debugger.run(.stepOver, maxCycles: 1_000_000) { m.run(cycles: $0) }
        #expect(m.instructionAddress(.host) == 0x2007 && m.peek(0x71) == 6)
    }

    @Test func reverseContinue() throws {
        let m = machine()
        #expect(m.runUntilIdle())
        loadProgram(m)
        m.poke(0x71, 0)
        let write = try m.debugger.add(Breakpoint(kind: .write, start: 0x70))
        m.paste("CALL &2000\n")
        m.debugger.run(.continue, maxCycles: 4_000_000) { m.run(cycles: $0) }
        m.debugger.removeAllBreakpoints()
        // Run on past it, back to the prompt, and some more.
        m.debugger.resume()
        #expect(m.runUntilIdle())
        m.run(seconds: 1)
        let back = try m.debugger.add(Breakpoint(kind: .write, start: 0x70))
        try m.debugger.reverseContinue()
        #expect(m.debugger.stopReason == .breakpoint(id: back.id, cpu: .host, address: 0x70, kind: .write))
        #expect(m.instructionAddress(.host) == 0x2002 && m.peek(0x70) == 5 && m.peek(0x71) == 0)
        _ = write
        // Nothing earlier: back to the start of history.
        try m.debugger.reverseContinue()
        #expect(m.debugger.stopReason == .historyStart)
        #expect(m.cycles == m.rewinder!.earliestCycle)
    }

    @Test func reverseNeedsHistory() {
        let m = BBCMicro(configuration: BeebROMs.configuration(for: .modelB))
        #expect(throws: Debugger.ReverseError.self) { try m.debugger.stepBack() }
    }
}
