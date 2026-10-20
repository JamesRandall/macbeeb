import Foundation
import Testing
@testable import BeebCore

/// A Z80 with 64K of flat RAM. Port reads return `inputValue` (or
/// `inputSequence` in order) and port writes are recorded.
final class Z80TestMachine: Z80Bus {
    let memory = UnsafeMutablePointer<UInt8>.allocate(capacity: 0x10000)
    var cpu: Z80!
    var inputValue: UInt8 = 0xFF
    var inputSequence: [UInt8] = []
    var inputs: [UInt16] = []
    var outputs: [(port: UInt16, value: UInt8)] = []
    var m1Fetches = 0

    init(_ bytes: [UInt8] = [], at address: Int = 0) {
        memory.initialize(repeating: 0, count: 0x10000)
        load(bytes, at: address)
        cpu = Z80(bus: self)
    }

    deinit { memory.deallocate() }

    func load(_ bytes: [UInt8], at address: Int) {
        for (i, byte) in bytes.enumerated() { memory[address + i] = byte }
    }

    func read(_ address: UInt16) -> UInt8 { memory[Int(address)] }
    func fetchOpcode(_ address: UInt16) -> UInt8 {
        m1Fetches += 1
        return memory[Int(address)]
    }
    func write(_ address: UInt16, _ value: UInt8) { memory[Int(address)] = value }
    func input(_ port: UInt16) -> UInt8 {
        inputs.append(port)
        return inputSequence.isEmpty ? inputValue : inputSequence.removeFirst()
    }
    func output(_ port: UInt16, _ value: UInt8) { outputs.append((port, value)) }
}

/// The bare minimum of CP/M to run a .COM file: BDOS functions 2 and 9
/// (console output) and a warm boot (jump to 0) that ends the program.
final class CPMMachine: Z80Bus {
    let memory = UnsafeMutablePointer<UInt8>.allocate(capacity: 0x10000)
    var cpu: Z80!
    var output = ""
    var tStates = 0

    init(program: [UInt8]) {
        memory.initialize(repeating: 0, count: 0x10000)
        for (i, byte) in program.enumerated() { memory[0x100 + i] = byte }
        // BDOS entry at 5 jumps to a RET at the top of the TPA; (6) is also
        // the top of memory, which the exercisers use for their stack.
        memory[5] = 0xC3
        memory[6] = 0x00
        memory[7] = 0xFE
        memory[0xFE00] = 0xC9
        cpu = Z80(bus: self)
        cpu.pc = 0x100
        cpu.sp = 0xFE00
    }

    deinit { memory.deallocate() }

    func read(_ address: UInt16) -> UInt8 { memory[Int(address)] }
    func write(_ address: UInt16, _ value: UInt8) { memory[Int(address)] = value }
    func input(_ port: UInt16) -> UInt8 { 0xFF }
    func output(_ port: UInt16, _ value: UInt8) {}

    /// Runs until the program warm boots. Returns the T-states taken.
    func run(echo: Bool = false) -> Int {
        tStates = 0
        while true {
            switch cpu.pc {
            case 0x0000:
                return tStates
            case 0x0005:
                bdos(echo: echo)
            default:
                break
            }
            tStates += cpu.step()
        }
    }

    private func bdos(echo: Bool) {
        var text = ""
        switch cpu.c {
        case 2:
            text = String(UnicodeScalar(cpu.e))
        case 9:
            var address = cpu.de
            while memory[Int(address)] != UInt8(ascii: "$") {
                text.unicodeScalars.append(UnicodeScalar(memory[Int(address)]))
                address &+= 1
            }
        default:
            break
        }
        output += text
        if echo {
            if text.contains("\n") { text = " [\(tStates)]" + text }
            FileHandle.standardError.write(text.data(using: .utf8)!)
        }
    }
}

struct Z80ExerciserTests {
    /// The address of the exercisers' table of tests (from `LD HL,tests` at
    /// $011F), which ends with a 0 word.
    static let testTable = 0x013A
    static let testCount = 67

    /// Tests run by default (indexes into the table): everything except
    /// the slowest groups (16 bit add/adc/sbc, the 8 bit ALU on registers and
    /// index halves, BIT n,r and most single-register INC/DEC), about 8% of
    /// the full run's 46.7 billion T-states. Set Z80_FULL_ZEX=1 to run them
    /// all, and Z80_ZEX_ECHO=1 to see the output as it runs.
    static let quickTests = [
        4,  // aluop a,nn
        8,  // bit n,(<ix,iy>+1)
        10, 11,  // cpd<r>, cpi<r>
        12,  // <daa,cpl,scf,ccf>
        13, 15, 25, 27, 28,  // <inc,dec> a, bc, (hl), (<ix,iy>+1), ixh
    ] + Array(32...66)  // loads, block transfers, neg, rrd/rld, rotates and shifts, stores

