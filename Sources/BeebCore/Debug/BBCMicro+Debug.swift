// Memory and registers for the debugger: every address space by name, read
// and written without side effects.

/// Somewhere memory lives.
public enum MemorySpace: Hashable, Sendable, Codable, CustomStringConvertible {
    /// As the CPU sees it now (with the current paging; I/O is peeked).
    case cpu(DebugCPU)
    /// The 32K at &0000-&7FFF.
    case mainRAM
    /// Shadow RAM, at the addresses it shadows (&3000-&7FFF).
    case shadowRAM
    /// The Master's ANDY (4K at &8000) or the B+'s 12K at &8000.
    case andy
    /// The Master's HAZEL (8K at &C000).
    case hazel
    /// A sideways ROM or RAM bank, at &8000-&BFFF.
    case sidewaysBank(Int)
    /// The OS ROM, at &C000-&FFFF.
    case osROM
    /// The second processor's 64K.
    case parasiteRAM

    public var description: String {
        switch self {
        case .cpu(let cpu): cpu == .host ? "host" : "parasite"
        case .mainRAM: "main"
        case .shadowRAM: "shadow"
        case .andy: "andy"
        case .hazel: "hazel"
        case .sidewaysBank(let bank): "bank\(String(bank, radix: 16, uppercase: true))"
        case .osROM: "os"
        case .parasiteRAM: "parasite_ram"
        }
    }

    /// Parses `description`'s form (and "rom9" etc. for banks).
    public init?(name: String) {
        let lower = name.lowercased()
        switch lower {
        case "host", "cpu": self = .cpu(.host)
        case "parasite", "tube", "second_processor": self = .cpu(.parasite)
        case "main": self = .mainRAM
        case "shadow": self = .shadowRAM
        case "andy": self = .andy
        case "hazel": self = .hazel
        case "os", "mos": self = .osROM
        case "parasite_ram": self = .parasiteRAM
        default:
            for prefix in ["bank", "rom"] where lower.hasPrefix(prefix) {
                if let bank = Int(lower.dropFirst(prefix.count), radix: 16), (0..<16).contains(bank) {
                    self = .sidewaysBank(bank)
                    return
                }
            }
            return nil
        }
    }
}

public struct MemoryRegion: Sendable, Equatable {
    public var space: MemorySpace
    public var name: String
    /// The CPU address of the region's first byte.
    public var base: Int
    public var size: Int
    public var isROM: Bool
}

extension BBCMicro {
    /// The debugger, created on first use.
    public var debugger: Debugger {
        if let existing = debuggerIfCreated {
            return existing
        }
        let created = Debugger(machine: self)
        debuggerIfCreated = created
        return created
    }

    public func debugCPU(_ which: DebugCPU) -> M6502? {
        which == .host ? cpu : secondProcessor?.cpu
    }

    /// The address of the instruction `which` is executing, or about to.
    public func instructionAddress(_ which: DebugCPU) -> UInt16 {
        guard let c = debugCPU(which) else { return 0 }
        return c.isAboutToExecute ? c.abus : c.opcodePC
    }

    /// The memory regions this machine has.
    public var memoryRegions: [MemoryRegion] {
        var regions = [
            MemoryRegion(space: .cpu(.host), name: "Host CPU's view", base: 0, size: 0x10000, isROM: false),
            MemoryRegion(space: .mainRAM, name: "Main RAM", base: 0, size: 0x8000, isROM: false),
        ]
        if model != .modelB {
            regions.append(MemoryRegion(space: .shadowRAM, name: "Shadow RAM", base: 0x3000, size: 0x5000, isROM: false))
            regions.append(MemoryRegion(space: .andy, name: model == .bPlus ? "Paged RAM (12K)" : "ANDY",
                                        base: 0x8000, size: model == .bPlus ? 0x3000 : 0x1000, isROM: false))
        }
        if model == .master128 {
            regions.append(MemoryRegion(space: .hazel, name: "HAZEL", base: 0xC000, size: 0x2000, isROM: false))
        }
        for bank in 0..<16 where sidewaysBanks[bank] != nil {
            let ram = sidewaysRAMBanks.contains(bank)
            regions.append(MemoryRegion(space: .sidewaysBank(bank),
                                        name: "Sideways \(ram ? "RAM" : "ROM") \(String(bank, radix: 16, uppercase: true))",
                                        base: 0x8000, size: 0x4000, isROM: !ram))
        }
        regions.append(MemoryRegion(space: .osROM, name: "OS ROM", base: 0xC000, size: 0x4000, isROM: true))
        if secondProcessor != nil {
            regions.append(MemoryRegion(space: .cpu(.parasite), name: "Second processor's view", base: 0, size: 0x10000, isROM: false))
            regions.append(MemoryRegion(space: .parasiteRAM, name: "Second processor RAM", base: 0, size: 0x10000, isROM: false))
        }
        return regions
    }

