// Instruction set definitions for the 6502 code generator.
//
// Derived from b2's 6502_gen.cpp (Copyright (C) Tom Seddon, GPLv3).

/// Addressing mode, plus a few pseudo-modes for instructions whose bus
/// behaviour differs from the standard sequence for their mode.
public enum Mode: String, CaseIterable, Sendable {
    case abs, abx, aby, acc, imm, imp, ind, indx, inx, iny, inz, rel, zpg, zpx, zpy
    case nop11CMOS, nop22CMOS, nop23CMOS, nop24CMOS, nop34CMOS, nop38CMOS
    case abx2CMOS
    case abxBrokenNMOS, abyBrokenNMOS, inyBrokenNMOS
    case zpgRelRockwell

    /// Name used in generated state names, e.g. "ABX_BROKEN_NMOS".
    var stateStem: String {
        switch self {
        case .nop11CMOS: return "NOP11_CMOS"
        case .nop22CMOS: return "NOP22_CMOS"
        case .nop23CMOS: return "NOP23_CMOS"
        case .nop24CMOS: return "NOP24_CMOS"
        case .nop34CMOS: return "NOP34_CMOS"
        case .nop38CMOS: return "NOP38_CMOS"
        case .abx2CMOS: return "ABX2_CMOS"
        case .abxBrokenNMOS: return "ABX_BROKEN_NMOS"
        case .abyBrokenNMOS: return "ABY_BROKEN_NMOS"
        case .inyBrokenNMOS: return "INY_BROKEN_NMOS"
        case .zpgRelRockwell: return "ZPG_REL_ROCKWELL"
        default: return rawValue.uppercased()
        }
    }

    /// The mode a disassembler should show for this pseudo-mode.
    var disassemblyMode: Mode {
        switch self {
        case .nop11CMOS: return .imp
        case .nop22CMOS, .nop23CMOS, .nop24CMOS: return .zpg
        case .nop34CMOS, .nop38CMOS: return .abs
        case .abx2CMOS, .abxBrokenNMOS: return .abx
        case .abyBrokenNMOS: return .aby
        case .inyBrokenNMOS: return .iny
        default: return self
        }
    }

    var numBytes: Int {
        switch self {
        case .acc, .imp, .nop11CMOS:
            return 1
        case .imm, .inx, .iny, .inyBrokenNMOS, .inz, .rel, .zpg, .zpx, .zpy, .nop22CMOS, .nop23CMOS, .nop24CMOS:
            return 2
        case .abs, .abx, .aby, .abxBrokenNMOS, .abyBrokenNMOS, .ind, .indx, .nop34CMOS, .nop38CMOS, .abx2CMOS, .zpgRelRockwell:
            return 3
        }
    }
}

enum InstrType: String {
    case unknown, r = "R", w = "W", branch = "Branch", imp = "IMP", push = "Push", pop = "Pop", rmw = "RMW"
}

private let instrTypes: [InstrType: Set<String>] = [
    .r: ["adc", "and", "bit", "cmp", "cpx", "cpy", "eor", "lda", "ldx", "ldy", "ora", "sbc",
         "bit_cmos",
         "lax", "asr", "arr", "ane", "lxa", "sbx", "anc", "lds"],
    .w: ["sta", "stx", "sty",
         "sax", "sha", "shy", "shx", "shs",
         "stz"],
    .branch: ["bcc", "bcs", "beq", "bmi", "bne", "bpl", "bvc", "bvs",
              "bra",
              "bbr0", "bbr1", "bbr2", "bbr3", "bbr4", "bbr5", "bbr6", "bbr7",
              "bbs0", "bbs1", "bbs2", "bbs3", "bbs4", "bbs5", "bbs6", "bbs7"],
    .imp: ["clc", "cld", "clv", "dex", "dey", "inx", "iny", "sec", "sed", "sei", "tax", "tay", "tsx", "txa", "txs", "tya",
           "cli"],
    .push: ["pha", "php", "phx", "phy"],
    .pop: ["pla", "plp", "plx", "ply"],
    .rmw: ["asl", "dec", "inc", "lsr", "rol", "ror",
           "slo", "rla", "sre", "rra", "dcp", "isb",
           "trb", "tsb",
           "rmb0", "rmb1", "rmb2", "rmb3", "rmb4", "rmb5", "rmb6", "rmb7",
           "smb0", "smb1", "smb2", "smb3", "smb4", "smb5", "smb6", "smb7"],
]