    static var full: Bool { ProcessInfo.processInfo.environment["Z80_FULL_ZEX"] != nil }

    func exercise(_ file: String) throws {
        let machine = CPMMachine(program: try testResource("z80/\(file)"))
        if !Self.full {
            let table = (0..<Self.testCount * 2).map { machine.memory[Self.testTable + $0] }
            var address = Self.testTable
            for index in Self.quickTests + [nil] {
                machine.memory[address] = index.map { table[$0 * 2] } ?? 0
                machine.memory[address + 1] = index.map { table[$0 * 2 + 1] } ?? 0
                address += 2
            }
        }
        let echo = ProcessInfo.processInfo.environment["Z80_ZEX_ECHO"] != nil
        let start = Date()
        let tStates = machine.run(echo: echo)
        let seconds = Date().timeIntervalSince(start)
        let mhz = Double(tStates) / seconds / 1e6
        print("\(file): \(tStates) T-states in \(String(format: "%.1f", seconds))s (\(String(format: "%.0f", mhz)) MHz)")
        let lines = machine.output.split(whereSeparator: \.isNewline)
        let passed = lines.filter { $0.hasSuffix("OK") }.count
        #expect(!machine.output.contains("ERROR"), "\(machine.output)")
        #expect(passed == (Self.full ? Self.testCount : Self.quickTests.count), "\(machine.output)")
        #expect(machine.output.contains("Tests complete"))
    }

    @Test func zexdoc() throws { try exercise("zexdoc.com") }
    @Test func zexall() throws { try exercise("zexall.com") }
}

struct Z80TimingTests {
    /// Runs one instruction at 0 and returns its T-states.
    func time(_ bytes: [UInt8], _ setup: (Z80) -> Void = { _ in }) -> Int {
        let machine = Z80TestMachine(bytes)
        machine.cpu.sp = 0x8000
        setup(machine.cpu)
        return machine.cpu.step()
    }

    @Test func unprefixed() {
        #expect(time([0x00]) == 4)  // NOP
        #expect(time([0x01, 0x34, 0x12]) == 10)  // LD BC,nn
        #expect(time([0x03]) == 6)  // INC BC
        #expect(time([0x09]) == 11)  // ADD HL,BC
        #expect(time([0x34]) == 11)  // INC (HL)
        #expect(time([0x36, 0x55]) == 10)  // LD (HL),n
        #expect(time([0x7E]) == 7)  // LD A,(HL)
        #expect(time([0x86]) == 7)  // ADD A,(HL)
        #expect(time([0x22, 0x00, 0x40]) == 16)  // LD (nn),HL
        #expect(time([0x3A, 0x00, 0x40]) == 13)  // LD A,(nn)
        #expect(time([0x18, 0x10]) == 12)  // JR
        #expect(time([0x20, 0x10]) { $0.f = 0 } == 12)  // JR NZ, taken
        #expect(time([0x20, 0x10]) { $0.f = Z80.flagZ } == 7)  // not taken
        #expect(time([0x10, 0x10]) { $0.b = 2 } == 13)  // DJNZ, taken
        #expect(time([0x10, 0x10]) { $0.b = 1 } == 8)  // not taken
        #expect(time([0xCA, 0x00, 0x40]) { $0.f = Z80.flagZ } == 10)  // JP Z, taken
        #expect(time([0xCA, 0x00, 0x40]) { $0.f = 0 } == 10)  // not taken
        #expect(time([0xC4, 0x00, 0x40]) { $0.f = 0 } == 17)  // CALL NZ, taken
        #expect(time([0xC4, 0x00, 0x40]) { $0.f = Z80.flagZ } == 10)  // not taken
        #expect(time([0xCD, 0x00, 0x40]) == 17)  // CALL
        #expect(time([0xD8]) { $0.f = Z80.flagC } == 11)  // RET C, taken
        #expect(time([0xD8]) { $0.f = 0 } == 5)  // not taken
        #expect(time([0xC9]) == 10)  // RET
        #expect(time([0xFF]) == 11)  // RST 38
        #expect(time([0xC5]) == 11)  // PUSH BC
        #expect(time([0xC1]) == 10)  // POP BC
        #expect(time([0xE3]) == 19)  // EX (SP),HL
        #expect(time([0xF9]) == 6)  // LD SP,HL
        #expect(time([0xD3, 0x10]) == 11)  // OUT (n),A
        #expect(time([0xDB, 0x10]) == 11)  // IN A,(n)
        #expect(time([0x76]) == 4)  // HALT
    }

