// Seeing when the machine is waiting for input: exactly, in the OS's
// OSRDCH loop, or by what software that reads the keyboard itself does.

import Testing
@testable import BeebCore
import BeebROMs

struct IdleTests {
    func screen(_ m: BBCMicro) -> [String] { m.screenText().filter { !$0.isEmpty } }

    @Test func waitsForTheOS() {
        let m = BBCMicro(os: BeebROMs.data(.os12), sidewaysROMs: [15: BeebROMs.data(.basic2)])
        #expect(m.runUntilIdle(maxSeconds: 3))
        #expect(screen(m).last == ">")
    }

    /// A program working without output isn't waiting.
    @Test func silentWorkIsntWaiting() {
        let m = bootModelB()
        m.paste("FOR I=1 TO 3000:NEXT:PRINT \"DONE\"\n")
        #expect(m.runUntilIdle(maxSeconds: 10))
        #expect(screen(m).suffix(2) == ["DONE", ">"], "\(screen(m))")
    }

    /// One reading the keyboard itself, with the screen still, is.
    @Test func pollingTheKeyboardIsWaiting() {
        let m = bootModelB()
        m.paste("REPEAT UNTIL INKEY(-99)\n")
        let start = m.cycles
        #expect(m.runUntilIdle(maxSeconds: 3))
        #expect(m.cycles - start < 2_000_000)
        #expect(screen(m).last == ">REPEAT UNTIL INKEY(-99)", "\(screen(m))")
        // Space ends it, back at the prompt.
        m.type(" ")
        #expect(m.runUntilIdle(maxSeconds: 3))
        #expect(screen(m).last == ">")
    }

    @Test func busyWithoutPollingIsntWaiting() {
        let m = bootModelB()
        m.paste("REPEAT UNTIL FALSE\n")
        #expect(!m.runUntilIdle(maxSeconds: 3))
    }

    /// Polling while the picture changes (a game, say) isn't waiting either.
    @Test func pollingWhileDrawingIsntWaiting() {
        let m = bootModelB()
        m.paste("REPEAT PRINT TIME:UNTIL INKEY(-99)\n")
        #expect(!m.runUntilIdle(maxSeconds: 3))
    }

    /// The Z80 asking for its CP/M disc: the DFS waits for the drive, not
    /// for a key.
    @Test func z80WaitingForADiscIsntWaitingForAKey() {
        let m = BBCMicro(configuration: BeebROMs.configuration(for: .modelB, secondProcessor: true, coprocessor: .z80))
        #expect(!m.runUntilIdle(maxSeconds: 3))
        #expect(screen(m).last == "Insert CP/M System disc in drive A")
    }

    @Test(arguments: [BBCMicro.Coprocessor.mos6502, .arm])
    func secondProcessorsWaitInTheHostOS(_ coprocessor: BBCMicro.Coprocessor) {
        let m = BBCMicro(configuration: BeebROMs.configuration(for: .modelB, secondProcessor: true, coprocessor: coprocessor))
        #expect(m.runUntilIdle(maxSeconds: 3))
        #expect(m.cycles < 4_000_000)
    }
}
