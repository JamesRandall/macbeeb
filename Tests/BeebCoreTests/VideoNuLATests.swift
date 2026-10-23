// VideoNuLA: its registers and palette protocol, the stock ULA unchanged
// without it, the picture, save states, and the MCP round trip. (The
// pictures b2 expects are in NuLAReferenceTests.)

import BeebAgentKit
import BeebCapture
import BeebHost
import Foundation
import Testing
@testable import BeebCore
import BeebROMs

func nulaMachine(_ model: BBCMicro.Model = .modelB, tv: TVOutput? = nil) -> BBCMicro {
    var c = BeebROMs.configuration(for: model)
    c.videoNuLA = true
    let m = BBCMicro(configuration: c)
    m.tv = tv
    m.runUntilIdle()
    return m
}

/// The MODE 2 colour bars, sixteen wide bands of logical colours 0-15.
let mode2Bars = ["MODE 2", "VDU 23,1,0;0;0;0;", "FOR C%=0 TO 15:GCOL 0,C%:X%=C%*80:MOVE X%,0:MOVE X%,1023:PLOT 85,X%+79,0:PLOT 85,X%+79,1023:NEXT"]

/// The middle of bar `logical` in a frame of the MODE 2 bars: each bar is
/// 10 MODE 2 pixels (40 TV pixels) wide, and bar 1 (red, never black) is the
/// first that isn't black on the row.
func barPixel(_ frame: [UInt32], _ logical: Int, firstBarColoured: Bool = false) -> UInt32 {
    let row = 300 * TVOutput.width
    let first = (0..<TVOutput.width).first { frame[row + $0] & 0xFFFFFF != 0 } ?? 88
    let x = (firstBarColoured ? first : first - 40) + logical * 40 + 20
    return frame[row + x] & 0xFFFFFF
}

struct VideoNuLATests {
    @Test func powersUpWithTheStandardColours() {
        let ula = VideoULA(nula: true)
        let n = ula.nula!
        for i in 0..<16 {
            #expect(n.outputPalette[i] == VideoULA.outputPalette[i])
            #expect(n.flash[i] == (i >= 8))
        }
        #expect(!n.directPalette && !n.paletteWritePending && !n.disableA1)
        #expect(n.rgb888(1) == "#FF0000")
    }

