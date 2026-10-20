import BeebCapture
import Testing
@testable import BeebCore
import BeebROMs

struct ModelBTests {
    @Test func bootsToBASIC() {
        let machine = bootModelB()
        let screen = machine.teletextScreenText() ?? []
        // The OS starts with a line feed, so row 0 is blank.
        #expect(Array(screen.prefix(6)) == ["", "BBC Computer 32K", "", "BASIC", "", ">"], "\(screen.prefix(6))")
    }

    /// Typing goes through the keyboard matrix, so this exercises the
    /// keyboard scan, the system VIA's CA2 interrupt and the OS's key
    /// handling.
    @Test func typingThroughKeyboardMatrix() {
        let machine = bootModelB()
        machine.type("PRINT 6*7\n")
        #expect(machine.runUntilIdle())
        let screen = machine.teletextScreenText() ?? []
        #expect(screen.contains(">PRINT 6*7"))
        #expect(screen.contains { $0.trimmingCharacters(in: .whitespaces) == "42" })
    }

    @Test func shiftedCharacters() {
        let machine = bootModelB()
        machine.type("PRINT \"A#B£C\"\n")
        #expect(machine.runUntilIdle())
        #expect(machine.teletextScreenText()?.contains("A#B£C") == true)
    }

    @Test func breakResets() {
        let machine = bootModelB()
        machine.paste("X%=123\n")
        #expect(machine.runUntilIdle())
        machine.setKey(.breakKey, down: true)
        machine.run(seconds: 0.1)
        machine.setKey(.breakKey, down: false)
        #expect(machine.runUntilIdle())
        // A soft reset keeps resident integer variables.
        machine.paste("PRINT X%\n")
        #expect(machine.runUntilIdle())
        #expect(machine.teletextScreenText()?.contains { $0.hasSuffix("123") } == true)
    }

    @Test func rendersAFrame() throws {
        let machine = BBCMicro(os: BeebROMs.data(.os12), sidewaysROMs: [15: BeebROMs.data(.basic2)])
        let tv = TVOutput()
        machine.tv = tv
        machine.runUntilIdle()
        machine.run(seconds: 0.1)
        #expect(tv.frameCount > 20)
        // White text on black: some pixels lit, most not.
        let lit = tv.lastFrame.filter { $0 & 0xFFFFFF == 0xFFFFFF }.count
        #expect(lit > 1000 && lit < tv.lastFrame.count / 10)
        let png = try #require(Screenshot.png(tv))
        #expect(png.count > 1000)
    }
}

import Foundation

struct JoystickTests {
    @Test func advalReadsJoystick() {
        let machine = bootModelB()
        machine.setJoystick(0, x: -1, y: 1, fire: true)
        // ADVAL needs a conversion cycle on each channel.
        machine.run(seconds: 0.2)
        machine.paste("PRINT ADVAL(1) DIV 256;\",\";ADVAL(2) DIV 256;\",\";ADVAL(0) AND 3\n")
        #expect(machine.runUntilIdle())
        // Left and up read high; fire button 0 is bit 0 of ADVAL(0).
        #expect(machine.teletextScreenText()?.contains { $0.hasSuffix("255,255,1") } == true, "\(machine.teletextScreenText() ?? [])")
    }
}
