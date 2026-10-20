// The Acorn Master 512 board: on its own beside a Master 128 (stepped by
// hand, with test ROMs), then fitted, with the bundled BIOS, and booting
// the bundled DOS Plus disc.

import Foundation
import Testing
@testable import BeebCore
import BeebROMs

struct Master512Tests {
    /// A Master 128 with the Tube enabled. The machine only opens the Tube
    /// to the host when it has a co-processor of its own, so it gets a Z80
    /// whose ROM is all HALT: it never touches the Tube.
    static func host() -> BBCMicro {
        var configuration = BeebROMs.configuration(for: .master128, secondProcessor: true, coprocessor: .z80, systemDisc: false)
        configuration.secondProcessorROM = [UInt8](repeating: 0x76, count: 4096)
        return BBCMicro(configuration: configuration)
    }

    static func board(_ m: BBCMicro, rom: [UInt8]) -> Master512 {
        Master512(rom: rom, machine: m)
    }

    /// A Master 128 with the Master 512 fitted, with or without the DOS
    /// Plus disc.
    static func fitted(systemDisc: Bool = false) -> BBCMicro {
        BBCMicro(configuration: BeebROMs.configuration(for: .master128, secondProcessor: true, coprocessor: .master512,
                                                       systemDisc: systemDisc))
    }

    static func screen(_ m: BBCMicro) -> [String] { m.screenText().filter { !$0.isEmpty } }

    // MARK: Without the BIOS

    /// A tiny BIOS: at F000:FFF0, jump to code that writes "HI" to the
    /// Tube's R1 and halts.
    static func testROM(_ program: [UInt8]) -> [UInt8] {
        var rom = [UInt8](repeating: 0x90, count: 0x4000)
        for (i, b) in program.enumerated() { rom[i] = b }
        // F000:FFF0 is 0x3FF0 in the 16K image: JMP F000:C000.
        rom.replaceSubrange(0x3FF0..<0x3FF5, with: [0xEA, 0x00, 0xC0, 0x00, 0xF0])
        return rom
    }

    @Test func memoryMap() throws {
        let m = Self.host()
        let b = Self.board(m, rom: Self.testROM([0xF4]))
        // The BIOS repeats through the top 64K and ignores writes.
        #expect(b.peek(0xFFFF0) == 0xEA && b.peek(0xF3FF0) == 0xEA && b.peek(0xF7FF0) == 0xEA)
        b.write(0xFFFF0, 0)
        #expect(b.peek(0xFFFF0) == 0xEA)
        b.write(0xEFFFF, 0x12)
        #expect(b.read(0xEFFFF) == 0x12)
        #expect(b.cpu.cs == 0xF000 && b.cpu.ip == 0xFFF0)
        // Ports other than the Tube's read &FF.
        #expect(b.input(0x40) == 0xFF && b.input(0xFF22) == 0xFF)
    }

    @Test func talksToTheTube() throws {
        let m = Self.host()
        // MOV AL,'H'; OUT 82h,AL; MOV AL,'I'; OUT 83h,AL; HLT
        let b = Self.board(m, rom: Self.testROM([0xB0, 0x48, 0xE6, 0x82, 0xB0, 0x49, 0xE6, 0x83, 0xF4]))
        for _ in 0..<100 { b.step() }
        #expect(b.cpu.halted)
        // Both bytes went into FIFO 1 (registers at an even and an odd port).
        #expect(m.tube.hostRead(1) == 0x48)
        #expect(m.tube.hostRead(1) == 0x49)
    }

    @Test func tubeIRQIsType12() throws {
        let m = Self.host()
        // Vector 12 -> 0000:0400; the handler reads R1 into BL and halts.
        // STI; HLT at C000; at 0400: IN AL,82h; MOV BL,AL; HLT.
        let b = Self.board(m, rom: Self.testROM([0xFB, 0xF4]))
        b.write(48, 0x00); b.write(49, 0x04); b.write(50, 0); b.write(51, 0)
        for (i, v) in [0xE4, 0x82, 0x88, 0xC3, 0xF4].enumerated() { b.write(0x400 + i, UInt8(v)) }
        for _ in 0..<20 { b.step() }
        #expect(b.cpu.halted && b.cpu.ip == 0xC002)
        // I (R1 interrupts) on, then a byte from the host.
        m.tube.hostWrite(0, Tube.Status.s | Tube.Status.i)
        m.tube.hostWrite(1, 0x5A)
        for _ in 0..<40 { b.step() }
        #expect(b.cpu.cs == 0 && b.cpu.bx & 0xFF == 0x5A && b.cpu.halted)
    }

    @Test func dmaFromTheTube() throws {
        let m = Self.host()
        // Set DMA 0 source = port 8Ah (R3), destination = 01000h, then idle
        // in a loop: MOV DX,FFC0h; MOV AX,008Ah; OUT DX,AX; MOV DL,C4h;
        // MOV AX,1000h; OUT DX,AX; JMP $
        let b = Self.board(m, rom: Self.testROM([0xBA, 0xC0, 0xFF, 0xB8, 0x8A, 0x00, 0xEF,
                                                     0xB2, 0xC4, 0xB8, 0x00, 0x10, 0xEF, 0xEB, 0xFE]))
        for _ in 0..<40 { b.step() }
        #expect(b.dma.source == 0x8A && b.dma.destination == 0x1000)
        // M on: each byte the host writes to R3 raises the request, and the
        // DMA takes it.
        m.tube.hostWrite(0, Tube.Status.s | Tube.Status.m)
        for byte in [0x11, 0x22, 0x33] as [UInt8] {
            m.tube.hostWrite(5, byte)
            for _ in 0..<10 { b.step() }
        }
        #expect([b.peek(0x1000), b.peek(0x1001), b.peek(0x1002)] == [0x11, 0x22, 0x33])
        #expect(b.dma.destination == 0x1003)
    }

