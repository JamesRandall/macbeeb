// 80186 arithmetic: the eight ALU operations, shifts and rotates,
// multiply and divide, and the decimal adjusts. Values are passed as UInt32
// holding a byte or a word (`wide`), so one implementation serves both.

private let fC = I80186.flagC, fP = I80186.flagP, fA = I80186.flagA, fZ = I80186.flagZ
private let fS = I80186.flagS, fO = I80186.flagO

extension I80186 {
    @inline(__always) func setSZP(_ r: UInt32, wide: Bool) {
        if wide { setSZP16(UInt16(truncatingIfNeeded: r)) } else { setSZP8(UInt8(truncatingIfNeeded: r)) }
    }

    // MARK: ALU

    /// ALU operation `op` (ADD OR ADC SBB AND SUB XOR CMP) on `a` and `b`,
    /// setting the flags. Returns the result (which CMP doesn't store).
    @inline(__always) func alu(_ op: UInt8, _ a: UInt32, _ b: UInt32, wide: Bool) -> UInt32 {
        switch op & 7 {
        case 0: return add(a, b, 0, wide: wide)
        case 1: return logic(a | b, wide: wide)
        case 2: return add(a, b, carry ? 1 : 0, wide: wide)
        case 3: return sub(a, b, carry ? 1 : 0, wide: wide)
        case 4: return logic(a & b, wide: wide)
        case 5: return sub(a, b, 0, wide: wide)
        case 6: return logic(a ^ b, wide: wide)
        default: return sub(a, b, 0, wide: wide)
        }
    }

    @inline(__always) func add(_ a: UInt32, _ b: UInt32, _ c: UInt32, wide: Bool) -> UInt32 {
        let mask: UInt32 = wide ? 0xFFFF : 0xFF
        let sign: UInt32 = wide ? 0x8000 : 0x80
        let full = a + b + c
        let r = full & mask
        f &= ~(fC | fA | fO)
        if full > mask { f |= fC }
        if (a ^ b ^ r) & 0x10 != 0 { f |= fA }
        if (a ^ r) & (b ^ r) & sign != 0 { f |= fO }
        setSZP(r, wide: wide)
        return r
    }

    @inline(__always) func sub(_ a: UInt32, _ b: UInt32, _ c: UInt32, wide: Bool) -> UInt32 {
        let mask: UInt32 = wide ? 0xFFFF : 0xFF
        let sign: UInt32 = wide ? 0x8000 : 0x80
        let r = (a &- b &- c) & mask
        f &= ~(fC | fA | fO)
        if b + c > a { f |= fC }
        if (a ^ b ^ r) & 0x10 != 0 { f |= fA }
        if (a ^ b) & (a ^ r) & sign != 0 { f |= fO }
        setSZP(r, wide: wide)
        return r
    }

    /// AND, OR, XOR, TEST: C, O and A clear.
    @inline(__always) func logic(_ r: UInt32, wide: Bool) -> UInt32 {
        f &= ~(fC | fA | fO)
        setSZP(r, wide: wide)
        return r
    }

    /// INC and DEC leave C alone.
    @inline(__always) func incdec(_ a: UInt32, decrement: Bool, wide: Bool) -> UInt32 {
        let c = f & fC
        let r = decrement ? sub(a, 1, 0, wide: wide) : add(a, 1, 0, wide: wide)
        f = (f & ~fC) | c
        return r
    }

    // MARK: Shifts and rotates

    /// Shift or rotate `op` (ROL ROR RCL RCR SHL SHR SHL SAR) by `count`,
    /// which the caller has masked (to 5 bits, as the 80186 does). A count
    /// of zero leaves the flags alone. Each bit is shifted in turn, so with
    /// counts above 1 the O flag comes from the last step.
    func shift(_ op: UInt8, _ value: UInt32, _ count: Int, wide: Bool) -> UInt32 {
        guard count > 0 else { return value }
        let mask: UInt32 = wide ? 0xFFFF : 0xFF
        let sign: UInt32 = wide ? 0x8000 : 0x80
        var v = value
        var c = carry
        var o = false
        switch op & 7 {
        case 0:  // ROL
            for _ in 0..<count {
                c = v & sign != 0
                v = ((v << 1) | (c ? 1 : 0)) & mask
            }
            o = (v & sign != 0) != c
        case 1:  // ROR
            for _ in 0..<count {
                c = v & 1 != 0
                v = (v >> 1) | (c ? sign : 0)
            }
            o = (v & sign != 0) != (v & (sign >> 1) != 0)
        case 2:  // RCL
            for _ in 0..<count {
                let out = v & sign != 0
                v = ((v << 1) | (c ? 1 : 0)) & mask
                c = out
            }
            o = (v & sign != 0) != c
        case 3:  // RCR
            for _ in 0..<count {
                let out = v & 1 != 0
                v = (v >> 1) | (c ? sign : 0)
                c = out
            }
            o = (v & sign != 0) != (v & (sign >> 1) != 0)
        case 4, 6:  // SHL (6 is an alias on the 80186)
            for _ in 0..<count {
                c = v & sign != 0
                v = (v << 1) & mask
            }
            o = (v & sign != 0) != c
            setSZP(v, wide: wide)
            setFlag(fA, v & 0x10 != 0)
        case 5:  // SHR
            for _ in 0..<count {
                o = v & sign != 0
                c = v & 1 != 0
                v >>= 1
            }
            setSZP(v, wide: wide)
            setFlag(fA, false)
        default:  // SAR
            for _ in 0..<count {
                c = v & 1 != 0
                v = (v >> 1) | (v & sign)
            }
            o = false
            setSZP(v, wide: wide)
            setFlag(fA, false)
        }
        setFlag(fC, c)
        setFlag(fO, o)
        return v
    }

