import BeebCore
import BeebHost
import Foundation

/// Debugging tools: memory in any address space, breakpoints, stepping,
/// registers and tracing, for the host CPU and the second processor.
extension AgentTools {
    static let cpuProperty = ["type": "string", "enum": ["host", "parasite"],
                              "description": "Which CPU (default host; parasite is the 6502 Second Processor)"] as JSONValue
    static let spaceProperty = prop("string", "Address space (default: the host CPU's current view). host, parasite (the CPU views), main, shadow, andy, hazel, os, bank0-bankF, parasite_ram; memory_regions lists them")

    static func cpu(_ args: JSONValue) throws -> DebugCPU {
        guard let name = args["cpu"]?.stringValue else { return .host }
        guard let cpu = DebugCPU(rawValue: name) else { throw ToolFailure("cpu must be host or parasite") }
        return cpu
    }

    static func space(_ args: JSONValue, cpu: DebugCPU) throws -> MemorySpace {
        guard let name = args["space"]?.stringValue else { return .cpu(cpu) }
        guard let space = MemorySpace(name: name) else { throw ToolFailure("unknown space \(name); see memory_regions") }
        return space
    }

    /// An address argument: a number or an expression (registers, memory,
    /// symbols), e.g. "&1900", "PC+3", "{&FFFE}".
    static func address(_ args: JSONValue, _ key: String, in machine: BBCMicro, cpu: DebugCPU) throws -> Int? {
        guard let value = args[key] else { return nil }
        if let n = value.intValue {
            return n
        }
        guard let text = value.stringValue else { throw ToolFailure("\(key) must be a number or expression") }
        // file.s:12, a source line from loaded debug info.
        if let colon = text.lastIndex(of: ":"), let line = Int(text[text.index(after: colon)...]),
           text[..<colon].contains(".") {
            let file = String(text[..<colon])
            guard let found = machine.debugger.symbols(cpu).addresses(file: file, line: line), let first = found.addresses.min() else {
                throw ToolFailure("no code at \(text) (load_symbols first?)")
            }
            return Int(first)
        }
        do {
            return try DebugExpression(text).evaluate(machine.debugger.expressionContext(cpu))
        } catch {
            throw ToolFailure("\(key): \(error)")
        }
    }

    static func flags(_ p: UInt8) -> String {
        zip("NV-BDIZC", (0..<8).reversed()).map { ch, bit in p & 1 << bit != 0 ? ch : Character(ch.lowercased()) }
            .map(String.init).joined()
    }

    static func registerLine(_ m: BBCMicro, _ cpu: DebugCPU) -> String? {
        guard let c = m.debugCPU(cpu) else { return nil }
        let pc = m.instructionAddress(cpu)
        let state = c.isAboutToExecute ? "" : " (mid-instruction)"
        return "\(cpu.rawValue): PC=&\(hex(pc, 4)) A=&\(hex(c.a)) X=&\(hex(c.x)) Y=&\(hex(c.y)) S=&\(hex(c.s)) P=\(flags(c.p))\(state)"
    }

    /// Disassembly from `start`, marking `pc`.
    static func disassembly(_ m: BBCMicro, _ cpu: DebugCPU, from start: UInt16, count: Int, mark pc: UInt16?) -> String {
        let disassembler = m.disassembler(cpu)
        let read = { (a: UInt16) in m.debugRead(.cpu(cpu), Int(a)) ?? 0xFF }
        var address = start
        var lines: [String] = []
        for _ in 0..<count {
            let (raw, length) = disassembler.disassemble(at: address, read: read)
            let symbols = m.debugger.symbols(cpu)
            let text = symbols.annotate(raw)
            let bytes = (0..<length).map { hex(read(address &+ UInt16($0))) }.joined(separator: " ")
            let marker = address == pc ? "> " : "  "
            if let label = symbols.names(at: address).first, address < 0xFC00 || address >= 0xFF00 {
                lines.append("\(label):")
            }
            var line = "\(marker)\(hex(address, 4))  \(bytes.padding(toLength: 9, withPad: " ", startingAt: 0))  \(text)"
            var notes: [String] = []
            if let source = symbols.location(at: address) {
                notes.append("\(source)")
            }
            let breakpoints = m.debugger.breakpoints.filter { $0.cpu == cpu && $0.kind.contains(.execute) && $0.start == address }
            if !breakpoints.isEmpty {
                notes.append("breakpoint " + breakpoints.map { "\($0.id)" }.joined(separator: ","))
            }
            if !notes.isEmpty {
                line += String(repeating: " ", count: max(1, 34 - line.count)) + "; " + notes.joined(separator: ", ")
            }
            lines.append(line)
            address &+= UInt16(length)
        }
        return lines.joined(separator: "\n")
    }

