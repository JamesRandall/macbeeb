import Testing
@testable import BeebCore
import BeebROMs

struct ModelATests {
    func boot() -> BBCMicro {
        let m = BBCMicro(configuration: BeebROMs.configuration(for: .modelA, secondProcessor: true))
        #expect(m.runUntilIdle())
        return m
    }

    @Test func bootsWith16K() {
        let m = boot()
        #expect(m.screenText().contains("BBC Computer 16K"), "\(m.screenText())")
        #expect(command(m, "PRINT ~HIMEM").contains("      3C00"))
        // The modes that need more than 16K aren't allowed.
        #expect(command(m, "MODE 0").contains("Bad MODE"))
    }

    @Test func theUpper16KMirrorsTheLower() {
        let m = boot()
        command(m, "?&7123=&5A")
        #expect(m.peek(0x3123) == 0x5A)
        // Mode 4's screen, nominally at &5800, is at &1800.
        command(m, "MODE 4")
        #expect(command(m, "PRINT ~HIMEM").contains("      1800"))
        #expect(m.screenText().contains(">PRINT ~HIMEM"), "\(m.screenText())")
    }

    @Test func hasNoDiscUserVIATubeOrADC() {
        let m = boot()
        #expect(m.intel8271 == nil && m.wd1770 == nil && m.secondProcessor == nil)
        // Unmapped: the stale data bus (the high byte of the address).
        #expect(command(m, "PRINT ~?&FE6E").contains("        FE"))
        #expect(command(m, "PRINT ~?&FEC0").contains("        FE"))
        #expect(!m.model.hasUserVIA && !m.model.hasDiscInterface)
    }
}