    /// Two writes per entry: [index|red] then [green|blue]; the first alone
    /// changes nothing; only that entry changes, and it stops flashing.
    @Test func paletteProtocol() {
        var ula = VideoULA(nula: true)
        ula.writeNuLAPalette(0x8F)
        #expect(ula.nula!.paletteWritePending && ula.nula!.outputPalette[8] == 0x000)
        ula.writeNuLAPalette(0x80)
        #expect(!ula.nula!.paletteWritePending)
        #expect(ula.nula!.outputPalette[8] == 0xF80 && ula.nula!.rgb888(8) == "#FF8800")
        #expect(!ula.nula!.flash[8] && ula.nula!.flash[9])
        for i in 0..<16 where i != 8 { #expect(ula.nula!.outputPalette[i] == VideoULA.outputPalette[i]) }
        // Rapid sequential writes: all sixteen.
        for i in 0..<16 {
            ula.writeNuLAPalette(UInt8(i << 4 | 1))
            ula.writeNuLAPalette(0x23)
        }
        #expect((0..<16).allSatisfy { ula.nula!.outputPalette[$0] == 0x123 })
    }

    @Test func controlFunctions() {
        var ula = VideoULA(nula: true)
        ula.writeNuLAControl(0x11)
        #expect(ula.nula!.directPalette)
        ula.writeNuLAControl(0x25)
        ula.writeNuLAControl(0x3A)
        #expect(ula.nula!.scrollOffset == 5 && ula.nula!.blankingSize == 10)
        ula.writeNuLAControl(0x80)
        ula.writeNuLAControl(0x95)
        #expect(!ula.nula!.flash[8] && !ula.nula!.flash[11] && ula.nula!.flash[13] && ula.nula!.flash[15] && !ula.nula!.flash[12])
        // Reset: the standard colours and settings; a half write forgotten.
        ula.writeNuLAPalette(0x0F)
        ula.writeNuLAControl(0x40)
        #expect(!ula.nula!.directPalette && ula.nula!.scrollOffset == 0 && ula.nula!.blankingSize == 0)
        #expect(!ula.nula!.paletteWritePending && ula.nula!.flash[8])
        // Unknown functions are ignored and counted.
        ula.writeNuLAControl(0xE3)
        #expect(ula.nula!.ignoredWrites == 1)
        // Disable: &FE22/&FE23 are the stock registers until power off.
        ula.writeNuLAControl(0x50)
        ula.writeNuLAControl(0x9C)
        #expect(ula.control == 0x9C)
        ula.writeNuLAPalette(0x12)
        #expect(ula.logicalPalette[1] == 5)
    }

    /// Without NuLA, &FE22 and &FE23 are the ULA's &FE20 and &FE21, as on
    /// a real stock Model B: no hidden palette.
    @Test func stockULAAliasesTheRegisters() {
        let m = BBCMicro(configuration: BeebROMs.configuration(for: .modelB))
        m.cpuWrite(0xFE23, 0x31)
        #expect(m.videoULA.logicalPalette[3] == 6)
        m.cpuWrite(0xFE22, 0x9C)
        #expect(m.videoULA.control == 0x9C && m.videoULA.nula == nil)
    }

    /// A programmed colour shows in the picture: bar 8 in MODE 2 becomes
    /// #FF8800 (the BBC writing its own palette, from BASIC).
    @Test func programmedColourShows() {
        let tv = TVOutput()
        let m = nulaMachine(tv: tv)
        for line in mode2Bars { enter(m, line) }
        m.run(seconds: 0.2)
        #expect(barPixel(tv.lastFrame, 1) == 0xFF0000)
        enter(m, "?&FE23=&8F:?&FE23=&80")
        m.run(seconds: 0.2)
        #expect(barPixel(tv.lastFrame, 8) == 0xFF8800)
        #expect(barPixel(tv.lastFrame, 1) == 0xFF0000)
        // Function 4 puts the colours back: bar 8 flashes black/white again.
        enter(m, "?&FE22=&40")
        m.run(seconds: 0.2)
        #expect([0x000000, 0xFFFFFF].contains(barPixel(tv.lastFrame, 8)))
    }

    /// A colour changed half way down the screen changes only the lines
    /// drawn after it: writes take effect as they happen.
    @Test func midFrameChangeShowsFromThatLine() {
        let tv = TVOutput()
        let m = nulaMachine(tv: tv)
        for line in mode2Bars { enter(m, line) }
        let frames = tv.frameCount
        while tv.frameCount == frames { m.run(cycles: 10) }
        // Half a frame (20ms is 40,000 cycles) in, red becomes green.
        m.run(cycles: 20_000)
        m.cpuWrite(0xFE23, 0x10)
        m.cpuWrite(0xFE23, 0xF0)
        let next = tv.frameCount
        while tv.frameCount == next { m.run(cycles: 10) }
        let frame = tv.lastFrame
        func bar1(row: Int) -> UInt32 {
            let base = row * TVOutput.width
            let x = (0..<TVOutput.width).first { frame[base + $0] & 0xFFFFFF != 0 }!
            return frame[base + x + 20] & 0xFFFFFF
        }
        #expect(bar1(row: 100) == 0xFF0000)
        #expect(bar1(row: 500) == 0x00FF00)
    }

    /// The guide's example, Examples/videonula/ramp.bas: a ramp from red
    /// (colour 0) to yellow (15) with NuLA; on a stock Model B the same
    /// writes reach the ordinary palette and every bar turns white.
    @Test(arguments: [true, false]) func guideExample(nula: Bool) throws {
        let tv = TVOutput()
        var c = BeebROMs.configuration(for: .modelB)
        c.videoNuLA = nula
        let m = BBCMicro(configuration: c)
        m.tv = tv
        m.runUntilIdle()
        let program = String(decoding: try testResource("nula/ramp.bas"), as: UTF8.self)
        for line in program.split(separator: "\n") { enter(m, String(line)) }
        enter(m, "RUN")
        m.run(seconds: 0.2)
        if nula {
            // Bar 0 is red now, not black.
            #expect(barPixel(tv.lastFrame, 0, firstBarColoured: true) == 0xFF0000)
            #expect(barPixel(tv.lastFrame, 1, firstBarColoured: true) == 0xFF1100)
            #expect(barPixel(tv.lastFrame, 8, firstBarColoured: true) == 0xFF8800)
            #expect(barPixel(tv.lastFrame, 15, firstBarColoured: true) == 0xFFFF00)
            enter(m, "?&FE22=&40")
            m.run(seconds: 0.2)
            #expect(barPixel(tv.lastFrame, 1) == 0xFF0000 && barPixel(tv.lastFrame, 2) == 0x00FF00)
        } else {
            let row = 300 * TVOutput.width
            let picture = (0..<TVOutput.width).map { tv.lastFrame[row + $0] & 0xFFFFFF }
            #expect(Set(picture).isSubset(of: [0x000000, 0xFFFFFF]))
            #expect(picture.filter { $0 == 0xFFFFFF }.count > 600)
        }
    }

    /// Direct palette mode: logical colours go straight to the palette.
    @Test func directPaletteMode() {
        let tv = TVOutput()
        let m = nulaMachine(tv: tv)
        for line in mode2Bars { enter(m, line) }
        enter(m, "VDU 19,3,4;0;")
        enter(m, "?&FE23=&30:?&FE23=&F0")
        m.run(seconds: 0.2)
        // Through the ULA's palette, logical 3 is physical 4 (blue).
        #expect(barPixel(tv.lastFrame, 3) == 0x0000FF)
        enter(m, "?&FE22=&11")
        m.run(seconds: 0.2)
        #expect(barPixel(tv.lastFrame, 3) == 0x00FF00)
    }

    /// MODE 7 uses colours 0-7 of NuLA's palette.
    @Test func teletextUsesThePalette() {
        let tv = TVOutput()
        let m = nulaMachine(tv: tv)
        enter(m, "MODE 7")
        enter(m, "VDU 23,1,0;0;0;0;")
        enter(m, "?&FE23=&7F:?&FE23=&80")
        enter(m, "PRINT \"WWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWW\"")
        m.run(seconds: 0.2)
        let colours = Set(tv.lastFrame.map { $0 & 0xFFFFFF })
        #expect(colours.contains(0xFF8800), "the text is in colour 7, now orange")
        #expect(!colours.contains(0xFFFFFF))
    }

    /// A palette write half done when something else writes: the second
    /// byte completes the entry, as the hardware does.
    @Test func halfWrittenPaletteCompletesWithTheNextByte() {
        let m = nulaMachine()
        m.cpuWrite(0xFE23, 0x5A)
        #expect(m.videoULA.nula!.paletteWritePending)
        m.cpuWrite(0xFE23, 0xBC)
        #expect(m.videoULA.nula!.outputPalette[5] == 0xABC)
    }

    @Test func saveStateKeepsThePalette() throws {
        let m = nulaMachine()
        m.cpuWrite(0xFE23, 0x2F)
        m.cpuWrite(0xFE23, 0x80)
        m.cpuWrite(0xFE22, 0x23)
        let restored = try SaveStateFile(data: try SaveStateFile(m).data()).makeMachine()
        #expect(restored.videoULA.nula?.outputPalette[2] == 0xF80)
        #expect(restored.videoULA.nula?.scrollOffset == 3)
        // An older save state (no NuLA in it) restores with NuLA at power-on.
        var old = SaveStateFile(m)
        old.snapshot.videoULA.nula = nil
        let fromOld = try old.makeMachine()
        #expect(fromOld.videoULA.nula?.outputPalette[2] == VideoULA.outputPalette[2])
        // And a stock machine's snapshot can't sneak NuLA in.
        let stock = BBCMicro(configuration: BeebROMs.configuration(for: .modelB))
        var sneaky = SaveStateFile(stock)
        sneaky.snapshot.videoULA.nula = VideoNuLA()
        #expect(try sneaky.makeMachine().videoULA.nula == nil)
    }

    /// NuLA coexists with a memory board: no I/O overlap.
    @Test func coexistsWithAMemoryBoard() {
        var c = BeebROMs.configuration(for: .modelB, expansions: .init(board: .ariesB32))
        c.videoNuLA = true
        let m = BBCMicro(configuration: c)
        m.runUntilIdle()
        enter(m, "*XSTATUS X")
        #expect(lines(m).contains("Current shadow RAM: 20K"))
        m.cpuWrite(0xFE23, 0x1F)
        m.cpuWrite(0xFE23, 0x00)
        #expect(m.videoULA.nula!.outputPalette[1] == 0xF00 && m.aries.ramsel == 15)
    }

    /// The Master too (its ULA is &FE20-&FE23).
    @Test func onTheMaster() {
        let m = nulaMachine(.master128)
        enter(m, "?&FE23=&4A:?&FE23=&BC")
        #expect(m.videoULA.nula!.outputPalette[4] == 0xABC)
    }

    /// The Bitshifters VideoNuLA gallery (MIT; not committed: it's run from
    /// reference/bitshifters-nula when it's there): with NuLA it programs a
    /// 16-colour palette and shows it; without, the same writes land in the
    /// stock palette, as on a real Model B.
    @Test(.enabled(if: FileManager.default.fileExists(atPath: galleryPath(1)) && optimisedOrSlowTestsWanted),
          arguments: [true, false])
    func bitshiftersGallery(nula: Bool) throws {
        var c = BeebROMs.configuration(for: .modelB)
        c.videoNuLA = nula
        let m = BBCMicro(configuration: c)
        let tv = TVOutput()
        m.tv = tv
        m.insertDisc(try Disc.fromSSD([UInt8](Data(contentsOf: URL(fileURLWithPath: galleryPath(1))))))
        m.setKey(.shift, down: true)
        m.run(seconds: 1)
        m.setKey(.shift, down: false)
        m.run(seconds: 11.5)
        let colours = Set(tv.lastFrame.map { $0 & 0xFFFFFF })
        if nula {
            #expect(colours.count >= 12, "\(colours.count) colours")
            // Colours a stock ULA can't make (any nibble other than 0 or F).
            #expect(colours.contains { c in [16, 8, 0].contains { c >> $0 & 0xFF != 0 && c >> $0 & 0xFF != 0xFF } })
        } else {
            #expect(colours.allSatisfy { c in [16, 8, 0].allSatisfy { c >> $0 & 0xFF == 0 || c >> $0 & 0xFF == 0xFF } })
        }
    }
}

func galleryPath(_ n: Int) -> String {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("reference/bitshifters-nula/bbcnula\(n).ssd").path
}

/// The spec's end-to-end MCP scenario.
struct VideoNuLAAgentTests {
    let support = AgentToolsTests()