    /// The storage behind a physical space's CPU address, if it exists.
    private func storage(_ space: MemorySpace, _ address: Int) -> UnsafeMutablePointer<UInt8>? {
        switch space {
        case .cpu:
            return nil
        case .mainRAM:
            return (0..<0x8000).contains(address) ? ram + address : nil
        case .shadowRAM:
            return model != .modelB && (0x3000..<0x8000).contains(address) ? ram + Self.shadowOffset + address : nil
        case .andy:
            let size = model == .bPlus ? 0x3000 : model == .master128 ? 0x1000 : 0
            return (0x8000..<0x8000 + size).contains(address) ? ram + Self.andyOffset + address - 0x8000 : nil
        case .hazel:
            return model == .master128 && (0xC000..<0xE000).contains(address) ? ram + Self.hazelOffset + address - 0xC000 : nil
        case .sidewaysBank(let bank):
            guard (0..<16).contains(bank), (0x8000..<0xC000).contains(address) else { return nil }
            return sidewaysBanks[bank].map { $0 + address - 0x8000 }
        case .osROM:
            return (0xC000..<0x10000).contains(address) ? osROM + address - 0xC000 : nil
        case .parasiteRAM:
            guard let p = secondProcessor, (0..<0x10000).contains(address) else { return nil }
            return p.ram + address
        }
    }

    /// Reads memory without side effects; nil if the space or address
    /// doesn't exist (or, for a CPU's view, nothing answers there).
    public func debugRead(_ space: MemorySpace, _ address: Int) -> UInt8? {
        switch space {
        case .cpu(.host):
            guard (0..<0x10000).contains(address) else { return nil }
            let a = UInt16(address)
            if a >= 0xFC00 && a < 0xFF00 {
                return peekIO(a)
            }
            return readPages[pageTable + address >> 12]?[address & 0xFFF]
        case .cpu(.parasite):
            guard let p = secondProcessor, (0..<0x10000).contains(address) else { return nil }
            let a = UInt16(address)
            return a & 0xFFF0 == 0xFEF0 ? tube.parasitePeek(Int(a)) : p.peek(a)
        default:
            return storage(space, address)?.pointee
        }
    }

    /// Writes memory, ROM included, without side effects; I/O isn't
    /// written. Returns false if there's nothing there.
    @discardableResult
    public func debugWrite(_ space: MemorySpace, _ address: Int, _ value: UInt8) -> Bool {
        switch space {
        case .cpu(.host):
            guard (0..<0x10000).contains(address), address < 0xFC00 || address >= 0xFF00,
                  let page = readPages[pageTable + address >> 12] else { return false }
            page[address & 0xFFF] = value
            return true
        case .cpu(.parasite):
            guard let p = secondProcessor, (0..<0x10000).contains(address), address & 0xFFF0 != 0xFEF0 else { return false }
            if p.bootMode && address >= 0xF000 { return false }
            p.ram[address] = value
            return true
        default:
            guard let pointer = storage(space, address) else { return false }
            pointer.pointee = value
            return true
        }
    }

    // MARK: Registers

    /// A register or flag: A X Y S P PC, C Z I D V N, or CYCLES.
    public func register(_ name: String, cpu which: DebugCPU) -> Int? {
        guard let c = debugCPU(which) else { return nil }
        switch name.uppercased() {
        case "A": return Int(c.a)
        case "X": return Int(c.x)
        case "Y": return Int(c.y)
        case "S", "SP": return Int(c.s)
        case "P": return Int(c.p)
        case "PC": return Int(instructionAddress(which))
        case "C": return c.c ? 1 : 0
        case "Z": return c.z ? 1 : 0
        case "I": return c.i ? 1 : 0
        case "D": return c.d ? 1 : 0
        case "V": return c.v ? 1 : 0
        case "N": return c.n ? 1 : 0
        case "CYCLES": return Int(cycles)
        default: return nil
        }
    }

    public enum RegisterError: Error, CustomStringConvertible {
        case unknown(String)
        case notAtInstruction
        case noSuchCPU

        public var description: String {
            switch self {
            case .unknown(let name): "unknown register \(name)"
            case .notAtInstruction: "PC can only be set between instructions"
            case .noSuchCPU: "there's no second processor"
            }
        }
    }

    /// Sets a register or flag. PC can only be changed between
    /// instructions (the new instruction's opcode is fetched now).
    public func setRegister(_ name: String, cpu which: DebugCPU, to value: Int) throws(RegisterError) {
        guard let c = debugCPU(which) else { throw .noSuchCPU }
        let byte = UInt8(truncatingIfNeeded: value)
        switch name.uppercased() {
        case "A": c.a = byte
        case "X": c.x = byte
        case "Y": c.y = byte
        case "S", "SP": c.s = byte
        case "P":
            c.n = byte & 0x80 != 0
            c.v = byte & 0x40 != 0
            c.d = byte & 0x08 != 0
            c.i = byte & 0x04 != 0
            c.z = byte & 0x02 != 0
            c.c = byte & 0x01 != 0
        case "C": c.c = value != 0
        case "Z": c.z = value != 0
        case "I": c.i = value != 0
        case "D": c.d = value != 0
        case "V": c.v = value != 0
        case "N": c.n = value != 0
        case "PC":
            guard c.isAboutToExecute else { throw .notAtInstruction }
            c.jump(to: UInt16(truncatingIfNeeded: value))
            // The fetch already happened this cycle: do it again.
            c.dbus = debugRead(.cpu(which), Int(c.abus)) ?? 0xFF
        default:
            throw .unknown(name)
        }
    }

    /// The disassembler for a CPU.
    public func disassembler(_ which: DebugCPU) -> M6502Disassembler {
        M6502Disassembler(variant: debugCPU(which)?.variant ?? .nmos)
    }

    /// Whether the debugger has stopped the machine.
    public var isStoppedByDebugger: Bool {
        debuggerIfCreated?.stopReason != nil
    }
}
