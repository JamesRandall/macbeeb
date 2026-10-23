import BeebCore
import BeebHost
import BeebROMs
import Foundation

/// The machine's hardware: what's fitted, the sideways banks, and loading
/// sideways RAM.
extension AgentTools {
    /// Agents' names for the memory boards.
    static let agentBoards: [String: BBCMicro.MemoryBoard] = [
        "none": .none, "sideways_ram_16": .sidewaysRAM16, "sideways_ram_32": .sidewaysRAM32, "watford_32k": .watford32K,
        "aries_b32": .ariesB32, "aries_b32_b12": .ariesB32B12,
    ]

    static func agentName(_ board: BBCMicro.MemoryBoard) -> String {
        agentBoards.first { $0.value == board }!.key
    }

    /// The sideways banks as a table.
    static func bankTable(_ m: BBCMicro) -> String {
        m.sidewaysSlots.filter { $0.kind != .empty || $0.owner != "Not fitted" }.map { slot in
            var line = String(format: "%2d  ", slot.bank)
            line += slot.kind == .empty ? "empty socket" : slot.kind == .rom ? "ROM" : "RAM"
            line += ", \(slot.owner)"
            switch slot.writePolicy {
            case .never: break
            case .whenSelected: line += ", writable when selected"
            case .whenWriteSelected: line += ", written while *RWRITE (&FE32) selects it"
            }
            if let header = slot.header {
                line += ": \(header.name)\(header.isLanguage ? " (language)" : "")"
            } else if slot.kind == .ram {
                line += ": no ROM image"
            }
            if Int(m.romsel & 0x0F) == slot.bank {
                line += "  <- selected"
            }
            return line
        }.joined(separator: "\n")
    }