public struct Instr: Sendable {
    public var mnemonic: String
    public var mode: Mode
    public var cmos = false
    public var undocumented = false
    public var rockwell = false

    init(_ mnemonic: String, _ mode: Mode) {
        self.mnemonic = mnemonic
        self.mode = mode
    }

    var type: InstrType {
        if mnemonic == "nop" {
            return mode == .imp ? .imp : .r
        }
        if mode == .acc {
            return .imp
        }
        for (type, names) in instrTypes where names.contains(mnemonic) {
            return type
        }
        return .unknown
    }

    var isShift: Bool { ["asl", "lsr", "rol", "ror"].contains(mnemonic) }
    var isBCD: Bool { mnemonic == "adc" || mnemonic == "sbc" }

    /// Mnemonic for disassembly, e.g. "bit_cmos" -> "bit".
    public var disassemblyMnemonic: String {
        if mnemonic.hasSuffix("_cmos") {
            return String(mnemonic.dropLast(5))
        }
        return mnemonic
    }

    /// The name of the first state of the bus sequence, and the name of the
    /// operation (the ALU part) if there is one.
    func t0AndOp() -> (t0: String, op: String?) {
        if mnemonic == "brk" {
            return (cmos ? "BRK_CMOS_0" : "Interrupt_0", nil)
        }

        let type = self.type
        if type == .unknown {
            switch mnemonic {
            case "rts", "rti", "jsr":
                return (mnemonic.uppercased() + "_0", nil)
            case "jmp":
                var stem = "JMP_" + mode.stateStem
                if cmos && mode == .ind {
                    stem += "_CMOS"
                }
                return (stem + "_0", nil)
            case "hlt":
                return ("HLT_0", nil)
            default:
                preconditionFailure("no sequence for \(mnemonic)")
            }
        }

        // Op names are Swift enum case names: "adc", "aslA", "adcCMOS", ...
        var op = mnemonic
        if op.hasSuffix("_cmos") {
            op = String(op.dropLast(5)) + "CMOS"
        }
        if rockwell, op.count == 4, op.last!.isNumber {
            op.removeLast()
        }

        let t0: String
        if mode == .imp || mode == .rel {
            t0 = type.rawValue + "_0"
        } else if mode == .acc {
            t0 = "IMP_0"
            op += "A"
        } else {
            var m = mode
            var suffix = ""
            if cmos {
                if m == .abx && isShift {
                    // 1 cycle shorter when no page boundary is crossed, unlike
                    // the other RMW instructions.
                    m = .abx2CMOS
                } else if isBCD {
                    // 1 cycle extra in decimal mode, and different flags.
                    suffix = "_BCD_CMOS"
                    op += "CMOS"
                } else if type == .rmw
                    || (type == .w && [.abx, .aby, .iny].contains(m))
                    || (type == .r && [.abx, .aby, .iny].contains(m)) {
                    suffix = "_CMOS"
                }
            }
            t0 = type.rawValue + "_" + m.stateStem + suffix + "_0"
        }
        return (t0, op)
    }
}

// MARK: - Instruction tables

private func table(_ entries: [(UInt8, String, Mode)]) -> [UInt8: Instr] {
    var result: [UInt8: Instr] = [:]
    for (opcode, mnemonic, mode) in entries {
        result[opcode] = Instr(mnemonic, mode)
    }
    return result
}