    @Test func prstHoldsItInReset() throws {
        let m = Self.host()
        let b = Self.board(m, rom: Self.testROM([0x40, 0xEB, 0xFD]))  // INC AX; JMP -3
        for _ in 0..<100 { b.step() }
        #expect(b.cpu.ax != 0)
        b.write(0x2000, 0x99)
        m.tube.hostWrite(0, Tube.Status.s | Tube.Status.p)
        for _ in 0..<10 { b.step() }
        #expect(b.cpu.cs == 0xF000 && b.cpu.ip == 0xFFF0)
        // Memory survives.
        #expect(b.peek(0x2000) == 0x99)
        m.tube.hostWrite(0, Tube.Status.p)
        for _ in 0..<10 { b.step() }
        #expect(b.cpu.cs == 0xF000 && (0xC000...0xC002).contains(b.cpu.ip))
    }

    @Test func savesAndRestoresState() throws {
        let m = Self.host()
        let b = Self.board(m, rom: Self.testROM([0x40, 0x89, 0x06, 0x00, 0x20, 0xEB, 0xF9]))
        for _ in 0..<500 { b.step() }
        let data = try JSONEncoder().encode(b.state)
        let copyHost = Self.host()
        let copy = Self.board(copyHost, rom: Self.testROM([0x40, 0x89, 0x06, 0x00, 0x20, 0xEB, 0xF9]))
        copy.restore(try JSONDecoder().decode(Master512.State.self, from: data))
        for _ in 0..<500 { b.step(); copy.step() }
        #expect(copy.cpu.ax == b.cpu.ax && copy.cpu.ip == b.cpu.ip && copy.peek(0x2000) == b.peek(0x2000))
    }

    // MARK: With BeebEm's BIOS

    @Test func biosStartsUp() throws {
        let m = Self.fitted()
        #expect(m.master512 != nil && m.tubeAccessible)
        m.run(seconds: 3)
        let text = Self.screen(m)
        #expect(text.contains { $0.contains("80186") }, "\(text)")
    }

    /// How fast the board runs on its own: the BIOS waiting for the host.
    @Test func speed() throws {
        let m = Self.fitted()
        m.run(seconds: 1)
        let start = Date()
        m.run(seconds: 2)
        let both = Date().timeIntervalSince(start)
        let host = BBCMicro(configuration: BeebROMs.configuration(for: .master128))
        let start2 = Date()
        host.run(seconds: 2)
        let hostOnly = Date().timeIntervalSince(start2)
        print(String(format: "Master 512: 2s with the board in %.3fs; host alone %.3fs", both, hostOnly))
    }

    /// The board goes inside a Master 128, so nothing else takes it.
    @Test func onlyFitsTheMaster128() {
        #expect(BBCMicro.Coprocessor.master512.fits(.master128))
        for model in [BBCMicro.Model.modelA, .modelB, .bPlus, .masterCompact] {
            #expect(!BBCMicro.Coprocessor.master512.fits(model))
            let configuration = BeebROMs.configuration(for: model, secondProcessor: true, coprocessor: .master512)
            #expect(configuration.secondProcessorROM == nil && configuration.startupDisc == nil)
        }
        #expect(BBCMicro.Coprocessor.z80.fits(.bPlus) && !BBCMicro.Coprocessor.z80.fits(.masterCompact))
        // Even given its ROM, a B doesn't get one.
        var configuration = BeebROMs.configuration(for: .modelB)
        configuration.coprocessor = .master512
        configuration.secondProcessorROM = BeebROMs.data(.master512BIOS)
        #expect(BBCMicro(configuration: configuration).master512 == nil)
    }

    @Test func savesStateAndRewinds() throws {
        let m = Self.fitted()
        m.enableRewind(seconds: 2)
        m.run(seconds: 1)
        let middle = m.cycles
        m.run(seconds: 0.5)
        let ip = m.master512!.cpu.ip
        try m.rewinder!.seek(to: middle)
        m.run(seconds: 0.5)
        #expect(m.master512!.cpu.ip == ip)
        // The RAM's compressed.
        #expect(m.master512!.state.memory.count < 100_000)
        let other = BBCMicro(configuration: BeebROMs.configuration(for: .master128, secondProcessor: true, coprocessor: .z80))
        #expect(throws: BBCMicro.RestoreError.self) { try other.restore(m.snapshot()) }
    }

    @Test func bootsDOSPlus() throws {
        let m = Self.fitted(systemDisc: true)
        // DOS Plus reads the keyboard itself, so waiting at the prompt is
        // seen by its polling.
        #expect(m.runUntilIdle(maxSeconds: 60))
        var text = Self.screen(m)
        #expect(text.last?.hasSuffix("A>") == true, "\(text)")
        #expect(text.first == "Acorn Master 512, DOS Plus 1.2", "\(text)")
        m.type("DIR\r")
        #expect(m.runUntilIdle(maxSeconds: 30))
        text = Self.screen(m)
        #expect(text.contains { $0.hasPrefix("COMMAND  COM") || $0.hasPrefix("PIP      CMD") }, "\(text)")
        #expect(text.last?.hasSuffix("A>") == true, "\(text)")
    }
}
