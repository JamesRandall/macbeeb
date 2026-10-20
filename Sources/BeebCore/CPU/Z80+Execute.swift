// Z80 instruction execution. Each function returns the instruction's
// T-states; the opcode (and any prefixes) have already been fetched.

private let fC = Z80.flagC, fN = Z80.flagN, fPV = Z80.flagPV, fX = Z80.flagX
private let fH = Z80.flagH, fY = Z80.flagY, fZ = Z80.flagZ, fS = Z80.flagS
private let fXY = Z80.flagX | Z80.flagY

extension Z80 {
    // MARK: Register codes

    /// Register by its 3 bit code: B C D E H L - A. Code 6 ((HL)) isn't
    /// handled here.
    @inline(__always) func reg8(_ code: UInt8) -> UInt8 {
        switch code & 7 {
        case 0: return b
        case 1: return c
        case 2: return d
        case 3: return e
        case 4: return h
        case 5: return l
        default: return a
        }
    }

    @inline(__always) func setReg8(_ code: UInt8, _ v: UInt8) {
        switch code & 7 {
        case 0: b = v
        case 1: c = v
        case 2: d = v
        case 3: e = v
        case 4: h = v
        case 5: l = v
        default: a = v
        }
    }

    /// As `reg8`, but H and L are the halves of `xy` (IX or IY).
    @inline(__always) func reg8(_ code: UInt8, _ xy: UInt16) -> UInt8 {
        switch code & 7 {
        case 4: return UInt8(xy >> 8)
        case 5: return UInt8(truncatingIfNeeded: xy)
        default: return reg8(code)
        }
    }

    @inline(__always) func setReg8(_ code: UInt8, _ v: UInt8, _ xy: inout UInt16) {
        switch code & 7 {
        case 4: xy = UInt16(v) << 8 | (xy & 0xFF)
        case 5: xy = (xy & 0xFF00) | UInt16(v)
        default: setReg8(code, v)
        }
    }

    // MARK: Unprefixed

