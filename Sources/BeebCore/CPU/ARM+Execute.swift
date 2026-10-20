// The ARM's instructions. While one runs, regs[15] is its address plus 8.

extension ARM {
    /// Runs an instruction whose condition passed. Returns its cycles.
    @inline(__always)
    func execute(_ i: UInt32, at address: UInt32) -> Int {
        switch (i >> 25) & 7 {
        case 0:
            if i & 0x0FC0_00F0 == 0x0000_0090 {
                return multiply(i)
            }
            return dataProcessing(i)
        case 1:
            return dataProcessing(i)
        case 2, 3:
            return singleTransfer(i, at: address)
        case 4:
            return blockTransfer(i, at: address)
        case 5:
            // B, BL: a signed 24-bit word offset from PC+8.
            if i & (1 << 24) != 0 {
                regs[14] = ((address &+ 4) & Self.pcMask) | psr
            }
            let offset = UInt32(bitPattern: Int32(bitPattern: i << 8) >> 6)
            writePC(regs[15] &+ offset)
            return 3
        case 6:
            // LDC/STC: no coprocessor.
            return undefined(at: address)
        default:
            if i & (1 << 24) != 0 {
                exception(Self.swiVector, .supervisor, link: address &+ 4, disableFIQ: false)
                return 3
            }
            // CDP/MCR/MRC: no coprocessor.
            return undefined(at: address)
        }
    }

    // Bus accesses, without retaining it.
    @inline(__always)
    func busReadWord(_ address: UInt32) -> UInt32 { busReference._withUnsafeGuaranteedRef { $0.readWord(address) } }
    @inline(__always)
    func busReadByte(_ address: UInt32) -> UInt8 { busReference._withUnsafeGuaranteedRef { $0.readByte(address) } }
    @inline(__always)
    func busWriteWord(_ address: UInt32, _ value: UInt32) { busReference._withUnsafeGuaranteedRef { $0.writeWord(address, value) } }
    @inline(__always)
    func busWriteByte(_ address: UInt32, _ value: UInt8) { busReference._withUnsafeGuaranteedRef { $0.writeByte(address, value) } }

    @inline(__always)
    func writePC(_ value: UInt32) {
        regs[15] = value & Self.pcMask
        branched = true
    }

    func undefined(at address: UInt32) -> Int {
        exception(Self.undefinedVector, .supervisor, link: address &+ 4, disableFIQ: false)
        return 3
    }

    // MARK: Data processing

    /// Operand 2 as a shifted register, and the shifter's carry out.
    @inline(__always)
    func shiftedRegister(_ i: UInt32, carry: inout Bool) -> UInt32 {
        let rm = Int(i & 15)
        let type = (i >> 5) & 3
        if i & 0x10 != 0 {
            // Register-specified: the extra cycle reads R15 4 further on.
            let value = rm == 15 ? (regs[15] &+ 4) | psr : regs[rm]
            let amount = regs[Int((i >> 8) & 15)] & 0xFF
            if amount == 0 { return value }
            switch type {
            case 0: // LSL
                if amount < 32 {
                    carry = (value >> (32 - amount)) & 1 != 0
                    return value << amount
                }
                carry = amount == 32 && value & 1 != 0
                return 0
            case 1: // LSR
                if amount < 32 {
                    carry = (value >> (amount - 1)) & 1 != 0
                    return value >> amount
                }
                carry = amount == 32 && value >> 31 != 0
                return 0
            case 2: // ASR
                if amount < 32 {
                    carry = (value >> (amount - 1)) & 1 != 0
                    return UInt32(bitPattern: Int32(bitPattern: value) >> Int32(amount))
                }
                carry = value >> 31 != 0
                return UInt32(bitPattern: Int32(bitPattern: value) >> 31)
            default: // ROR
                let r = amount & 31
                if r == 0 {
                    carry = value >> 31 != 0
                    return value
                }
                carry = (value >> (r - 1)) & 1 != 0
                return value >> r | value << (32 - r)
            }
        }
        let value = rm == 15 ? regs[15] | psr : regs[rm]
        let amount = (i >> 7) & 31
        return immediateShift(value, type: type, amount: amount, carry: &carry)
    }

