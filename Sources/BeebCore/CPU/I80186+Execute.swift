// 80186 instruction execution. Each function returns the instruction's
// clocks; the opcode (and any prefixes) have already been fetched.

private let fC = I80186.flagC, fP = I80186.flagP, fA = I80186.flagA, fZ = I80186.flagZ
private let fS = I80186.flagS, fT = I80186.flagT, fI = I80186.flagI, fD = I80186.flagD
private let fO = I80186.flagO

extension I80186 {
    func execute(_ op: UInt8, continuing: Bool) -> Int {
        switch op {
        // ALU: Eb,Gb  Ev,Gv  Gb,Eb  Gv,Ev  AL,Ib  AX,Iv
        case 0x00, 0x08, 0x10, 0x18, 0x20, 0x28, 0x30, 0x38:
            decodeModRM()
            let r = alu(op >> 3, UInt32(rm8()), UInt32(reg8(regField)), wide: false)
            if op < 0x38 { setRM8(UInt8(r)) }
            return clocks(3, 10)
        case 0x01, 0x09, 0x11, 0x19, 0x21, 0x29, 0x31, 0x39:
            decodeModRM()
            let r = alu(op >> 3, UInt32(rm16()), UInt32(reg16(regField)), wide: true)
            if op < 0x38 { setRM16(UInt16(r)) }
            return clocks(3, 10)
        case 0x02, 0x0A, 0x12, 0x1A, 0x22, 0x2A, 0x32, 0x3A:
            decodeModRM()
            let r = alu(op >> 3, UInt32(reg8(regField)), UInt32(rm8()), wide: false)
            if op < 0x38 { setReg8(regField, UInt8(r)) }
            return clocks(3, 10)
        case 0x03, 0x0B, 0x13, 0x1B, 0x23, 0x2B, 0x33, 0x3B:
            decodeModRM()
            let r = alu(op >> 3, UInt32(reg16(regField)), UInt32(rm16()), wide: true)
            if op < 0x38 { setReg16(regField, UInt16(r)) }
            return clocks(3, 10)
        case 0x04, 0x0C, 0x14, 0x1C, 0x24, 0x2C, 0x34, 0x3C:
            let r = alu(op >> 3, UInt32(al), UInt32(fetch()), wide: false)
            if op < 0x38 { al = UInt8(r) }
            return 3
        case 0x05, 0x0D, 0x15, 0x1D, 0x25, 0x2D, 0x35, 0x3D:
            let r = alu(op >> 3, UInt32(ax), UInt32(fetch16()), wide: true)
            if op < 0x38 { ax = UInt16(r) }
            return 4

        case 0x06, 0x0E, 0x16, 0x1E:  // PUSH seg
            push(sreg(op >> 3))
            return 9
        case 0x07, 0x17, 0x1F:  // POP seg
            setSreg(op >> 3, pop())
            interruptShadow = true
            return 8
        case 0x27: daa(); return 4
        case 0x2F: das(); return 4
        case 0x37: asciiAdjust(subtract: false); return 8
        case 0x3F: asciiAdjust(subtract: true); return 7

        case 0x40...0x47:  // INC r16
            setReg16(op, UInt16(incdec(UInt32(reg16(op)), decrement: false, wide: true)))
            return 3
        case 0x48...0x4F:  // DEC r16
            setReg16(op, UInt16(incdec(UInt32(reg16(op)), decrement: true, wide: true)))
            return 3
        case 0x50...0x57:  // PUSH r16 (PUSH SP pushes the decremented value)
            if op == 0x54 {
                sp &-= 2
                write16(ss, sp, sp)
            } else {
                push(reg16(op))
            }
            return 10
        case 0x58...0x5F:  // POP r16
            let v = pop()
            setReg16(op, v)
            return 10

        case 0x60:  // PUSHA
            let original = sp
            push(ax); push(cx); push(dx); push(bx)
            push(original); push(bp); push(si); push(di)
            return 36
        case 0x61:  // POPA
            di = pop(); si = pop(); bp = pop(); sp &+= 2
            bx = pop(); dx = pop(); cx = pop(); ax = pop()
            return 51
        case 0x62:  // BOUND
            decodeModRM()
            if isRegisterOperand { return undefinedOpcode() }
            let index = Int16(bitPattern: reg16(regField))
            let low = Int16(bitPattern: read16(eaSegment, eaOffset))
            let high = Int16(bitPattern: read16(eaSegment, eaOffset &+ 2))
            if index < low || index > high {
                ip = instructionStart
                interrupt(Interrupt.bound)
                return 33 + 45
            }
            return 33
        case 0x68:  // PUSH imm16
            push(fetch16())
            return 10
        case 0x6A:  // PUSH imm8
            push(fetchS8())
            return 10
        case 0x69, 0x6B:  // IMUL r16,Ev,imm
            decodeModRM()
            let a = Int32(Int16(bitPattern: rm16()))
            let b = Int32(Int16(bitPattern: op == 0x69 ? fetch16() : fetchS8()))
            let p = a * b
            let fits = p == Int32(Int16(truncatingIfNeeded: p))
            setFlag(fC, !fits)
            setFlag(fO, !fits)
            setReg16(regField, UInt16(truncatingIfNeeded: p))
            return op == 0x69 ? clocks(25, 32) : clocks(22, 29)
        case 0x6C, 0x6D, 0x6E, 0x6F, 0xA4, 0xA5, 0xA6, 0xA7, 0xAA, 0xAB, 0xAC, 0xAD, 0xAE, 0xAF:
            return string(op, continuing: continuing)

        case 0x70...0x7F:  // Jcc short
            let d = fetchS8()
            if condition(op) {
                ip &+= d
                return 13
            }
            return 4

        case 0x80, 0x82:  // group 1: Eb,Ib
            decodeModRM()
            let a = UInt32(rm8())
            let r = alu(regField, a, UInt32(fetch()), wide: false)
            if regField != 7 { setRM8(UInt8(r)) }
            return regField == 7 ? clocks(4, 10) : clocks(4, 16)
        case 0x81, 0x83:  // group 1: Ev,Iv  Ev,Ib (sign extended)
            decodeModRM()
            let a = UInt32(rm16())
            let b = op == 0x81 ? fetch16() : fetchS8()
            let r = alu(regField, a, UInt32(b), wide: true)
            if regField != 7 { setRM16(UInt16(r)) }
            return regField == 7 ? clocks(4, 10) : clocks(4, 16)
        case 0x84:  // TEST Eb,Gb
            decodeModRM()
            _ = logic(UInt32(rm8() & reg8(regField)), wide: false)
            return clocks(3, 10)
        case 0x85:
            decodeModRM()
            _ = logic(UInt32(rm16() & reg16(regField)), wide: true)
            return clocks(3, 10)
        case 0x86:  // XCHG Eb,Gb
            decodeModRM()
            let a = rm8()
            setRM8(reg8(regField))
            setReg8(regField, a)
            return clocks(4, 17)
        case 0x87:
            decodeModRM()
            let a = rm16()
            setRM16(reg16(regField))
            setReg16(regField, a)
            return clocks(4, 17)
        case 0x88:  // MOV Eb,Gb
            decodeModRM()
            setRM8(reg8(regField))
            return clocks(2, 12)
        case 0x89:
            decodeModRM()
            setRM16(reg16(regField))
            return clocks(2, 12)
        case 0x8A:  // MOV Gb,Eb
            decodeModRM()
            setReg8(regField, rm8())
            return clocks(2, 9)
        case 0x8B:
            decodeModRM()
            setReg16(regField, rm16())
            return clocks(2, 9)
        case 0x8C:  // MOV Ew,Sw (bit 5 of the ModR/M ignored)
            decodeModRM()
            setRM16(sreg(regField))
            return clocks(2, 11)
        case 0x8D:  // LEA (the register form leaves the last address)
            decodeModRM()
            setReg16(regField, eaOffset)
            return 6
        case 0x8E:  // MOV Sw,Ew: CS or a code above 3 is undefined
            decodeModRM()
            guard regField == 0 || regField == 2 || regField == 3 else { return undefinedOpcode() }
            setSreg(regField, rm16())
            interruptShadow = true
            return clocks(2, 9)
        case 0x8F:  // POP Ev
            decodeModRM()
            let v = pop()
            setRM16(v)
            return clocks(10, 20)

        case 0x90:  // NOP (XCHG AX,AX)
            return 3
        case 0x91...0x97:  // XCHG AX,r16
            let v = reg16(op)
            setReg16(op, ax)
            ax = v
            return 3
        case 0x98:  // CBW
            ax = UInt16(bitPattern: Int16(Int8(bitPattern: al)))
            return 2
        case 0x99:  // CWD
            dx = ax & 0x8000 != 0 ? 0xFFFF : 0
            return 4
        case 0x9A:  // CALL far
            let offset = fetch16()
            let segment = fetch16()
            push(cs)
            push(ip)
            cs = segment
            ip = offset
            return 23
        case 0x9B:  // WAIT (no coprocessor: TEST is always active)
            return 6
        case 0x9C:  // PUSHF
            push(flags)
            return 9
        case 0x9D:  // POPF
            flags = pop()
            return 8
        case 0x9E:  // SAHF
            f = (f & 0xFF00) | (UInt16(ah) & 0xD5)
            return 3
        case 0x9F:  // LAHF
            ah = UInt8(truncatingIfNeeded: flags)
            return 2

        case 0xA0:  // MOV AL,[moffs]
            al = read8(dataSegment, fetch16())
            return 8
        case 0xA1:
            ax = read16(dataSegment, fetch16())
            return 8
        case 0xA2:
            write8(dataSegment, fetch16(), al)
            return 9
        case 0xA3:
            write16(dataSegment, fetch16(), ax)
            return 9
        case 0xA8:  // TEST AL,Ib
            _ = logic(UInt32(al & fetch()), wide: false)
            return 4
        case 0xA9:
            _ = logic(UInt32(ax & fetch16()), wide: true)
            return 4

        case 0xB0...0xB7:  // MOV r8,Ib
            setReg8(op, fetch())
            return 3
        case 0xB8...0xBF:  // MOV r16,Iv
            setReg16(op, fetch16())
            return 4

        case 0xC0:  // shift Eb,Ib
            decodeModRM()
            let v = UInt32(rm8())
            let count = Int(fetch() & 0x1F)
            setRM8(UInt8(shift(regField, v, count, wide: false)))
            return clocks(5, 17) + count
        case 0xC1:
            decodeModRM()
            let v = UInt32(rm16())
            let count = Int(fetch() & 0x1F)
            setRM16(UInt16(shift(regField, v, count, wide: true)))
            return clocks(5, 17) + count
        case 0xC2:  // RET imm16
            let n = fetch16()
            ip = pop()
            sp &+= n
            return 18
        case 0xC3:  // RET
            ip = pop()
            return 16
        case 0xC4, 0xC5:  // LES, LDS (the register form uses the last address)
            decodeModRM()
            let offset = read16(eaSegment, eaOffset)
            let segment = read16(eaSegment, eaOffset &+ 2)
            setReg16(regField, offset)
            if op == 0xC4 { es = segment } else { ds = segment }
            return 18
        case 0xC6:  // MOV Eb,Ib
            decodeModRM()
            setRM8(fetch())
            return clocks(3, 12)
        case 0xC7:
            decodeModRM()
            setRM16(fetch16())
            return clocks(4, 13)
        case 0xC8:  // ENTER
            let size = fetch16()
            let level = Int(fetch() & 0x1F)
            push(bp)
            let frame = sp
            if level > 0 {
                for _ in 1..<level {
                    bp &-= 2
                    push(read16(ss, bp))
                }
                push(frame)
            }
            bp = frame
            sp &-= size
            return level == 0 ? 15 : level == 1 ? 25 : 22 + 16 * (level - 1)
        case 0xC9:  // LEAVE
            sp = bp
            bp = pop()
            return 8
        case 0xCA:  // RETF imm16
            let n = fetch16()
            ip = pop()
            cs = pop()
            sp &+= n
            return 25
        case 0xCB:  // RETF
            ip = pop()
            cs = pop()
            return 22
        case 0xCC:  // INT 3
            interrupt(Interrupt.breakpoint)
            return 45
        case 0xCD:  // INT n
            interrupt(fetch())
            return 47
        case 0xCE:  // INTO
            if f & fO != 0 {
                interrupt(Interrupt.overflow)
                return 48
            }
            return 4
        case 0xCF:  // IRET
            ip = pop()
            cs = pop()
            flags = pop()
            return 28

        case 0xD0:  // shift Eb,1
            decodeModRM()
            setRM8(UInt8(shift(regField, UInt32(rm8()), 1, wide: false)))
            return clocks(2, 15)
        case 0xD1:
            decodeModRM()
            setRM16(UInt16(shift(regField, UInt32(rm16()), 1, wide: true)))
            return clocks(2, 15)
        case 0xD2:  // shift Eb,CL
            decodeModRM()
            let count = Int(cx & 0x1F)
            setRM8(UInt8(shift(regField, UInt32(rm8()), count, wide: false)))
            return clocks(5, 17) + count
        case 0xD3:
            decodeModRM()
            let count = Int(cx & 0x1F)
            setRM16(UInt16(shift(regField, UInt32(rm16()), count, wide: true)))
            return clocks(5, 17) + count
        case 0xD4:  // AAM
            if !aam(fetch()) {
                interrupt(Interrupt.divideError)
                return 19 + 45
            }
            return 19
        case 0xD5:  // AAD
            aad(fetch())
            return 15
        case 0xD6:  // SALC (undocumented)
            al = carry ? 0xFF : 0
            return 3
        case 0xD7:  // XLAT
            al = read8(dataSegment, bx &+ UInt16(al))
            return 11
        case 0xD8...0xDF:  // ESC: no coprocessor
            decodeModRM()
            if escapeTrap {
                ip = instructionStart
                interrupt(7)
                return 45
            }
            if !isRegisterOperand { _ = read16(eaSegment, eaOffset) }
            return 6

        case 0xE0:  // LOOPNE
            let d = fetchS8()
            cx &-= 1
            if cx != 0 && f & fZ == 0 { ip &+= d; return 16 }
            return 6
        case 0xE1:  // LOOPE
            let d = fetchS8()
            cx &-= 1
            if cx != 0 && f & fZ != 0 { ip &+= d; return 16 }
            return 6
        case 0xE2:  // LOOP
            let d = fetchS8()
            cx &-= 1
            if cx != 0 { ip &+= d; return 16 }
            return 6
        case 0xE3:  // JCXZ
            let d = fetchS8()
            if cx == 0 { ip &+= d; return 15 }
            return 5
        case 0xE4:  // IN AL,Ib
            al = bus.input(UInt16(fetch()))
            return 10
        case 0xE5:
            ax = input16(UInt16(fetch()))
            return 10
        case 0xE6:  // OUT Ib,AL
            bus.output(UInt16(fetch()), al)
            return 9
        case 0xE7:
            output16(UInt16(fetch()), ax)
            return 9
        case 0xE8:  // CALL near
            let d = fetch16()
            push(ip)
            ip &+= d
            return 15
        case 0xE9:  // JMP near
            let d = fetch16()
            ip &+= d
            return 14
        case 0xEA:  // JMP far
            let offset = fetch16()
            cs = fetch16()
            ip = offset
            return 14
        case 0xEB:  // JMP short
            let d = fetchS8()
            ip &+= d
            return 14
        case 0xEC:  // IN AL,DX
            al = bus.input(dx)
            return 8
        case 0xED:
            ax = input16(dx)
            return 8
        case 0xEE:  // OUT DX,AL
            bus.output(dx, al)
            return 7
        case 0xEF:
            output16(dx, ax)
            return 7

        case 0xF4:  // HLT
            halted = true
            return 2
        case 0xF5: f ^= fC; return 2
        case 0xF6: return group3(wide: false)
        case 0xF7: return group3(wide: true)
        case 0xF8: f &= ~fC; return 2
        case 0xF9: f |= fC; return 2
        case 0xFA: f &= ~fI; return 2
        case 0xFB:  // STI: interrupts from after the next instruction
            f |= fI
            interruptShadow = true
            return 2
        case 0xFC: f &= ~fD; return 2
        case 0xFD: f |= fD; return 2
        case 0xFE:  // group 4
            decodeModRM()
            switch regField {
            case 0, 1:
                setRM8(UInt8(incdec(UInt32(rm8()), decrement: regField == 1, wide: false)))
                return clocks(3, 15)
            case 7:
                return undefinedOpcode()
            default:
                return 3
            }
        case 0xFF:
            return group5()

        default:
            // 0F, 63-67, F1: the 80186 traps them.
            return undefinedOpcode()
        }
    }