    @Test func prefixed() {
        #expect(time([0xCB, 0x00]) == 8)  // RLC B
        #expect(time([0xCB, 0x06]) == 15)  // RLC (HL)
        #expect(time([0xCB, 0x46]) == 12)  // BIT 0,(HL)
        #expect(time([0xCB, 0xC6]) == 15)  // SET 0,(HL)
        #expect(time([0xDD, 0x21, 0x00, 0x40]) == 14)  // LD IX,nn
        #expect(time([0xDD, 0x7E, 0x05]) == 19)  // LD A,(IX+d)
        #expect(time([0xDD, 0x77, 0x05]) == 19)  // LD (IX+d),A
        #expect(time([0xDD, 0x36, 0x05, 0x55]) == 19)  // LD (IX+d),n
        #expect(time([0xDD, 0x34, 0x05]) == 23)  // INC (IX+d)
        #expect(time([0xDD, 0x86, 0x05]) == 19)  // ADD A,(IX+d)
        #expect(time([0xDD, 0x26, 0x12]) == 11)  // LD IXH,n
        #expect(time([0xDD, 0x7C]) == 8)  // LD A,IXH
        #expect(time([0xDD, 0x24]) == 8)  // INC IXH
        #expect(time([0xDD, 0x09]) == 15)  // ADD IX,BC
        #expect(time([0xDD, 0x23]) == 10)  // INC IX
        #expect(time([0xDD, 0xE5]) == 15)  // PUSH IX
        #expect(time([0xDD, 0xE1]) == 14)  // POP IX
        #expect(time([0xDD, 0xE3]) == 23)  // EX (SP),IX
        #expect(time([0xDD, 0xE9]) == 8)  // JP (IX)
        #expect(time([0xFD, 0x22, 0x00, 0x40]) == 20)  // LD (nn),IY
        #expect(time([0xDD, 0xCB, 0x05, 0x46]) == 20)  // BIT 0,(IX+d)
        #expect(time([0xDD, 0xCB, 0x05, 0x06]) == 23)  // RLC (IX+d)
        #expect(time([0xFD, 0xCB, 0x05, 0xC0]) == 23)  // SET 0,(IY+d),B
        #expect(time([0xDD, 0x00]) == 8)  // ignored prefix + NOP
        #expect(time([0xDD, 0xDD, 0x21, 0x00, 0x40]) == 18)  // ignored prefix + LD IX,nn
        #expect(time([0xED, 0x57]) == 9)  // LD A,I
        #expect(time([0xED, 0x47]) == 9)  // LD I,A
        #expect(time([0xED, 0x5E]) == 8)  // IM 2
        #expect(time([0xED, 0x44]) == 8)  // NEG
        #expect(time([0xED, 0x52]) == 15)  // SBC HL,DE
        #expect(time([0xED, 0x43, 0x00, 0x40]) == 20)  // LD (nn),BC
        #expect(time([0xED, 0x6F]) == 18)  // RLD
        #expect(time([0xED, 0x78]) == 12)  // IN A,(C)
        #expect(time([0xED, 0x79]) == 12)  // OUT (C),A
        #expect(time([0xED, 0x4D]) == 14)  // RETI
        #expect(time([0xED, 0x45]) == 14)  // RETN
        #expect(time([0xED, 0xA0]) == 16)  // LDI
        #expect(time([0xED, 0x00]) == 8)  // NOP
    }

    @Test func blockRepeats() {
        // LDIR: 21 T-states per repeat, 16 for the last.
        let machine = Z80TestMachine([0xED, 0xB0])
        let cpu = machine.cpu!
        machine.load([1, 2, 3], at: 0x1000)
        cpu.hl = 0x1000
        cpu.de = 0x2000
        cpu.bc = 3
        #expect(cpu.step() == 21)
        #expect(cpu.pc == 0)
        #expect(cpu.step() == 21)
        #expect(cpu.step() == 16)
        #expect(cpu.pc == 2)
        #expect((0..<3).map { machine.memory[0x2000 + $0] } == [1, 2, 3])
        #expect(cpu.bc == 0 && cpu.hl == 0x1003 && cpu.de == 0x2003)
        #expect(cpu.f & Z80.flagPV == 0)

        // CPIR stops when it finds a match.
        let search = Z80TestMachine([0xED, 0xB1])
        search.load([5, 6, 7, 8], at: 0x1000)
        search.cpu.hl = 0x1000
        search.cpu.bc = 4
        search.cpu.a = 7
        #expect(search.cpu.step() == 21)
        #expect(search.cpu.step() == 21)
        #expect(search.cpu.step() == 16)
        #expect(search.cpu.f & Z80.flagZ != 0)
        #expect(search.cpu.f & Z80.flagPV != 0)  // BC is still 1
        #expect(search.cpu.hl == 0x1003 && search.cpu.bc == 1)

        // OTIR outputs with the decremented B in the port's high byte.
        let out = Z80TestMachine([0xED, 0xB3])
        out.load([0xAA, 0xBB], at: 0x1000)
        out.cpu.hl = 0x1000
        out.cpu.bc = 0x0234
        #expect(out.cpu.run(tStates: 37) == 37)
        #expect(out.outputs.map(\.port) == [0x0134, 0x0034])
        #expect(out.outputs.map(\.value) == [0xAA, 0xBB])
        #expect(out.cpu.f & Z80.flagZ != 0)
    }
}

