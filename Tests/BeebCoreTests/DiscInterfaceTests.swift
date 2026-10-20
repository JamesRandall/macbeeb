import Testing
@testable import BeebCore
import BeebROMs

struct DiscInterfaceTests {
    static let boards: [BBCMicro.DiscInterface] = [.acorn1770, .watfordDDB2, .watfordDDB3, .opus]

    @Test(arguments: boards)
    func cataloguesADiscThroughTheBoard(_ board: BBCMicro.DiscInterface) throws {
        let m = BBCMicro(configuration: BeebROMs.configuration(for: .modelB, discInterface: board))
        #expect(m.intel8271 == nil && m.wd1770 != nil)
        m.insertDisc(try Disc.fromSSD(testResource("discs/TestTimings.ssd")))
        #expect(m.runUntilIdle())
        let screen = command(m, "*CAT", maxSeconds: 20)
        #expect(screen.contains { $0.contains("TEST") }, "\(board): \(screen)")
    }

    @Test func readableLatches() {
        let m = BBCMicro(configuration: BeebROMs.configuration(for: .modelB, discInterface: .opus))
        #expect(m.runUntilIdle())
        // Opus: the latch is at &FE84, readable.
        m.load([0xA9, 0x43, 0x8D, 0x84, 0xFE, 0xAD, 0x84, 0xFE, 0x85, 0x70, 0x60], at: 0x2000)
        command(m, "CALL &2000")
        #expect(m.peek(0x70) == 0x43)
        #expect(m.wd1770?.selectedDrive == 1 && m.wd1770?.isDoubleDensity == true && m.wd1770?.isSideUpper == true)
    }

    @Test func theStandardIsThe8271() {
        let m = BBCMicro(configuration: BeebROMs.configuration(for: .modelB))
        #expect(m.intel8271 != nil && m.wd1770 == nil)
    }
}