    /// The undefined opcode trap: interrupt 6, returning to the instruction
    /// (and its prefixes).
    func undefinedOpcode() -> Int {
        ip = instructionStart
        interrupt(Interrupt.undefinedOpcode)
        return 45
    }

    @inline(__always) func condition(_ op: UInt8) -> Bool {
        let s = f & fS != 0, o = f & fO != 0
        let r: Bool
        switch (op >> 1) & 7 {
        case 0: r = o
        case 1: r = f & fC != 0
        case 2: r = f & fZ != 0
        case 3: r = f & (fC | fZ) != 0
        case 4: r = s
        case 5: r = f & fP != 0
        case 6: r = s != o
        default: r = f & fZ != 0 || s != o
        }
        return op & 1 == 0 ? r : !r
    }

    @inline(__always) func input16(_ port: UInt16) -> UInt16 {
        let lo = bus.input(port)
        return UInt16(bus.input(port &+ 1)) << 8 | UInt16(lo)
    }

    @inline(__always) func output16(_ port: UInt16, _ value: UInt16) {
        bus.output(port, UInt8(truncatingIfNeeded: value))
        bus.output(port &+ 1, UInt8(value >> 8))
    }

    // MARK: Groups

    /// F6/F7: TEST NOT NEG MUL IMUL DIV IDIV.
    func group3(wide: Bool) -> Int {
        decodeModRM()
        let v = UInt32(wide ? rm16() : UInt16(rm8()))
        let mask: UInt32 = wide ? 0xFFFF : 0xFF
        switch regField {
        case 0, 1:  // TEST (1 is an alias)
            let imm = wide ? UInt32(fetch16()) : UInt32(fetch())
            _ = logic(v & imm, wide: wide)
            return clocks(4, 10)
        case 2:  // NOT
            store(~v & mask, wide: wide)
            return clocks(3, 10)
        case 3:  // NEG
            store(sub(0, v, 0, wide: wide), wide: wide)
            return clocks(3, 10)
        case 4:
            multiply(v, signed: false, wide: wide)
            return wide ? clocks(35, 41) : clocks(26, 32)
        case 5:
            multiply(v, signed: true, wide: wide)
            return wide ? clocks(34, 40) : clocks(25, 31)
        case 6:
            let clocks = wide ? clocks(38, 44) : clocks(29, 35)
            if !divide(v, signed: false, wide: wide) {
                interrupt(Interrupt.divideError)
                return clocks + 45
            }
            return clocks
        default:
            let clocks = wide ? clocks(53, 59) : clocks(44, 50)
            if !divide(v, signed: true, wide: wide) {
                interrupt(Interrupt.divideError)
                return clocks + 45
            }
            return clocks
        }
    }