func definedInstructions() -> [UInt8: Instr] {
    table([
        (0x00, "brk", .imp), (0x01, "ora", .inx), (0x05, "ora", .zpg), (0x06, "asl", .zpg),
        (0x08, "php", .imp), (0x09, "ora", .imm), (0x0a, "asl", .acc), (0x0d, "ora", .abs),
        (0x0e, "asl", .abs), (0x10, "bpl", .rel), (0x11, "ora", .iny), (0x15, "ora", .zpx),
        (0x16, "asl", .zpx), (0x18, "clc", .imp), (0x19, "ora", .aby), (0x1d, "ora", .abx),
        (0x1e, "asl", .abx), (0x20, "jsr", .abs), (0x21, "and", .inx), (0x24, "bit", .zpg),
        (0x25, "and", .zpg), (0x26, "rol", .zpg), (0x28, "plp", .imp), (0x29, "and", .imm),
        (0x2a, "rol", .acc), (0x2c, "bit", .abs), (0x2d, "and", .abs), (0x2e, "rol", .abs),
        (0x30, "bmi", .rel), (0x31, "and", .iny), (0x35, "and", .zpx), (0x36, "rol", .zpx),
        (0x38, "sec", .imp), (0x39, "and", .aby), (0x3d, "and", .abx), (0x3e, "rol", .abx),
        (0x40, "rti", .imp), (0x41, "eor", .inx), (0x45, "eor", .zpg), (0x46, "lsr", .zpg),
        (0x48, "pha", .imp), (0x49, "eor", .imm), (0x4a, "lsr", .acc), (0x4c, "jmp", .abs),
        (0x4d, "eor", .abs), (0x4e, "lsr", .abs), (0x50, "bvc", .rel), (0x51, "eor", .iny),
        (0x55, "eor", .zpx), (0x56, "lsr", .zpx), (0x58, "cli", .imp), (0x59, "eor", .aby),
        (0x5d, "eor", .abx), (0x5e, "lsr", .abx), (0x60, "rts", .imp), (0x61, "adc", .inx),
        (0x65, "adc", .zpg), (0x66, "ror", .zpg), (0x68, "pla", .imp), (0x69, "adc", .imm),
        (0x6a, "ror", .acc), (0x6c, "jmp", .ind), (0x6d, "adc", .abs), (0x6e, "ror", .abs),
        (0x70, "bvs", .rel), (0x71, "adc", .iny), (0x75, "adc", .zpx), (0x76, "ror", .zpx),
        (0x78, "sei", .imp), (0x79, "adc", .aby), (0x7d, "adc", .abx), (0x7e, "ror", .abx),
        (0x81, "sta", .inx), (0x84, "sty", .zpg), (0x85, "sta", .zpg), (0x86, "stx", .zpg),
        (0x88, "dey", .imp), (0x8a, "txa", .imp), (0x8c, "sty", .abs), (0x8d, "sta", .abs),
        (0x8e, "stx", .abs), (0x90, "bcc", .rel), (0x91, "sta", .iny), (0x94, "sty", .zpx),
        (0x95, "sta", .zpx), (0x96, "stx", .zpy), (0x98, "tya", .imp), (0x99, "sta", .aby),
        (0x9a, "txs", .imp), (0x9d, "sta", .abx), (0xa0, "ldy", .imm), (0xa1, "lda", .inx),
        (0xa2, "ldx", .imm), (0xa4, "ldy", .zpg), (0xa5, "lda", .zpg), (0xa6, "ldx", .zpg),
        (0xa8, "tay", .imp), (0xa9, "lda", .imm), (0xaa, "tax", .imp), (0xac, "ldy", .abs),
        (0xad, "lda", .abs), (0xae, "ldx", .abs), (0xb0, "bcs", .rel), (0xb1, "lda", .iny),
        (0xb4, "ldy", .zpx), (0xb5, "lda", .zpx), (0xb6, "ldx", .zpy), (0xb8, "clv", .imp),
        (0xb9, "lda", .aby), (0xba, "tsx", .imp), (0xbc, "ldy", .abx), (0xbd, "lda", .abx),
        (0xbe, "ldx", .aby), (0xc0, "cpy", .imm), (0xc1, "cmp", .inx), (0xc4, "cpy", .zpg),
        (0xc5, "cmp", .zpg), (0xc6, "dec", .zpg), (0xc8, "iny", .imp), (0xc9, "cmp", .imm),
        (0xca, "dex", .imp), (0xcc, "cpy", .abs), (0xcd, "cmp", .abs), (0xce, "dec", .abs),
        (0xd0, "bne", .rel), (0xd1, "cmp", .iny), (0xd5, "cmp", .zpx), (0xd6, "dec", .zpx),
        (0xd8, "cld", .imp), (0xd9, "cmp", .aby), (0xdd, "cmp", .abx), (0xde, "dec", .abx),
        (0xe0, "cpx", .imm), (0xe1, "sbc", .inx), (0xe4, "cpx", .zpg), (0xe5, "sbc", .zpg),
        (0xe6, "inc", .zpg), (0xe8, "inx", .imp), (0xe9, "sbc", .imm), (0xea, "nop", .imp),
        (0xec, "cpx", .abs), (0xed, "sbc", .abs), (0xee, "inc", .abs), (0xf0, "beq", .rel),
        (0xf1, "sbc", .iny), (0xf5, "sbc", .zpx), (0xf6, "inc", .zpx), (0xf8, "sed", .imp),
        (0xf9, "sbc", .aby), (0xfd, "sbc", .abx), (0xfe, "inc", .abx),
    ])
}

