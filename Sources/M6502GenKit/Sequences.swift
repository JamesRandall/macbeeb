// Per-cycle bus sequences for the regular instruction groups.
//
// Derived from b2's 6502_gen.cpp (Copyright (C) Tom Seddon, GPLv3). The
// irregular sequences (branches, interrupts, most CMOS indexed modes, the
// broken NMOS SHx stores) are hand-written in BeebCore's M6502+Special.swift.
//
// Each cycle is one bus access: an address to put on the bus in phase 1, and
// what to do with the data bus in phase 2. The opcode fetch (T0) is implicit.

struct Cycle {
    enum Kind {
        case write
        case readData
        /// A data read that's a dummy if there was a carry in the address
        /// calculation.
        case readDataNoCarry
        case readInstruction
        case readAddress
        case readDummy
    }

    var kind: Kind
    /// Address expression - see `Emitter.addressCode`.
    var addr: String
    /// Write source or read destination - see `Emitter.whatSource/whatDest`.
    var what: String?
    /// Action after the access: nil, call, maybeCall, callBCDCMOS,
    /// maybeCallBCDCMOS, jmp.
    var action: String?
}

private func W(_ addr: String, _ what: String?, _ action: String? = nil) -> Cycle { Cycle(kind: .write, addr: addr, what: what, action: action) }
private func Rd(_ addr: String, _ what: String?, _ action: String? = nil) -> Cycle { Cycle(kind: .readData, addr: addr, what: what, action: action) }
private func Rn(_ addr: String, _ what: String?, _ action: String? = nil) -> Cycle { Cycle(kind: .readDataNoCarry, addr: addr, what: what, action: action) }
private func Ri(_ addr: String, _ what: String?, _ action: String? = nil) -> Cycle { Cycle(kind: .readInstruction, addr: addr, what: what, action: action) }
private func Ra(_ addr: String, _ what: String?, _ action: String? = nil) -> Cycle { Cycle(kind: .readAddress, addr: addr, what: what, action: action) }
private func Ru(_ addr: String, _ what: String?, _ action: String? = nil) -> Cycle { Cycle(kind: .readDummy, addr: addr, what: what, action: action) }

struct BusSequence {
    var stem: String
    var description: String
    var cycles: [Cycle]
    /// Index register for indexed addressing: "x", "y" or nil.
    var index: String?
}