    @inline(__always) func store(_ v: UInt32, wide: Bool) {
        if wide { setRM16(UInt16(v)) } else { setRM8(UInt8(v)) }
    }

    /// FF: INC DEC CALL CALLF JMP JMPF PUSH.
    func group5() -> Int {
        decodeModRM()
        switch regField {
        case 0, 1:
            setRM16(UInt16(incdec(UInt32(rm16()), decrement: regField == 1, wide: true)))
            return clocks(3, 15)
        case 2:  // CALL near Ev
            let target = rm16()
            push(ip)
            ip = target
            return clocks(13, 19)
        case 3:  // CALL far Ep
            let offset = read16(eaSegment, eaOffset)
            let segment = read16(eaSegment, eaOffset &+ 2)
            push(cs)
            push(ip)
            cs = segment
            ip = offset
            return 38
        case 4:  // JMP near Ev
            ip = rm16()
            return clocks(11, 17)
        case 5:  // JMP far Ep
            ip = read16(eaSegment, eaOffset)
            cs = read16(eaSegment, eaOffset &+ 2)
            return 26
        case 6:  // PUSH Ev (PUSH SP pushes the decremented value)
            if isRegisterOperand && modrm & 7 == 4 {
                sp &-= 2
                write16(ss, sp, sp)
            } else {
                push(rm16())
            }
            return clocks(10, 16)
        default:
            return undefinedOpcode()
        }
    }