func undocumentedNMOSInstructions() -> [UInt8: Instr] {
    var result = table([
        (0x0c, "nop", .abs),
        (0x07, "slo", .zpg), (0x17, "slo", .zpx), (0x03, "slo", .inx), (0x13, "slo", .iny),
        (0x0f, "slo", .abs), (0x1f, "slo", .abx), (0x1b, "slo", .aby),
        (0x27, "rla", .zpg), (0x37, "rla", .zpx), (0x23, "rla", .inx), (0x33, "rla", .iny),
        (0x2f, "rla", .abs), (0x3f, "rla", .abx), (0x3b, "rla", .aby),
        (0x47, "sre", .zpg), (0x57, "sre", .zpx), (0x43, "sre", .inx), (0x53, "sre", .iny),
        (0x4f, "sre", .abs), (0x5f, "sre", .abx), (0x5b, "sre", .aby),
        (0x67, "rra", .zpg), (0x77, "rra", .zpx), (0x63, "rra", .inx), (0x73, "rra", .iny),
        (0x6f, "rra", .abs), (0x7f, "rra", .abx), (0x7b, "rra", .aby),
        (0xc7, "dcp", .zpg), (0xd7, "dcp", .zpx), (0xc3, "dcp", .inx), (0xd3, "dcp", .iny),
        (0xcf, "dcp", .abs), (0xdf, "dcp", .abx), (0xdb, "dcp", .aby),
        (0xe7, "isb", .zpg), (0xf7, "isb", .zpx), (0xe3, "isb", .inx), (0xf3, "isb", .iny),
        (0xef, "isb", .abs), (0xff, "isb", .abx), (0xfb, "isb", .aby),
        (0x87, "sax", .zpg), (0x97, "sax", .zpy), (0x83, "sax", .inx), (0x8f, "sax", .abs),
        (0xa7, "lax", .zpg), (0xb7, "lax", .zpy), (0xa3, "lax", .inx), (0xb3, "lax", .iny),
        (0xaf, "lax", .abs), (0xbf, "lax", .aby),
        (0x4b, "asr", .imm), (0x6b, "arr", .imm), (0x8b, "ane", .imm), (0xab, "lxa", .imm),
        (0xcb, "sbx", .imm),
        (0x93, "sha", .inyBrokenNMOS), (0x9f, "sha", .abyBrokenNMOS), (0x9c, "shy", .abxBrokenNMOS),
        (0x9e, "shx", .abyBrokenNMOS), (0x9b, "shs", .abyBrokenNMOS),
        (0x0b, "anc", .imm), (0x2b, "anc", .imm), (0xbb, "lds", .aby), (0xeb, "sbc", .imm),
    ])

    for opcode: UInt8 in [0x1a, 0x3a, 0x5a, 0x7a, 0xda, 0xfa] { result[opcode] = Instr("nop", .imp) }
    for opcode: UInt8 in [0x80, 0x82, 0x89, 0xc2, 0xe2] { result[opcode] = Instr("nop", .imm) }
    for opcode: UInt8 in [0x04, 0x44, 0x64] { result[opcode] = Instr("nop", .zpg) }
    // b2 has these as zp,Y; the indexing register is X on real hardware, which
    // matters when the dummy read hits I/O.
    for opcode: UInt8 in [0x14, 0x34, 0x54, 0x74, 0xd4, 0xf4] { result[opcode] = Instr("nop", .zpx) }
    for opcode: UInt8 in [0x1c, 0x3c, 0x5c, 0x7c, 0xdc, 0xfc] { result[opcode] = Instr("nop", .abx) }
    for opcode: UInt8 in [0x02, 0x12, 0x22, 0x32, 0x42, 0x52, 0x62, 0x72, 0x92, 0xb2, 0xd2, 0xf2] {
        result[opcode] = Instr("hlt", .imp)
    }

    for key in result.keys { result[key]!.undocumented = true }
    return result
}

