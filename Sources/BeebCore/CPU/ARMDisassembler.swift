/// Disassembles ARM (26-bit, ARM2) instructions in Acorn's syntax: upper
/// case, the condition before S or B ("ADDEQS", "LDRNEB"), R15 as PC and
/// hex numbers with a & prefix. Branch targets are absolute. The P forms of
/// the comparisons are shown as "TEQP" and so on, and coprocessor
/// instructions are decoded although the Evaluation System has none.
public struct ARMDisassembler: Sendable {
    public init() {}

    /// Disassembles the instruction at `address`, reading memory a word at a
    /// time with `read` (which should have no side effects). Returns the
    /// text, e.g. "LDR R0,[R1,#&04]!", and the length in bytes (always 4).
    public func disassemble(at address: UInt32, read: (UInt32) -> UInt32) -> (text: String, length: Int) {
        (Self.decode(read(address & ~3), at: address & ~3), 4)
    }

    /// Disassembles one instruction word.
    public static func decode(_ i: UInt32, at address: UInt32) -> String {
        let cond = conditions[Int(i >> 28)]
        switch (i >> 25) & 7 {
        case 0 where i & 0x0FC0_00F0 == 0x0000_0090:
            let s = i & (1 << 20) != 0 ? "S" : ""
            let rd = reg(i >> 16), rm = reg(i), rs = reg(i >> 8)
            if i & (1 << 21) != 0 {
                return "MLA\(cond)\(s) \(rd),\(rm),\(rs),\(reg(i >> 12))"
            }
            return "MUL\(cond)\(s) \(rd),\(rm),\(rs)"
        case 0, 1:
            return dataProcessing(i, cond)
        case 2, 3:
            if i & (1 << 25) != 0 && i & 0x10 != 0 { return "Undefined" }
            return singleTransfer(i, cond, at: address)
        case 4:
            let load = i & (1 << 20) != 0
            let mode = ["DA", "IA", "DB", "IB"][Int((i >> 23) & 3)]
            let writeback = i & (1 << 21) != 0 ? "!" : ""
            let hat = i & (1 << 22) != 0 ? "^" : ""
            return "\(load ? "LDM" : "STM")\(cond)\(mode) \(reg(i >> 16))\(writeback),{\(registerList(i & 0xFFFF))}\(hat)"
        case 5:
            let offset = UInt32(bitPattern: Int32(bitPattern: i << 8) >> 6)
            let target = (address &+ 8 &+ offset) & 0x03FF_FFFC
            return "\(i & (1 << 24) != 0 ? "BL" : "B")\(cond) &\(hex(target, 8))"
        case 6:
            let load = i & (1 << 20) != 0
            let long = i & (1 << 22) != 0 ? "L" : ""
            let offset = (i & 0xFF) << 2
            let sign = i & (1 << 23) != 0 ? "" : "-"
            let rn = reg(i >> 16)
            let operand = i & (1 << 24) != 0
                ? "[\(rn),#\(sign)&\(hex(offset, 2))]\(i & (1 << 21) != 0 ? "!" : "")"
                : "[\(rn)],#\(sign)&\(hex(offset, 2))"
            return "\(load ? "LDC" : "STC")\(cond)\(long) CP\((i >> 8) & 15),C\((i >> 12) & 15),\(operand)"
        default:
            if i & (1 << 24) != 0 {
                return "SWI\(cond) &\(hex(i & 0xFF_FFFF, 6))"
            }
            let cp = "CP\((i >> 8) & 15)"
            let info = (i >> 5) & 7
            if i & 0x10 != 0 {
                let load = i & (1 << 20) != 0
                return "\(load ? "MRC" : "MCR")\(cond) \(cp),\((i >> 21) & 7),\(reg(i >> 12)),C\((i >> 16) & 15),C\(i & 15),\(info)"
            }
            return "CDP\(cond) \(cp),\((i >> 20) & 15),C\((i >> 12) & 15),C\((i >> 16) & 15),C\(i & 15),\(info)"
        }
    }

    static func dataProcessing(_ i: UInt32, _ cond: String) -> String {
        let opcode = Int((i >> 21) & 15)
        let name = opcodes[opcode]
        let setFlags = i & (1 << 20) != 0
        let rd = reg(i >> 12), rn = reg(i >> 16)
        let op2 = operand2(i)
        switch opcode {
        case 8...11:
            // The P forms write the PSR; without S it's no comparison.
            let p = (i >> 12) & 15 == 15 ? "P" : ""
            return "\(name)\(cond)\(p) \(rn),\(op2)"
        case 13, 15:
            return "\(name)\(cond)\(setFlags ? "S" : "") \(rd),\(op2)"
        default:
            return "\(name)\(cond)\(setFlags ? "S" : "") \(rd),\(rn),\(op2)"
        }
    }

