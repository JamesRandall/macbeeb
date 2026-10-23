import BeebCore
import BeebHost
import Foundation

/// The machine's hardware: what's fitted, the sideways banks, and loading
/// sideways RAM.
extension AgentTools {
    /// Agents' names for the memory boards.
    static let agentBoards: [String: BBCMicro.MemoryBoard] = [
        "none": .none, "sideways_ram_16": .sidewaysRAM16, "sideways_ram_32": .sidewaysRAM32,
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
                } else {
                    lines.append("memory board: none (expansion boards fit the Model B only)")
                }
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