func allSequences() -> [BusSequence] {
    var s: [BusSequence] = []
    func G(_ stem: String, _ description: String, _ cycles: [Cycle], _ index: String? = nil) {
        s.append(BusSequence(stem: stem, description: description, cycles: cycles, index: index))
    }

    // 1-byte instructions.
    G("IMP", "1-byte instructions", [Ri("pc", "data!", "call")])

    // Read instructions.
    G("R_IMM", "Read/Immediate", [Ri("pc++", "data", "call")])
    G("R_ZPG", "Read/Zero page", [Ri("pc++", "adl"), Rd("adl", "data", "call")])
    G("R_ABS", "Read/Absolute", [Ri("pc++", "adl"), Ri("pc++", "adh"), Rd("ad", "data", "call")])
    G("R_INX", "Read/Indirect,X", [Ri("pc++", "ial"), Ru("ial", "data!"), Ra("ial+x", "adl"), Ra("ial+x+1", "adh"), Rd("ad", "data", "call")])
    let rAbsIndexed = [Ri("pc++", "adl"), Ri("pc++", "adh"), Rn("1.ad+index", "data!", "maybeCall"), Rd("2.ad+index", "data", "call")]
    G("R_ABX", "Read/Absolute,X", rAbsIndexed, "x")
    G("R_ABY", "Read/Absolute,Y", rAbsIndexed, "y")
    let rZpgIndexed = [Ri("pc++", "adl"), Ru("adl", "data!"), Rd("adl+index", "data", "call")]
    G("R_ZPX", "Read/Zero page,X", rZpgIndexed, "x")
    G("R_ZPY", "Read/Zero page,Y", rZpgIndexed, "y")
    G("R_INY", "Read/Indirect,Y", [Ri("pc++", "ial"), Ra("ial", "adl"), Ra("ial+1", "adh"), Rn("1.ad+index", "data!", "maybeCall"), Rd("2.ad+index", "data", "call")], "y")
    G("R_INZ", "Read/Indirect Zero Page", [Ri("pc++", "ial"), Ra("ial", "adl"), Ra("ial+1", "adh"), Rd("ad", "data", "call")])

    // Read instructions with BCD (CMOS). The extra decimal-mode cycle is a
    // dummy read of the next opcode.
    G("R_IMM_BCD_CMOS", "Read/Immediate (CMOS BCD)", [Ri("pc++", "data", "callBCDCMOS"), Ru("pc", nil)])
    G("R_ZPG_BCD_CMOS", "Read/Zero page (CMOS BCD)", [Ri("pc++", "adl"), Rd("adl", "data", "callBCDCMOS"), Ru("pc", nil)])
    G("R_ABS_BCD_CMOS", "Read/Absolute (CMOS BCD)", [Ri("pc++", "adl"), Ri("pc++", "adh"), Rd("ad", "data", "callBCDCMOS"), Ru("pc", nil)])
    G("R_INX_BCD_CMOS", "Read/Indirect,X (CMOS BCD)", [Ri("pc++", "ial"), Ru("ial", "data!"), Ra("ial+x", "adl"), Ra("ial+x+1", "adh"), Rd("ad", "data", "callBCDCMOS"), Ru("pc", nil)])
    let rZpgIndexedBCDCMOS = [Ri("pc++", "adl"), Ru("adl", "data!"), Ra("adl+index", "data", "callBCDCMOS"), Rd("pc", nil)]
    G("R_ZPX_BCD_CMOS", "Read/Zero page,X (CMOS BCD)", rZpgIndexedBCDCMOS, "x")
    G("R_INZ_BCD_CMOS", "Read/Indirect Zero Page (CMOS BCD)", [Ri("pc++", "ial"), Ra("ial", "adl"), Ra("ial+1", "adh"), Rd("ad", "data", "callBCDCMOS"), Ru("pc", nil)])

    // Write instructions.
    G("W_ZPG", "Write/Zero page", [Ri("pc++", "adl", "call"), W("adl", "data")])
    G("W_ABS", "Write/Absolute", [Ri("pc++", "adl"), Ri("pc++", "adh", "call"), W("ad", "data")])
    G("W_INX", "Write/Indirect,X", [Ri("pc++", "ial"), Ru("ial", "data!"), Ra("ial+x", "adl"), Ra("ial+x+1", "adh", "call"), W("ad", "data")])
    let wAbsIndexed = [Ri("pc++", "adl"), Ri("pc++", "adh"), Ru("1.ad+index", "data!", "call"), W("2.ad+index", "data")]
    G("W_ABX", "Write/Absolute,X", wAbsIndexed, "x")
    G("W_ABY", "Write/Absolute,Y", wAbsIndexed, "y")
    let wZpgIndexed = [Ri("pc++", "adl"), Ru("adl", "data", "call"), W("adl+index", "data")]
    G("W_ZPX", "Write/Zero page,X", wZpgIndexed, "x")
    G("W_ZPY", "Write/Zero page,Y", wZpgIndexed, "y")
    G("W_INY", "Write/Indirect,Y", [Ri("pc++", "ial"), Ra("ial", "adl"), Ra("ial+1", "adh"), Ru("1.ad+index", "data", "call"), W("2.ad+index", "data")], "y")
    G("W_INZ", "Write/Indirect Zero Page", [Ri("pc++", "ial"), Ra("ial", "adl"), Ra("ial+1", "adh", "call"), W("ad", "data")])

    // Read-modify-write instructions (NMOS: the unmodified value is written
    // back before the modified one).
    G("RMW_ZPG", "Read-modify-write/Zero page", [Ri("pc++", "adl"), Rd("adl", "data!"), W("adl", "data!", "call"), W("adl", "data")])
    G("RMW_ABS", "Read-modify-write/Absolute", [Ri("pc++", "adl"), Ri("pc++", "adh"), Rd("ad", "data!"), W("ad", "data!", "call"), W("ad", "data")])
    G("RMW_ZPX", "Read-modify-write/Zero page,X", [Ri("pc++", "adl"), Ru("adl", "data"), Rd("adl+index", "data!"), W("adl+index", "data!", "call"), W("adl+index", "data")], "x")
    G("RMW_ABX", "Read-modify-write/Absolute,X", [Ri("pc++", "adl"), Ri("pc++", "adh"), Ru("1.ad+index", "data!"), Rd("2.ad+index", "data!"), W("2.ad+index", "data!", "call"), W("2.ad+index", "data")], "x")
    G("RMW_ABY", "Read-modify-write/Absolute,Y", [Ri("pc++", "adl"), Ri("pc++", "adh"), Ru("1.ad+index", "data!"), Rd("2.ad+index", "data!"), W("2.ad+index", "data!", "call"), W("2.ad+index", "data")], "y")
    G("RMW_INX", "Read-modify-write/Indirect,X", [Ri("pc++", "ial"), Ru("ial", "data!"), Ra("ial+x", "adl"), Ra("ial+x+1", "adh"), Rd("ad", "data"), W("ad", "data", "call"), W("ad", "data")], "x")
    G("RMW_INY", "Read-modify-write/Indirect,Y", [Ri("pc++", "ial"), Ra("ial", "adl"), Ra("ial+1", "adh"), Ru("1.ad+index", "data"), Rd("2.ad+index", "data"), W("2.ad+index", "data", "call"), W("2.ad+index", "data")], "y")

    // Read-modify-write instructions (CMOS: the data address is read twice).
    G("RMW_ZPG_CMOS", "Read-modify-write/Zero page (CMOS)", [Ri("pc++", "adl"), Rd("adl", "data!"), Ru("adl", "data!", "call"), W("adl", "data")])
    G("RMW_ABS_CMOS", "Read-modify-write/Absolute (CMOS)", [Ri("pc++", "adl"), Ri("pc++", "adh"), Rd("ad", "data!"), Ru("ad", "data!", "call"), W("ad", "data")])
    G("RMW_ZPX_CMOS", "Read-modify-write/Zero page,X (CMOS)", [Ri("pc++", "adl"), Ru("pba", "data!"), Rd("adl+index", "data"), Ru("adl+index", "data", "call"), W("adl+index", "data")], "x")

    // Stack.
    G("Push", "Push instructions", [Ri("pc", "data!", "call"), W("sp--", "data")])
    G("Pop", "Pop instructions", [Ri("pc", "data!"), Rd("sp++", "data!"), Rd("sp", "data", "call")])

    // Special cases.
    G("JSR", "JSR", [Ri("pc++", "adl"), Ru("sp", "data!"), W("sp--", "pch"), W("sp--", "pcl"), Ri("pc++", "adh", "jmp")])
    G("Reset", "Reset", [Ri("pc", "data!"), Rd("sp--", "pch"), Rd("sp--", "pcl"), Rd("sp--", "data"), Ra("resl", "pcl"), Ra("resh", "pch")])
    G("RTI", "RTI", [Ri("pc", "data!"), Rd("sp++", "data"), Rd("sp++", "p"), Rd("sp++", "pcl"), Rd("sp", "pch")])
    G("JMP_ABS", "JMP absolute", [Ri("pc++", "adl"), Ri("pc++", "adh", "jmp")])
    G("JMP_IND", "JMP indirect", [Ri("pc++", "ial"), Ri("pc++", "iah"), Ra("ia", "pcl"), Ra("ia+1(nocarry)", "pch")])
    G("JMP_IND_CMOS", "JMP indirect (CMOS)", [Ri("pc++", "ial"), Ri("pc++", "iah"), Ra("ia", "pcl"), Ru("ia+1", "pch"), Ra("ia+1", "pch")])
    G("JMP_INDX", "JMP (indirect,X)", [Ri("pc++", "ial"), Ri("pc++", "iah"), Ru("1.ia+x_cmos", "data!"), Ra("2.ia+x_cmos", "pcl"), Ra("3.ia+x_cmos", "pch")], "x")
    G("RTS", "RTS", [Ri("pc", "data!"), Rd("sp++", "data"), Rd("sp++", "pcl"), Rd("sp", "pch"), Rd("pc++", "data")])

    // CMOS NOPs.
    G("R_NOP11_CMOS", "CMOS NOP (1 byte, 1 cycle)", [])
    G("R_NOP22_CMOS", "CMOS NOP (2 bytes, 2 cycles)", [Ri("pc++", "data")])
    G("R_NOP23_CMOS", "CMOS NOP (2 bytes, 3 cycles)", [Ri("pc", "data"), Ri("pc++", "data")])
    G("R_NOP24_CMOS", "CMOS NOP (2 bytes, 4 cycles)", [Ri("pc", "data"), Ri("pc", "data"), Ri("pc++", "data")])
    G("R_NOP34_CMOS", "CMOS NOP (3 bytes, 4 cycles)", [Ri("pc++", "adl"), Ri("pc++", "adh"), Ri("ad", "data!")])
    G("R_NOP38_CMOS", "CMOS NOP (3 bytes, 8 cycles)", [Ri("pc", "data"), Ri("pc", "data"), Ri("pc", "data"), Ri("pc", "data"), Ri("pc", "data"), Ri("pc++", "data"), Ri("pc++", "data")])

    return s
}

