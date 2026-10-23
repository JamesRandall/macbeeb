// The stock machines' pictures and memory maps, as they were before the
// Model B hardware expansions (sideways RAM, Watford and Aries shadow RAM,
// VideoNuLA) were added. None of those may change a machine that doesn't
// have them fitted: these hashes were taken first and must never move.

import Testing
@testable import BeebCore
import BeebROMs

struct StockBaselineTests {
    /// FNV-1a over a frame's pixels.
    static func hash(_ pixels: [UInt32]) -> UInt64 {
        var h: UInt64 = 0xCBF2_9CE4_8422_2325
        for p in pixels {
            h = (h ^ UInt64(p)) &* 0x100_0000_01B3
        }
        return h
    }

    /// Boots `model`, types `program` (if any), runs a fixed time and
    /// hashes the last whole frame.
    static func frameHash(_ model: BBCMicro.Model, _ program: String?) -> UInt64 {
        let m = BBCMicro(configuration: BeebROMs.configuration(for: model))
        let tv = TVOutput()
        m.tv = tv
        m.run(seconds: 2)
        if let program {
            m.paste(program)
            m.run(seconds: 3)
        }
        return hash(tv.lastFrame)
    }

    /// MODE 2 with all sixteen colours as bars, flashing ones included,
    /// and some text: the Video ULA's palette, pixel rates and flash.
    static let colourBars = "MODE 2\nFOR C%=0 TO 15:GCOL 0,C%:X%=C%*80:MOVE X%,0:MOVE X%,1023:PLOT 85,X%+79,0:PLOT 85,X%+79,1023:NEXT\nCOLOUR 7:PRINT \"STOCK\"\n"

    @Test func modelBBoots() {
        #expect(Self.frameHash(.modelB, nil) == 7_427_117_924_673_569_654)
    }

    @Test func modelBMode2ColourBars() {
        #expect(Self.frameHash(.modelB, Self.colourBars) == 4_068_440_576_083_588_941)
    }

    @Test func master128Mode2ColourBars() {
        #expect(Self.frameHash(.master128, Self.colourBars) == 9_767_218_341_628_120_997)
    }

    /// The stock Model B's sideways banks: ROM in 14 and 15, nothing
    /// else, nothing writable, and nothing at &FE32-&FE3F or &FFFC-&FFFF
    /// beyond ROMSEL and the OS ROM.
    @Test func modelBMemoryMap() {
        let m = BBCMicro(configuration: BeebROMs.configuration(for: .modelB))
        #expect(m.memoryRegions.map(\.name) == ["Host CPU's view", "Main RAM", "Sideways ROM E", "Sideways ROM F", "OS ROM"])
        for bank in 0..<16 {
            #expect((m.sidewaysBanks[bank] != nil) == (bank >= 14), "bank \(bank)")
        }
        #expect(m.sidewaysRAMBanks.isEmpty)
        // A write to the OS ROM's top bytes changes nothing.
        m.poke(0xFFFC, 0x12)
        #expect(m.peek(0xFFFC) == BeebROMs.data(.os12)[0x3FFC])
    }
}