    static let hardwareTools: [Tool] = [
        Tool(definition: ToolDefinition(
            name: "get_hardware",
            description: "What hardware is fitted: the model, second processor, disc interface, the Model B's memory expansion board (sideways RAM) and every sideways bank (ROM, RAM, empty socket; what's in it; when it's writable; which is selected). peek and poke take space bankN to read or write a bank directly (its physical storage) without paging it in; space host is the CPU's current (logical) view. power_cycle with memory_board changes the board.",
            inputSchema: schema()
        )) { context, _ in
            .text(try context.perform { session in
                let m = session.machine
                let c = m.configuration
                var lines = ["model: \(modelDescription(m.model))"]
                let coprocessor = m.secondProcessor != nil || m.z80Processor != nil || m.master512 != nil || m.armProcessor != nil
                lines.append("second processor: \(coprocessor ? c.coprocessor.displayName : "none")")
                if m.model == .modelB {
                    lines.append("disc interface: \(c.discInterface.displayName)")
                    let e = c.expansions
                    var board = "memory board: \(agentName(e.board)) (\(e.board.displayName))"
                    if e.board.isSidewaysRAM {
                        board += ", in socket \(e.sidewaysRAMSocket)"
                        if e.board == .sidewaysRAM32 { board += ", second bank \(e.secondBankBelow) below" }
                        board += "; \(e.board.extraRAM / 1024)K of sideways RAM in bank\(e.sidewaysRAMBanks.count > 1 ? "s" : "") \(e.sidewaysRAMBanks.map(String.init).joined(separator: " and "))"
                    }
                    lines.append(board)
                    lines.append("memory: 32K main RAM\(e.board.extraRAM > 0 ? " + \(e.board.extraRAM / 1024)K on the board" : "")")
                    if let bank = e.board.controllerROMBank {
                        let rom = m.sidewaysBankContents(bank).map { Array($0.prefix(Firmware.standard(for: e.board)?.size ?? 0x4000)) }
                        let identity = rom.map { Firmware.identify($0, for: e.board) }
                        let described: String = switch identity {
                        case .known(let f)?: "\(f.name) \(f.version)\(f.isBundled ? " (bundled)" : "")"
                        case .unknown?: "an unknown version"
                        default: "missing"
                        }
                        lines.append("controller ROM: \(described) in bank \(bank), SHA-256 \(rom.map(Firmware.sha256) ?? "-")")
                    }
                    if m.ariesFitted {
                        lines.append("aries: \(m.aries.shadowAllocation); shadow now \(m.aries.shadow ? "on" : "off"); writes to &8000-&BFFF go to \(m.aries.writeTarget); start-up link \(e.ariesStartUpLink ? "fitted" : "removed"); the ROM's state byte &27F = &\(hex(m.peek(0x27F))) (*XSTATUS shows any pending change, applied at the next MODE or Break)")
                        lines.append("aries pool: peek space bankD and bankE (or \"board\", 32K: bank 13 then 14); shadow &4000-&7FFF is bank 13, &3000-&3FFF the top 4K of bank 14")
                    }
                    if m.watfordFitted {
                        lines.append("watford latch: \(m.watfordMapping.description); board RAM is peek space \"board\" (&0000-&7FFF); the video always shows main RAM")
                    }
                    if let problem = c.expansionProblem {
                        lines.append("problem: \(problem)")
                    }
                } else {
                    lines.append("memory board: none (expansion boards fit the Model B only)")
                }
                lines.append("video: \(m.videoULA.nula == nil ? "the stock Video ULA" : "VideoNuLA (16 programmable 12-bit colours\(m.videoULA.nula!.disableA1 ? "; disabled by the BBC until power off" : "")); video_nula shows its state")")
                lines.append("sideways banks (ROMSEL &\(hex(m.romsel)), bank \(m.romsel & 0x0F) selected):")
                lines.append(bankTable(m))
                return lines.joined(separator: "\n")
            })
        },

        Tool(definition: ToolDefinition(
            name: "load_sideways_bank",
            description: "Put a ROM image file (up to 16K, loaded at &8000) into a sideways RAM bank from outside the BBC, as a loader program would, or with clear=true empty the bank (all zeros). Only sideways RAM: get_hardware lists the banks. The OS finds a new ROM at the next Break (press_break, or ctrl=true for a hard reset). To load from the BBC itself, use the BBC's own tools, e.g. *SRLOAD on DFS 2.26 (disc_interface acorn1770).",
            inputSchema: schema(["bank": prop("integer", "The bank, 0-15"),
                                 "path": prop("string", "The ROM image file"),
                                 "clear": prop("boolean", "Empty the bank instead")],
                                required: ["bank"])
        )) { context, args in
            guard let bank = args["bank"]?.intValue, (0..<16).contains(bank) else { throw ToolFailure("bank must be 0-15") }
            let clear = args["clear"]?.boolValue ?? false
            var image: [UInt8]?
            if let path = args["path"]?.stringValue {
                guard !clear else { throw ToolFailure("path or clear, not both") }
                image = [UInt8](try Data(contentsOf: URL(fileURLWithPath: (path as NSString).expandingTildeInPath)))
            } else if !clear {
                throw ToolFailure("give path, or clear: true")
            }
            let loaded = image
            return .text(try context.perform { session in
                let m = session.machine
                do {
                    if let loaded {
                        try m.loadSidewaysImage(loaded, bank: bank)
                    } else {
                        try m.clearSidewaysBank(bank)
                    }
                } catch let error as BBCMicro.SidewaysImageError {
                    throw ToolFailure("\(error)" + (m.sidewaysRAMBanks.isEmpty ? " (there's no sideways RAM: power_cycle with memory_board sideways_ram_16 or sideways_ram_32)" : ". Sideways RAM: banks \(m.sidewaysRAMBanks.sorted().map(String.init).joined(separator: ", "))"))
                }
                let slot = m.sidewaysSlots[bank]
                if let loaded {
                    let what = slot.header.map { "a ROM image, \($0.name)" } ?? "data (no ROM header)"
                    return "loaded \(loaded.count) bytes into bank \(bank): \(what). The OS finds it at the next Break."
                }
                return "cleared bank \(bank)"
            })
        },

        Tool(definition: ToolDefinition(
            name: "save_sideways_bank",
            description: "Save a sideways bank's 16K (ROM or RAM) to a file, without paging it in.",
            inputSchema: schema(["bank": prop("integer", "The bank, 0-15"), "path": prop("string", "Output file")],
                                required: ["bank", "path"])
        )) { context, args in
            guard let bank = args["bank"]?.intValue, (0..<16).contains(bank) else { throw ToolFailure("bank must be 0-15") }
            guard let path = args["path"]?.stringValue else { throw ToolFailure("path is required") }
            let contents = try context.perform { session in session.machine.sidewaysBankContents(bank) }
            guard let contents else { throw ToolFailure("bank \(bank) is empty") }
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(contents).write(to: url)
            } catch {
                throw ToolFailure("can't write \(path): \(error.localizedDescription)")
            }
            return .text("saved bank \(bank) (16384 bytes) to \(url.path)")
        },
    ]
}