/// States written by hand in M6502+Special.swift. Listed here so the
/// generated State enum includes them.
let handwrittenStates: [String] = {
    var names: [String] = []
    func add(_ stem: String, _ suffixes: [String]) {
        names += suffixes.map { "\(stem)_\($0)" }
    }
    add("Branch", ["0", "1", "2", "3"])
    add("Branch_ZPG_REL_ROCKWELL", ["0", "1", "2", "3"])
    for reg in ["X", "Y"] {
        add("R_AB\(reg)_CMOS", ["0", "1", "2", "3_AC0", "3_AC1", "4_AC1"])
        add("W_AB\(reg)_CMOS", ["0", "1", "2", "3", "4"])
        add("R_AB\(reg)_BCD_CMOS", ["0", "1", "2_D0", "2_D1", "3_D0_AC0", "3_D0_AC1", "4_D0_AC1",
                                    "3_D1_AC0", "3_D1_AC1", "4_D1_AC0", "4_D1_AC1", "5_D1_AC1"])
        add("W_AB\(reg)_BROKEN_NMOS", ["0", "1", "2", "3", "4"])
    }
    add("RMW_ABX_CMOS", ["0", "1", "2", "3", "4", "5", "6"])
    add("RMW_ABX2_CMOS", ["0", "1", "2", "3_AC0", "4_AC0", "5_AC0", "3_AC1", "4_AC1", "5_AC1", "6_AC1"])
    add("R_INY_CMOS", ["0", "1", "2", "3", "4_AC0", "4_AC1", "5_AC1"])
    add("R_INY_BCD_CMOS", ["0", "1", "2", "3_D0", "3_D1", "4_D0_AC0", "4_D0_AC1", "5_D0_AC1",
                           "4_D1_AC0", "5_D1_AC0", "4_D1_AC1", "5_D1_AC1", "6_D1_AC1"])
    add("W_INY_CMOS", ["0", "1", "2", "3", "4", "5"])
    add("W_INY_BROKEN_NMOS", ["0", "1", "2", "3", "4", "5"])
    add("HLT", ["0", "1", "2", "3", "4"])
    add("Interrupt", ["0", "1", "2", "3", "4", "5", "6"])
    add("InterruptCMOS", ["0", "1", "2", "3", "4", "5", "6"])
    add("BRK_CMOS", ["0", "1", "2", "3", "4", "5", "6"])
    return names
}()