    // MARK: String instructions

    /// One iteration of a string instruction; with a REP prefix, sets
    /// `repeating` (and points `ip` back at the prefixes) if there are more
    /// to go.
    func string(_ op: UInt8, continuing: Bool) -> Int {
        let wide = op & 1 != 0
        let delta: UInt16 = f & fD != 0 ? (wide ? 0xFFFE : 0xFFFF) : (wide ? 2 : 1)
        // Single clocks, then REP base and per-iteration clocks.
        let single: Int, base: Int, each: Int
        var compares = false
        switch op {
        case 0x6C, 0x6D:  // INS
            single = 14; base = 8; each = 8
        case 0x6E, 0x6F:  // OUTS
            single = 14; base = 8; each = 8
        case 0xA4, 0xA5:  // MOVS
            single = 14; base = 8; each = 8
        case 0xA6, 0xA7:  // CMPS
            single = 22; base = 5; each = 22; compares = true
        case 0xAA, 0xAB:  // STOS
            single = 10; base = 6; each = 9
        case 0xAC, 0xAD:  // LODS
            single = 12; base = 6; each = 11
        default:  // SCAS
            single = 15; base = 5; each = 15; compares = true
        }
        if repPrefix == 0 {
            stringIteration(op, wide: wide, delta: delta)
            return single
        }
        let start = continuing ? 0 : base
        if cx == 0 {
            return start
        }
        stringIteration(op, wide: wide, delta: delta)
        cx &-= 1
        var done = cx == 0
        if compares && !done {
            done = (f & fZ != 0) != (repPrefix == 0xF3)
        }
        if !done {
            repeating = true
            ip = instructionStart
        }
        return start + each
    }

