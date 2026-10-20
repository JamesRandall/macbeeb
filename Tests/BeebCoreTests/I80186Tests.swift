// The 80186 core: the SingleStepTests 8086 suite (where the 80186 agrees
// with the 8086), targeted tests of the 80186's own instructions and
// differences, interrupts, and the disassembler.
//
// A subset of the suite is bundled (Resources/i80186, see its README). To
// run all of it, download https://github.com/SingleStepTests/8086 and set
// I80186_SST_DIR to its v1 directory (with the .json.gz files and
// metadata.json).

import Foundation
import Testing
@testable import BeebCore

/// 1MB of RAM, all writable; I/O reads 0xFF (as the test suite expects).
final class FlatBus: I80186Bus {
    var ram = [UInt8](repeating: 0, count: 0x100000)
    var written: [Int] = []
    var trackWrites = false
    var outputs: [(UInt16, UInt8)] = []
    var inputs: [UInt16: UInt8] = [:]

    func read(_ address: Int) -> UInt8 { ram[address] }
    func write(_ address: Int, _ value: UInt8) {
        ram[address] = value
        if trackWrites { written.append(address) }
    }
    func input(_ port: UInt16) -> UInt8 { inputs[port] ?? 0xFF }
    func output(_ port: UInt16, _ value: UInt8) { outputs.append((port, value)) }
}

/// Decompresses a gzip file (Foundation's zlib is raw DEFLATE).
func gunzip(_ data: Data) throws -> Data {
    let b = [UInt8](data)
    guard b.count > 18, b[0] == 0x1F, b[1] == 0x8B, b[2] == 8 else { throw CocoaError(.fileReadCorruptFile) }
    let flags = b[3]
    var i = 10
    if flags & 4 != 0 { i += 2 + Int(b[i]) | Int(b[i + 1]) << 8 }
    if flags & 8 != 0 { while b[i] != 0 { i += 1 }; i += 1 }
    if flags & 16 != 0 { while b[i] != 0 { i += 1 }; i += 1 }
    if flags & 2 != 0 { i += 2 }
    return try (Data(b[i..<(b.count - 8)]) as NSData).decompressed(using: .zlib) as Data
}

struct SSTState: Decodable {
    var regs: [String: Int]
    var ram: [[Int]]
}

struct SSTTest: Decodable {
    var name: String
    var bytes: [Int]
    var initial: SSTState
    var final: SSTState
    /// Bundled subset only: the flags that are defined.
    var mask: Int?
    var file: String?
}

struct SingleStepRunner {
    let bus = FlatBus()
    let cpu: I80186

    init() {
        cpu = I80186(bus: bus)
        bus.trackWrites = true
    }

    static let registers = ["ax", "bx", "cx", "dx", "cs", "ss", "ds", "es", "sp", "bp", "si", "di", "ip", "flags"]

    func get(_ name: String) -> Int {
        switch name {
        case "ax": Int(cpu.ax)
        case "bx": Int(cpu.bx)
        case "cx": Int(cpu.cx)
        case "dx": Int(cpu.dx)
        case "cs": Int(cpu.cs)
        case "ss": Int(cpu.ss)
        case "ds": Int(cpu.ds)
        case "es": Int(cpu.es)
        case "sp": Int(cpu.sp)
        case "bp": Int(cpu.bp)
        case "si": Int(cpu.si)
        case "di": Int(cpu.di)
        case "ip": Int(cpu.ip)
        default: Int(cpu.flags)
        }
    }

    func set(_ name: String, _ v: Int) {
        let v = UInt16(v)
        switch name {
        case "ax": cpu.ax = v
        case "bx": cpu.bx = v
        case "cx": cpu.cx = v
        case "dx": cpu.dx = v
        case "cs": cpu.cs = v
        case "ss": cpu.ss = v
        case "ds": cpu.ds = v
        case "es": cpu.es = v
        case "sp": cpu.sp = v
        case "bp": cpu.bp = v
        case "si": cpu.si = v
        case "di": cpu.di = v
        case "ip": cpu.ip = v
        default: cpu.flags = v
        }
    }