    static func operand2(_ i: UInt32) -> String {
        if i & (1 << 25) != 0 {
            let rotate = (i >> 7) & 0x1E
            let imm = i & 0xFF
            let value = rotate == 0 ? imm : imm >> rotate | imm << (32 - rotate)
            return "#" + number(value)
        }
        return shiftedRegister(i, allowRegisterShift: true)
    }

    static func shiftedRegister(_ i: UInt32, allowRegisterShift: Bool) -> String {
        let rm = reg(i)
        let type = Int((i >> 5) & 3)
        if allowRegisterShift && i & 0x10 != 0 {
            return "\(rm),\(shifts[type]) \(reg(i >> 8))"
        }
        let amount = (i >> 7) & 31
        switch (type, amount) {
        case (0, 0): return rm
        case (3, 0): return "\(rm),RRX"
        case (_, 0): return "\(rm),\(shifts[type]) #32"
        default: return "\(rm),\(shifts[type]) #\(amount)"
        }
    }

    static func singleTransfer(_ i: UInt32, _ cond: String, at address: UInt32) -> String {
        let load = i & (1 << 20) != 0
        let byte = i & (1 << 22) != 0 ? "B" : ""
        let pre = i & (1 << 24) != 0
        let up = i & (1 << 23) != 0
        let writeback = i & (1 << 21) != 0
        // Post-indexed with W set forces a user mode (T) access.
        let t = !pre && writeback ? "T" : ""
        let rd = reg(i >> 12)
        let rnNumber = (i >> 16) & 15
        let sign = up ? "" : "-"
        let offset: String
        if i & (1 << 25) != 0 {
            offset = sign + shiftedRegister(i, allowRegisterShift: false)
        } else {
            let value = i & 0xFFF
            // PC-relative, pre-indexed: show the address.
            if rnNumber == 15 && pre && !writeback {
                let target = up ? address &+ 8 &+ value : address &+ 8 &- value
                return "\(load ? "LDR" : "STR")\(cond)\(byte) \(rd),&\(hex(target & 0x03FF_FFFF, 8))"
            }
            if value == 0 { return "\(load ? "LDR" : "STR")\(cond)\(byte)\(t) \(rd),[\(reg(rnNumber))]" }
            offset = "#\(sign)" + number(value)
        }
        let rn = reg(rnNumber)
        let operand = pre ? "[\(rn),\(offset)]\(writeback ? "!" : "")" : "[\(rn)],\(offset)"
        return "\(load ? "LDR" : "STR")\(cond)\(byte)\(t) \(rd),\(operand)"
    }

    static func registerList(_ list: UInt32) -> String {
        var parts: [String] = []
        var r = 0
        while r < 16 {
            guard list & (1 << r) != 0 else { r += 1; continue }
            var end = r
            while end < 15 && list & (1 << (end + 1)) != 0 { end += 1 }
            parts.append(end > r + 1 ? "\(reg(UInt32(r)))-\(reg(UInt32(end)))"
                         : end == r + 1 ? "\(reg(UInt32(r))),\(reg(UInt32(end)))" : reg(UInt32(r)))
            r = end + 1
        }
        return parts.joined(separator: ",")
    }

    static func reg(_ field: UInt32) -> String {
        let r = field & 15
        return r == 15 ? "PC" : "R\(r)"
    }

    static func number(_ value: UInt32) -> String {
        value < 10 ? "\(value)" : "&" + hex(value, value <= 0xFF ? 2 : value <= 0xFFFF ? 4 : 8)
    }

    static func hex(_ value: UInt32, _ digits: Int) -> String {
        let s = String(value, radix: 16, uppercase: true)
        return String(repeating: "0", count: max(0, digits - s.count)) + s
    }

    static let conditions = ["EQ", "NE", "CS", "CC", "MI", "PL", "VS", "VC",
                             "HI", "LS", "GE", "LT", "GT", "LE", "", "NV"]
    static let opcodes = ["AND", "EOR", "SUB", "RSB", "ADD", "ADC", "SBC", "RSC",
                          "TST", "TEQ", "CMP", "CMN", "ORR", "MOV", "BIC", "MVN"]
    static let shifts = ["LSL", "LSR", "ASR", "ROR"]
}
