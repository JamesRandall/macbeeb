import Foundation
import Testing
@testable import BeebCore
import BeebROMs

struct SaveStateTests {
    /// Runs `cycles` and returns a hash of every bus access, plus RAM.
    func trace(_ machine: BBCMicro, cycles: Int) -> (Int, [UInt8]) {
        var hasher = Hasher()
        for _ in 0..<cycles {
            // As run(cycles:) does.
            if machine.cycles % 1000 == 0 {
                machine.processKeyEvents()
            }
            machine.step()
            hasher.combine(machine.cpu.abus)
            hasher.combine(machine.cpu.dbus)
            hasher.combine(machine.cpu.access.rawValue)
        }
        return (hasher.finalize(), (0..<0x8000).map { machine.peek(UInt16($0)) })
    }

    func busyMachine() -> BBCMicro {
        let machine = bootModelB()
        machine.paste("MODE 2\n10 GCOL0,RND(7):DRAW RND(1280),RND(1024):SOUND 1,-10,RND(255),1:GOTO 10\nRUN\n")
        machine.run(seconds: 1.3)
        // Leave typing in flight, and stop mid-instruction.
        machine.type("HELLO")
        machine.run(cycles: 12_345)
        return machine
    }

    @Test func restoredMachineRunsIdentically() throws {
        let original = busyMachine()
        let snapshot = original.snapshot()
        let expected = trace(original, cycles: 2_000_000)

        let copy = BBCMicro(os: BeebROMs.data(.os12), sidewaysROMs: [15: BeebROMs.data(.basic2)])
        try copy.restore(snapshot)
        let actual = trace(copy, cycles: 2_000_000)
        #expect(actual.0 == expected.0)
        #expect(actual.1 == expected.1)
    }

    @Test func restoreRewindsTheSameMachine() throws {
        let machine = busyMachine()
        let snapshot = machine.snapshot()
        let first = trace(machine, cycles: 500_000)
        try machine.restore(snapshot)
        let second = trace(machine, cycles: 500_000)
        #expect(first.0 == second.0)
        #expect(first.1 == second.1)
    }

    @Test func snapshotSurvivesEncoding() throws {
        let original = busyMachine()
        let snapshot = original.snapshot()
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(BBCMicro.Snapshot.self, from: data)
        let copy = BBCMicro(os: BeebROMs.data(.os12), sidewaysROMs: [15: BeebROMs.data(.basic2)])
        try copy.restore(decoded)
        let expected = trace(original, cycles: 200_000)
        let actual = trace(copy, cycles: 200_000)
        #expect(actual.0 == expected.0)
    }
}

struct SaveStateFileTests {
    @Test func fileRoundTripWithDisc() throws {
        let machine = try bootModelBWithDFS("TestTimings.ssd")
        machine.paste("X%=4242\n")
        machine.runUntilIdle()
        let data = try SaveStateFile(machine).data()
        #expect(data.count < 100_000, "\(data.count) bytes")

        let restored = try SaveStateFile(data: data).makeMachine()
        restored.paste("PRINT X%\n*CAT\n")
        #expect(restored.runUntilIdle(maxSeconds: 10))
        let screen = restored.teletextScreenText() ?? []
        #expect(screen.contains { $0.hasSuffix("4242") })
        #expect(screen.contains { $0.contains("TEST") }, "\(screen)")
    }

    @Test func rejectsOtherFiles() {
        #expect(throws: (any Error).self) { try SaveStateFile(data: Data("hello".utf8)) }
    }
}
