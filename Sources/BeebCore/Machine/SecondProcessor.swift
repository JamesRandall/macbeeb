// The 6502 Second Processor: a 3MHz 65C02 with 64K of RAM, talking to the
// host through the Tube. Also the Master Turbo's 65C102 Co-Processor, the
// same at 4MHz on the Master's internal Tube (as b2 has it).
//
// Follows b2's parasite handling in BBCMicro_Update.inl (Copyright (C) Tom
// Seddon, GPLv3). At power on and reset it's in boot mode, where reads of
// &F000-&FFFF come from the Tube OS ROM (writes still go to RAM), until it
// first touches the Tube's registers at &FEF0-&FEF7.

public final class SecondProcessor {
    public enum IRQDevice {
        public static let tube: UInt8 = 1 << 0
    }

    public enum NMIDevice {
        public static let tube: UInt8 = 1 << 0
    }

    public let cpu = M6502(variant: .rockwell)
    let ram: UnsafeMutablePointer<UInt8>
    /// 4K; the 2K ROM sits at the top (&F800-&FFFF), as in b2.
    let rom: [UInt8]
    public internal(set) var bootMode = true
    /// Set while the debugger wants to see every access.
    unowned(unsafe) var debugger: Debugger?

    init(rom romImage: [UInt8]) {
        precondition(romImage.count <= 4096, "second processor ROM too big")
        rom = [UInt8](repeating: 0, count: 4096 - romImage.count) + romImage
        ram = .allocate(capacity: 0x10000)
        ram.initialize(repeating: 0, count: 0x10000)
        cpu.reset()
    }

    deinit {
        ram.deallocate()
    }

    /// Reads parasite memory as the CPU would, without side effects (the
    /// Tube's registers aren't included).
    public func peek(_ address: UInt16) -> UInt8 {
        bootMode && address >= 0xF000 ? rom[Int(address & 0xFFF)] : ram[Int(address)]
    }

    public func poke(_ address: UInt16, _ value: UInt8) {
        ram[Int(address)] = value
    }

    /// Resets the CPU into boot mode.
    func reset() {
        cpu.reset()
        bootMode = true
    }

    /// Runs one parasite cycle.
    @inline(__always)
    func step(tube: inout Tube) {
        cpu.tick()
        if tube.tubeResetRequested {
            tube.reset()
        }
        if tube.parasiteResetRequested {
            reset()
        }
        cpu.setIRQ(IRQDevice.tube, tube.parasiteIRQ)
        cpu.setNMI(NMIDevice.tube, tube.parasiteNMI)

        let address = cpu.abus
        if address & 0xFFF0 == 0xFEF0 {
            if cpu.access == .write {
                tube.parasiteWrite(Int(address), cpu.dbus)
            } else {
                cpu.dbus = tube.parasiteRead(Int(address))
            }
            bootMode = false
        } else if cpu.access == .write {
            ram[Int(address)] = cpu.dbus
        } else if bootMode && address >= 0xF000 {
            cpu.dbus = rom[Int(address & 0xFFF)]
        } else {
            cpu.dbus = ram[Int(address)]
        }
        debugger?.parasiteAccessed(address, cpu.access)
    }
}
