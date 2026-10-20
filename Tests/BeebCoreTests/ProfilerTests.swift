import Testing
@testable import BeebCore
import BeebROMs

struct ProfilerTests {
    /// spin: INX : JMP spin, at &2000, CALLed from BASIC.
    func spinning(secondProcessor: Bool = false) -> BBCMicro {
        let m = BBCMicro(configuration: BeebROMs.configuration(for: .modelB, secondProcessor: secondProcessor))
        #expect(m.runUntilIdle())
        let code: [UInt8] = [0xE8, 0x4C, 0x00, 0x20]
        for (i, byte) in code.enumerated() {
            m.debugWrite(secondProcessor ? .parasiteRAM : .mainRAM, 0x2000 + i, byte)
        }
        var symbols = SymbolTable()
        symbols.add("spin", 0x2000)
        m.debugger.addSymbols(symbols, cpu: secondProcessor ? .parasite : .host)
        m.paste("CALL &2000\n")
        m.run(seconds: 0.5)
        return m
    }

    @Test func whereTheTimeGoes() throws {
        let m = spinning()
        m.debugger.startProfiling()
        m.run(seconds: 1)
        m.debugger.stopProfiling()
        let report = try #require(m.debugger.profileReport())
        #expect(report.totalCycles == 2_000_000)
        #expect((49...51).contains(report.frames), "\(report.frames) frames")
        // The OS's 100Hz timer and vsync interrupts take a few percent.
        let interruptShare = Double(report.interruptCycles) / Double(report.totalCycles)
        #expect(interruptShare > 0.005 && interruptShare < 0.1, "\(interruptShare)")
        // INX is 2 cycles, JMP 3: the spin loop is the rest.
        let inx = try #require(report.hottest.first { $0.address == 0x2000 })
        let jmp = try #require(report.hottest.first { $0.address == 0x2001 })
        #expect(report.hottest.prefix(2).map(\.address).sorted() == [0x2000, 0x2001])
        #expect(abs(Double(jmp.cycles) / Double(inx.cycles) - 1.5) < 0.01)
        #expect(inx.executions == jmp.executions || abs(inx.executions - jmp.executions) == 1)
        #expect(Double(inx.cycles + jmp.cycles) + Double(report.interruptCycles) > 0.98 * Double(report.totalCycles))
        // Grouped by symbol.
        #expect(report.routines.first?.name == "spin")
        #expect(abs(report.cyclesPerFrame - 40_000) < 1_000)
    }

    @Test func profilingStops() throws {
        let m = spinning()
        m.debugger.startProfiling()
        m.run(seconds: 0.2)
        m.debugger.stopProfiling()
        let before = try #require(m.debugger.profileReport()).totalCycles
        m.run(seconds: 0.2)
        #expect(m.debugger.profileReport()?.totalCycles == before)
        #expect(!m.debugger.isProfiling)
    }

    @Test func secondProcessor() throws {
        let m = spinning(secondProcessor: true)
        m.debugger.startProfiling()
        m.run(seconds: 1)
        let report = try #require(m.debugger.profileReport(.parasite))
        // 3MHz.
        #expect(report.totalCycles == 3_000_000)
        #expect(report.routines.first?.name == "spin")
        // Meanwhile the host waits for the Tube.
        #expect(m.debugger.profileReport(.host)?.totalCycles == 2_000_000)
    }
}