    @Test func discoverEnableProgramInspectCaptureSaveDisable() throws {
        let session = HeadlessSession { BBCMicro(configuration: BeebROMs.configuration(for: .modelB)) }
        session.machine.runUntilIdle()
        let tools = AgentTools(context: session)
        func text(_ name: String, _ args: JSONValue = [:]) -> String { support.text(tools.call(name, arguments: args)) }

        // 1. Supported, and off.
        #expect(text("get_hardware").contains("video: the stock Video ULA"))
        #expect(text("video_nula").contains("not fitted"))
        let refused = tools.call("set_video_nula_palette", arguments: ["index": 8, "rgb": "F80"])
        #expect(refused.isError && support.text(refused).hasPrefix("not_fitted:"))

        // 2. Fit it (a restart).
        #expect(!tools.call("power_cycle", arguments: ["video_nula": true]).isError)
        #expect(text("get_hardware").contains("video: VideoNuLA"))

        // 3. MODE 2 bars, then colour 8 = F80 through the real register, and
        //    colour 9 with the helper.
        for line in mode2Bars { _ = tools.call("run_command", arguments: ["text": .string(line)]) }
        #expect(!tools.call("bus_write", arguments: ["address": "&FE23", "bytes": [0x8F, 0x80]]).isError)
        #expect(text("set_video_nula_palette", ["index": 9, "rgb": "&0F8"]).contains("colour 9 = &0F8 (#00FF88)"))

        // 4. The state says so.
        let state = text("video_nula")
        #expect(state.contains(" 8: &F80 (#FF8800)") && state.contains(" 8 -> physical  8 -> &F80 (#FF8800)"), "\(state)")
        #expect(state.contains("attribute_modes_2_3: unsupported"))

        // 5. And the screen shows it.
        _ = tools.call("run", arguments: ["frames": 5])
        guard case .png(let png) = try #require(tools.call("screenshot", arguments: [:]).content.first) else {
            Issue.record("no screenshot")
            return
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nula-\(UUID().uuidString).png")
        try png.write(to: url)
        let frame = try #require(B2Pictures.pixels(url))
        #expect(barPixel(frame, 8) == 0xFF8800)
        #expect(barPixel(frame, 9) == 0x00FF88)

        // 6. Save and restore: the same colours and pixels.
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("nula-\(UUID().uuidString).beebstate").path
        #expect(!tools.call("save_state", arguments: ["path": .string(path)]).isError)
        _ = tools.call("set_video_nula_control", arguments: ["function": 4])
        #expect(text("video_nula").contains(" 8: &000"))
        #expect(!tools.call("load_state", arguments: ["path": .string(path)]).isError)
        #expect(text("video_nula").contains(" 8: &F80 (#FF8800)"))
        _ = tools.call("run", arguments: ["frames": 3])
        guard case .png(let restoredPNG) = try #require(tools.call("screenshot", arguments: [:]).content.first) else { return }
        try restoredPNG.write(to: url)
        #expect(barPixel(try #require(B2Pictures.pixels(url)), 8) == 0xFF8800)

        // Errors are specific.
        #expect(support.text(tools.call("set_video_nula_palette", arguments: ["index": 16, "rgb": "F80"])).hasPrefix("invalid_value:"))
        #expect(support.text(tools.call("set_video_nula_palette", arguments: ["index": 1, "rgb": "F800"])).hasPrefix("invalid_value:"))
        #expect(support.text(tools.call("set_video_nula_control", arguments: ["function": 7, "value": 1])).hasPrefix("unsupported_feature:"))
        #expect(support.text(tools.call("set_video_nula_control", arguments: ["function": 2, "value": 9])).hasPrefix("invalid_value:"))
        _ = tools.call("bus_write", arguments: ["address": "&FE23", "bytes": [0x3F]])
        #expect(support.text(tools.call("set_video_nula_palette", arguments: ["index": 1, "rgb": "F00"])).hasPrefix("pending_write:"))

        // Disable it again: the stock ULA, stock colours.
        #expect(!tools.call("power_cycle", arguments: ["video_nula": false]).isError)
        #expect(text("video_nula").contains("not fitted"))
        #expect(session.machine.videoULA.nula == nil)
    }
}
