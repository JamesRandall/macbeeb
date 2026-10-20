/// Disassembles 80186 instructions in Intel (MASM) syntax: "MOV AX,[BX+SI+12h]",
/// "ADD BYTE PTR ES:[DI],5", "REP MOVSB". Numbers are hex with an h suffix
/// (and a leading 0 if they'd start with a letter); jump targets are shown
/// as offsets in the current code segment.
///
/// Opcodes the 80186 traps as undefined are shown as "DB 0Fh" (length 1).
public struct I80186Disassembler: Sendable {
    public init() {}

    /// Disassembles the instruction at `segment:offset`, reading memory by
    /// linear address with `read` (which should have no side effects).
    /// Returns the text and the instruction's length in bytes.
    public func disassemble(segment: UInt16, offset: UInt16, read: (Int) -> UInt8) -> (text: String, length: Int) {
        withoutActuallyEscaping(read) { read in
            var decoder = Decoder(segment: segment, offset: offset, read: read)
            let text = decoder.decode()
            return (text, decoder.length)
        }
    }
}

private let reg8Names = ["AL", "CL", "DL", "BL", "AH", "CH", "DH", "BH"]
private let reg16Names = ["AX", "CX", "DX", "BX", "SP", "BP", "SI", "DI"]
private let sregNames = ["ES", "CS", "SS", "DS"]
private let baseNames = ["BX+SI", "BX+DI", "BP+SI", "BP+DI", "SI", "DI", "BP", "BX"]
private let aluNames = ["ADD", "OR", "ADC", "SBB", "AND", "SUB", "XOR", "CMP"]
private let shiftNames = ["ROL", "ROR", "RCL", "RCR", "SHL", "SHR", "SHL", "SAR"]
private let group3Names = ["TEST", "TEST", "NOT", "NEG", "MUL", "IMUL", "DIV", "IDIV"]
private let jccNames = ["JO", "JNO", "JB", "JAE", "JE", "JNE", "JBE", "JA",
                        "JS", "JNS", "JP", "JNP", "JL", "JGE", "JLE", "JG"]

/// MASM style hex: "0FFh", "12h", "0".
private func hex(_ v: Int, digits: Int = 1) -> String {
    var s = String(v, radix: 16, uppercase: true)
    if s.count < digits { s = String(repeating: "0", count: digits - s.count) + s }
    if v < 10 && digits == 1 { return s }
    if let first = s.first, first >= "A" { s = "0" + s }
    return s + "h"
}

private struct Decoder {
    let segment: UInt16
    let offset: UInt16
    let read: (Int) -> UInt8
    var length = 0
    var override: String?
    var modrm: UInt8 = 0

    init(segment: UInt16, offset: UInt16, read: @escaping (Int) -> UInt8) {
        self.segment = segment
        self.offset = offset
        self.read = read
    }

    mutating func next() -> UInt8 {
        let v = read((Int(segment) << 4 + Int(offset &+ UInt16(length))) & 0xFFFFF)
        length += 1
        return v
    }

    mutating func word() -> Int {
        let lo = Int(next())
        return Int(next()) << 8 | lo
    }

    mutating func imm8() -> String { hex(Int(next())) }
    mutating func imm16() -> String { hex(word()) }

    /// A sign extended byte immediate, as a word.
    mutating func simm8() -> String {
        hex(Int(UInt16(bitPattern: Int16(Int8(bitPattern: next())))))
    }

    mutating func rel8() -> String {
        let d = Int8(bitPattern: next())
        return hex(Int(offset &+ UInt16(length) &+ UInt16(bitPattern: Int16(d))), digits: 4)
    }

    mutating func rel16() -> String {
        let d = UInt16(word())
        return hex(Int(offset &+ UInt16(length) &+ d), digits: 4)
    }

    var reg: Int { Int(modrm >> 3) & 7 }

    /// The r/m operand: a register, or a memory reference with `size`
    /// ("BYTE PTR " etc.) in front when the size isn't otherwise implied.
    mutating func rm(wide: Bool, size: String = "") -> String {
        if modrm >= 0xC0 {
            return wide ? reg16Names[Int(modrm & 7)] : reg8Names[Int(modrm & 7)]
        }
        return size + memory()
    }

    mutating func memory() -> String {
        let mod = modrm >> 6
        let r = Int(modrm & 7)
        var inner: String
        if mod == 0 && r == 6 {
            inner = hex(word())
        } else {
            inner = baseNames[r]
            if mod == 1 {
                let d = Int(Int8(bitPattern: next()))
                if d != 0 { inner += d < 0 ? "-" + hex(-d) : "+" + hex(d) }
            } else if mod == 2 {
                inner += "+" + hex(word())
            }
        }
        return (override.map { $0 + ":" } ?? "") + "[" + inner + "]"
    }

    func sizePtr(_ wide: Bool) -> String { wide ? "WORD PTR " : "BYTE PTR " }