    /// Why a test doesn't apply to the 80186, if it doesn't.
    static func skipReason(_ t: SSTTest) -> String? {
        var i = 0
        var rep = false
        while [0x26, 0x2E, 0x36, 0x3E, 0xF0, 0xF2, 0xF3].contains(t.bytes[i]) {
            if t.bytes[i] == 0xF2 || t.bytes[i] == 0xF3 { rep = true }
            i += 1
        }
        let op = t.bytes[i]
        let reg = i + 1 < t.bytes.count ? (t.bytes[i + 1] >> 3) & 7 : 0
        switch op {
        case 0x0F, 0x60...0x6F, 0xC0, 0xC1, 0xC8, 0xC9, 0xF1:
            return "an 80186 instruction or trap"
        case 0xD0...0xD3 where reg == 6:
            return "SETMO is SHL on the 80186"
        case 0xD2, 0xD3:
            return t.initial.regs["cx"]! & 0xE0 != 0 ? "the 80186 masks shift counts to 5 bits" : nil
        case 0x8E where ![0, 2, 3].contains(reg):
            return "MOV CS / an undefined segment register traps on the 80186"
        case 0xFF where reg == 7:
            return "FF /7 traps on the 80186"
        case 0xF6 where reg >= 4 && rep, 0xF7 where reg >= 4 && rep:
            return "the 8086's REP MUL/DIV sign quirk"
        default:
            return nil
        }
    }

    /// Runs a test; returns a description of what's wrong, or nil. With
    /// `strict`, the undefined flags are compared too.
    func run(_ t: SSTTest, mask: Int, strict: Bool = false) -> String? {
        for a in bus.written { bus.ram[a] = 0 }
        bus.written.removeAll(keepingCapacity: true)
        cpu.reset()
        cpu.halted = false
        cpu.intr = false
        for (name, v) in t.initial.regs { set(name, v) }
        for e in t.initial.ram {
            bus.ram[e[0]] = UInt8(e[1])
            bus.written.append(e[0])
        }
        cpu.step()
        var n = 0
        while cpu.repeating && n < 100_000 {
            cpu.step()
            n += 1
        }
        let flagsMask = strict ? 0xFFFF : mask
        var problems: [String] = []
        for name in Self.registers {
            let expected = t.final.regs[name] ?? t.initial.regs[name]!
            var actual = get(name)
            var e = expected
            if name == "flags" {
                actual &= flagsMask
                e &= flagsMask
            }
            if actual != e {
                problems.append("\(name) \(hex(actual)) expected \(hex(e))")
            }
        }
        // A divide error pushes the flags, undefined bits and all.
        let exception = t.final.regs["cs"] == 0 && t.final.regs["ip"] == 1024
        var flagsOnStack: Set<Int> = []
        if exception, let ss = t.final.regs["ss"] ?? t.initial.regs["ss"], let sp = t.final.regs["sp"] {
            flagsOnStack = [(ss << 4 + (sp + 4) & 0xFFFF) & 0xFFFFF, (ss << 4 + (sp + 5) & 0xFFFF) & 0xFFFFF]
        }
        for e in t.final.ram {
            var actual = Int(bus.ram[e[0]])
            var expected = e[1]
            if flagsOnStack.contains(e[0]) {
                let m = e[0] == flagsOnStack.min() ? flagsMask & 0xFF : flagsMask >> 8
                actual &= m
                expected &= m
            }
            if actual != expected {
                problems.append("[\(hex(e[0]))] \(hex(actual)) expected \(hex(expected))")
            }
        }
        return problems.isEmpty ? nil : problems.joined(separator: ", ")
    }

    func hex(_ v: Int) -> String { String(v, radix: 16) }
}

struct I80186Tests {
    static let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Resources/i80186")

    static let fullSuite = ProcessInfo.processInfo.environment["I80186_SST_DIR"]