    /// A shift by a constant. A zero amount means LSL #0 (no shift), LSR #32,
    /// ASR #32 or RRX.
    @inline(__always)
    func immediateShift(_ value: UInt32, type: UInt32, amount: UInt32, carry: inout Bool) -> UInt32 {
        switch type {
        case 0:
            if amount == 0 { return value }
            carry = (value >> (32 - amount)) & 1 != 0
            return value << amount
        case 1:
            if amount == 0 {
                carry = value >> 31 != 0
                return 0
            }
            carry = (value >> (amount - 1)) & 1 != 0
            return value >> amount
        case 2:
            if amount == 0 {
                carry = value >> 31 != 0
                return UInt32(bitPattern: Int32(bitPattern: value) >> 31)
            }
            carry = (value >> (amount - 1)) & 1 != 0
            return UInt32(bitPattern: Int32(bitPattern: value) >> Int32(amount))
        default:
            if amount == 0 {
                let result = value >> 1 | (c ? 0x8000_0000 : 0)
                carry = value & 1 != 0
                return result
            }
            carry = (value >> (amount - 1)) & 1 != 0
            return value >> amount | value << (32 - amount)
        }
    }

    /// a + b + carry, with the carry and overflow out.
    @inline(__always)
    func add(_ a: UInt32, _ b: UInt32, _ carryIn: Bool, carry: inout Bool, overflow: inout Bool) -> UInt32 {
        let wide = UInt64(a) + UInt64(b) + (carryIn ? 1 : 0)
        let result = UInt32(truncatingIfNeeded: wide)
        carry = wide >> 32 != 0
        overflow = (~(a ^ b) & (a ^ result)) >> 31 != 0
        return result
    }

    func dataProcessing(_ i: UInt32) -> Int {
        var shifterCarry = c
        let op2: UInt32
        var cycles = 1
        if i & (1 << 25) != 0 {
            let rotate = (i >> 7) & 0x1E
            let imm = i & 0xFF
            op2 = rotate == 0 ? imm : imm >> rotate | imm << (32 - rotate)
            if rotate != 0 { shifterCarry = op2 >> 31 != 0 }
        } else {
            op2 = shiftedRegister(i, carry: &shifterCarry)
            if i & 0x10 != 0 { cycles = 2 }
        }
        let rn = Int((i >> 16) & 15)
        // Rn = R15 is the PC alone (4 further on with a register shift).
        let op1 = rn == 15 && i & 0x02000010 == 0x10 ? (regs[15] &+ 4) & Self.pcMask : regs[rn]
        let rd = Int((i >> 12) & 15)
        let setFlags = i & (1 << 20) != 0
        let opcode = (i >> 21) & 15

        var result: UInt32
        var carry = shifterCarry
        var overflow = v
        switch opcode {
        case 0x0, 0x8: result = op1 & op2
        case 0x1, 0x9: result = op1 ^ op2
        case 0xC: result = op1 | op2
        case 0xD: result = op2
        case 0xE: result = op1 & ~op2
        case 0xF: result = ~op2
        case 0x2, 0xA: result = add(op1, ~op2, true, carry: &carry, overflow: &overflow)
        case 0x3: result = add(op2, ~op1, true, carry: &carry, overflow: &overflow)
        case 0x4, 0xB: result = add(op1, op2, false, carry: &carry, overflow: &overflow)
        case 0x5: result = add(op1, op2, c, carry: &carry, overflow: &overflow)
        case 0x6: result = add(op1, ~op2, c, carry: &carry, overflow: &overflow)
        default: result = add(op2, ~op1, c, carry: &carry, overflow: &overflow)
        }

        if opcode & 0xC == 0x8 {
            // TST, TEQ, CMP, CMN: only with S. Rd = R15 is the P form,
            // which writes the PSR from the result.
            guard setFlags else { return cycles }
            if rd == 15 {
                writePSR(result)
            } else {
                n = result >> 31 != 0
                z = result == 0
                c = carry
                v = overflow
            }
            return cycles
        }
        if rd == 15 {
            writePC(result)
            if setFlags { writePSR(result) }
            return cycles + 2
        }
        regs[rd] = result
        if setFlags {
            n = result >> 31 != 0
            z = result == 0
            c = carry
            v = overflow
        }
        return cycles
    }

    /// MUL and MLA (the ARM2's). Rd = R15 does nothing, Rd = Rm gives 0 (as
    /// Tarmac). C is left alone.
    func multiply(_ i: UInt32) -> Int {
        let rd = Int((i >> 16) & 15)
        let rm = Int(i & 15)
        let rs = regs[Int((i >> 8) & 15)]
        guard rd != 15 else { return 2 }
        var result: UInt32 = 0
        if rd != rm {
            result = (rm == 15 ? (regs[15] &+ 4) | psr : regs[rm]) &* rs
            if i & (1 << 21) != 0 {
                let rn = Int((i >> 12) & 15)
                result &+= rn == 15 ? regs[15] | psr : regs[rn]
            }
        }
        regs[rd] = result
        if i & (1 << 20) != 0 {
            n = result >> 31 != 0
            z = result == 0
        }
        // Booth's algorithm, 2 bits a cycle.
        return 1 + max(1, (32 - rs.leadingZeroBitCount + 1) / 2)
    }