    func execute(_ op: UInt8) -> Int {
        switch op {
        case 0x00: return 4  // NOP
        case 0x01: c = fetch(); b = fetch(); return 10
        case 0x11: e = fetch(); d = fetch(); return 10
        case 0x21: l = fetch(); h = fetch(); return 10
        case 0x31: sp = fetch16(); return 10
        case 0x02:  // LD (BC),A
            write(bc, a)
            wz = UInt16(a) << 8 | ((bc &+ 1) & 0xFF)
            return 7
        case 0x12:  // LD (DE),A
            write(de, a)
            wz = UInt16(a) << 8 | ((de &+ 1) & 0xFF)
            return 7
        case 0x0A: a = read(bc); wz = bc &+ 1; return 7
        case 0x1A: a = read(de); wz = de &+ 1; return 7
        case 0x22:  // LD (nn),HL
            let addr = fetch16()
            write16(addr, hl)
            wz = addr &+ 1
            return 16
        case 0x2A:  // LD HL,(nn)
            let addr = fetch16()
            hl = read16(addr)
            wz = addr &+ 1
            return 16
        case 0x32:  // LD (nn),A
            let addr = fetch16()
            write(addr, a)
            wz = UInt16(a) << 8 | ((addr &+ 1) & 0xFF)
            return 13
        case 0x3A:  // LD A,(nn)
            let addr = fetch16()
            a = read(addr)
            wz = addr &+ 1
            return 13
        case 0x03: bc &+= 1; return 6
        case 0x13: de &+= 1; return 6
        case 0x23: hl &+= 1; return 6
        case 0x33: sp &+= 1; return 6
        case 0x0B: bc &-= 1; return 6
        case 0x1B: de &-= 1; return 6
        case 0x2B: hl &-= 1; return 6
        case 0x3B: sp &-= 1; return 6
        case 0x04: b = inc8(b); return 4
        case 0x0C: c = inc8(c); return 4
        case 0x14: d = inc8(d); return 4
        case 0x1C: e = inc8(e); return 4
        case 0x24: h = inc8(h); return 4
        case 0x2C: l = inc8(l); return 4
        case 0x3C: a = inc8(a); return 4
        case 0x05: b = dec8(b); return 4
        case 0x0D: c = dec8(c); return 4
        case 0x15: d = dec8(d); return 4
        case 0x1D: e = dec8(e); return 4
        case 0x25: h = dec8(h); return 4
        case 0x2D: l = dec8(l); return 4
        case 0x3D: a = dec8(a); return 4
        case 0x34: let addr = hl; write(addr, inc8(read(addr))); return 11
        case 0x35: let addr = hl; write(addr, dec8(read(addr))); return 11
        case 0x06: b = fetch(); return 7
        case 0x0E: c = fetch(); return 7
        case 0x16: d = fetch(); return 7
        case 0x1E: e = fetch(); return 7
        case 0x26: h = fetch(); return 7
        case 0x2E: l = fetch(); return 7
        case 0x3E: a = fetch(); return 7
        case 0x36: let v = fetch(); write(hl, v); return 10
        case 0x07: rlca(); return 4
        case 0x0F: rrca(); return 4
        case 0x17: rla(); return 4
        case 0x1F: rra(); return 4
        case 0x27: daa(); return 4
        case 0x2F: cpl(); return 4
        case 0x37: scf(); return 4
        case 0x3F: ccf(); return 4
        case 0x08:  // EX AF,AF'
            let t = af
            af = afPrime
            afPrime = t
            return 4
        case 0x09: hl = add16(hl, bc); return 11
        case 0x19: hl = add16(hl, de); return 11
        case 0x29: hl = add16(hl, hl); return 11
        case 0x39: hl = add16(hl, sp); return 11
        case 0x10:  // DJNZ e: 13 taken, 8 not
            b &-= 1
            let target = fetchDisplacement(pc &+ 1)
            if b != 0 {
                pc = target
                wz = target
                return 13
            }
            return 8
        case 0x18:  // JR e
            pc = fetchDisplacement(pc &+ 1)
            wz = pc
            return 12
        case 0x20, 0x28, 0x30, 0x38:  // JR cc,e: 12 taken, 7 not
            let target = fetchDisplacement(pc &+ 1)
            if condition((op >> 3) & 3) {
                pc = target
                wz = target
                return 12
            }
            return 7
        case 0x76:  // HALT
            halted = true
            return 4
        case 0x40...0x7F:  // LD r,r'
            let dst = (op >> 3) & 7, src = op & 7
            if src == 6 {
                setReg8(dst, read(hl))
                return 7
            }
            if dst == 6 {
                write(hl, reg8(src))
                return 7
            }
            setReg8(dst, reg8(src))
            return 4
        case 0x80...0xBF:  // ALU A,r
            if op & 7 == 6 {
                alu(op >> 3, read(hl))
                return 7
            }
            alu(op >> 3, reg8(op))
            return 4
        case 0xC6, 0xCE, 0xD6, 0xDE, 0xE6, 0xEE, 0xF6, 0xFE:  // ALU A,n
            alu(op >> 3, fetch())
            return 7
        case 0xC0, 0xC8, 0xD0, 0xD8, 0xE0, 0xE8, 0xF0, 0xF8:  // RET cc: 11 taken, 5 not
            if condition(op >> 3) {
                pc = pop()
                wz = pc
                return 11
            }
            return 5
        case 0xC9:  // RET
            pc = pop()
            wz = pc
            return 10
        case 0xC1: bc = pop(); return 10
        case 0xD1: de = pop(); return 10
        case 0xE1: hl = pop(); return 10
        case 0xF1: af = pop(); return 10
        case 0xC5: push(bc); return 11
        case 0xD5: push(de); return 11
        case 0xE5: push(hl); return 11
        case 0xF5: push(af); return 11
        case 0xC2, 0xCA, 0xD2, 0xDA, 0xE2, 0xEA, 0xF2, 0xFA:  // JP cc,nn: 10 either way
            let addr = fetch16()
            wz = addr
            if condition(op >> 3) { pc = addr }
            return 10
        case 0xC3:
            pc = fetch16()
            wz = pc
            return 10
        case 0xC4, 0xCC, 0xD4, 0xDC, 0xE4, 0xEC, 0xF4, 0xFC:  // CALL cc,nn: 17 taken, 10 not
            let addr = fetch16()
            wz = addr
            if condition(op >> 3) {
                push(pc)
                pc = addr
                return 17
            }
            return 10
        case 0xCD:
            let addr = fetch16()
            push(pc)
            pc = addr
            wz = addr
            return 17
        case 0xC7, 0xCF, 0xD7, 0xDF, 0xE7, 0xEF, 0xF7, 0xFF:  // RST p
            push(pc)
            pc = UInt16(op & 0x38)
            wz = pc
            return 11
        case 0xD3:  // OUT (n),A
            let n = fetch()
            bus.output(UInt16(a) << 8 | UInt16(n), a)
            wz = UInt16(a) << 8 | UInt16(n &+ 1)
            return 11
        case 0xDB:  // IN A,(n)
            let port = UInt16(a) << 8 | UInt16(fetch())
            a = bus.input(port)
            wz = port &+ 1
            return 11
        case 0xD9:  // EXX
            var t = bc; bc = bcPrime; bcPrime = t
            t = de; de = dePrime; dePrime = t
            t = hl; hl = hlPrime; hlPrime = t
            return 4
        case 0xE3:  // EX (SP),HL
            let v = read16(sp)
            write16(sp, hl)
            hl = v
            wz = v
            return 19
        case 0xE9: pc = hl; return 4  // JP (HL)
        case 0xEB:  // EX DE,HL
            let t = de
            de = hl
            hl = t
            return 4
        case 0xF9: sp = hl; return 6
        case 0xF3:  // DI
            iff1 = false
            iff2 = false
            return 4
        case 0xFB:  // EI
            iff1 = true
            iff2 = true
            eiDelay = true
            return 4
        case 0xCB: return executeCB()
        case 0xED: return executeED()
        case 0xDD:
            let t = executeIndexed(&ix)
            return t >= 0 ? t : 4 + execute(UInt8(-1 - t))
        default:  // 0xFD
            let t = executeIndexed(&iy)
            return t >= 0 ? t : 4 + execute(UInt8(-1 - t))
        }
    }