    /// Where the debugger stopped, the registers and the code there.
    static func debugSummary(_ session: MachineSession, cpu: DebugCPU, reason: StopReason?) -> String {
        let m = session.machine
        var text = reason.map { "stopped: \($0)" } ?? "still running (time limit reached)"
        let stoppedCPU: DebugCPU = switch reason {
        case .breakpoint(_, let c, _, _), .stepped(let c), .interrupt(let c): c
        default: cpu
        }
        for c in DebugCPU.allCases {
            if let line = registerLine(m, c) { text += "\n" + line }
        }
        let pc = m.instructionAddress(stoppedCPU)
        text += "\n" + disassembly(m, stoppedCPU, from: pc, count: 6, mark: pc)
        let log = m.debugger.log.suffix(10)
        if !log.isEmpty {
            text += "\nlog:\n" + log.map { "  [\($0.cpu.rawValue) \($0.cycle)] \($0.text)" }.joined(separator: "\n")
        }
        let time = String(format: "%.6f", Double(m.cycles) / 2_000_000)
        return text + "\n[t=\(time)s, cycle \(m.cycles)]"
    }

    static let debugTools: [Tool] = [
        Tool(definition: ToolDefinition(
            name: "peek",
            description: "Read memory without side effects (I/O registers are peeked, not read). Returns a hex dump. Addresses can be numbers or expressions (e.g. \"PC\", \"{&FFFE}\").",
            inputSchema: schema(["address": prop("string", "Start address: &1900, $1900, 0x1900, decimal or an expression"),
                                 "length": prop("integer", "Bytes (default 64, max 4096)"),
                                 "space": spaceProperty, "cpu": cpuProperty],
                                required: ["address"])
        )) { context, args in
            let cpu = try cpu(args)
            let space = try space(args, cpu: cpu)
            let length = min(max(args["length"]?.intValue ?? 64, 1), 4096)
            return .text(try context.perform { session in
                let m = session.machine
                guard let address = try address(args, "address", in: m, cpu: cpu) else { throw ToolFailure("address is required") }
                var bytes: [UInt8] = []
                for offset in 0..<length {
                    guard let byte = m.debugRead(space, address + offset) else { break }
                    bytes.append(byte)
                }
                guard !bytes.isEmpty else { throw ToolFailure("nothing at &\(String(address, radix: 16, uppercase: true)) in \(space)") }
                return hexDump(bytes, address: address)
            })
        },

        Tool(definition: ToolDefinition(
            name: "poke",
            description: "Write bytes to memory, including ROM (to patch it) but not I/O. Defaults to the host CPU's current view; use space to write elsewhere (e.g. shadow, bank4, parasite_ram).",
            inputSchema: schema(["address": prop("string", "Start address or expression"),
                                 "bytes": ["type": "array", "items": ["type": "integer"], "description": "Values 0-255"],
                                 "space": spaceProperty, "cpu": cpuProperty],
                                required: ["address", "bytes"])
        )) { context, args in
            let cpu = try cpu(args)
            let space = try space(args, cpu: cpu)
            guard let bytes = args["bytes"]?.arrayValue?.compactMap(\.intValue), bytes.allSatisfy({ (0...255).contains($0) }) else {
                throw ToolFailure("bytes must be an array of 0-255")
            }
            return .text(try context.perform { session in
                let m = session.machine
                guard let address = try address(args, "address", in: m, cpu: cpu) else { throw ToolFailure("address is required") }
                for (offset, byte) in bytes.enumerated() {
                    guard m.debugWrite(space, address + offset, UInt8(byte)) else {
                        throw ToolFailure("can't write &\(String(address + offset, radix: 16, uppercase: true)) in \(space) (I/O, or nothing there); wrote \(offset) bytes")
                    }
                }
                return "wrote \(bytes.count) bytes at &\(String(address, radix: 16, uppercase: true)) in \(space)"
            })
        },

        Tool(definition: ToolDefinition(
            name: "disassemble",
            description: "Disassemble code (for the CPU's instruction set: NMOS 6502, 65C12 or 65C02) as the CPU sees memory now. Default: from the current instruction. Marks the PC and breakpoints.",
            inputSchema: schema(["address": prop("string", "Start address or expression (default PC)"),
                                 "count": prop("integer", "Instructions (default 16)"),
                                 "cpu": cpuProperty])
        )) { context, args in
            let cpu = try cpu(args)
            let count = min(max(args["count"]?.intValue ?? 16, 1), 256)
            return .text(try context.perform { session in
                let m = session.machine
                guard m.debugCPU(cpu) != nil else { throw ToolFailure("there's no second processor") }
                let pc = m.instructionAddress(cpu)
                let start = try address(args, "address", in: m, cpu: cpu).map { UInt16(truncatingIfNeeded: $0) } ?? pc
                return disassembly(m, cpu, from: start, count: count, mark: pc)
            })
        },

        Tool(definition: ToolDefinition(
            name: "memory_regions",
            description: "The machine's memory regions (for peek/poke's space), and the current paging: which sideways bank is in, shadow RAM, etc.",
            inputSchema: schema()
        )) { context, _ in
            .text(try context.perform { session in
                let m = session.machine
                var lines = m.memoryRegions.map { r in
                    "\(String(describing: r.space).padding(toLength: 13, withPad: " ", startingAt: 0)) \(r.name): &\(hex(UInt16(r.base), 4))-&\(hex(UInt16(r.base + r.size - 1), 4))\(r.isROM ? " (ROM)" : "")"
                }
                lines.append("paging: ROMSEL=&\(hex(m.romsel)) (bank \(String(m.romsel & 0x0F, radix: 16, uppercase: true)) at &8000)"
                             + (m.model == .modelB ? "" : " ACCCON=&\(hex(m.acccon))"))
                return lines.joined(separator: "\n")
            })
        },

        Tool(definition: ToolDefinition(
            name: "registers",
            description: "CPU registers (both CPUs if there's a second processor), flags (upper case = set), and whether the debugger has stopped the machine.",
            inputSchema: schema()
        )) { context, _ in
            .text(try context.perform { session in
                let m = session.machine
                var lines = DebugCPU.allCases.compactMap { registerLine(m, $0) }
                lines.append("cycle \(m.cycles)")
                if let reason = m.debuggerIfCreated?.stopReason {
                    lines.append("stopped: \(reason)")
                }
                return lines.joined(separator: "\n")
            })
        },

        Tool(definition: ToolDefinition(
            name: "set_register",
            description: "Set a register (A X Y S P PC) or flag (C Z I D V N). PC can only be set between instructions, e.g. at a breakpoint or after a step.",
            inputSchema: schema(["name": prop("string", "Register or flag"),
                                 "value": prop("string", "Value or expression"),
                                 "cpu": cpuProperty],
                                required: ["name", "value"])
        )) { context, args in
            let cpu = try cpu(args)
            guard let name = args["name"]?.stringValue else { throw ToolFailure("name is required") }
            return .text(try context.perform { session in
                let m = session.machine
                guard let value = try address(args, "value", in: m, cpu: cpu) else { throw ToolFailure("value is required") }
                do {
                    try m.setRegister(name, cpu: cpu, to: value)
                } catch {
                    throw ToolFailure("\(error)")
                }
                return registerLine(m, cpu) ?? ""
            })
        },

        Tool(definition: ToolDefinition(
            name: "set_breakpoint",
            description: "Stop when the CPU executes an address (default), or reads or writes it (a watchpoint). Then use continue. Ranges, conditions (e.g. \"A == &41 && [&70] > 3\"), hit counts, and log points (log_message, with {expression}s, instead of stopping) are supported. Returns the breakpoint's ID.",
            inputSchema: schema(["address": prop("string", "Address, expression, symbol, or source line (hello.s:12, with debug info loaded)"),
                                 "end": prop("string", "Last address of a range (default: just address)"),
                                 "type": ["type": "string", "enum": ["execute", "read", "write", "access"],
                                          "description": "What to stop on (default execute; access is read or write)"] as JSONValue,
                                 "condition": prop("string", "Only when this is true"),
                                 "hit_count": prop("integer", "Only stop on this hit (and later ones)"),
                                 "log_message": prop("string", "Log this instead of stopping, e.g. \"A={A} at {PC}\""),
                                 "rom_bank": prop("integer", "Host only: only while this sideways bank (0-15) is paged in"),
                                 "cpu": cpuProperty],
                                required: ["address"])
        )) { context, args in
            let cpu = try cpu(args)
            let kind: Breakpoint.Kind = switch args["type"]?.stringValue ?? "execute" {
            case "execute": .execute
            case "read": .read
            case "write": .write
            case "access": .access
            default: throw ToolFailure("type must be execute, read, write or access")
            }
            return .text(try context.perform { session in
                let m = session.machine
                guard let start = try address(args, "address", in: m, cpu: cpu), (0...0xFFFF).contains(start) else {
                    throw ToolFailure("address must be 0-&FFFF")
                }
                let end = try address(args, "end", in: m, cpu: cpu) ?? start
                guard (0...0xFFFF).contains(end) else { throw ToolFailure("end must be 0-&FFFF") }
                let breakpoint = Breakpoint(cpu: cpu, kind: kind, start: UInt16(start), end: UInt16(end),
                                            romBank: args["rom_bank"]?.intValue, condition: args["condition"]?.stringValue,
                                            hitTarget: args["hit_count"]?.intValue, logMessage: args["log_message"]?.stringValue)
                do {
                    let added = try m.debugger.add(breakpoint)
                    return "breakpoint \(added.id): \(describe(added))"
                } catch {
                    throw ToolFailure("condition: \(error)")
                }
            })
        },

        Tool(definition: ToolDefinition(
            name: "list_breakpoints",
            description: "The breakpoints, with hit counts.",
            inputSchema: schema()
        )) { context, _ in
            .text(try context.perform { session in
                let breakpoints = session.machine.debugger.breakpoints
                return breakpoints.isEmpty ? "no breakpoints" : breakpoints.map { "\($0.id): \(describe($0))" }.joined(separator: "\n")
            })
        },

        Tool(definition: ToolDefinition(
            name: "delete_breakpoint",
            description: "Delete a breakpoint by ID, or all of them.",
            inputSchema: schema(["id": prop("integer", "Breakpoint ID"), "all": prop("boolean", "Delete them all")])
        )) { context, args in
            let id = args["id"]?.intValue
            let all = args["all"]?.boolValue ?? false
            guard id != nil || all else { throw ToolFailure("give id, or all: true") }
            return .text(try context.perform { session in
                let debugger = session.machine.debugger
                if all {
                    debugger.removeAllBreakpoints()
                    return "deleted all breakpoints"
                }
                guard debugger.breakpoints.contains(where: { $0.id == id }) else { throw ToolFailure("no breakpoint \(id!)") }
                debugger.remove(id: id!)
                return "deleted breakpoint \(id!)"
            })
        },

        Tool(definition: ToolDefinition(
            name: "continue",
            description: "Run until a breakpoint or watchpoint hits (or max_seconds of emulated time). Also resumes after a stop. Returns where it stopped, the registers and the code there.",
            inputSchema: schema(["max_seconds": prop("number", "Longest to run (default 30)")])
        )) { context, args in
            let maxSeconds = args["max_seconds"]?.doubleValue ?? 30
            return .text(try context.perform { session in
                let reason = session.machine.debugger.run(.continue, maxCycles: Int(maxSeconds * 2_000_000)) {
                    session.advance(cycles: $0)
                }
                return debugSummary(session, cpu: .host, reason: reason)
            })
        },

        Tool(definition: ToolDefinition(
            name: "step",
            description: "Step one CPU: instruction (into subroutines), over (a JSR runs to the next instruction), out (until the subroutine or interrupt handler returns), cycle (one 2MHz cycle), scanline, frame, interrupt (until one starts), to (an address, given in address), or back (to the previous instruction, using the rewind history). Repeats count times. Returns the registers and code.",
            inputSchema: schema(["kind": ["type": "string", "enum": ["instruction", "over", "out", "cycle", "scanline", "frame", "interrupt", "to", "back"],
                                          "description": "What to step (default instruction)"] as JSONValue,
                                 "count": prop("integer", "How many (default 1, max 10000)"),
                                 "address": prop("string", "For kind to: where to run to"),
                                 "max_seconds": prop("number", "Longest per step (default 10)"),
                                 "cpu": cpuProperty])
        )) { context, args in
            let cpu = try cpu(args)
            let count = min(max(args["count"]?.intValue ?? 1, 1), 10_000)
            let maxSeconds = args["max_seconds"]?.doubleValue ?? 10
            return .text(try context.perform { session in
                let m = session.machine
                guard m.debugCPU(cpu) != nil else { throw ToolFailure("there's no second processor") }
                if args["kind"]?.stringValue == "back" {
                    for _ in 0..<count {
                        do {
                            try m.debugger.stepBack(cpu)
                        } catch {
                            throw ToolFailure("\(error)")
                        }
                        if m.debugger.stopReason == .historyStart { break }
                    }
                    return debugSummary(session, cpu: cpu, reason: m.debugger.stopReason)
                }
                let command: RunCommand
                switch args["kind"]?.stringValue ?? "instruction" {
                case "instruction": command = .stepInstruction
                case "over": command = .stepOver
                case "out": command = .stepOut
                case "cycle": command = .stepCycle
                case "scanline": command = .nextScanline
                case "frame": command = .nextFrame
                case "interrupt": command = .nextInterrupt
                case "to":
                    guard let target = try address(args, "address", in: m, cpu: cpu) else { throw ToolFailure("to needs an address") }
                    command = .runToAddress(UInt16(truncatingIfNeeded: target))
                default: throw ToolFailure("unknown kind")
                }
                var reason: StopReason?
                for _ in 0..<count {
                    reason = m.debugger.run(command, cpu: cpu, maxCycles: Int(maxSeconds * 2_000_000)) { session.advance(cycles: $0) }
                    // A breakpoint, or the time limit, ends the run early.
                    if case .breakpoint = reason { break }
                    if reason == nil { break }
                }
                return debugSummary(session, cpu: cpu, reason: reason)
            })
        },

        Tool(definition: ToolDefinition(
            name: "reverse_continue",
            description: "Run backwards to the last time a breakpoint or watchpoint hit (e.g. \"who wrote &70?\": set a write breakpoint on &70, then reverse_continue), using the rewind history (about the last 60 seconds). Stops there, as if it had just hit.",
            inputSchema: schema()
        )) { context, _ in
            .text(try context.perform { session in
                let m = session.machine
                do {
                    try m.debugger.reverseContinue()
                } catch {
                    throw ToolFailure("\(error)")
                }
                return debugSummary(session, cpu: .host, reason: m.debugger.stopReason)
            })
        },

        Tool(definition: ToolDefinition(
            name: "rewind",
            description: "Go back in time: by seconds (of emulated time), or to an exact cycle. History covers about the last 60 seconds. Running on afterwards replaces what came after.",
            inputSchema: schema(["seconds": prop("number", "How far back"),
                                 "cycle": prop("integer", "Or: the cycle to go to")])
        )) { context, args in
            let seconds = args["seconds"]?.doubleValue
            let cycle = args["cycle"]?.intValue
            guard seconds != nil || cycle != nil else { throw ToolFailure("give seconds or cycle") }
            return .text(try context.perform { session in
                let m = session.machine
                guard let rewinder = m.rewinder, let earliest = rewinder.earliestCycle else { throw ToolFailure("no rewind history") }
                let target = cycle.map { UInt64(max(0, $0)) } ?? UInt64(max(Int(earliest), Int(m.cycles) - Int(seconds! * 2_000_000)))
                do {
                    try rewinder.seek(to: max(target, earliest))
                } catch {
                    throw ToolFailure("\(error)")
                }
                return summary(session, extra: "now at cycle \(m.cycles) (history from cycle \(earliest))")
            })
        },

        Tool(definition: ToolDefinition(
            name: "trace",
            description: "Instruction trace: with enable, start recording each CPU's last N instructions (0 stops); otherwise show the last count recorded, with registers before each.",
            inputSchema: schema(["enable": prop("integer", "Start recording this many instructions (0 to stop)"),
                                 "count": prop("integer", "Show the last this many (default 32)"),
                                 "cpu": cpuProperty])
        )) { context, args in
            let cpu = try cpu(args)
            let enable = args["enable"]?.intValue
            let count = min(max(args["count"]?.intValue ?? 32, 1), 10_000)
            return .text(try context.perform { session in
                let m = session.machine
                if let enable {
                    m.debugger.setTracing(capacity: max(0, min(enable, 10_000_000)))
                    return enable > 0 ? "tracing the last \(enable) instructions" : "tracing off"
                }
                guard m.debugger.tracing else { return "tracing is off; call trace with enable first" }
                let disassembler = m.disassembler(cpu)
                let lines = m.debugger.trace(cpu).last(count).map { e -> String in
                    if e.interrupt {
                        return "\(e.cycle)  \(hex(e.pc, 4))  -- interrupt --"
                    }
                    let bytes = [e.bytes.0, e.bytes.1, e.bytes.2]
                    let (text, _) = disassembler.disassemble(at: e.pc) { bytes[Int($0 &- e.pc) % 3] }
                    let regs = "A=\(hex(e.a)) X=\(hex(e.x)) Y=\(hex(e.y)) S=\(hex(e.s)) \(flags(e.p))"
                    return "\(e.cycle)  \(hex(e.pc, 4))  \(text.padding(toLength: 16, withPad: " ", startingAt: 0)) \(regs)"
                }
                return lines.isEmpty ? "nothing traced yet" : lines.joined(separator: "\n")
            })
        },

        Tool(definition: ToolDefinition(
            name: "load_symbols",
            description: "Load symbols for the debugger: ld65 debug info (ld65 --dbgfile, which also maps code to source lines, so breakpoints can be \"hello.s:12\"), or a label file (ld65 -Ln, VICE, \"name = $1234\" lists). Then addresses and expressions can use the names, and disassembly shows them. The OS entry points (OSWRCH...) and hardware registers are always known.",
            inputSchema: schema(["path": prop("string", "The .dbg or label file"),
                                 "clear": prop("boolean", "Forget previously loaded symbols first"),
                                 "cpu": cpuProperty],
                                required: ["path"])
        )) { context, args in
            let cpu = try cpu(args)
            guard let path = args["path"]?.stringValue else { throw ToolFailure("path is required") }
            let table: SymbolTable
            do {
                table = try SymbolTable.load(path: (path as NSString).expandingTildeInPath)
            } catch {
                throw ToolFailure("\(error)")
            }
            let clear = args["clear"]?.boolValue ?? false
            return .text(try context.perform { session in
                let debugger = session.machine.debugger
                if clear { debugger.clearSymbols() }
                debugger.addSymbols(table, cpu: cpu)
                return "loaded \(table.symbolCount) symbols and \(table.lineCount) source lines"
            })
        },

        Tool(definition: ToolDefinition(
            name: "lookup_symbol",
            description: "A symbol's address, or the symbols and source line at an address.",
            inputSchema: schema(["name": prop("string", "Symbol name"),
                                 "address": prop("string", "Or an address"),
                                 "cpu": cpuProperty])
        )) { context, args in
            let cpu = try cpu(args)
            return .text(try context.perform { session in
                let m = session.machine
                let symbols = m.debugger.symbols(cpu)
                if let name = args["name"]?.stringValue {
                    guard let value = symbols.address(of: name) else { throw ToolFailure("no symbol \(name)") }
                    return "\(name) = &\(String(value, radix: 16, uppercase: true))"
                }
                guard let address = try address(args, "address", in: m, cpu: cpu) else { throw ToolFailure("give name or address") }
                let a = UInt16(truncatingIfNeeded: address)
                var parts = symbols.names(at: a)
                if parts.isEmpty, let near = symbols.nearest(below: a) { parts.append("\(near.name)+\(near.offset)") }
                if let source = symbols.location(at: a) { parts.append("at \(source)") }
                return parts.isEmpty ? "nothing known at &\(hex(a, 4))" : "&\(hex(a, 4)): " + parts.joined(separator: ", ")
            })
        },

        Tool(definition: ToolDefinition(
            name: "debug_log",
            description: "Output from log-point breakpoints (log_message), oldest first.",
            inputSchema: schema(["count": prop("integer", "Show the last this many (default 50)")])
        )) { context, args in
            let count = max(args["count"]?.intValue ?? 50, 1)
            return .text(try context.perform { session in
                let log = session.machine.debugger.log.suffix(count)
                return log.isEmpty ? "no log output" : log.map { "[\($0.cpu.rawValue) \($0.cycle)] \($0.text)" }.joined(separator: "\n")
            })
        },
    ]

    static func describe(_ b: Breakpoint) -> String {
        let kind = b.kind == .execute ? "execute" : b.kind == .read ? "read" : b.kind == .write ? "write" : "access"
        var text = "\(kind) &\(hex(b.start, 4))" + (b.end != b.start ? "-&\(hex(b.end, 4))" : "")
        if b.cpu == .parasite { text += " on the parasite" }
        if let bank = b.romBank { text += " in bank \(String(bank, radix: 16, uppercase: true))" }
        if let condition = b.condition { text += " if \(condition)" }
        if let target = b.hitTarget { text += " from hit \(target)" }
        if let message = b.logMessage { text += " log \"\(message)\"" }
        if !b.enabled { text += " (disabled)" }
        return text + ", hit \(b.hitCount) times"
    }
}