    struct Result {
        var passed = 0, failed = 0, skipped = 0, strictFailed = 0
        var failures: [String: [String]] = [:]
        var strictFailures: [String: [String]] = [:]
        var strictCounts: [String: Int] = [:]
    }

    static func runSuite(_ tests: [SSTTest], mask: (SSTTest) -> Int) -> Result {
        let runner = SingleStepRunner()
        var result = Result()
        for t in tests {
            if SingleStepRunner.skipReason(t) != nil {
                result.skipped += 1
                continue
            }
            if let problem = runner.run(t, mask: mask(t)) {
                // The 8086 traps on the most negative quotient; the 80186
                // doesn't.
                let expectedTrap = t.final.regs["cs"] == 0 && t.final.regs["ip"] == 1024
                let idiv = t.name.hasPrefix("idiv")
                if expectedTrap && idiv && runner.cpu.ip != 1024
                    && (t.bytes.contains(0xF6) ? runner.cpu.al == 0x80 : runner.cpu.ax == 0x8000) {
                    result.skipped += 1
                    continue
                }
                result.failed += 1
                let key = t.file ?? String(format: "%02X", t.bytes.first { ![0x26, 0x2E, 0x36, 0x3E, 0xF0, 0xF2, 0xF3].contains($0) } ?? 0)
                if result.failures[key, default: []].count < 3 {
                    result.failures[key, default: []].append("\(t.name) \(t.bytes): \(problem)")
                }
            } else {
                result.passed += 1
                if let problem = runner.run(t, mask: 0xFFFF, strict: true) {
                    result.strictFailed += 1
                    let key = t.file ?? "?"
                    if result.strictFailures[key, default: []].count < 2 {
                        result.strictFailures[key, default: []].append("\(t.name) \(t.bytes) \(t.initial.regs["flags"]!): \(problem)")
                    }
                    result.strictCounts[key, default: 0] += 1
                }
            }
        }
        return result
    }

    static func report(_ r: Result, _ label: String) -> String {
        var s = "\(label): \(r.passed) passed, \(r.failed) failed, \(r.skipped) skipped (80186 differences); "
        s += "\(r.passed - r.strictFailed) of the passes also match the undefined flags"
        for (k, v) in r.failures.sorted(by: { $0.key < $1.key }) {
            s += "\n  \(k): " + v.joined(separator: "\n      ")
        }
        return s
    }

    @Test func singleStepSubset() throws {
        let data = try gunzip(Data(contentsOf: Self.resources.appendingPathComponent("sst8086-subset.json.gz")))
        let tests = try JSONDecoder().decode([SSTTest].self, from: data)
        #expect(tests.count > 3000)
        let r = Self.runSuite(tests) { $0.mask ?? 0xFFFF }
        print(Self.report(r, "SingleStepTests 8086 subset"))
        #expect(r.failed == 0, "\(Self.report(r, "subset"))")
    }

    @Test(.enabled(if: fullSuite != nil))
    func singleStepFullSuite() throws {
        let dir = URL(fileURLWithPath: Self.fullSuite!)
        let metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("metadata.json"))) as! [String: Any]
        let opcodes = metadata["opcodes"] as! [String: Any]
        var total = Result()
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".json.gz") }.sorted()
        for file in files {
            let stem = String(file.dropLast(8))
            let parts = stem.split(separator: ".")
            var entry = opcodes[String(parts[0])] as? [String: Any] ?? [:]
            if parts.count > 1 {
                entry = (entry["reg"] as? [String: Any])?[String(parts[1])] as? [String: Any] ?? [:]
            }
            let mask = entry["flags-mask"] as? Int ?? 0xFFFF
            var tests = try JSONDecoder().decode([SSTTest].self, from: gunzip(Data(contentsOf: dir.appendingPathComponent(file))))
            for i in tests.indices { tests[i].file = stem }
            let r = Self.runSuite(tests) { _ in mask }
            total.passed += r.passed
            total.failed += r.failed
            total.skipped += r.skipped
            total.strictFailed += r.strictFailed
            total.failures.merge(r.failures) { $0 + $1 }
            total.strictFailures.merge(r.strictFailures) { $0 + $1 }
            total.strictCounts.merge(r.strictCounts) { $0 + $1 }
        }
        print(Self.report(total, "SingleStepTests 8086 full suite"))
        if ProcessInfo.processInfo.environment["I80186_SST_VERBOSE"] != nil {
            for (k, v) in total.strictFailures.sorted(by: { $0.key < $1.key }) {
                print("undefined flags \(k) (\(total.strictCounts[k]!)): " + v.joined(separator: "\n      "))
            }
        }
        #expect(total.failed == 0)
    }
}

