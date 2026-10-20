// Hand-written per-cycle sequences that don't fit the generator's model.
//
// A port of b2's 6502.c (Copyright (C) Tom Seddon, GPLv3). Each case runs
// phase 2 of one cycle and phase 1 of the next.

extension M6502 {
    @inline(__always)
    private func setADH() {
        ad = (ad & 0x00FF) | UInt16(dbus) << 8
    }

    @inline(__always)
    private func setADL() {
        ad = (ad & 0xFF00) | UInt16(dbus)
    }

    /// True if adding `index` to `ad` crosses a page.
    @inline(__always)
    private func pageCrossed(_ index: UInt8) -> Bool {
        (ad &+ UInt16(index)) & 0xFF00 != ad & 0xFF00
    }

    func tickSpecial() {
        switch state {
        // MARK: Branches

        case .Branch_0:
            checkForInterrupts()
            abus = pc
            pc &+= 1
            access = .instruction
            state = .Branch_1

        case .Branch_1:
            setADL()
            execute(op)
            if data == 0 {
                // Not taken.
                nextInstruction()
                return
            }
            ad = pc &+ UInt16(bitPattern: Int16(Int8(bitPattern: UInt8(truncatingIfNeeded: ad))))
            abus = pc
            access = .instruction
            state = .Branch_2

        case .Branch_2:
            if ad & 0xFF00 == pc & 0xFF00 {
                // Taken, same page. Interrupts aren't checked, so an IRQ
                // arriving now waits for one more instruction.
                pc = ad
                nextInstruction()
                return
            }
            abus = (pc & 0xFF00) | (ad & 0x00FF)
            access = .instruction
            state = .Branch_3
            // Penultimate cycle of a page-crossing branch. (b2 checks in
            // Branch_3, a cycle late; perfect6502 agrees with this.)
            checkForInterrupts()

        case .Branch_3:
            pc = ad
            nextInstruction()

        // MARK: BBR/BBS (Rockwell)

        case .Branch_ZPG_REL_ROCKWELL_0:
            abus = pc
            pc &+= 1
            access = .instruction
            state = .Branch_ZPG_REL_ROCKWELL_1

        case .Branch_ZPG_REL_ROCKWELL_1:
            abus = UInt16(dbus)
            ia = UInt16(dbus)
            access = .data
            state = .Branch_ZPG_REL_ROCKWELL_2

        case .Branch_ZPG_REL_ROCKWELL_2:
            data = dbus
            access = .dummy
            state = .Branch_ZPG_REL_ROCKWELL_3

        case .Branch_ZPG_REL_ROCKWELL_3:
            abus = pc
            pc &+= 1
            access = .instruction
            state = .Branch_1

        // MARK: CMOS indexed reads

        case .R_ABX_CMOS_0, .R_ABY_CMOS_0:
            abus = pc
            pc &+= 1
            access = .instruction
            state = state == .R_ABX_CMOS_0 ? .R_ABX_CMOS_1 : .R_ABY_CMOS_1

        case .R_ABX_CMOS_1, .R_ABY_CMOS_1:
            setADL()
            abus = pc
            pc &+= 1
            access = .instruction
            state = state == .R_ABX_CMOS_1 ? .R_ABX_CMOS_2 : .R_ABY_CMOS_2

        case .R_ABX_CMOS_2, .R_ABY_CMOS_2:
            setADH()
            let isX = state == .R_ABX_CMOS_2
            let index = isX ? x : y
            if pageCrossed(index) {
                // Dummy read of the last operand byte.
                access = .dummy
                state = isX ? .R_ABX_CMOS_3_AC1 : .R_ABY_CMOS_3_AC1
            } else {
                abus = ad &+ UInt16(index)
                access = .data
                state = isX ? .R_ABX_CMOS_3_AC0 : .R_ABY_CMOS_3_AC0
                checkForInterrupts()
            }

        case .R_ABX_CMOS_3_AC0, .R_ABY_CMOS_3_AC0, .R_ABX_CMOS_4_AC1, .R_ABY_CMOS_4_AC1:
            data = dbus
            execute(op)
            nextInstruction()

        case .R_ABX_CMOS_3_AC1, .R_ABY_CMOS_3_AC1:
            let isX = state == .R_ABX_CMOS_3_AC1
            abus = ad &+ UInt16(isX ? x : y)
            access = .data
            state = isX ? .R_ABX_CMOS_4_AC1 : .R_ABY_CMOS_4_AC1
            checkForInterrupts()

        // MARK: CMOS INC/DEC abs,X (always 7 cycles)

        case .RMW_ABX_CMOS_0:
            abus = pc
            pc &+= 1
            access = .instruction
            state = .RMW_ABX_CMOS_1

        case .RMW_ABX_CMOS_1:
            setADL()
            abus = pc
            pc &+= 1
            access = .instruction
            state = .RMW_ABX_CMOS_2

        case .RMW_ABX_CMOS_2:
            setADH()
            if !pageCrossed(x) {
                abus = ad &+ UInt16(x)
            }
            access = .dummy
            state = .RMW_ABX_CMOS_3

        case .RMW_ABX_CMOS_3:
            abus = ad &+ UInt16(x)
            access = .dummy
            state = .RMW_ABX_CMOS_4

        case .RMW_ABX_CMOS_4:
            access = .data
            state = .RMW_ABX_CMOS_5

        case .RMW_ABX_CMOS_5:
            data = dbus
            execute(op)
            dbus = data
            access = .write
            state = .RMW_ABX_CMOS_6
            checkForInterrupts()

        case .RMW_ABX_CMOS_6:
            nextInstruction()

        // MARK: CMOS shifts abs,X (1 cycle shorter without a page crossing)

        case .RMW_ABX2_CMOS_0:
            abus = pc
            pc &+= 1
            access = .instruction
            state = .RMW_ABX2_CMOS_1

        case .RMW_ABX2_CMOS_1:
            setADL()
            abus = pc
            pc &+= 1
            access = .instruction
            state = .RMW_ABX2_CMOS_2

        case .RMW_ABX2_CMOS_2:
            setADH()
            access = .dummy
            if !pageCrossed(x) {
                abus = ad &+ UInt16(x)
                state = .RMW_ABX2_CMOS_3_AC0
            } else {
                state = .RMW_ABX2_CMOS_3_AC1
            }

        case .RMW_ABX2_CMOS_3_AC0:
            access = .data
            state = .RMW_ABX2_CMOS_4_AC0

        case .RMW_ABX2_CMOS_4_AC0:
            data = dbus
            execute(op)
            checkForInterrupts()
            dbus = data
            access = .write
            state = .RMW_ABX2_CMOS_5_AC0

        case .RMW_ABX2_CMOS_5_AC0, .RMW_ABX2_CMOS_6_AC1:
            nextInstruction()

        case .RMW_ABX2_CMOS_3_AC1:
            abus = ad &+ UInt16(x)
            access = .dummy
            state = .RMW_ABX2_CMOS_4_AC1

        case .RMW_ABX2_CMOS_4_AC1:
            access = .data
            state = .RMW_ABX2_CMOS_5_AC1

        case .RMW_ABX2_CMOS_5_AC1:
            data = dbus
            execute(op)
            dbus = data
            access = .write
            state = .RMW_ABX2_CMOS_6_AC1
            checkForInterrupts()

        // MARK: CMOS indexed writes

        case .W_ABX_CMOS_0, .W_ABY_CMOS_0:
            abus = pc
            pc &+= 1
            access = .instruction
            state = state == .W_ABX_CMOS_0 ? .W_ABX_CMOS_1 : .W_ABY_CMOS_1

        case .W_ABX_CMOS_1, .W_ABY_CMOS_1:
            setADL()
            abus = pc
            pc &+= 1
            access = .instruction
            state = state == .W_ABX_CMOS_1 ? .W_ABX_CMOS_2 : .W_ABY_CMOS_2

        case .W_ABX_CMOS_2, .W_ABY_CMOS_2:
            setADH()
            let isX = state == .W_ABX_CMOS_2
            let index = isX ? x : y
            if !pageCrossed(index) {
                abus = ad &+ UInt16(index)
            }
            access = .dummy
            state = isX ? .W_ABX_CMOS_3 : .W_ABY_CMOS_3

        case .W_ABX_CMOS_3, .W_ABY_CMOS_3:
            execute(op)
            let isX = state == .W_ABX_CMOS_3
            abus = ad &+ UInt16(isX ? x : y)
            dbus = data
            access = .write
            state = isX ? .W_ABX_CMOS_4 : .W_ABY_CMOS_4
            checkForInterrupts()

        case .W_ABX_CMOS_4, .W_ABY_CMOS_4:
            nextInstruction()

        // MARK: CMOS ADC/SBC abs,X / abs,Y (extra cycle in decimal mode)

        case .R_ABX_BCD_CMOS_0, .R_ABY_BCD_CMOS_0:
            abus = pc
            pc &+= 1
            access = .instruction
            state = state == .R_ABX_BCD_CMOS_0 ? .R_ABX_BCD_CMOS_1 : .R_ABY_BCD_CMOS_1

        case .R_ABX_BCD_CMOS_1, .R_ABY_BCD_CMOS_1:
            setADL()
            abus = pc
            pc &+= 1
            access = .instruction
            if state == .R_ABX_BCD_CMOS_1 {
                state = d ? .R_ABX_BCD_CMOS_2_D1 : .R_ABX_BCD_CMOS_2_D0
            } else {
                state = d ? .R_ABY_BCD_CMOS_2_D1 : .R_ABY_BCD_CMOS_2_D0
            }

        // Binary mode.
        case .R_ABX_BCD_CMOS_2_D0, .R_ABY_BCD_CMOS_2_D0:
            setADH()
            let isX = state == .R_ABX_BCD_CMOS_2_D0
            let index = isX ? x : y
            if pageCrossed(index) {
                access = .dummy
                state = isX ? .R_ABX_BCD_CMOS_3_D0_AC1 : .R_ABY_BCD_CMOS_3_D0_AC1
            } else {
                // No carry - penultimate cycle.
                checkForInterrupts()
                abus = ad &+ UInt16(index)
                access = .data
                state = isX ? .R_ABX_BCD_CMOS_3_D0_AC0 : .R_ABY_BCD_CMOS_3_D0_AC0
            }

        case .R_ABX_BCD_CMOS_3_D0_AC1, .R_ABY_BCD_CMOS_3_D0_AC1:
            let isX = state == .R_ABX_BCD_CMOS_3_D0_AC1
            abus = ad &+ UInt16(isX ? x : y)
            access = .data
            state = isX ? .R_ABX_BCD_CMOS_4_D0_AC1 : .R_ABY_BCD_CMOS_4_D0_AC1
            checkForInterrupts()

        case .R_ABX_BCD_CMOS_3_D0_AC0, .R_ABY_BCD_CMOS_3_D0_AC0,
             .R_ABX_BCD_CMOS_4_D0_AC1, .R_ABY_BCD_CMOS_4_D0_AC1:
            data = dbus
            execute(op)
            nextInstruction()

        // Decimal mode.
        case .R_ABX_BCD_CMOS_2_D1, .R_ABY_BCD_CMOS_2_D1:
            setADH()
            let isX = state == .R_ABX_BCD_CMOS_2_D1
            let index = isX ? x : y
            if pageCrossed(index) {
                access = .dummy
                state = isX ? .R_ABX_BCD_CMOS_3_D1_AC1 : .R_ABY_BCD_CMOS_3_D1_AC1
            } else {
                abus = ad &+ UInt16(index)
                access = .data
                state = isX ? .R_ABX_BCD_CMOS_3_D1_AC0 : .R_ABY_BCD_CMOS_3_D1_AC0
            }

        case .R_ABX_BCD_CMOS_3_D1_AC1, .R_ABY_BCD_CMOS_3_D1_AC1:
            let isX = state == .R_ABX_BCD_CMOS_3_D1_AC1
            abus = ad &+ UInt16(isX ? x : y)
            checkForInterrupts()
            access = .data
            state = isX ? .R_ABX_BCD_CMOS_4_D1_AC1 : .R_ABY_BCD_CMOS_4_D1_AC1

        case .R_ABX_BCD_CMOS_3_D1_AC0, .R_ABY_BCD_CMOS_3_D1_AC0:
            data = dbus
            // Dummy read of the next opcode.
            abus = pc
            access = .dummy
            checkForInterrupts()
            state = state == .R_ABX_BCD_CMOS_3_D1_AC0 ? .R_ABX_BCD_CMOS_4_D1_AC0 : .R_ABY_BCD_CMOS_4_D1_AC0

        case .R_ABX_BCD_CMOS_4_D1_AC1, .R_ABY_BCD_CMOS_4_D1_AC1:
            data = dbus
            abus = pc
            access = .dummy
            checkForInterrupts()
            state = state == .R_ABX_BCD_CMOS_4_D1_AC1 ? .R_ABX_BCD_CMOS_5_D1_AC1 : .R_ABY_BCD_CMOS_5_D1_AC1

        case .R_ABX_BCD_CMOS_4_D1_AC0, .R_ABY_BCD_CMOS_4_D1_AC0,
             .R_ABX_BCD_CMOS_5_D1_AC1, .R_ABY_BCD_CMOS_5_D1_AC1:
            execute(op)
            nextInstruction()

        // MARK: CMOS (zp),Y reads

        case .R_INY_CMOS_0:
            abus = pc
            pc &+= 1
            access = .instruction
            state = .R_INY_CMOS_1

        case .R_INY_CMOS_1:
            ia = UInt16(dbus)
            abus = ia
            access = .address
            state = .R_INY_CMOS_2

        case .R_INY_CMOS_2:
            setADL()
            abus = (ia &+ 1) & 0xFF
            access = .address
            state = .R_INY_CMOS_3

        case .R_INY_CMOS_3:
            setADH()
            if pageCrossed(y) {
                access = .dummy
                state = .R_INY_CMOS_4_AC1
            } else {
                checkForInterrupts()
                abus = ad &+ UInt16(y)
                access = .data
                state = .R_INY_CMOS_4_AC0
            }

        case .R_INY_CMOS_4_AC0, .R_INY_CMOS_5_AC1:
            data = dbus
            execute(op)
            nextInstruction()

        case .R_INY_CMOS_4_AC1:
            abus = ad &+ UInt16(y)
            checkForInterrupts()
            access = .data
            state = .R_INY_CMOS_5_AC1

        // MARK: CMOS ADC/SBC (zp),Y

        case .R_INY_BCD_CMOS_0:
            abus = pc
            pc &+= 1
            access = .instruction
            state = .R_INY_BCD_CMOS_1

        case .R_INY_BCD_CMOS_1:
            ia = UInt16(dbus)
            abus = ia
            access = .address
            state = .R_INY_BCD_CMOS_2

        case .R_INY_BCD_CMOS_2:
            setADL()
            abus = (ia &+ 1) & 0xFF
            access = .address
            state = d ? .R_INY_BCD_CMOS_3_D1 : .R_INY_BCD_CMOS_3_D0

        // Binary mode.
        case .R_INY_BCD_CMOS_3_D0:
            setADH()
            if pageCrossed(y) {
                access = .dummy
                state = .R_INY_BCD_CMOS_4_D0_AC1
            } else {
                checkForInterrupts()
                abus = ad &+ UInt16(y)
                access = .data
                state = .R_INY_BCD_CMOS_4_D0_AC0
            }

        case .R_INY_BCD_CMOS_4_D0_AC0, .R_INY_BCD_CMOS_5_D0_AC1:
            data = dbus
            execute(op)
            nextInstruction()

        case .R_INY_BCD_CMOS_4_D0_AC1:
            abus = ad &+ UInt16(y)
            checkForInterrupts()
            access = .data
            state = .R_INY_BCD_CMOS_5_D0_AC1

        // Decimal mode.
        case .R_INY_BCD_CMOS_3_D1:
            setADH()
            if pageCrossed(y) {
                access = .dummy
                state = .R_INY_BCD_CMOS_4_D1_AC1
            } else {
                abus = ad &+ UInt16(y)
                access = .data
                state = .R_INY_BCD_CMOS_4_D1_AC0
            }

        case .R_INY_BCD_CMOS_4_D1_AC0:
            data = dbus
            abus = pc
            access = .dummy
            checkForInterrupts()
            state = .R_INY_BCD_CMOS_5_D1_AC0

        case .R_INY_BCD_CMOS_5_D1_AC0, .R_INY_BCD_CMOS_6_D1_AC1:
            execute(op)
            nextInstruction()

        case .R_INY_BCD_CMOS_4_D1_AC1:
            abus = ad &+ UInt16(y)
            access = .data
            state = .R_INY_BCD_CMOS_5_D1_AC1

        case .R_INY_BCD_CMOS_5_D1_AC1:
            data = dbus
            abus = pc
            access = .dummy
            checkForInterrupts()
            state = .R_INY_BCD_CMOS_6_D1_AC1

        // MARK: CMOS (zp),Y writes

        case .W_INY_CMOS_0:
            abus = pc
            pc &+= 1
            access = .instruction
            state = .W_INY_CMOS_1

        case .W_INY_CMOS_1:
            ia = UInt16(dbus)
            abus = ia
            access = .address
            state = .W_INY_CMOS_2

        case .W_INY_CMOS_2:
            setADL()
            abus = (ia &+ 1) & 0xFF
            access = .address
            state = .W_INY_CMOS_3

        case .W_INY_CMOS_3:
            setADH()
            access = .dummy
            state = .W_INY_CMOS_4

        case .W_INY_CMOS_4:
            abus = ad &+ UInt16(y)
            execute(op)
            dbus = data
            access = .write
            state = .W_INY_CMOS_5
            checkForInterrupts()

        case .W_INY_CMOS_5:
            nextInstruction()

        // MARK: NMOS SHA/SHX/SHY/SHS
        //
        // When the index crosses a page, the high byte of the address is
        // replaced by the value written. (Makes the dp111 timing test pass.)

        case .W_INY_BROKEN_NMOS_0:
            abus = pc
            pc &+= 1
            access = .instruction
            state = .W_INY_BROKEN_NMOS_1

        case .W_INY_BROKEN_NMOS_1:
            ia = UInt16(dbus)
            abus = ia
            access = .address
            state = .W_INY_BROKEN_NMOS_2

        case .W_INY_BROKEN_NMOS_2:
            setADL()
            abus = (abus & 0xFF00) | ((ia &+ 1) & 0xFF)
            state = .W_INY_BROKEN_NMOS_3

        case .W_INY_BROKEN_NMOS_3:
            setADH()
            abus = (ad & 0xFF00) | ((ad &+ UInt16(y)) & 0xFF)
            access = .dummy
            state = .W_INY_BROKEN_NMOS_4

        case .W_INY_BROKEN_NMOS_4:
            brokenWrite(y)
            state = .W_INY_BROKEN_NMOS_5
            checkForInterrupts()

        case .W_INY_BROKEN_NMOS_5:
            nextInstruction()

        case .W_ABX_BROKEN_NMOS_0, .W_ABY_BROKEN_NMOS_0:
            abus = pc
            pc &+= 1
            access = .instruction
            state = state == .W_ABX_BROKEN_NMOS_0 ? .W_ABX_BROKEN_NMOS_1 : .W_ABY_BROKEN_NMOS_1

        case .W_ABX_BROKEN_NMOS_1, .W_ABY_BROKEN_NMOS_1:
            setADL()
            abus = pc
            pc &+= 1
            state = state == .W_ABX_BROKEN_NMOS_1 ? .W_ABX_BROKEN_NMOS_2 : .W_ABY_BROKEN_NMOS_2

        case .W_ABX_BROKEN_NMOS_2, .W_ABY_BROKEN_NMOS_2:
            setADH()
            let isX = state == .W_ABX_BROKEN_NMOS_2
            abus = (ad & 0xFF00) | ((ad &+ UInt16(isX ? x : y)) & 0xFF)
            access = .dummy
            state = isX ? .W_ABX_BROKEN_NMOS_3 : .W_ABY_BROKEN_NMOS_3

        case .W_ABX_BROKEN_NMOS_3, .W_ABY_BROKEN_NMOS_3:
            let isX = state == .W_ABX_BROKEN_NMOS_3
            brokenWrite(isX ? x : y)
            state = isX ? .W_ABX_BROKEN_NMOS_4 : .W_ABY_BROKEN_NMOS_4
            checkForInterrupts()

        case .W_ABX_BROKEN_NMOS_4, .W_ABY_BROKEN_NMOS_4:
            nextInstruction()

        // MARK: HLT/KIL
        //
        // After the operand fetch the address bus goes $FFFF, $FFFE, $FFFE,
        // then stays at $FFFF; interrupts are ignored. (From perfect6502;
        // b2 guesses $FFFF throughout.)

        case .HLT_0:
            abus = pc
            pc &+= 1
            access = .instruction
            state = .HLT_1

        case .HLT_1:
            abus = 0xFFFF
            access = .dummy
            state = .HLT_2

        case .HLT_2:
            abus = 0xFFFE
            access = .dummy
            state = .HLT_3

        case .HLT_3:
            state = .HLT_4

        case .HLT_4:
            abus = 0xFFFF
            access = .dummy

        // MARK: NMOS BRK/IRQ/NMI
        //
        // BRK and interrupts share a sequence. d1x1 is high for BRK; the
        // vector is chosen in T4, so an NMI arriving during BRK or IRQ
        // hijacks it.

        case .Interrupt_0:
            abus = pc
            access = .instruction
            state = .Interrupt_1
            if d1x1 {
                // BRK.
                pc &+= 1
            }

        case .Interrupt_1:
            data = dbus
            push(UInt8(truncatingIfNeeded: pc >> 8))
            state = .Interrupt_2

        case .Interrupt_2:
            push(UInt8(truncatingIfNeeded: pc))
            state = .Interrupt_3

        case .Interrupt_3:
            push(p)
            state = .Interrupt_4
            // The vector is chosen here, so an NMI must arrive at least a
            // cycle before the vector fetch to hijack a BRK or IRQ. (b2
            // chooses a cycle later; perfect6502 agrees with this.)
            if nmiFlags != 0 {
                nmiVector = true
            } else {
                // BRK/IRQ. (With d1x1 low but no obvious source, the CPU
                // still does an IRQ.)
                nmiVector = false
                if d1x1 || irqFlags != 0 {
                    irqFlags = deviceIRQFlags
                }
            }

        case .Interrupt_4:
            abus = nmiVector ? 0xFFFA : 0xFFFE
            i = true
            access = .address
            state = .Interrupt_5
            d1x1 = true

        case .Interrupt_5, .InterruptCMOS_5:
            if state == .Interrupt_5 && nmiFlags != 0 {
                // An NMI edge during the vector fetch (V or V+1) is absorbed
                // by an NMI sequence. In a BRK/IRQ sequence it survives only
                // if NMI is still asserted at V+2. (From perfect6502.)
                nmiFlags = 0
                nmiRecheck = !nmiVector
            }
            pc = (pc & 0xFF00) | UInt16(dbus)
            abus &+= 1
            access = .address
            state = state == .Interrupt_5 ? .Interrupt_6 : .InterruptCMOS_6

        case .Interrupt_6, .InterruptCMOS_6, .BRK_CMOS_6:
            if nmiRecheck {
                nmiRecheck = false
                nmiFlags |= deviceNMIFlags
            }
            pc = (pc & 0x00FF) | UInt16(dbus) << 8
            nextInstruction()

        // MARK: CMOS IRQ/NMI
        //
        // The interrupt type is decided straight away, so one can't turn into
        // another. CMOS BRK is separate.

        case .InterruptCMOS_0:
            if nmiFlags != 0 {
                data = 1
                nmiFlags = 0
            } else if irqFlags != 0 {
                data = 0
                irqFlags = deviceIRQFlags
            } else {
                data = 1
            }
            d1x1 = true
            abus = pc
            access = .instruction
            state = .InterruptCMOS_1

        case .InterruptCMOS_1:
            push(UInt8(truncatingIfNeeded: pc >> 8))
            state = .InterruptCMOS_2

        case .InterruptCMOS_2:
            push(UInt8(truncatingIfNeeded: pc))
            state = .InterruptCMOS_3

        case .InterruptCMOS_3:
            push(p & ~0x10)
            state = .InterruptCMOS_4

        case .InterruptCMOS_4:
            abus = data != 0 ? 0xFFFA : 0xFFFE
            i = true
            d = false
            access = .address
            state = .InterruptCMOS_5

        // MARK: CMOS BRK

        case .BRK_CMOS_0:
            abus = pc
            pc &+= 1
            access = .instruction
            state = .BRK_CMOS_1

        case .BRK_CMOS_1:
            data = dbus
            push(UInt8(truncatingIfNeeded: pc >> 8))
            state = .BRK_CMOS_2

        case .BRK_CMOS_2:
            push(UInt8(truncatingIfNeeded: pc))
            state = .BRK_CMOS_3

        case .BRK_CMOS_3:
            push(p | 0x10)
            state = .BRK_CMOS_4

        case .BRK_CMOS_4:
            i = true
            d = false
            abus = 0xFFFE
            access = .instruction
            state = .BRK_CMOS_5

        case .BRK_CMOS_5:
            pc = (pc & 0xFF00) | UInt16(dbus)
            abus &+= 1
            access = .instruction
            state = .BRK_CMOS_6

        default:
            preconditionFailure("M6502: no handler for state \(state)")
        }
    }

    /// Phase 1 of a stack push.
    @inline(__always)
    private func push(_ value: UInt8) {
        abus = 0x100 | UInt16(s)
        s &-= 1
        dbus = value
        access = .write
    }

    /// The final write of an NMOS SHx instruction.
    @inline(__always)
    private func brokenWrite(_ index: UInt8) {
        execute(op)
        let target = ad &+ UInt16(index)
        if target & 0xFF00 == ad & 0xFF00 {
            abus = target
        } else {
            abus = UInt16(data) << 8 | (target & 0xFF)
        }
        dbus = data
        access = .write
    }
}
