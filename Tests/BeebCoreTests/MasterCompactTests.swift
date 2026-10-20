import Testing
@testable import BeebCore
import BeebROMs

struct MasterCompactTests {
    func boot(_ configure: (BBCMicro) -> Void = { _ in }) -> BBCMicro {
        let m = BBCMicro(configuration: BeebROMs.configuration(for: .masterCompact))
        configure(m)
        #expect(m.runUntilIdle())
        return m
    }

    @Test func bootsADFSAndBASIC() {
        let m = boot()
        let screen = m.screenText()
        #expect(screen.contains("Acorn MOS") && screen.contains("Acorn ADFS") && screen.contains("BASIC"), "\(screen)")
        #expect(m.cpu.variant == .cmos)
        #expect(m.wd1770?.variant == .wd1772)
        #expect(command(m, "PRINT 6*7").contains("        42"))
    }

    @Test func hasNoTubeADCOrKeypad() {
        let m = BBCMicro(configuration: BeebROMs.configuration(for: .masterCompact, secondProcessor: true))
        #expect(m.secondProcessor == nil)
        // &FE18 (the Master 128's ADC) is unmapped.
        #expect(m.peek(0xFE18) == 0xFF)
        m.setKey(.keypad5, down: true)
        #expect(m.isKeyDown(.digit5) && !m.isKeyDown(.keypad5))
    }

    @Test func settingsLiveInTheEEPROM() {
        // Reading: MODE 1 at power on.
        let m = boot { m in
            var contents = PCD8572.defaultMasterCompact
            contents[10] = 0x11
            m.eeprom = PCD8572(contents: contents)
        }
        #expect(m.peekMainRAM(0x355) == 1)
        // Writing.
        command(m, "*CONFIGURE MODE 3")
        #expect(m.eeprom.contents[10] & 7 == 3)
        command(m, "*CONFIGURE DELAY 20")
        #expect(m.eeprom.contents[12] == 20)
    }

    @Test func digitalJoystick() {
        let m = boot()
        m.setJoystick(0, x: 1, y: 0, fire: true)
        m.run(cycles: 4)
        // Right and fire, active low.
        #expect(m.userVIA.b.p & 0x1F == 0x1F ^ 0x11)
        m.setJoystick(0, x: -0.9, y: 0.9, fire: false)
        m.run(cycles: 4)
        #expect(m.userVIA.b.p & 0x1F == 0x1F ^ 0x0A)
        // The OS reads it as ADVAL(0)... from BASIC, the port is &FE60.
        let screen = command(m, "PRINT ?&FE60 AND 31")
        #expect(screen.contains("        21"), "\(screen)")
    }

    @Test func snapshotsKeepTheEEPROM() throws {
        let m = boot()
        command(m, "*CONFIGURE MODE 3")
        let copy = BBCMicro(configuration: m.configuration)
        try copy.restore(m.snapshot())
        #expect(copy.eeprom == m.eeprom)
    }
}
