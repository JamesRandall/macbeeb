// CPU and interrupt timing test programs, loaded straight from their disc
// images into a Model B (no disc system needed), checked against real
// hardware results.

import Foundation
import Testing
@testable import BeebCore

struct TimingDiscTests {
    /// Loads a file from a test disc into memory, at PAGE if it's BASIC.
    func loadFile(_ disc: String, _ name: String, into machine: BBCMicro) throws -> DFSDisc.File {
        let image = try DFSDisc(side: testResource("discs/\(disc)"))
        let file = try #require(image.file(named: name), "\(name) not on \(disc)")
        let contents = image.contents(of: file)
        if contents.first == 0x0D {
            machine.loadBASIC(contents)
        } else {
            machine.load(contents, at: UInt16(truncatingIfNeeded: file.loadAddress))
        }
        return file
    }

    func run(_ machine: BBCMicro, _ command: String, maxSeconds: Double = 120) throws -> String {
        machine.capturedOutput = []
        machine.captureOutput = true
        machine.paste(command + "\n")
        let finished = machine.runUntilIdle(maxSeconds: maxSeconds)
        let output = String(decoding: machine.capturedOutput.map { $0 == 13 ? 10 : $0 }, as: UTF8.self)
        try #require(finished, "didn't finish:\n\(output)")
        return output
    }

    @Test(arguments: ["6502timing", "6502timing1M"])
    func dp111Timing(_ disc: String) throws {
        let machine = bootModelB()
        let file = try loadFile("dp111-\(disc).ssd", "6502tim", into: machine)
        var failures: UInt8?
        machine.unmappedIOWriteObserver = { address, value in
            if address == 0xFCD0 { failures = value }
        }
        let output = try run(machine, "CALL &\(String(file.executionAddress, radix: 16))")
        #expect(failures == 0, "\(output)")
    }

    @Test func tomSeddonTiming() throws {
        let machine = bootModelB()
        _ = try loadFile("beeb_6502_timing_tests.ssd", "TIMINGS", into: machine)
        let output = try run(machine, "RUN")
        #expect(!output.contains("FAILED"), "\(output)")
        #expect(output.contains("Total: 81"), "\(output)")
    }

    @Test func readModifyWrite() throws {
        let machine = bootModelB()
        _ = try loadFile("RmwX.ssd", "Timings", into: machine)
        _ = try run(machine, "CALL &110")
        let result = stride(from: 0x100, to: 0x110, by: 4).map { base in
            (0..<4).reversed().map { String(format: "%02x", machine.peek(UInt16(base + $0))) }.joined()
        }.joined(separator: " ")
        #expect(result == "f2fe0a16 eaeadae6 f2fe0a16 c1cdd9e5")
    }

    @Test func bcd() throws {
        let machine = bootModelB()
        _ = try loadFile("bcdtest.ssd", "BCDTEST", into: machine)
        let output = try run(machine, "CALL &2900")
        #expect(output.contains("PASSED"), "\(output)")
    }

    @Test func irqTimings() throws {
        let machine = bootModelB()
        _ = try loadFile("TestTimings.ssd", "TEST", into: machine)
        _ = try run(machine, "RUN")
        let count = Int(machine.peek(0x71)) + 1
        let results = (0..<count).map { i -> [Int] in
            let i = UInt16(i)
            return [Int(machine.peek(0x4300 + i)) << 8 | Int(machine.peek(0x4000 + i)),
                    Int(machine.peek(0x4100 + i)), Int(machine.peek(0x4200 + i))]
        }
        // From jsbeeb's tests/integration/timings.js.
        let expected: [[Int]] = [
            [0x4436, 0x00, 0xDD], [0x4443, 0x00, 0xDD], [0x4450, 0x00, 0xDD], [0x445E, 0x00, 0xDD],
            [0x0000, 0x00, 0x00], [0x0000, 0x00, 0x00], [0x4488, 0x00, 0xFF], [0x4497, 0x00, 0x00],
            [0x0000, 0x00, 0x00], [0x44B8, 0xC0, 0xFF], [0x44C5, 0xC0, 0xFF], [0x0000, 0x00, 0x00],
            [0x0000, 0x00, 0x00], [0x44F6, 0xC0, 0xDB], [0x4506, 0xC0, 0xDC], [0x4516, 0xC0, 0xFF],
            [0x4527, 0xC0, 0x00], [0x453A, 0xC0, 0x01], [0x454A, 0xC0, 0x01], [0x4559, 0xC0, 0x00],
            [0x4569, 0xC0, 0x00], [0x4578, 0xC0, 0x01], [0x458A, 0xC0, 0xFF], [0x4599, 0xC0, 0x00],
            [0x45A6, 0xC0, 0x00], [0x0000, 0x00, 0x00],
        ]
        #expect(results == expected)
    }

    /// The OS's IRQ handler under a fast timer: depends on the ACIA (TDRE
    /// inhibited by CTS) and the ADC being emulated. Real Model Bs give
    /// 1066-1072 (stardot thread 9805).
    @Test func irqHandlerLoadMatchesRealBeeb() throws {
        let machine = bootModelB()
        _ = try loadFile("Irq-Timing.ssd", "T", into: machine)
        machine.paste("RUN\n")
        machine.run(seconds: 4)
        // Lines are "count  ticks  mean"; the program loops for ever.
        let lines = machine.teletextScreenText() ?? []
        let values = lines.compactMap { line -> Int? in
            let fields = line.split(separator: " ")
            return fields.count == 3 ? Int(fields[1]) : nil
        }
        try #require(!values.isEmpty, "no results:\n\(lines.joined(separator: "\n"))")
        for value in values {
            #expect((1060...1080).contains(value), "\(value)")
        }
    }
}