    @inline(__always) func stringIteration(_ op: UInt8, wide: Bool, delta: UInt16) {
        switch op {
        case 0x6C:
            write8(es, di, bus.input(dx))
            di &+= delta
        case 0x6D:
            write16(es, di, input16(dx))
            di &+= delta
        case 0x6E:
            bus.output(dx, read8(dataSegment, si))
            si &+= delta
        case 0x6F:
            output16(dx, read16(dataSegment, si))
            si &+= delta
        case 0xA4:
            write8(es, di, read8(dataSegment, si))
            si &+= delta; di &+= delta
        case 0xA5:
            write16(es, di, read16(dataSegment, si))
            si &+= delta; di &+= delta
        case 0xA6:
            _ = sub(UInt32(read8(dataSegment, si)), UInt32(read8(es, di)), 0, wide: false)
            si &+= delta; di &+= delta
        case 0xA7:
            _ = sub(UInt32(read16(dataSegment, si)), UInt32(read16(es, di)), 0, wide: true)
            si &+= delta; di &+= delta
        case 0xAA:
            write8(es, di, al)
            di &+= delta
        case 0xAB:
            write16(es, di, ax)
            di &+= delta
        case 0xAC:
            al = read8(dataSegment, si)
            si &+= delta
        case 0xAD:
            ax = read16(dataSegment, si)
            si &+= delta
        case 0xAE:
            _ = sub(UInt32(al), UInt32(read8(es, di)), 0, wide: false)
            di &+= delta
        default:
            _ = sub(UInt32(ax), UInt32(read16(es, di)), 0, wide: true)
            di &+= delta
        }
    }
}