func nmosInstructions() -> [UInt8: Instr] {
    definedInstructions().merging(undocumentedNMOSInstructions()) { _, _ in
        preconditionFailure("opcode defined twice")
    }
}

func cmosInstructions() -> [UInt8: Instr] {
    var result = definedInstructions()
    let additions = table([
        (0xda, "phx", .imp), (0x5a, "phy", .imp), (0xfa, "plx", .imp), (0x7a, "ply", .imp),
        (0x64, "stz", .zpg), (0x74, "stz", .zpx), (0x9c, "stz", .abs), (0x9e, "stz", .abx),
        (0x14, "trb", .zpg), (0x1c, "trb", .abs), (0x04, "tsb", .zpg), (0x0c, "tsb", .abs),
        (0x80, "bra", .rel),
        (0x72, "adc", .inz), (0x32, "and", .inz), (0xd2, "cmp", .inz), (0x52, "eor", .inz),
        (0xb2, "lda", .inz), (0x12, "ora", .inz), (0xf2, "sbc", .inz), (0x92, "sta", .inz),
        (0x89, "bit_cmos", .imm), (0x34, "bit", .zpx), (0x3c, "bit", .abx),
        (0x3a, "dec", .acc), (0x1a, "inc", .acc), (0x7c, "jmp", .indx),
    ])
    result.merge(additions) { _, new in new }

    for lsn: UInt8 in [0x03, 0x07, 0x0b, 0x0f] {
        for msn: UInt8 in 0..<16 {
            result[msn << 4 | lsn] = Instr("nop", .nop11CMOS)
        }
    }
    for opcode: UInt8 in [0x02, 0x22, 0x42, 0x62, 0x82, 0xc2, 0xe2] { result[opcode] = Instr("nop", .nop22CMOS) }
    result[0x44] = Instr("nop", .nop23CMOS)
    for opcode: UInt8 in [0x54, 0xd4, 0xf4] { result[opcode] = Instr("nop", .nop24CMOS) }
    result[0x5c] = Instr("nop", .nop38CMOS)
    for opcode: UInt8 in [0xdc, 0xfc] { result[opcode] = Instr("nop", .nop34CMOS) }

    precondition(result.count == 256, "CMOS table incomplete")
    for key in result.keys { result[key]!.cmos = true }
    return result
}

func rockwellInstructions() -> [UInt8: Instr] {
    var result = cmosInstructions()
    for bit: UInt8 in 0..<8 {
        let pairs: [(String, Mode, UInt8)] = [
            ("rmb", .zpg, 0x07), ("smb", .zpg, 0x87),
            ("bbr", .zpgRelRockwell, 0x0f), ("bbs", .zpgRelRockwell, 0x8f),
        ]
        for (base, mode, baseOpcode) in pairs {
            var instr = Instr(base + String(bit), mode)
            instr.rockwell = true
            // b2 leaves these flagged NMOS, which gives RMB/SMB the NMOS
            // write-twice RMW sequence. Every 65C02 RMW does read-read-write,
            // so use the CMOS sequence.
            instr.cmos = true
            result[baseOpcode | bit << 4] = instr
        }
    }
    return result
}

/// A CPU variant to generate an opcode table for.
public struct Config: Sendable {
    public var name: String
    public var instructions: [UInt8: Instr]
}

public func allConfigs() -> [Config] {
    [
        Config(name: "nmos", instructions: nmosInstructions()),
        Config(name: "cmos", instructions: cmosInstructions()),
        Config(name: "rockwell", instructions: rockwellInstructions()),
    ]
}
