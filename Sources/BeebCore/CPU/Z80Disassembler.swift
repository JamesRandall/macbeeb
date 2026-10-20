/// Disassembles Z80 instructions with Zilog mnemonics, including the
/// undocumented ones: SLL, IXH/IXL/IYH/IYL, IN (C), OUT (C),0, the DDCB/FDCB
/// register copies (e.g. "RLC (IX+$05),B") and the ED mirrors of NEG, RETN
/// and IM. Numbers are hex with a $ prefix, as in `M6502Disassembler`.
///
/// A DD or FD prefix in front of an instruction it doesn't affect is shown
/// on its own as "DB $DD" (length 1), as are ED xx opcodes that are NOPs
/// ("DB $ED,$xx", length 2).
public struct Z80Disassembler: Sendable {
    public init() {}

    /// Disassembles the instruction at `address`, reading memory with `read`
    /// (which should have no side effects). Returns the text, e.g.
    /// "LD A,(IX+$05)", and the instruction's length in bytes.
    public func disassemble(at address: UInt16, read: (UInt16) -> UInt8) -> (text: String, length: Int) {
        withoutActuallyEscaping(read) { read in
            var decoder = Decoder(address: address, read: read)
            let text = decoder.decode()
            return (text, decoder.length)
        }
    }
}

private let registers = ["B", "C", "D", "E", "H", "L", "(HL)", "A"]
private let pairs = ["BC", "DE", "HL", "SP"]
private let pairs2 = ["BC", "DE", "HL", "AF"]
private let conditions = ["NZ", "Z", "NC", "C", "PO", "PE", "P", "M"]
private let aluOps = ["ADD A,", "ADC A,", "SUB ", "SBC A,", "AND ", "XOR ", "OR ", "CP "]
private let rotations = ["RLC", "RRC", "RL", "RR", "SLA", "SRA", "SLL", "SRL"]
private let accumulatorOps = ["RLCA", "RRCA", "RLA", "RRA", "DAA", "CPL", "SCF", "CCF"]
private let interruptModes = ["0", "0", "1", "2", "0", "0", "1", "2"]
private let blockOps = [
    ["LDI", "CPI", "INI", "OUTI"], ["LDD", "CPD", "IND", "OUTD"],
    ["LDIR", "CPIR", "INIR", "OTIR"], ["LDDR", "CPDR", "INDR", "OTDR"],
]

private func hex2(_ v: UInt8) -> String { "$" + hexDigits(UInt16(v), 2) }
private func hex4(_ v: UInt16) -> String { "$" + hexDigits(v, 4) }

private struct Decoder {
    let address: UInt16
    let read: (UInt16) -> UInt8
    var length = 0
    /// "IX" or "IY" after a DD/FD prefix.
    var index: String?
    /// Set when the instruction used H, L, HL or (HL), so an index prefix
    /// had an effect.
    var usedHL = false

    init(address: UInt16, read: @escaping (UInt16) -> UInt8) {
        self.address = address
        self.read = read
    }

    mutating func next() -> UInt8 {
        let v = read(address &+ UInt16(length))
        length += 1
        return v
    }

    mutating func word() -> String {
        let lo = next()
        return hex4(UInt16(next()) << 8 | UInt16(lo))
    }

    mutating func displacement() -> String {
        let d = Int8(bitPattern: next())
        return d < 0 ? "-" + hex2(UInt8(-Int(d))) : "+" + hex2(UInt8(d))
    }

    mutating func relative() -> String {
        let d = Int8(bitPattern: next())
        return hex4(address &+ UInt16(length) &+ UInt16(bitPattern: Int16(d)))
    }

    /// (HL), or (IX+d) after a prefix.
    mutating func memoryOperand() -> String {
        usedHL = true
        guard let index else { return "(HL)" }
        return "(" + index + displacement() + ")"
    }

    /// Register `code`. With a prefix, H and L become IXH and IXL unless
    /// `realHL` (the instruction also uses (IX+d)).
    mutating func register(_ code: Int, realHL: Bool = false) -> String {
        switch code {
        case 6: return memoryOperand()
        case 4, 5:
            usedHL = true
            if let index, !realHL { return index + (code == 4 ? "H" : "L") }
            return registers[code]
        default: return registers[code]
        }
    }

    mutating func pair(_ p: Int, _ table: [String] = pairs) -> String {
        guard p == 2 else { return table[p] }
        usedHL = true
        return index ?? "HL"
    }

    mutating func decode() -> String {
        let op = next()
        switch op {
        case 0xCB: return decodeCB()
        case 0xED: return decodeED()
        case 0xDD, 0xFD:
            index = op == 0xDD ? "IX" : "IY"
            let following = read(address &+ 1)
            if following == 0xCB { return decodeIndexedCB() }
            if following != 0xDD && following != 0xFD && following != 0xED {
                let text = decodeUnprefixed(next())
                if usedHL { return text }
            }
            length = 1
            return "DB " + hex2(op)
        default:
            return decodeUnprefixed(op)
        }
    }