/// VideoNuLA: discovering it, reading its state, and programming it through
/// its real registers (&FE22 and &FE23, written as the CPU writes them).
extension AgentTools {
    /// What MacBeeb's VideoNuLA does, by NuLA's name for it.
    static let nulaCapabilities: [(name: String, supported: Bool, note: String)] = [
        ("palette", true, "16 colours of 4096 (RGB444), two writes to &FE23 each"),
        ("direct_palette", true, "function 1: logical colours straight to the palette"),
        ("horizontal_offset", true, "function 2, 0-7 pixels"),
        ("left_blanking", true, "function 3, 0-15 columns"),
        ("reset", true, "function 4: the standard colours, flashing 8-15, no offset or blanking"),
        ("disable", true, "function 5: NuLA's registers off (stock ULA) until power off"),
        ("attribute_mode_1", true, "function 6 value 1, as b2 emulates it"),
        ("flash_flags", true, "functions 8 and 9: which of colours 8-15 flash"),
        ("mode7_palette", true, "teletext uses colours 0-7 of the palette"),
        ("attribute_modes_2_3", false, "function 6 values 2 and 3: not emulated (no verified reference)"),
        ("text_attribute_mode", false, "function 7: not emulated (b2 and jsbeeb don't draw it either)"),
        ("border_and_blank_colours", false, "functions E and F: not emulated (jsbeeb stubs them too)"),
    ]

    static func rgbText(_ c: UInt16) -> String {
        String(format: "&%03X (#%02X%02X%02X)", c & 0xFFF, Int(c >> 8 & 15) * 17, Int(c >> 4 & 15) * 17, Int(c & 15) * 17)
    }