    // MARK: Multiply and divide

    /// MUL/IMUL into AX (byte) or DX:AX (word). C and O are set when the
    /// high half is significant.
    func multiply(_ src: UInt32, signed: Bool, wide: Bool) {
        if wide {
            let r: UInt32
            if signed {
                let p = Int32(Int16(bitPattern: ax)) * Int32(Int16(bitPattern: UInt16(src)))
                r = UInt32(bitPattern: p)
                let fits = p == Int32(Int16(truncatingIfNeeded: p))
                setFlag(fC, !fits)
                setFlag(fO, !fits)
            } else {
                r = UInt32(ax) * src
                setFlag(fC, r > 0xFFFF)
                setFlag(fO, r > 0xFFFF)
            }
            ax = UInt16(truncatingIfNeeded: r)
            dx = UInt16(r >> 16)
            setSZP16(dx)
            setFlag(fZ, r == 0)
        } else {
            let r: UInt16
            if signed {
                let p = Int16(Int8(bitPattern: al)) * Int16(Int8(bitPattern: UInt8(src)))
                r = UInt16(bitPattern: p)
                let fits = p == Int16(Int8(truncatingIfNeeded: p))
                setFlag(fC, !fits)
                setFlag(fO, !fits)
            } else {
                r = UInt16(al) * UInt16(src)
                setFlag(fC, r > 0xFF)
                setFlag(fO, r > 0xFF)
            }
            ax = r
            setSZP8(ah)
            setFlag(fZ, r == 0)
        }
        setFlag(fA, false)
    }

    /// DIV/IDIV of AX (byte) or DX:AX (word). Returns false (having stored
    /// nothing) for a divide error: a zero divisor or a quotient that
    /// doesn't fit. Unlike the 8086, the 80186 accepts the most negative
    /// quotient (-128 or -32768).
    func divide(_ src: UInt32, signed: Bool, wide: Bool) -> Bool {
        guard src != 0 else { return false }
        if wide {
            let dividend = UInt32(dx) << 16 | UInt32(ax)
            if signed {
                let n = Int64(Int32(bitPattern: dividend))
                let d = Int64(Int16(bitPattern: UInt16(src)))
                let q = n / d
                guard q >= -0x8000 && q <= 0x7FFF else { return false }
                ax = UInt16(truncatingIfNeeded: q)
                dx = UInt16(truncatingIfNeeded: n % d)
            } else {
                let q = dividend / src
                guard q <= 0xFFFF else { return false }
                ax = UInt16(q)
                dx = UInt16(dividend % src)
            }
        } else {
            if signed {
                let n = Int32(Int16(bitPattern: ax))
                let d = Int32(Int8(bitPattern: UInt8(src)))
                let q = n / d
                guard q >= -0x80 && q <= 0x7F else { return false }
                ax = UInt16(UInt8(truncatingIfNeeded: n % d)) << 8 | UInt16(UInt8(truncatingIfNeeded: q))
            } else {
                let n = UInt32(ax)
                let q = n / src
                guard q <= 0xFF else { return false }
                ax = UInt16(n % src) << 8 | UInt16(q)
            }
        }
        return true
    }

    // MARK: Decimal adjust

    func daa() {
        let old = al
        let oldC = carry
        let oldA = f & fA != 0
        var a = old
        if a & 0x0F > 9 || oldA {
            a &+= 6
            f |= fA
        } else {
            f &= ~fA
        }
        // The 8086's threshold is higher when A was set.
        if old > (oldA ? 0x9F : 0x99) || oldC {
            a &+= 0x60
            f |= fC
        } else {
            f &= ~fC
        }
        setFlag(fO, (old & 0x80 == 0) && (a & 0x80 != 0))
        al = a
        setSZP8(a)
    }

    func das() {
        let old = al
        let oldC = carry
        let oldA = f & fA != 0
        var a = old
        if a & 0x0F > 9 || oldA {
            a &-= 6
            f |= fA
        } else {
            f &= ~fA
        }
        // The 8086's threshold is higher when A was set.
        if old > (oldA ? 0x9F : 0x99) || oldC {
            a &-= 0x60
            f |= fC
        } else {
            f &= ~fC
        }
        setFlag(fO, (old & 0x80 != 0) && (a & 0x80 == 0))
        al = a
        setSZP8(a)
    }

    /// AAA (`subtract` false) and AAS.
    func asciiAdjust(subtract: Bool) {
        if al & 0x0F > 9 || f & fA != 0 {
            if subtract {
                _ = sub(UInt32(al), 6, 0, wide: false)
                al &-= 6
                ah &-= 1
            } else {
                _ = add(UInt32(al), 6, 0, wide: false)
                al &+= 6
                ah &+= 1
            }
            f |= fA | fC
        } else {
            setSZP8(al)
            f &= ~(fA | fC | fO)
        }
        al &= 0x0F
    }

    /// AAM: false for a divide error (a zero base), which leaves the flags
    /// as for a zero result.
    func aam(_ base: UInt8) -> Bool {
        guard base != 0 else {
            setSZP8(0)
            return false
        }
        let a = al
        ah = a / base
        al = a % base
        setSZP8(al)
        f &= ~(fC | fA | fO)
        return true
    }

    func aad(_ base: UInt8) {
        let product = UInt32(UInt8(truncatingIfNeeded: UInt32(ah) * UInt32(base)))
        al = UInt8(add(UInt32(al), product, 0, wide: false))
        ah = 0
    }
}