/// Targeted tests of the 80186's own instructions, its differences from the
/// 8086, interrupts and prefixes.
struct I80186InstructionTests {
    let bus = FlatBus()
    let cpu: I80186

    init() {
        cpu = I80186(bus: bus)
        cpu.cs = 0x0100
        cpu.ip = 0
        cpu.ss = 0x2000
        cpu.sp = 0x1000
        cpu.ds = 0x3000
        cpu.es = 0x4000
    }

    /// Loads code at CS:0 (linear 0x1000).
    func load(_ code: [UInt8]) {
        for (i, b) in code.enumerated() { bus.ram[0x1000 + i] = b }
    }

    /// Points interrupt `type` at 0000:handler, which is an IRET.
    func vector(_ type: Int, to handler: Int) {
        bus.ram[type * 4] = UInt8(handler & 0xFF)
        bus.ram[type * 4 + 1] = UInt8(handler >> 8)
        bus.ram[type * 4 + 2] = 0
        bus.ram[type * 4 + 3] = 0
        bus.ram[handler] = 0xCF
    }

    func stackWord(_ i: Int) -> UInt16 {
        let a = 0x20000 + Int(cpu.sp) + i * 2
        return UInt16(bus.ram[a]) | UInt16(bus.ram[a + 1]) << 8
    }

    @Test func pushaPopa() {
        cpu.ax = 1; cpu.cx = 2; cpu.dx = 3; cpu.bx = 4; cpu.bp = 6; cpu.si = 7; cpu.di = 8
        load([0x60, 0x31, 0xC0, 0x89, 0xC3, 0x61])  // PUSHA; XOR AX,AX; MOV BX,AX; POPA
        #expect(cpu.step() == 36)
        #expect(cpu.sp == 0x1000 - 16)
        // DI SI BP SP BX DX CX AX from the top of the stack; SP as it was.
        #expect((0..<8).map(stackWord) == [8, 7, 6, 0x1000, 4, 3, 2, 1])
        cpu.step(); cpu.step()
        cpu.sp = 0x1000 - 16
        cpu.step()
        #expect(cpu.ax == 1 && cpu.bx == 4 && cpu.di == 8 && cpu.sp == 0x1000)
    }

    @Test func enterLeave() {
        cpu.bp = 0x0F00
        // ENTER 8,0; ENTER 4,2; LEAVE; LEAVE
        load([0xC8, 0x08, 0x00, 0x00, 0xC8, 0x04, 0x00, 0x02, 0xC9, 0xC9])
        cpu.step()
        #expect(cpu.bp == 0x0FFE && cpu.sp == 0x0FFE - 8)
        cpu.step()
        // Pushed: old BP (FFE), the outer frame pointer (copied from [BP-2]), the new frame.
        let frame = UInt16(0x0FFE - 8 - 2)
        #expect(cpu.bp == frame && cpu.sp == frame - 4 - 4)
        // Above the 4 bytes of locals: the new frame pointer, the display
        // entry copied from the outer frame, the old BP.
        #expect(stackWord(2) == frame && stackWord(4) == 0x0FFE)
        cpu.step()
        #expect(cpu.bp == 0x0FFE && cpu.sp == 0x0FFE - 8)
        cpu.step()
        #expect(cpu.bp == 0x0F00 && cpu.sp == 0x1000)
    }