struct Z80InterruptTests {
    @Test func mode1WaitsForTheInstructionAfterEI() {
        // EI; NOP; NOP
        let machine = Z80TestMachine([0xFB, 0x00, 0x00])
        let cpu = machine.cpu!
        cpu.sp = 0x8000
        cpu.im = 1
        cpu.irq = true
        #expect(cpu.step() == 4)  // EI
        #expect(cpu.step() == 4 && cpu.pc == 2)  // NOP: still delayed
        #expect(cpu.step() == 13)  // acceptance
        #expect(cpu.pc == 0x38 && cpu.wz == 0x38)
        #expect(!cpu.iff1 && !cpu.iff2)
        #expect(cpu.sp == 0x7FFE && machine.memory[0x7FFE] == 2 && machine.memory[0x7FFF] == 0)
    }

    @Test func consecutiveEIsKeepDelaying() {
        let machine = Z80TestMachine([0xFB, 0xFB, 0xFB, 0x00])
        let cpu = machine.cpu!
        cpu.sp = 0x8000
        cpu.im = 1
        cpu.irq = true
        cpu.step()
        cpu.step()
        cpu.step()
        #expect(cpu.pc == 3)
        cpu.step()  // the NOP
        #expect(cpu.pc == 4)
        #expect(cpu.step() == 13 && cpu.pc == 0x38)
    }

    @Test func diBlocksInterrupts() {
        let machine = Z80TestMachine([0xF3, 0x00, 0x00])
        let cpu = machine.cpu!
        cpu.iff1 = true
        cpu.iff2 = true
        cpu.im = 1
        cpu.step()  // DI
        cpu.irq = true
        cpu.step()
        cpu.step()
        #expect(cpu.pc == 3)
    }

    @Test func mode2() {
        let machine = Z80TestMachine([0x00])
        let cpu = machine.cpu!
        cpu.sp = 0x8000
        cpu.im = 2
        cpu.i = 0x90
        cpu.interruptDataBus = 0x10
        machine.load([0x34, 0x12], at: 0x9010)
        cpu.iff1 = true
        cpu.irq = true
        #expect(cpu.step() == 19)
        #expect(cpu.pc == 0x1234)
        #expect(machine.memory[0x7FFE] == 0 && machine.memory[0x7FFF] == 0)
    }

    @Test func mode0ExecutesTheDataBusByte() {
        let machine = Z80TestMachine([0x00])
        let cpu = machine.cpu!
        cpu.sp = 0x8000
        cpu.iff1 = true
        cpu.irq = true
        cpu.interruptDataBus = 0xD7  // RST 10
        #expect(cpu.step() == 13)
        #expect(cpu.pc == 0x10)

        // Any single byte instruction works.
        let other = Z80TestMachine([0x00])
        other.cpu.iff1 = true
        other.cpu.irq = true
        other.cpu.a = 1
        other.cpu.interruptDataBus = 0x3C  // INC A
        #expect(other.cpu.step() == 6)
        #expect(other.cpu.a == 2 && other.cpu.pc == 0)
    }

    @Test func nmiIsEdgeTriggeredAndRETNRestoresIFF1() {
        // At 0: NOP; NOP. At $66: RETN.
        let machine = Z80TestMachine([0x00, 0x00])
        machine.load([0xED, 0x45], at: 0x66)
        let cpu = machine.cpu!
        cpu.sp = 0x8000
        cpu.iff1 = true
        cpu.iff2 = true
        cpu.step()
        cpu.setNMI(true)
        #expect(cpu.step() == 11)
        #expect(cpu.pc == 0x66 && !cpu.iff1 && cpu.iff2)
        cpu.setNMI(true)  // still asserted: no new edge
        #expect(cpu.step() == 14)  // RETN
        #expect(cpu.pc == 1 && cpu.iff1)
        cpu.step()
        #expect(cpu.pc == 2)
        cpu.setNMI(false)
        cpu.setNMI(true)
        cpu.step()
        #expect(cpu.pc == 0x66)
    }

    @Test func nmiIsAcceptedWhenInterruptsAreDisabled() {
        let machine = Z80TestMachine([0xF3, 0x00])
        let cpu = machine.cpu!
        cpu.sp = 0x8000
        cpu.step()
        cpu.setNMI(true)
        cpu.step()
        #expect(cpu.pc == 0x66)
    }