    mutating func decodeUnprefixed(_ op: UInt8) -> String {
        let x = Int(op >> 6), y = Int(op >> 3) & 7, z = Int(op) & 7
        let p = y >> 1, q = y & 1
        switch x {
        case 0:
            switch z {
            case 0:
                switch y {
                case 0: return "NOP"
                case 1: return "EX AF,AF'"
                case 2: return "DJNZ " + relative()
                case 3: return "JR " + relative()
                default: return "JR " + conditions[y - 4] + "," + relative()
                }
            case 1:
                if q == 0 {
                    let rp = pair(p)
                    return "LD " + rp + "," + word()
                }
                let dst = pair(2)
                return "ADD " + dst + "," + pair(p)
            case 2:
                switch (p, q) {
                case (0, 0): return "LD (BC),A"
                case (1, 0): return "LD (DE),A"
                case (2, 0): let rp = pair(2); return "LD (" + word() + ")," + rp
                case (3, 0): return "LD (" + word() + "),A"
                case (0, _): return "LD A,(BC)"
                case (1, _): return "LD A,(DE)"
                case (2, _): let rp = pair(2); return "LD " + rp + ",(" + word() + ")"
                default: return "LD A,(" + word() + ")"
                }
            case 3: return (q == 0 ? "INC " : "DEC ") + pair(p)
            case 4: return "INC " + register(y)
            case 5: return "DEC " + register(y)
            case 6:
                let dst = register(y)
                return "LD " + dst + "," + hex2(next())
            default: return accumulatorOps[y]
            }
        case 1:
            if op == 0x76 { return "HALT" }
            let usesMemory = y == 6 || z == 6
            let dst = register(y, realHL: usesMemory)
            return "LD " + dst + "," + register(z, realHL: usesMemory)
        case 2:
            return aluOps[y] + register(z)
        default:
            switch z {
            case 0: return "RET " + conditions[y]
            case 1:
                if q == 0 { return "POP " + pair(p, pairs2) }
                switch p {
                case 0: return "RET"
                case 1: return "EXX"
                case 2: return "JP (" + pair(2) + ")"
                default: return "LD SP," + pair(2)
                }
            case 2: return "JP " + conditions[y] + "," + word()
            case 3:
                switch y {
                case 0: return "JP " + word()
                case 2: return "OUT (" + hex2(next()) + "),A"
                case 3: return "IN A,(" + hex2(next()) + ")"
                case 4: return "EX (SP)," + pair(2)
                case 5: return "EX DE,HL"
                case 6: return "DI"
                default: return "EI"  // y == 1 (CB) is handled by the caller
                }
            case 4: return "CALL " + conditions[y] + "," + word()
            case 5:
                if q == 0 { return "PUSH " + pair(p, pairs2) }
                return "CALL " + word()  // the prefixes are handled by the caller
            case 6: return aluOps[y] + hex2(next())
            default: return "RST " + hex2(UInt8(y * 8))
            }
        }
    }

    mutating func decodeCB() -> String {
        let op = next()
        return cbText(op, operand: registers[Int(op) & 7])
    }

    func cbText(_ op: UInt8, operand: String) -> String {
        let y = Int(op >> 3) & 7
        switch op >> 6 {
        case 0: return rotations[y] + " " + operand
        case 1: return "BIT \(y)," + operand
        case 2: return "RES \(y)," + operand
        default: return "SET \(y)," + operand
        }
    }

    mutating func decodeIndexedCB() -> String {
        length = 2
        let operand = memoryOperand()
        let op = next()
        let z = Int(op) & 7
        var text = cbText(op, operand: operand)
        if op >> 6 != 1 && z != 6 { text += "," + registers[z] }
        return text
    }

    mutating func decodeED() -> String {
        let op = next()
        let x = Int(op >> 6), y = Int(op >> 3) & 7, z = Int(op) & 7
        let p = y >> 1, q = y & 1
        if x == 1 {
            switch z {
            case 0: return y == 6 ? "IN (C)" : "IN " + registers[y] + ",(C)"
            case 1: return y == 6 ? "OUT (C),0" : "OUT (C)," + registers[y]
            case 2: return (q == 0 ? "SBC HL," : "ADC HL,") + pairs[p]
            case 3: return q == 0 ? "LD (" + word() + ")," + pairs[p] : "LD " + pairs[p] + ",(" + word() + ")"
            case 4: return "NEG"
            case 5: return y == 1 ? "RETI" : "RETN"
            case 6: return "IM " + interruptModes[y]
            default:
                switch y {
                case 0: return "LD I,A"
                case 1: return "LD R,A"
                case 2: return "LD A,I"
                case 3: return "LD A,R"
                case 4: return "RRD"
                case 5: return "RLD"
                default: break
                }
            }
        } else if x == 2 && z <= 3 && y >= 4 {
            return blockOps[y - 4][z]
        }
        return "DB $ED," + hex2(op)
    }
}