    @Test func boundTrapsOutOfRange() {
        vector(5, to: 0x500)
        // Bounds -2..10 at DS:0.
        bus.ram[0x30000] = 0xFE; bus.ram[0x30001] = 0xFF
        bus.ram[0x30002] = 10; bus.ram[0x30003] = 0
        load([0x62, 0x06, 0x00, 0x00, 0x62, 0x06, 0x00, 0x00])  // BOUND AX,[0] twice
        cpu.ax = 0xFFFE  // -2: in range (signed)
        cpu.step()
        #expect(cpu.cs == 0x100 && cpu.ip == 4)
        cpu.ax = 11
        cpu.step()
        // The return address is the BOUND instruction itself.
        #expect(cpu.cs == 0 && cpu.ip == 0x500 && stackWord(0) == 4 && stackWord(1) == 0x100)
    }

    @Test func pushImmediateAndIMUL() {
        // PUSH 1234h; PUSH -2; IMUL CX,AX,-3; IMUL DX,AX,7FFFh
        load([0x68, 0x34, 0x12, 0x6A, 0xFE, 0x6B, 0xC8, 0xFD, 0x69, 0xD0, 0xFF, 0x7F])
        cpu.step(); cpu.step()
        #expect(stackWord(0) == 0xFFFE && stackWord(1) == 0x1234)
        cpu.ax = 100
        cpu.step()
        #expect(cpu.cx == UInt16(bitPattern: -300) && cpu.flags & (I80186.flagC | I80186.flagO) == 0)
        cpu.step()
        #expect(cpu.dx == UInt16(truncatingIfNeeded: 100 * 0x7FFF))
        #expect(cpu.flags & (I80186.flagC | I80186.flagO) == I80186.flagC | I80186.flagO)
    }

    @Test func shiftCountsAreMaskedTo5Bits() {
        // SHL AX,33 (= 1); MOV CL,40; SHR BX,CL (= 8)
        load([0xC1, 0xE0, 0x21, 0xB1, 0x28, 0xD3, 0xEB])
        cpu.ax = 0x4001
        cpu.bx = 0x8000
        let clocks = cpu.step()
        #expect(cpu.ax == 0x8002 && clocks == 5 + 1)
        // O: the top bit changed.
        #expect(cpu.flags & I80186.flagO != 0 && cpu.flags & I80186.flagC == 0)
        cpu.step(); cpu.step()
        #expect(cpu.bx == 0x0080)
    }

    @Test func insAndOuts() {
        bus.inputs[0x80] = 0xAB
        cpu.dx = 0x80
        cpu.cx = 3
        cpu.di = 0x10
        load([0xF3, 0x6C, 0xBE, 0x10, 0x00, 0x26, 0x6E])  // REP INSB; MOV SI,10h; ES: OUTSB
        cpu.step()
        #expect(cpu.repeating)
        while cpu.repeating { cpu.step() }
        #expect(cpu.cx == 0 && cpu.di == 0x13 && bus.ram[0x40010...0x40012].allSatisfy { $0 == 0xAB })
        cpu.step(); cpu.step()
        #expect(bus.outputs.count == 1 && bus.outputs[0].0 == 0x80 && bus.outputs[0].1 == 0xAB)
    }

    @Test func undefinedOpcodesTrap() {
        vector(6, to: 0x600)
        load([0x2E, 0x0F])  // CS: then 0F
        cpu.step()
        // The return address includes the prefix.
        #expect(cpu.cs == 0 && cpu.ip == 0x600 && stackWord(0) == 0)
        for op: UInt8 in [0x63, 0x64, 0x65, 0x66, 0x67, 0xF1] {
            cpu.cs = 0x100; cpu.ip = 0; cpu.sp = 0x1000
            load([op])
            cpu.step()
            #expect(cpu.ip == 0x600, "\(op)")
        }
    }