    @Test func retiCopiesIFF2() {
        let machine = Z80TestMachine([0xED, 0x4D])
        let cpu = machine.cpu!
        cpu.sp = 0x8000
        machine.load([0x34, 0x12], at: 0x8000)
        cpu.iff2 = true
        #expect(cpu.step() == 14)
        #expect(cpu.pc == 0x1234 && cpu.iff1 && cpu.sp == 0x8002)
    }

    @Test func haltWaitsForAnInterrupt() {
        // HALT at 0, with the IM 1 handler at $38.
        let machine = Z80TestMachine([0x76, 0x00])
        let cpu = machine.cpu!
        cpu.sp = 0x8000
        cpu.im = 1
        cpu.iff1 = true
        #expect(cpu.step() == 4)
        #expect(cpu.halted && cpu.pc == 1)
        let r = cpu.r
        #expect(cpu.step() == 4)
        #expect(cpu.step() == 4)
        #expect(cpu.pc == 1 && cpu.r == r &+ 2)
        #expect(cpu.run(tStates: 100) == 100)
        #expect(cpu.r == r &+ 27)
        cpu.irq = true
        #expect(cpu.step() == 13)
        #expect(!cpu.halted && cpu.pc == 0x38)
        #expect(machine.memory[0x7FFE] == 1)  // returns to after the HALT
    }

    @Test func nmiWakesFromHalt() {
        let machine = Z80TestMachine([0x76])
        let cpu = machine.cpu!
        cpu.sp = 0x8000
        cpu.step()
        cpu.step()
        cpu.setNMI(true)
        #expect(cpu.step() == 11)
        #expect(!cpu.halted && cpu.pc == 0x66 && machine.memory[0x7FFE] == 1)
    }

    @Test func ldAIAndLdARCopyIFF2ToPV() {
        // LD A,I; LD A,R
        let machine = Z80TestMachine([0xED, 0x57, 0xED, 0x5F])
        let cpu = machine.cpu!
        cpu.i = 0x80
        cpu.iff2 = true
        cpu.step()
        #expect(cpu.a == 0x80)
        #expect(cpu.f & Z80.flagPV != 0 && cpu.f & Z80.flagS != 0)
        cpu.iff2 = false
        cpu.step()
        #expect(cpu.a == 4)  // four M1 fetches so far
        #expect(cpu.f & Z80.flagPV == 0)
    }

    @Test func interruptAfterLdAIClearsPV() {
        let machine = Z80TestMachine([0xED, 0x57])
        let cpu = machine.cpu!
        cpu.sp = 0x8000
        cpu.im = 1
        cpu.iff1 = true
        cpu.iff2 = true
        cpu.step()
        #expect(cpu.f & Z80.flagPV != 0)
        cpu.irq = true
        cpu.step()
        #expect(cpu.pc == 0x38 && cpu.f & Z80.flagPV == 0)
    }
}

struct Z80RegisterTests {
    @Test func refreshRegisterCountsM1Cycles() {
        let machine = Z80TestMachine([
            0x00,  // NOP: 1
            0xDD, 0x21, 0x00, 0x00,  // LD IX,0: 2
            0xCB, 0x00,  // RLC B: 2
            0xED, 0x44,  // NEG: 2
            0xFD, 0xCB, 0x00, 0x06,  // RLC (IY+0): 2
            0xDD, 0x00,  // ignored prefix + NOP: 2
        ])
        let cpu = machine.cpu!
        for expected: UInt8 in [1, 3, 5, 7, 9, 11] {
            cpu.step()
            #expect(cpu.r == expected)
        }
        #expect(machine.m1Fetches == 11)
    }

    @Test func refreshRegisterKeepsBit7() {
        // LD A,$FF; LD R,A; NOP; LD A,R
        let machine = Z80TestMachine([0x3E, 0xFF, 0xED, 0x4F, 0x00, 0xED, 0x5F])
        let cpu = machine.cpu!
        cpu.step()
        cpu.step()
        #expect(cpu.r == 0xFF)
        cpu.step()
        #expect(cpu.r == 0x80)
        cpu.step()
        #expect(cpu.a == 0x82)
    }