    // MARK: LDR/STR

    func singleTransfer(_ i: UInt32, at address: UInt32) -> Int {
        let offset: UInt32
        if i & (1 << 25) != 0 {
            if i & 0x10 != 0 { return undefined(at: address) }
            let rm = Int(i & 15)
            var unused = c
            offset = immediateShift(rm == 15 ? regs[15] | psr : regs[rm], type: (i >> 5) & 3,
                                    amount: (i >> 7) & 31, carry: &unused)
        } else {
            offset = i & 0xFFF
        }
        let rn = Int((i >> 16) & 15)
        let rd = Int((i >> 12) & 15)
        let base = regs[rn]
        let indexed = i & (1 << 23) != 0 ? base &+ offset : base &- offset
        let pre = i & (1 << 24) != 0
        let target = pre ? indexed : base
        let writeback = !pre || i & (1 << 21) != 0
        let byte = i & (1 << 22) != 0
        guard target & 0xFC00_0000 == 0 else {
            exception(Self.addressExceptionVector, .supervisor, link: address &+ 8, disableFIQ: false)
            return 3
        }
        if i & (1 << 20) != 0 {
            let value: UInt32
            if byte {
                value = UInt32(busReadByte(target))
            } else {
                let word = busReadWord(target & ~3)
                let rotate = (target & 3) << 3
                value = rotate == 0 ? word : word >> rotate | word << (32 - rotate)
            }
            if aborted { return dataAbort(at: address) }
            if writeback { setRegister(rn, indexed) }
            setRegister(rd, value)
            return rd == 15 ? 5 : 3
        }
        // A stored R15 is 12 on, with the PSR.
        let value = rd == 15 ? ((regs[15] &+ 4) & Self.pcMask) | psr : regs[rd]
        if byte {
            busWriteByte(target, UInt8(truncatingIfNeeded: value))
        } else {
            busWriteWord(target & ~3, value)
        }
        if aborted { return dataAbort(at: address) }
        if writeback { setRegister(rn, indexed) }
        return 2
    }

    @inline(__always)
    func setRegister(_ r: Int, _ value: UInt32) {
        if r == 15 {
            writePC(value)
        } else {
            regs[r] = value
        }
    }

    func dataAbort(at address: UInt32) -> Int {
        aborted = false
        exception(Self.dataAbortVector, .supervisor, link: address &+ 8, disableFIQ: false)
        return 3
    }

    // MARK: LDM/STM

    func blockTransfer(_ i: UInt32, at address: UInt32) -> Int {
        let rn = Int((i >> 16) & 15)
        let list = i & 0xFFFF
        let count = UInt32(list.nonzeroBitCount)
        let base = rn == 15 ? regs[15] | psr : regs[rn]
        let up = i & (1 << 23) != 0
        let pre = i & (1 << 24) != 0
        let sBit = i & (1 << 22) != 0
        let writeback = i & (1 << 21) != 0 && rn != 15
        let final = up ? base &+ count << 2 : base &- count << 2
        var next = up ? (pre ? base &+ 4 : base) : (pre ? final : final &+ 4)
        guard next & 0xFC00_0000 == 0 else {
            exception(Self.addressExceptionVector, .supervisor, link: address &+ 8, disableFIQ: false)
            return 3
        }
        var remaining = list
        if i & (1 << 20) != 0 {
            // LDM: the base is written back first, so a loaded base wins.
            if writeback { regs[rn] = final }
            let userBank = sBit && list & 0x8000 == 0
            while remaining != 0 {
                let r = remaining.trailingZeroBitCount
                remaining &= remaining - 1
                let value = busReadWord(next & ~3)
                next &+= 4
                if r == 15 {
                    if aborted { break }
                    writePC(value)
                    // With S, the PSR comes back too.
                    if sBit { writePSR(value) }
                } else {
                    regs[userBank ? userSlot(r) : r] = value
                }
            }
            if aborted { return dataAbort(at: address) }
            return Int(count) + (list & 0x8000 != 0 ? 4 : 2)
        }
        // STM: the base is written back after the first register's stored,
        // so a base that isn't first in the list is stored updated. With S,
        // the user bank's stored.
        var first = true
        while remaining != 0 {
            let r = remaining.trailingZeroBitCount
            remaining &= remaining - 1
            let value = r == 15 ? ((regs[15] &+ 4) & Self.pcMask) | psr : regs[sBit ? userSlot(r) : r]
            busWriteWord(next & ~3, value)
            next &+= 4
            if first {
                first = false
                if writeback { regs[rn] = final }
            }
        }
        if aborted { return dataAbort(at: address) }
        return Int(count) + 1
    }
}