    @Test func divideErrors() {
        vector(0, to: 0x700)
        // IDIV CL with AX = -256, CL = 2: quotient -128 is allowed on the 80186.
        load([0xF6, 0xF9, 0xF6, 0xF1])  // IDIV CL; DIV CL
        cpu.ax = UInt16(bitPattern: -256)
        cpu.cx = 2
        cpu.step()
        #expect(cpu.al == 0x80 && cpu.ah == 0 && cpu.ip == 2)
        // DIV CL with AX = 0x8000, CL = 2: overflow. The return address is
        // the next instruction.
        cpu.ax = 0x8000
        cpu.step()
        #expect(cpu.ip == 0x700 && stackWord(0) == 4 && cpu.ax == 0x8000)
    }

    @Test func interruptedRepeatResumesFromItsPrefixes() {
        vector(12, to: 0x800)
        for i in 0..<8 { bus.ram[0x30100 + i] = UInt8(i + 1) }
        cpu.si = 0x100; cpu.di = 0; cpu.cx = 8
        cpu.flags = I80186.flagI
        load([0xF3, 0x2E, 0xA4, 0x90])  // REP CS: MOVSB (from CS:SI); NOP
        // Copy from CS (0x1000+0x100) instead: put data there.
        for i in 0..<8 { bus.ram[0x1100 + i] = UInt8(0x10 + i) }
        cpu.step(); cpu.step(); cpu.step()
        #expect(cpu.repeating && cpu.cx == 5 && cpu.ip == 0)
        cpu.intr = true
        cpu.interruptType = 12
        cpu.step()
        #expect(cpu.ip == 0x800 && stackWord(0) == 0)  // back to the REP prefix
        cpu.intr = false
        cpu.step()  // IRET
        while cpu.ip < 3 { cpu.step() }
        #expect(cpu.cx == 0 && (0..<8).map { bus.ram[0x40000 + $0] } == (0..<8).map { UInt8(0x10 + $0) })
    }

    @Test func repeatCompareStopsOnMismatch() {
        let text: [UInt8] = Array("HELLO".utf8)
        for (i, c) in text.enumerated() { bus.ram[0x40000 + i] = c }
        cpu.di = 0; cpu.cx = 5; cpu.ax = UInt16(UInt8(ascii: "L"))
        load([0xF2, 0xAE])  // REPNE SCASB
        cpu.step()
        while cpu.repeating { cpu.step() }
        #expect(cpu.di == 3 && cpu.cx == 2 && cpu.flags & I80186.flagZ != 0)
    }

    @Test func interruptShadowAndHalt() {
        vector(12, to: 0x900)
        cpu.intr = true
        load([0xFB, 0x90, 0xF4])  // STI; NOP; HLT
        cpu.step()
        // The instruction after STI runs before the interrupt is taken.
        cpu.step()
        #expect(cpu.ip == 2)
        cpu.step()
        #expect(cpu.ip == 0x900 && stackWord(0) == 2)
        // HLT, then an interrupt wakes it.
        cpu.intr = false
        cpu.step()  // IRET
        cpu.step()  // HLT
        #expect(cpu.halted && cpu.step() == 2)
        cpu.intr = true
        cpu.step()
        #expect(!cpu.halted && cpu.ip == 0x900 && stackWord(0) == 3)
    }

    @Test func nmiIsEdgeTriggeredAndIgnoresIF() {
        vector(2, to: 0xA00)
        load([0x90, 0x90, 0x90])
        cpu.setNMI(true)
        cpu.step()
        #expect(cpu.ip == 0xA00)
        cpu.step()  // IRET
        cpu.step()
        #expect(cpu.ip == 1)
        cpu.setNMI(false)
        cpu.setNMI(true)
        cpu.step()
        #expect(cpu.ip == 0xA00)
    }

    @Test func singleStepTrap() {
        vector(1, to: 0xB00)
        cpu.flags = I80186.flagT
        load([0x40, 0x40])  // INC AX
        cpu.step()
        // INC ran, then the trap: IP pushed is the next instruction.
        #expect(cpu.ax == 1 && cpu.ip == 0xB00 && stackWord(0) == 1)
        #expect(cpu.flags & I80186.flagT == 0)
    }