    // MARK: CB

    /// CB xx: 8 T-states for a register; 15 for (HL), 12 for BIT n,(HL).
    func executeCB() -> Int {
        let op = fetchOpcode()
        let code = op & 7
        let n = (op >> 3) & 7
        if code == 6 {
            let addr = hl
            let v = read(addr)
            switch op >> 6 {
            case 0: write(addr, rotateShift(n, v))
            case 1:
                bit(n, v, xy: UInt8(wz >> 8))
                return 12
            case 2: write(addr, v & ~(1 << n))
            default: write(addr, v | (1 << n))
            }
            return 15
        }
        let v = reg8(code)
        switch op >> 6 {
        case 0: setReg8(code, rotateShift(n, v))
        case 1: bit(n, v, xy: v)
        case 2: setReg8(code, v & ~(1 << n))
        default: setReg8(code, v | (1 << n))
        }
        return 8
    }

    // MARK: DD/FD

    /// DD/FD xx, with `xy` IX or IY. A prefix in front of an instruction
    /// that doesn't use HL, H or L (or another prefix) is a 4 T-state NOP:
    /// then this returns -1 - opcode, and the caller executes the opcode
    /// (outside the access to `xy`).
    func executeIndexed(_ xy: inout UInt16) -> Int {
        let op = fetchOpcode()
        switch op {
        case 0x09: xy = add16(xy, bc); return 15
        case 0x19: xy = add16(xy, de); return 15
        case 0x29: xy = add16(xy, xy); return 15
        case 0x39: xy = add16(xy, sp); return 15
        case 0x21: xy = fetch16(); return 14
        case 0x22:
            let addr = fetch16()
            write16(addr, xy)
            wz = addr &+ 1
            return 20
        case 0x2A:
            let addr = fetch16()
            xy = read16(addr)
            wz = addr &+ 1
            return 20
        case 0x23: xy &+= 1; return 10
        case 0x2B: xy &-= 1; return 10
        case 0x24: setReg8(4, inc8(reg8(4, xy)), &xy); return 8
        case 0x25: setReg8(4, dec8(reg8(4, xy)), &xy); return 8
        case 0x2C: setReg8(5, inc8(reg8(5, xy)), &xy); return 8
        case 0x2D: setReg8(5, dec8(reg8(5, xy)), &xy); return 8
        case 0x26: setReg8(4, fetch(), &xy); return 11
        case 0x2E: setReg8(5, fetch(), &xy); return 11
        case 0x34:
            let addr = fetchDisplacement(xy)
            wz = addr
            write(addr, inc8(read(addr)))
            return 23
        case 0x35:
            let addr = fetchDisplacement(xy)
            wz = addr
            write(addr, dec8(read(addr)))
            return 23
        case 0x36:
            let addr = fetchDisplacement(xy)
            wz = addr
            write(addr, fetch())
            return 19
        case 0x76:
            halted = true
            return 8
        case 0x40...0x7F:
            let dst = (op >> 3) & 7, src = op & 7
            if src == 6 {  // LD r,(IX+d), with the real H/L
                let addr = fetchDisplacement(xy)
                wz = addr
                setReg8(dst, read(addr))
                return 19
            }
            if dst == 6 {  // LD (IX+d),r
                let addr = fetchDisplacement(xy)
                wz = addr
                write(addr, reg8(src))
                return 19
            }
            setReg8(dst, reg8(src, xy), &xy)
            return 8
        case 0x80...0xBF:
            if op & 7 == 6 {
                let addr = fetchDisplacement(xy)
                wz = addr
                alu(op >> 3, read(addr))
                return 19
            }
            alu(op >> 3, reg8(op, xy))
            return 8
        case 0xCB: return executeIndexedCB(xy)
        case 0xE1: xy = pop(); return 14
        case 0xE5: push(xy); return 15
        case 0xE3:  // EX (SP),IX
            let v = read16(sp)
            write16(sp, xy)
            xy = v
            wz = v
            return 23
        case 0xE9: pc = xy; return 8
        case 0xF9: sp = xy; return 10
        default:
            return -1 - Int(op)
        }
    }