    @Test func registerPairsAndExchanges() {
        // EXX; EX AF,AF'; EX DE,HL
        let machine = Z80TestMachine([0xD9, 0x08, 0xEB])
        let cpu = machine.cpu!
        cpu.bc = 0x1111
        cpu.de = 0x2222
        cpu.hl = 0x3333
        cpu.af = 0x4444
        cpu.bcPrime = 0x5555
        cpu.dePrime = 0x6666
        cpu.hlPrime = 0x7777
        cpu.afPrime = 0x8888
        cpu.step()
        #expect(cpu.bc == 0x5555 && cpu.de == 0x6666 && cpu.hl == 0x7777 && cpu.af == 0x4444)
        #expect(cpu.bcPrime == 0x1111 && cpu.dePrime == 0x2222 && cpu.hlPrime == 0x3333)
        cpu.step()
        #expect(cpu.af == 0x8888 && cpu.afPrime == 0x4444)
        cpu.step()
        #expect(cpu.de == 0x7777 && cpu.hl == 0x6666)
    }

    @Test func resetState() {
        let cpu = Z80TestMachine().cpu!
        cpu.pc = 0x1234
        cpu.iff1 = true
        cpu.im = 2
        cpu.i = 5
        cpu.r = 9
        cpu.reset()
        #expect(cpu.pc == 0 && !cpu.iff1 && !cpu.iff2 && cpu.im == 0 && cpu.i == 0 && cpu.r == 0)
        #expect(cpu.af == 0xFFFF && cpu.sp == 0xFFFF)
    }
}

struct Z80InstructionTests {
    func run(_ bytes: [UInt8], steps: Int = 1, _ setup: (Z80TestMachine) -> Void = { _ in }) -> Z80TestMachine {
        let machine = Z80TestMachine(bytes)
        machine.cpu.sp = 0x8000
        setup(machine)
        for _ in 0..<steps { machine.cpu.step() }
        return machine
    }

    @Test func scfAndCCFTakeXYFromAOrF() {
        // After an instruction that didn't set the flags, X/Y = (A | F).
        // POP AF (A=$00, F=$28); SCF
        var m = run([0xF1, 0x37], steps: 2) { $0.load([0x28, 0x00], at: 0x8000) }
        #expect(m.cpu.f == 0x28 | Z80.flagC)
        // POP AF (A=$20, F=$08); CCF (C was clear, so C is set)
        m = run([0xF1, 0x3F], steps: 2) { $0.load([0x08, 0x20], at: 0x8000) }
        #expect(m.cpu.f == 0x28 | Z80.flagC)

        // After a flag-setting instruction, X/Y come from A.
        // XOR A; CP $28 (sets X and Y from the operand); SCF
        m = run([0xAF, 0xFE, 0x28, 0x37], steps: 3)
        #expect(m.cpu.f & 0x28 == 0)
        // LD A,$28; OR A; CCF
        m = run([0x3E, 0x28, 0xB7, 0x3F], steps: 3)
        #expect(m.cpu.f & 0x28 == 0x28)
        #expect(m.cpu.f & Z80.flagC != 0)
    }

    @Test func bitHLLeaksMemptr() {
        // LD A,($28FF) sets MEMPTR to $2900; BIT 0,(HL)
        let m = run([0x3A, 0xFF, 0x28, 0xCB, 0x46], steps: 2) { $0.cpu.hl = 0x4000 }
        #expect(m.cpu.wz == 0x2900)
        #expect(m.cpu.f & 0x28 == 0x28)
        #expect(m.cpu.f & Z80.flagZ != 0)
    }

    @Test func bitIndexedTakesXYFromTheAddress() {
        // BIT 7,(IX+$10) with IX = $27F8: address $2808
        let m = run([0xDD, 0xCB, 0x10, 0x7E]) {
            $0.cpu.ix = 0x27F8
            $0.memory[0x2808] = 0x80
        }
        #expect(m.cpu.f & 0x28 == 0x28)
        #expect(m.cpu.f & Z80.flagS != 0 && m.cpu.f & Z80.flagZ == 0)
    }

    @Test func daa() {
        // LD A,$15; ADD A,$27; DAA
        var m = run([0x3E, 0x15, 0xC6, 0x27, 0x27], steps: 3)
        #expect(m.cpu.a == 0x42)
        // LD A,$42; SUB $15; DAA
        m = run([0x3E, 0x42, 0xD6, 0x15, 0x27], steps: 3)
        #expect(m.cpu.a == 0x27 && m.cpu.f & Z80.flagN != 0)
        // LD A,$99; ADD A,$01; DAA: 00 with carry
        m = run([0x3E, 0x99, 0xC6, 0x01, 0x27], steps: 3)
        #expect(m.cpu.a == 0x00 && m.cpu.f & Z80.flagC != 0 && m.cpu.f & Z80.flagZ != 0)
    }