    static func nulaState(_ m: BBCMicro) -> String {
        guard let n = m.videoULA.nula else {
            return "VideoNuLA: not fitted (the stock Video ULA). power_cycle with video_nula: true fits it. On the stock ULA, &FE22 and &FE23 are &FE20 and &FE21 again."
        }
        var lines = ["VideoNuLA: fitted (emulator diagnostic state: NuLA's registers are write-only on the BBC)"]
        lines.append("registers: \(n.disableA1 ? "disabled by function 5 until power off (&FE22/&FE23 now act as &FE20/&FE21)" : "enabled at &FE22 (control) and &FE23 (palette)")")
        lines.append("palette mode: \(n.directPalette ? "direct (function 1): logical colours index the palette" : "through the ULA's palette (&FE21)")")
        lines.append("palette write: \(n.paletteWritePending ? String(format: "half done: first byte &%02X (colour %d, red %X) waiting for the green/blue byte", n.paletteWriteBuffer, n.paletteWriteBuffer >> 4, n.paletteWriteBuffer & 15) : "ready for a first byte")")
        lines.append("horizontal offset: \(n.scrollOffset); left blanking: \(n.blankingSize); attribute mode: \(n.attributeMode)\(n.attributeMode >= 2 ? " (not emulated: drawn as 0)" : ""); text attribute mode: \(n.textAttributeMode ? "on (not emulated)" : "off")")
        lines.append("ULA control (&FE20): &\(hex(m.videoULA.control)); flash \(m.videoULA.flash ? "second" : "first") state")
        lines.append("palette (index: RGB444 (RGB888), flashing):")
        for i in 0..<16 {
            lines.append(String(format: "  %2d: ", i) + rgbText(n.outputPalette[i]) + (n.flash[i] ? ", flashes" : ""))
        }
        let logical = m.videoULA.logicalPalette
        lines.append("logical colours (&FE21 mapping -> what pixels of that colour show now):")
        for i in 0..<16 {
            lines.append(String(format: "  %2d -> physical %2d -> ", i, logical[i]) + rgbText(m.videoULA.effectiveColour(logical: i)))
        }
        if n.ignoredWrites > 0 { lines.append("writes to &FE22 with unknown functions: \(n.ignoredWrites) (ignored)") }
        return lines.joined(separator: "\n")
    }

    /// The machine, checked for a usable NuLA, or why not.
    static func requireNuLA(_ m: BBCMicro) throws {
        guard let n = m.videoULA.nula else {
            throw ToolFailure("not_fitted: VideoNuLA isn't fitted (power_cycle with video_nula: true; it restarts the BBC)")
        }
        guard !n.disableA1 else {
            throw ToolFailure("disabled: the BBC disabled NuLA's registers (function 5) until power off; power_cycle to re-enable them")
        }
    }

    /// Parses a 12-bit colour: 3840, "F80", "&F80", "$F80", "0xF80", "#F80".
    static func rgb444(_ value: JSONValue?) -> UInt16? {
        if let n = value?.intValue { return (0...0xFFF).contains(n) ? UInt16(n) : nil }
        guard var text = value?.stringValue?.trimmingCharacters(in: .whitespaces) else { return nil }
        for prefix in ["0x", "0X", "&", "$", "#"] where text.hasPrefix(prefix) { text.removeFirst(prefix.count) }
        guard text.count == 3, let n = Int(text, radix: 16) else { return nil }
        return UInt16(n)
    }

    static let nulaTools: [Tool] = [
        Tool(definition: ToolDefinition(
            name: "video_nula",
            description: "VideoNuLA's state, without side effects: whether it's fitted and enabled, the palette mode, all 16 colours as RGB444 and RGB888 with their flash flags, each logical colour's mapping and the colour its pixels show now, a half-done palette write, offset, blanking, attribute modes, and what's emulated (capabilities). The registers are write-only on the BBC; this is the emulator's own record.",
            inputSchema: schema()
        )) { context, _ in
            .text(try context.perform { session in
                let m = session.machine
                var text = nulaState(m)
                text += "\ncapabilities:\n" + nulaCapabilities.map { "  \($0.name): \($0.supported ? "yes" : "unsupported"), \($0.note)" }.joined(separator: "\n")
                return text
            })
        },

        Tool(definition: ToolDefinition(
            name: "set_video_nula_palette",
            description: "Set one of VideoNuLA's 16 colours to a 12-bit RGB colour, by writing the two bytes to &FE23 as a program would ([index|red] then [green|blue]); the same path as the BBC's own writes, so it shows on screen at once (in the colours the screen uses: video_nula shows which). Errors: not_fitted, disabled, invalid_value, pending_write (a program is half way through a palette write).",
            inputSchema: schema(["index": prop("integer", "Colour 0-15"),
                                 "rgb": prop("string", "RGB444, e.g. \"F80\" or \"&F80\" (red F, green 8, blue 0 = #FF8800), or a number 0-4095")],
                                required: ["index", "rgb"])
        )) { context, args in
            guard let index = args["index"]?.intValue, (0...15).contains(index) else { throw ToolFailure("invalid_value: index must be 0-15") }
            guard let rgb = rgb444(args["rgb"]) else { throw ToolFailure("invalid_value: rgb must be 3 hex digits (RGB444, e.g. F80) or 0-4095") }
            return .text(try context.perform { session in
                let m = session.machine
                try requireNuLA(m)
                if m.videoULA.nula!.paletteWritePending {
                    throw ToolFailure("pending_write: the BBC has written the first byte of a palette entry (&\(hex(m.videoULA.nula!.paletteWriteBuffer))) and not the second; writing now would complete its entry instead. Run the machine on, or reset NuLA (set_video_nula_control function 4)")
                }
                m.cpuWrite(0xFE23, UInt8(index << 4) | UInt8(rgb >> 8))
                m.cpuWrite(0xFE23, UInt8(rgb & 0xFF))
                return "colour \(index) = \(rgbText(m.videoULA.nula!.outputPalette[index]))"
            })
        },

        Tool(definition: ToolDefinition(
            name: "set_video_nula_control",
            description: "Write VideoNuLA's control register (&FE22: function << 4 | value) as the CPU would. Functions: 1 direct palette (value 0/1), 2 horizontal offset (0-7), 3 left blanking (0-15), 4 reset NuLA's colours and settings, 5 disable NuLA until power off, 6 attribute mode (0 or 1), 8 flash flags for colours 8-11 (bits 3-0), 9 for 12-15. Unemulated functions (6 with 2 or 3, 7, 14, 15) are refused with unsupported_feature rather than pretending.",
            inputSchema: schema(["function": prop("integer", "1-9"), "value": prop("integer", "0-15")], required: ["function"])
        )) { context, args in
            guard let function = args["function"]?.intValue else { throw ToolFailure("invalid_value: function is required") }
            let value = args["value"]?.intValue ?? 0
            guard (0...15).contains(value) else { throw ToolFailure("invalid_value: value must be 0-15") }
            let limits: [Int: ClosedRange<Int>] = [1: 0...1, 2: 0...7, 3: 0...15, 4: 0...15, 5: 0...15, 6: 0...1, 8: 0...15, 9: 0...15]
            if function == 6 && value >= 2 || function == 7 || function == 14 || function == 15 {
                throw ToolFailure("unsupported_feature: NuLA function \(function)\(function == 6 ? " value \(value)" : "") isn't emulated (video_nula lists what is)")
            }
            guard let range = limits[function] else { throw ToolFailure("invalid_value: function must be 1-6, 8 or 9") }
            guard range.contains(value) else { throw ToolFailure("invalid_value: function \(function) takes \(range.lowerBound)-\(range.upperBound)") }
            return .text(try context.perform { session in
                let m = session.machine
                try requireNuLA(m)
                m.cpuWrite(0xFE22, UInt8(function << 4 | value))
                return String(format: "wrote &%02X to &FE22\n", function << 4 | value) + nulaState(m)
            })
        },

        Tool(definition: ToolDefinition(
            name: "bus_write",
            description: "Write bytes as the BBC's CPU would, through its address decoding: I/O registers (&FC00-&FEFF) receive them as from a program (unlike poke, which only writes memory), so this is the real hardware route to a device, e.g. &FE21 (the ULA's palette), &FE22/&FE23 (VideoNuLA) or &FE30 (ROMSEL). Memory writes go through the current paging (ROM ignores them). Several bytes go to the same address one after another (as two STA &FE23 would).",
            inputSchema: schema(["address": prop("string", "Address, e.g. &FE23"),
                                 "bytes": ["type": "array", "items": ["type": "integer"], "description": "Values 0-255, written in order"]],
                                required: ["address", "bytes"])
        )) { context, args in
            guard let bytes = args["bytes"]?.arrayValue?.compactMap(\.intValue), !bytes.isEmpty, bytes.allSatisfy({ (0...255).contains($0) }) else {
                throw ToolFailure("invalid_value: bytes must be an array of 0-255")
            }
            return .text(try context.perform { session in
                let m = session.machine
                guard let address = try address(args, "address", in: m, cpu: .host), (0...0xFFFF).contains(address) else {
                    throw ToolFailure("invalid_value: address must be 0-&FFFF")
                }
                for byte in bytes { m.cpuWrite(UInt16(address), UInt8(byte)) }
                return "wrote \(bytes.count) byte\(bytes.count == 1 ? "" : "s") to &\(hex(UInt16(address), 4)) through the bus"
            })
        },
    ]
}