    /// DDCB d xx / FDCB d xx: 23 T-states, or 20 for BIT. Neither the
    /// displacement nor the final opcode is an M1 fetch. Except for BIT,
    /// the result is also copied to the register in bits 0-2 (unless 6).
    func executeIndexedCB(_ xy: UInt16) -> Int {
        let addr = fetchDisplacement(xy)
        let op = fetch()
        wz = addr
        let v = read(addr)
        let n = (op >> 3) & 7
        let res: UInt8
        switch op >> 6 {
        case 0: res = rotateShift(n, v)
        case 1:
            bit(n, v, xy: UInt8(addr >> 8))
            return 20
        case 2: res = v & ~(1 << n)
        default: res = v | (1 << n)
        }
        write(addr, res)
        if op & 7 != 6 { setReg8(op & 7, res) }
        return 23
    }

    // MARK: ED

    func executeED() -> Int {
        let op = fetchOpcode()
        switch op {
        case 0x40, 0x48, 0x50, 0x58, 0x60, 0x68, 0x70, 0x78:  // IN r,(C); 70 is IN (C)
            let port = bc
            let v = bus.input(port)
            wz = port &+ 1
            setFlags((f & fC) | z80SZXYP[Int(v)])
            if op != 0x70 { setReg8(op >> 3, v) }
            return 12
        case 0x41, 0x49, 0x51, 0x59, 0x61, 0x69, 0x71, 0x79:  // OUT (C),r; 71 is OUT (C),0
            let port = bc
            bus.output(port, op == 0x71 ? 0 : reg8(op >> 3))
            wz = port &+ 1
            return 12
        case 0x42: sbc16(bc); return 15
        case 0x52: sbc16(de); return 15
        case 0x62: sbc16(hl); return 15
        case 0x72: sbc16(sp); return 15
        case 0x4A: adc16(bc); return 15
        case 0x5A: adc16(de); return 15
        case 0x6A: adc16(hl); return 15
        case 0x7A: adc16(sp); return 15
        case 0x43, 0x53, 0x63, 0x73:  // LD (nn),rp
            let addr = fetch16()
            let v: UInt16
            switch op {
            case 0x43: v = bc
            case 0x53: v = de
            case 0x63: v = hl
            default: v = sp
            }
            write16(addr, v)
            wz = addr &+ 1
            return 20
        case 0x4B, 0x5B, 0x6B, 0x7B:  // LD rp,(nn)
            let addr = fetch16()
            let v = read16(addr)
            switch op {
            case 0x4B: bc = v
            case 0x5B: de = v
            case 0x6B: hl = v
            default: sp = v
            }
            wz = addr &+ 1
            return 20
        case 0x44, 0x4C, 0x54, 0x5C, 0x64, 0x6C, 0x74, 0x7C:
            neg()
            return 8
        case 0x45, 0x4D, 0x55, 0x5D, 0x65, 0x6D, 0x75, 0x7D:  // RETN; 4D is RETI
            // Both copy IFF2 to IFF1.
            iff1 = iff2
            pc = pop()
            wz = pc
            return 14
        case 0x46, 0x4E, 0x66, 0x6E: im = 0; return 8
        case 0x56, 0x76: im = 1; return 8
        case 0x5E, 0x7E: im = 2; return 8
        case 0x47: i = a; return 9
        case 0x4F: r = a; return 9
        case 0x57:  // LD A,I
            a = i
            setFlags((f & fC) | z80SZXY[Int(a)] | (iff2 ? fPV : 0))
            afterLDAIR = true
            return 9
        case 0x5F:  // LD A,R
            a = r
            setFlags((f & fC) | z80SZXY[Int(a)] | (iff2 ? fPV : 0))
            afterLDAIR = true
            return 9
        case 0x67:  // RRD
            let addr = hl
            let v = read(addr)
            write(addr, a << 4 | v >> 4)
            a = (a & 0xF0) | (v & 0x0F)
            setFlags((f & fC) | z80SZXYP[Int(a)])
            wz = addr &+ 1
            return 18
        case 0x6F:  // RLD
            let addr = hl
            let v = read(addr)
            write(addr, v << 4 | (a & 0x0F))
            a = (a & 0xF0) | (v >> 4)
            setFlags((f & fC) | z80SZXYP[Int(a)])
            wz = addr &+ 1
            return 18
        case 0xA0: ldi(1); return 16
        case 0xA8: ldi(0xFFFF); return 16
        case 0xB0, 0xB8:  // LDIR/LDDR: 21 repeating, 16 not
            ldi(op == 0xB0 ? 1 : 0xFFFF)
            if bc != 0 {
                repeatBlock()
                return 21
            }
            return 16
        case 0xA1: cpi(1); return 16
        case 0xA9: cpi(0xFFFF); return 16
        case 0xB1, 0xB9:  // CPIR/CPDR
            cpi(op == 0xB1 ? 1 : 0xFFFF)
            if bc != 0 && f & fZ == 0 {
                repeatBlock()
                return 21
            }
            return 16
        case 0xA2: _ = ini(1); return 16
        case 0xAA: _ = ini(0xFFFF); return 16
        case 0xB2, 0xBA:  // INIR/INDR
            let v = ini(op == 0xB2 ? 1 : 0xFFFF)
            if b != 0 {
                repeatBlock()
                repeatBlockIOFlags(v)
                return 21
            }
            return 16
        case 0xA3: _ = outi(1); return 16
        case 0xAB: _ = outi(0xFFFF); return 16
        case 0xB3, 0xBB:  // OTIR/OTDR
            let v = outi(op == 0xB3 ? 1 : 0xFFFF)
            if b != 0 {
                repeatBlock()
                repeatBlockIOFlags(v)
                return 21
            }
            return 16
        default:
            return 8  // the other ED xx are 8 T-state NOPs
        }
    }