    mutating func decode() -> String {
        var prefixes: [String] = []
        var op = next()
        while true {
            switch op {
            case 0x26: override = "ES"
            case 0x2E: override = "CS"
            case 0x36: override = "SS"
            case 0x3E: override = "DS"
            case 0xF0: prefixes.append("LOCK")
            case 0xF2: prefixes.append("REPNE")
            case 0xF3: prefixes.append("REP")
            default:
                let text = instruction(op)
                // An override with no memory operand to apply to.
                if let o = override, !text.contains(o + ":") {
                    prefixes.insert(o + ":", at: 0)
                }
                if prefixes.contains("REP") && ["CMPS", "SCAS"].contains(where: { text.hasPrefix($0) }) {
                    prefixes = prefixes.map { $0 == "REP" ? "REPE" : $0 }
                }
                return (prefixes + [text]).joined(separator: " ")
            }
            op = next()
        }
    }

    mutating func instruction(_ op: UInt8) -> String {
        let wide = op & 1 != 0
        switch op {
        case 0x00...0x3F where op & 7 < 6:
            let name = aluNames[Int(op >> 3)]
            switch op & 7 {
            case 0, 1:
                modrm = next()
                let r = wide ? reg16Names[reg] : reg8Names[reg]
                return "\(name) \(rm(wide: wide)),\(r)"
            case 2, 3:
                modrm = next()
                let r = wide ? reg16Names[reg] : reg8Names[reg]
                return "\(name) \(r),\(rm(wide: wide))"
            case 4: return "\(name) AL,\(imm8())"
            default: return "\(name) AX,\(imm16())"
            }
        case 0x06, 0x0E, 0x16, 0x1E: return "PUSH " + sregNames[Int(op >> 3)]
        case 0x07, 0x17, 0x1F: return "POP " + sregNames[Int(op >> 3)]
        case 0x27: return "DAA"
        case 0x2F: return "DAS"
        case 0x37: return "AAA"
        case 0x3F: return "AAS"
        case 0x40...0x47: return "INC " + reg16Names[Int(op & 7)]
        case 0x48...0x4F: return "DEC " + reg16Names[Int(op & 7)]
        case 0x50...0x57: return "PUSH " + reg16Names[Int(op & 7)]
        case 0x58...0x5F: return "POP " + reg16Names[Int(op & 7)]
        case 0x60: return "PUSHA"
        case 0x61: return "POPA"
        case 0x62:
            modrm = next()
            return "BOUND \(reg16Names[reg]),\(rm(wide: true))"
        case 0x68: return "PUSH " + imm16()
        case 0x69, 0x6B:
            modrm = next()
            let src = rm(wide: true)
            return "IMUL \(reg16Names[reg]),\(src),\(op == 0x69 ? imm16() : simm8())"
        case 0x6A: return "PUSH " + simm8()
        case 0x6C: return "INSB"
        case 0x6D: return "INSW"
        case 0x6E: return "OUTSB"
        case 0x6F: return "OUTSW"
        case 0x70...0x7F: return jccNames[Int(op & 0xF)] + " " + rel8()
        case 0x80...0x83:
            modrm = next()
            let dst = rm(wide: wide, size: sizePtr(wide))
            let src = op == 0x81 ? imm16() : op == 0x83 ? simm8() : imm8()
            return "\(aluNames[reg]) \(dst),\(src)"
        case 0x84, 0x85, 0x86, 0x87, 0x88, 0x89:
            modrm = next()
            let name = op < 0x86 ? "TEST" : op < 0x88 ? "XCHG" : "MOV"
            let r = wide ? reg16Names[reg] : reg8Names[reg]
            return "\(name) \(rm(wide: wide)),\(r)"
        case 0x8A, 0x8B:
            modrm = next()
            let r = wide ? reg16Names[reg] : reg8Names[reg]
            return "MOV \(r),\(rm(wide: wide))"
        case 0x8C:
            modrm = next()
            return "MOV \(rm(wide: true)),\(sregNames[reg & 3])"
        case 0x8D:
            modrm = next()
            return "LEA \(reg16Names[reg]),\(rm(wide: true))"
        case 0x8E:
            modrm = next()
            return "MOV \(sregNames[reg & 3]),\(rm(wide: true))"
        case 0x8F:
            modrm = next()
            return "POP " + rm(wide: true, size: "WORD PTR ")
        case 0x90: return "NOP"
        case 0x91...0x97: return "XCHG AX," + reg16Names[Int(op & 7)]
        case 0x98: return "CBW"
        case 0x99: return "CWD"
        case 0x9A:
            let o = word()
            return "CALL \(hex(word(), digits: 4)):\(hex(o, digits: 4))"
        case 0x9B: return "WAIT"
        case 0x9C: return "PUSHF"
        case 0x9D: return "POPF"
        case 0x9E: return "SAHF"
        case 0x9F: return "LAHF"
        case 0xA0, 0xA1:
            return "MOV \(wide ? "AX" : "AL"),\(override.map { $0 + ":" } ?? "")[\(imm16())]"
        case 0xA2, 0xA3:
            return "MOV \(override.map { $0 + ":" } ?? "")[\(imm16())],\(wide ? "AX" : "AL")"
        case 0xA4: return "MOVSB"
        case 0xA5: return "MOVSW"
        case 0xA6: return "CMPSB"
        case 0xA7: return "CMPSW"
        case 0xA8: return "TEST AL," + imm8()
        case 0xA9: return "TEST AX," + imm16()
        case 0xAA: return "STOSB"
        case 0xAB: return "STOSW"
        case 0xAC: return "LODSB"
        case 0xAD: return "LODSW"
        case 0xAE: return "SCASB"
        case 0xAF: return "SCASW"
        case 0xB0...0xB7: return "MOV \(reg8Names[Int(op & 7)]),\(imm8())"
        case 0xB8...0xBF: return "MOV \(reg16Names[Int(op & 7)]),\(imm16())"
        case 0xC0, 0xC1:
            modrm = next()
            let dst = rm(wide: wide, size: sizePtr(wide))
            return "\(shiftNames[reg]) \(dst),\(imm8())"
        case 0xC2: return "RET " + imm16()
        case 0xC3: return "RET"
        case 0xC4, 0xC5:
            modrm = next()
            return "\(op == 0xC4 ? "LES" : "LDS") \(reg16Names[reg]),\(rm(wide: true))"
        case 0xC6, 0xC7:
            modrm = next()
            let dst = rm(wide: wide, size: sizePtr(wide))
            return "MOV \(dst),\(wide ? imm16() : imm8())"
        case 0xC8:
            let size = imm16()
            return "ENTER \(size),\(imm8())"
        case 0xC9: return "LEAVE"
        case 0xCA: return "RETF " + imm16()
        case 0xCB: return "RETF"
        case 0xCC: return "INT 3"
        case 0xCD: return "INT " + imm8()
        case 0xCE: return "INTO"
        case 0xCF: return "IRET"
        case 0xD0...0xD3:
            modrm = next()
            let dst = rm(wide: wide, size: sizePtr(wide))
            return "\(shiftNames[reg]) \(dst),\(op < 0xD2 ? "1" : "CL")"
        case 0xD4:
            let b = next()
            return b == 10 ? "AAM" : "AAM " + hex(Int(b))
        case 0xD5:
            let b = next()
            return b == 10 ? "AAD" : "AAD " + hex(Int(b))
        case 0xD6: return "SALC"
        case 0xD7: return "XLAT"
        case 0xD8...0xDF:
            modrm = next()
            return "ESC \(hex(Int(op & 7) << 3 | reg)),\(rm(wide: true))"
        case 0xE0: return "LOOPNE " + rel8()
        case 0xE1: return "LOOPE " + rel8()
        case 0xE2: return "LOOP " + rel8()
        case 0xE3: return "JCXZ " + rel8()
        case 0xE4: return "IN AL," + imm8()
        case 0xE5: return "IN AX," + imm8()
        case 0xE6: return "OUT \(imm8()),AL"
        case 0xE7: return "OUT \(imm8()),AX"
        case 0xE8: return "CALL " + rel16()
        case 0xE9: return "JMP " + rel16()
        case 0xEA:
            let o = word()
            return "JMP \(hex(word(), digits: 4)):\(hex(o, digits: 4))"
        case 0xEB: return "JMP SHORT " + rel8()
        case 0xEC: return "IN AL,DX"
        case 0xED: return "IN AX,DX"
        case 0xEE: return "OUT DX,AL"
        case 0xEF: return "OUT DX,AX"
        case 0xF4: return "HLT"
        case 0xF5: return "CMC"
        case 0xF6, 0xF7:
            modrm = next()
            let dst = rm(wide: wide, size: sizePtr(wide))
            if reg < 2 { return "TEST \(dst),\(wide ? imm16() : imm8())" }
            return "\(group3Names[reg]) \(dst)"
        case 0xF8: return "CLC"
        case 0xF9: return "STC"
        case 0xFA: return "CLI"
        case 0xFB: return "STI"
        case 0xFC: return "CLD"
        case 0xFD: return "STD"
        case 0xFE:
            modrm = next()
            if reg > 1 { return "DB 0FEh," + hex(Int(modrm)) }
            return "\(reg == 0 ? "INC" : "DEC") \(rm(wide: false, size: "BYTE PTR "))"
        case 0xFF:
            modrm = next()
            switch reg {
            case 0: return "INC " + rm(wide: true, size: "WORD PTR ")
            case 1: return "DEC " + rm(wide: true, size: "WORD PTR ")
            case 2: return "CALL " + rm(wide: true, size: "WORD PTR ")
            case 3: return "CALL " + rm(wide: true, size: "DWORD PTR ")
            case 4: return "JMP " + rm(wide: true, size: "WORD PTR ")
            case 5: return "JMP " + rm(wide: true, size: "DWORD PTR ")
            case 6: return "PUSH " + rm(wide: true, size: "WORD PTR ")
            default: return "DB 0FFh," + hex(Int(modrm))
            }
        default:  // 0F, 63-67, F1
            return "DB " + hex(Int(op))
        }
    }
}
