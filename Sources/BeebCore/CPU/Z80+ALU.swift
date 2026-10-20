// Z80 arithmetic, logic and flag calculations.

private let fC = Z80.flagC, fN = Z80.flagN, fPV = Z80.flagPV, fX = Z80.flagX
private let fH = Z80.flagH, fY = Z80.flagY, fZ = Z80.flagZ, fS = Z80.flagS
private let fXY = Z80.flagX | Z80.flagY

/// S, Z, X and Y for each value.
nonisolated(unsafe) let z80SZXY: UnsafePointer<UInt8> = {
    let table = UnsafeMutablePointer<UInt8>.allocate(capacity: 256)
    for v in 0..<256 {
        table[v] = UInt8(v) & (Z80.flagS | Z80.flagX | Z80.flagY) | (v == 0 ? Z80.flagZ : 0)
    }
    return UnsafePointer(table)
}()

/// S, Z, X, Y and P (set for even parity) for each value.
nonisolated(unsafe) let z80SZXYP: UnsafePointer<UInt8> = {
    let table = UnsafeMutablePointer<UInt8>.allocate(capacity: 256)
    for v in 0..<256 {
        table[v] = z80SZXY[v] | (UInt8(v).nonzeroBitCount & 1 == 0 ? Z80.flagPV : 0)
    }
    return UnsafePointer(table)
}()

@inline(__always) func z80Parity(_ v: UInt8) -> UInt8 { z80SZXYP[Int(v)] & Z80.flagPV }

extension Z80 {
    @inline(__always) func add8(_ v: UInt8, carry: UInt8 = 0) {
        let sum = Int(a) + Int(v) + Int(carry)
        let res = UInt8(truncatingIfNeeded: sum)
        setFlags(z80SZXY[Int(res)] | ((a ^ v ^ res) & fH)
            | (((a ^ ~v) & (a ^ res) & 0x80) >> 5) | (sum > 0xFF ? fC : 0))
        a = res
    }

    @inline(__always) func sub8(_ v: UInt8, carry: UInt8 = 0) {
        let diff = Int(a) - Int(v) - Int(carry)
        let res = UInt8(truncatingIfNeeded: diff)
        setFlags(z80SZXY[Int(res)] | fN | ((a ^ v ^ res) & fH)
            | (((a ^ v) & (a ^ res) & 0x80) >> 5) | (diff < 0 ? fC : 0))
        a = res
    }

    /// CP: as SUB, but X and Y come from the operand.
    @inline(__always) func cp8(_ v: UInt8) {
        let diff = Int(a) - Int(v)
        let res = UInt8(truncatingIfNeeded: diff)
        setFlags((z80SZXY[Int(res)] & (fS | fZ)) | (v & fXY) | fN | ((a ^ v ^ res) & fH)
            | (((a ^ v) & (a ^ res) & 0x80) >> 5) | (diff < 0 ? fC : 0))
    }

    @inline(__always) func and8(_ v: UInt8) {
        a &= v
        setFlags(z80SZXYP[Int(a)] | fH)
    }

    @inline(__always) func xor8(_ v: UInt8) {
        a ^= v
        setFlags(z80SZXYP[Int(a)])
    }

    @inline(__always) func or8(_ v: UInt8) {
        a |= v
        setFlags(z80SZXYP[Int(a)])
    }

    /// ALU operation `op` (bits 3-5 of the opcode) on A and `v`.
    @inline(__always) func alu(_ op: UInt8, _ v: UInt8) {
        switch op & 7 {
        case 0: add8(v)
        case 1: add8(v, carry: f & fC)
        case 2: sub8(v)
        case 3: sub8(v, carry: f & fC)
        case 4: and8(v)
        case 5: xor8(v)
        case 6: or8(v)
        default: cp8(v)
        }
    }

    @inline(__always) func inc8(_ v: UInt8) -> UInt8 {
        let res = v &+ 1
        setFlags((f & fC) | z80SZXY[Int(res)] | (res & 0x0F == 0 ? fH : 0) | (res == 0x80 ? fPV : 0))
        return res
    }

    @inline(__always) func dec8(_ v: UInt8) -> UInt8 {
        let res = v &- 1
        setFlags((f & fC) | fN | z80SZXY[Int(res)] | (v & 0x0F == 0 ? fH : 0) | (v == 0x80 ? fPV : 0))
        return res
    }

    /// ADD HL/IX/IY,rp.
    @inline(__always) func add16(_ x: UInt16, _ y: UInt16) -> UInt16 {
        let sum = UInt32(x) + UInt32(y)
        let res = UInt16(truncatingIfNeeded: sum)
        wz = x &+ 1
        setFlags((f & (fS | fZ | fPV)) | (UInt8(res >> 8) & fXY)
            | (UInt8(truncatingIfNeeded: (x ^ y ^ res) >> 8) & fH) | UInt8(sum >> 16))
        return res
    }