    // MARK: Block instructions

    /// LDI (`step` 1) or LDD (`step` $FFFF).
    @inline(__always) func ldi(_ step: UInt16) {
        let v = read(hl)
        write(de, v)
        hl &+= step
        de &+= step
        bc &-= 1
        let n = v &+ a
        setFlags((f & (fS | fZ | fC)) | (bc != 0 ? fPV : 0) | (n & fX) | ((n & 0x02) << 4))
    }

    @inline(__always) func cpi(_ step: UInt16) {
        let v = read(hl)
        let res = a &- v
        hl &+= step
        bc &-= 1
        wz &+= step
        let half = (a ^ v ^ res) & fH
        let n = res &- (half >> 4)
        setFlags((f & fC) | fN | (res & fS) | (res == 0 ? fZ : 0) | half | (bc != 0 ? fPV : 0)
            | (n & fX) | ((n & 0x02) << 4))
    }

    /// The flags of INI/IND/OUTI/OUTD. `k` is the value plus C±1 or L.
    @inline(__always) func blockIOFlags(_ v: UInt8, _ k: Int) {
        setFlags(z80SZXY[Int(b)] | ((v & 0x80) >> 6) | (k > 0xFF ? fH | fC : 0)
            | z80Parity(UInt8(k & 7) ^ b))
    }