    @Test func intAndIntoAndSegmentPrefixes() {
        vector(0x21, to: 0xC00)
        vector(4, to: 0xC10)
        bus.ram[0x10000 + 0x20] = 0x5A  // ES=0x1000 for the override below
        cpu.es = 0x1000
        load([0xCD, 0x21, 0xCE, 0x26, 0xA0, 0x20, 0x00])  // INT 21h; INTO; MOV AL,ES:[20h]
        cpu.step()
        #expect(cpu.ip == 0xC00 && stackWord(0) == 2)
        cpu.step()  // IRET
        cpu.flags = I80186.flagO
        cpu.step()
        #expect(cpu.ip == 0xC10)
        cpu.step()
        cpu.step()
        #expect(cpu.al == 0x5A)
    }

    /// A rough figure: a loop of everyday instructions.
    @Test func speed() {
        // L: ADD AX,[BX+SI]; MOV [DI+4],AX; INC SI; SHL DX,1; XOR CX,AX; LOOP L
        load([0x03, 0x00, 0x89, 0x45, 0x04, 0x46, 0xD1, 0xE2, 0x31, 0xC1, 0xE2, 0xF4])
        let start = Date()
        var clocks = 0
        var instructions = 0
        while clocks < 80_000_000 {
            clocks += cpu.step()
            instructions += 1
        }
        let t = Date().timeIntervalSince(start)
        print(String(format: "80186: %d instructions, %d clocks (%.1fs at 8MHz) in %.3fs: %.0fx real time",
                     instructions, clocks, Double(clocks) / 8e6, t, Double(clocks) / 8e6 / t))
    }

    @Test func disassembler() {
        let d = I80186Disassembler()
        func dis(_ bytes: [UInt8]) -> String {
            d.disassemble(segment: 0, offset: 0x100) { a in a >= 0x100 && a - 0x100 < bytes.count ? bytes[a - 0x100] : 0 }.text
        }
        #expect(dis([0x03, 0x40, 0x12]) == "ADD AX,[BX+SI+12h]")
        #expect(dis([0x26, 0x80, 0x05, 0x05]) == "ADD BYTE PTR ES:[DI],5")
        #expect(dis([0xF3, 0xA4]) == "REP MOVSB")
        #expect(dis([0xF3, 0xA6]) == "REPE CMPSB")
        #expect(dis([0xB8, 0xFF, 0xFF]) == "MOV AX,0FFFFh")
        #expect(dis([0xEB, 0xFE]) == "JMP SHORT 0100h")
        #expect(dis([0x75, 0x02]) == "JNE 0104h")
        #expect(dis([0xE8, 0x00, 0x10]) == "CALL 1103h")
        #expect(dis([0xEA, 0xF0, 0xFF, 0x00, 0xF0]) == "JMP 0F000h:0FFF0h")
        #expect(dis([0x8B, 0x46, 0xFE]) == "MOV AX,[BP-2]")
        #expect(dis([0xC7, 0x06, 0x34, 0x12, 0x01, 0x00]) == "MOV WORD PTR [1234h],1")
        #expect(dis([0x6B, 0xC8, 0xFD]) == "IMUL CX,AX,0FFFDh")
        #expect(dis([0xC8, 0x08, 0x00, 0x01]) == "ENTER 8,1")
        #expect(dis([0xC1, 0xE0, 0x04]) == "SHL AX,4")
        #expect(dis([0xD3, 0x2F]) == "SHR WORD PTR [BX],CL")
        #expect(dis([0xFF, 0x1E, 0x00, 0x20]) == "CALL DWORD PTR [2000h]")
        #expect(dis([0xE6, 0x82]) == "OUT 82h,AL")
        #expect(dis([0x0F]) == "DB 0Fh")
        #expect(d.disassemble(segment: 0, offset: 0x100) { a in [0x2E, 0x8B, 0x87, 0x34, 0x12][a - 0x100] }.length == 5)
    }
}