    func adc16(_ y: UInt16) {
        let x = hl
        let sum = UInt32(x) + UInt32(y) + UInt32(f & fC)
        let res = UInt16(truncatingIfNeeded: sum)
        wz = x &+ 1
        setFlags((UInt8(res >> 8) & (fS | fXY)) | (res == 0 ? fZ : 0)
            | (UInt8(truncatingIfNeeded: (x ^ y ^ res) >> 8) & fH)
            | UInt8(truncatingIfNeeded: ((x ^ ~y) & (x ^ res) & 0x8000) >> 13) | UInt8(sum >> 16))
        hl = res
    }

    func sbc16(_ y: UInt16) {
        let x = hl
        let diff = Int(x) - Int(y) - Int(f & fC)
        let res = UInt16(truncatingIfNeeded: diff)
        wz = x &+ 1
        setFlags((UInt8(res >> 8) & (fS | fXY)) | (res == 0 ? fZ : 0) | fN
            | (UInt8(truncatingIfNeeded: (x ^ y ^ res) >> 8) & fH)
            | UInt8(truncatingIfNeeded: ((x ^ y) & (x ^ res) & 0x8000) >> 13) | (diff < 0 ? fC : 0))
        hl = res
    }

    func daa() {
        var adjust: UInt8 = 0
        var carry = f & fC
        let lowNibble = a & 0x0F
        if f & fH != 0 || lowNibble > 9 { adjust = 0x06 }
        if carry != 0 || a > 0x99 {
            adjust |= 0x60
            carry = fC
        }
        let res: UInt8
        let half: UInt8
        if f & fN != 0 {
            res = a &- adjust
            half = (f & fH != 0 && lowNibble < 6) ? fH : 0
        } else {
            res = a &+ adjust
            half = lowNibble > 9 ? fH : 0
        }
        a = res
        setFlags(z80SZXYP[Int(res)] | (f & fN) | half | carry)
    }

    func rlca() {
        a = a << 1 | a >> 7
        setFlags((f & (fS | fZ | fPV)) | (a & (fXY | fC)))
    }

    func rrca() {
        let carry = a & 1
        a = a >> 1 | a << 7
        setFlags((f & (fS | fZ | fPV)) | (a & fXY) | carry)
    }

    func rla() {
        let carry = a >> 7
        a = a << 1 | (f & fC)
        setFlags((f & (fS | fZ | fPV)) | (a & fXY) | carry)
    }

    func rra() {
        let carry = a & 1
        a = a >> 1 | (f & fC) << 7
        setFlags((f & (fS | fZ | fPV)) | (a & fXY) | carry)
    }

    func cpl() {
        a = ~a
        setFlags((f & (fS | fZ | fPV | fC)) | fH | fN | (a & fXY))
    }

    func scf() {
        setFlags((f & (fS | fZ | fPV)) | fC | (((lastQ ^ f) | a) & fXY))
    }

    func ccf() {
        let carry = f & fC
        setFlags((f & (fS | fZ | fPV)) | (carry != 0 ? fH : fC) | (((lastQ ^ f) | a) & fXY))
    }

    func neg() {
        let v = a
        a = 0
        sub8(v)
    }

    /// CB rotate/shift `op` (bits 3-5 of the opcode) on `v`.
    @inline(__always) func rotateShift(_ op: UInt8, _ v: UInt8) -> UInt8 {
        let res: UInt8
        let carry: UInt8
        switch op & 7 {
        case 0: res = v << 1 | v >> 7; carry = v >> 7  // RLC
        case 1: res = v >> 1 | v << 7; carry = v & 1  // RRC
        case 2: res = v << 1 | (f & fC); carry = v >> 7  // RL
        case 3: res = v >> 1 | (f & fC) << 7; carry = v & 1  // RR
        case 4: res = v << 1; carry = v >> 7  // SLA
        case 5: res = v >> 1 | (v & 0x80); carry = v & 1  // SRA
        case 6: res = v << 1 | 1; carry = v >> 7  // SLL (undocumented)
        default: res = v >> 1; carry = v & 1  // SRL
        }
        setFlags(z80SZXYP[Int(res)] | carry)
        return res
    }

    /// BIT n: X and Y come from `xy` (the operand, or for memory operands
    /// the high byte of MEMPTR).
    @inline(__always) func bit(_ n: UInt8, _ v: UInt8, xy: UInt8) {
        let set = v & (1 << n)
        setFlags((f & fC) | fH | (xy & fXY) | (set == 0 ? fZ | fPV : 0) | (set & fS))
    }

    @inline(__always) func condition(_ cc: UInt8) -> Bool {
        switch cc & 7 {
        case 0: return f & fZ == 0
        case 1: return f & fZ != 0
        case 2: return f & fC == 0
        case 3: return f & fC != 0
        case 4: return f & fPV == 0
        case 5: return f & fPV != 0
        case 6: return f & fS == 0
        default: return f & fS != 0
        }
    }
}