    @Test func indexedRegisterCopy() {
        // RLC (IX+5),B
        let m = run([0xDD, 0xCB, 0x05, 0x00]) {
            $0.cpu.ix = 0x1000
            $0.memory[0x1005] = 0x81
        }
        #expect(m.memory[0x1005] == 0x03 && m.cpu.b == 0x03)
        #expect(m.cpu.f & Z80.flagC != 0)
        // SET 7,(IY-1),A
        let s = run([0xFD, 0xCB, 0xFF, 0xFF]) { $0.cpu.iy = 0x1000 }
        #expect(s.memory[0x0FFF] == 0x80 && s.cpu.a == 0x80)
    }

    @Test func indexHalves() {
        // LD IXH,$12; LD IXL,$34; LD A,IXH; ADD A,IXL; LD IYL,A
        let m = run([0xDD, 0x26, 0x12, 0xDD, 0x2E, 0x34, 0xDD, 0x7C, 0xDD, 0x85, 0xFD, 0x6F], steps: 5)
        #expect(m.cpu.ix == 0x1234)
        #expect(m.cpu.a == 0x46)
        #expect(m.cpu.iy & 0xFF == 0x46)
        // LD H,(IX+1) loads the real H.
        let n = run([0xDD, 0x66, 0x01]) {
            $0.cpu.ix = 0x2000
            $0.memory[0x2001] = 0x99
        }
        #expect(n.cpu.h == 0x99 && n.cpu.ix == 0x2000)
    }

    @Test func sll() {
        let m = run([0xCB, 0x30]) { $0.cpu.b = 0x80 }
        #expect(m.cpu.b == 0x01 && m.cpu.f & Z80.flagC != 0)
    }

    @Test func ports() {
        // LD A,$12; IN A,($34); IN B,(C); IN (C); OUT (C),0; OUT ($56),A
        let m = run([0x3E, 0x12, 0xDB, 0x34, 0xED, 0x40, 0xED, 0x70, 0xED, 0x71, 0xD3, 0x56], steps: 6) {
            $0.cpu.bc = 0x7F80
            $0.inputSequence = [0x55, 0x00, 0x81]
        }
        #expect(m.inputs == [0x1234, 0x7F80, 0x0080])
        #expect(m.cpu.b == 0x00)
        #expect(m.cpu.f & Z80.flagS != 0 && m.cpu.f & Z80.flagPV != 0)  // from IN (C) = $81
        #expect(m.outputs.map(\.port) == [0x0080, 0x5556])
        #expect(m.outputs.map(\.value) == [0x00, 0x55])
    }

    @Test func memptr() {
        // LD A,$12; LD ($80FF),A
        var m = run([0x3E, 0x12, 0x32, 0xFF, 0x80], steps: 2)
        #expect(m.cpu.wz == 0x1200)
        // LD HL,($4000)
        m = run([0x2A, 0x00, 0x40])
        #expect(m.cpu.wz == 0x4001)
        // JP $1234
        m = run([0xC3, 0x34, 0x12])
        #expect(m.cpu.wz == 0x1234)
        // ADD HL,DE
        m = run([0x19]) { $0.cpu.hl = 0x1000 }
        #expect(m.cpu.wz == 0x1001)
        // LD A,(IX-2)
        m = run([0xDD, 0x7E, 0xFE]) { $0.cpu.ix = 0x1000 }
        #expect(m.cpu.wz == 0x0FFE)
    }

    @Test func interruptedLDIRTakesXYFromPC() {
        // LDIR at $2800, interrupted after one iteration
        let m = Z80TestMachine()
        m.load([0xED, 0xB0], at: 0x2800)
        m.cpu.pc = 0x2800
        m.cpu.hl = 0x1000
        m.cpu.de = 0x2000
        m.cpu.bc = 2
        m.cpu.step()
        #expect(m.cpu.pc == 0x2800)
        #expect(m.cpu.f & 0x28 == 0x28)
        #expect(m.cpu.wz == 0x2801)
    }
}

struct Z80DisassemblerTests {
    func dis(_ bytes: [UInt8], at address: UInt16 = 0) -> (String, Int) {
        let result = Z80Disassembler().disassemble(at: address) { a in
            let i = Int(a &- address)
            return i < bytes.count ? bytes[i] : 0
        }
        return (result.text, result.length)
    }