    @inline(__always) func ini(_ step: UInt16) -> UInt8 {
        let port = bc
        wz = port &+ step
        let v = bus.input(port)
        write(hl, v)
        b &-= 1
        hl &+= step
        blockIOFlags(v, Int(v) + Int(c &+ UInt8(truncatingIfNeeded: step)))
        return v
    }

    @inline(__always) func outi(_ step: UInt16) -> UInt8 {
        let v = read(hl)
        b &-= 1
        let port = bc
        wz = port &+ step
        bus.output(port, v)
        hl &+= step
        blockIOFlags(v, Int(v) + Int(l))
        return v
    }

    /// Sets up a block instruction to run again: X and Y come from the high
    /// byte of PC (the instruction's address).
    @inline(__always) func repeatBlock() {
        pc &-= 2
        wz = pc &+ 1
        setFlags((f & ~fXY) | (UInt8(pc >> 8) & fXY))
    }

    /// The extra flag changes of a repeating INIR/INDR/OTIR/OTDR.
    func repeatBlockIOFlags(_ v: UInt8) {
        var flags = f
        if flags & fC != 0 {
            flags &= ~fH
            if v & 0x80 != 0 {
                flags ^= z80Parity((b &- 1) & 7) ^ fPV
                if b & 0x0F == 0x00 { flags |= fH }
            } else {
                flags ^= z80Parity((b &+ 1) & 7) ^ fPV
                if b & 0x0F == 0x0F { flags |= fH }
            }
        } else {
            flags ^= z80Parity(b & 7) ^ fPV
        }
        setFlags(flags)
    }
}