    @Test func instructions() {
        let cases: [([UInt8], String, Int)] = [
            ([0x00], "NOP", 1),
            ([0x01, 0x34, 0x12], "LD BC,$1234", 3),
            ([0x08], "EX AF,AF'", 1),
            ([0x10, 0xFE], "DJNZ $1000", 2),
            ([0x20, 0x05], "JR NZ,$1007", 2),
            ([0x22, 0x00, 0x40], "LD ($4000),HL", 3),
            ([0x3A, 0x00, 0x40], "LD A,($4000)", 3),
            ([0x36, 0x55], "LD (HL),$55", 2),
            ([0x76], "HALT", 1),
            ([0x7E], "LD A,(HL)", 1),
            ([0x41], "LD B,C", 1),
            ([0x96], "SUB (HL)", 1),
            ([0x8F], "ADC A,A", 1),
            ([0xFE, 0x10], "CP $10", 2),
            ([0xC0], "RET NZ", 1),
            ([0xF1], "POP AF", 1),
            ([0xE9], "JP (HL)", 1),
            ([0xFA, 0x00, 0x80], "JP M,$8000", 3),
            ([0xD3, 0xFE], "OUT ($FE),A", 2),
            ([0xDB, 0x01], "IN A,($01)", 2),
            ([0xE3], "EX (SP),HL", 1),
            ([0xCD, 0x05, 0x00], "CALL $0005", 3),
            ([0xFF], "RST $38", 1),
            ([0xCB, 0x00], "RLC B", 2),
            ([0xCB, 0x36], "SLL (HL)", 2),
            ([0xCB, 0x7E], "BIT 7,(HL)", 2),
            ([0xCB, 0xC7], "SET 0,A", 2),
            ([0xED, 0x40], "IN B,(C)", 2),
            ([0xED, 0x70], "IN (C)", 2),
            ([0xED, 0x71], "OUT (C),0", 2),
            ([0xED, 0x52], "SBC HL,DE", 2),
            ([0xED, 0x7B, 0x00, 0x80], "LD SP,($8000)", 4),
            ([0xED, 0x4C], "NEG", 2),
            ([0xED, 0x4D], "RETI", 2),
            ([0xED, 0x55], "RETN", 2),
            ([0xED, 0x5E], "IM 2", 2),
            ([0xED, 0x5F], "LD A,R", 2),
            ([0xED, 0x6F], "RLD", 2),
            ([0xED, 0xB0], "LDIR", 2),
            ([0xED, 0xBB], "OTDR", 2),
            ([0xED, 0x00], "DB $ED,$00", 2),
            ([0xDD, 0x21, 0x34, 0x12], "LD IX,$1234", 4),
            ([0xFD, 0x2A, 0x00, 0x40], "LD IY,($4000)", 4),
            ([0xDD, 0x7E, 0x05], "LD A,(IX+$05)", 3),
            ([0xFD, 0x77, 0xFB], "LD (IY-$05),A", 3),
            ([0xDD, 0x66, 0x01], "LD H,(IX+$01)", 3),
            ([0xDD, 0x36, 0x02, 0x99], "LD (IX+$02),$99", 4),
            ([0xDD, 0x34, 0x80], "INC (IX-$80)", 3),
            ([0xDD, 0x26, 0x12], "LD IXH,$12", 3),
            ([0xFD, 0x6C], "LD IYL,IYH", 2),
            ([0xDD, 0x85], "ADD A,IXL", 2),
            ([0xDD, 0x29], "ADD IX,IX", 2),
            ([0xDD, 0x19], "ADD IX,DE", 2),
            ([0xDD, 0xE5], "PUSH IX", 2),
            ([0xDD, 0xE9], "JP (IX)", 2),
            ([0xFD, 0xF9], "LD SP,IY", 2),
            ([0xDD, 0xE3], "EX (SP),IX", 2),
            ([0xDD, 0xCB, 0x05, 0x06], "RLC (IX+$05)", 4),
            ([0xDD, 0xCB, 0x05, 0x00], "RLC (IX+$05),B", 4),
            ([0xFD, 0xCB, 0xFF, 0x4E], "BIT 1,(IY-$01)", 4),
            ([0xFD, 0xCB, 0xFF, 0x48], "BIT 1,(IY-$01)", 4),
            ([0xFD, 0xCB, 0x00, 0xFF], "SET 7,(IY+$00),A", 4),
            ([0xDD, 0x00], "DB $DD", 1),
            ([0xDD, 0xEB], "DB $DD", 1),
            ([0xDD, 0xDD, 0x21], "DB $DD", 1),
            ([0xFD, 0xED, 0x44], "DB $FD", 1),
        ]
        for (bytes, text, length) in cases {
            let (t, n) = dis(bytes, at: 0x1000)
            #expect(t == text && n == length, "\(bytes.map { hex($0) })")
        }
    }

    @Test func everyOpcodeDecodes() {
        // Lengths agree with execution: run each instruction from a NOP-filled
        // page and compare the PC change (for non-jumps).
        for prefix: [UInt8] in [[], [0xCB], [0xED], [0xDD], [0xFD], [0xDD, 0xCB, 0x01], [0xFD, 0xCB, 0x01]] {
            for op in 0...255 {
                let bytes = prefix + [UInt8(op), 0x01, 0x01]
                let (text, length) = dis(bytes)
                #expect(!text.isEmpty)
                #expect((1...4).contains(length))
            }
        }
    }
}
