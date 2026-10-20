import BeebCapture
import BeebCore
import BeebHost
import BeebROMs
import Foundation
import Synchronization

/// A tool's result, in MCP's content model.
public struct ToolResult: Sendable {
    public enum Content: Sendable {
        case text(String)
        case png(Data)
    }

    public var content: [Content]
    public var isError: Bool

    public static func text(_ text: String) -> ToolResult { ToolResult(content: [.text(text)], isError: false) }
    public static func error(_ text: String) -> ToolResult { ToolResult(content: [.text(text)], isError: true) }
}

public struct ToolDefinition: Sendable {
    public var name: String
    public var description: String
    public var inputSchema: JSONValue
}

struct ToolFailure: Error {
    var message: String
    init(_ message: String) { self.message = message }
}

/// The tools an agent uses to drive a BBC Micro. All time is emulated time,
/// so waits are exact and run as fast as the host can manage.
public final class AgentTools: Sendable {
    let context: MachineContext
    /// Named in-memory snapshots, for quick experiments.
    static let slots = Mutex<[String: SaveStateFile]>([:])

    public init(context: MachineContext) {
        self.context = context
    }

    public func call(_ name: String, arguments: JSONValue) -> ToolResult {
        guard let tool = Self.tools.first(where: { $0.definition.name == name }) else {
            return .error("unknown tool \(name)")
        }
        do {
            return try tool.run(context, arguments)
        } catch let failure as ToolFailure {
            return .error(failure.message)
        } catch {
            return .error("\(error)")
        }
    }

    public static var definitions: [ToolDefinition] { tools.map(\.definition) }

    struct Tool: Sendable {
        var definition: ToolDefinition
        var run: @Sendable (MachineContext, JSONValue) throws -> ToolResult
    }

    static func schema(_ properties: [String: JSONValue] = [:], required: [String] = []) -> JSONValue {
        .object([
            "type": "object",
            "properties": .object(properties),
            "required": .array(required.map { .string($0) }),
        ])
    }

    static let agentModels: [String: BBCMicro.Model] = ["model_b": .modelB, "master_128": .master128]

    static func modelDescription(_ model: BBCMicro.Model) -> String {
        switch model {
        case .modelB: "BBC Micro Model B (OS 1.20, BASIC 2, DFS 1.20)"
        case .master128: "BBC Master 128 (MOS 3.20, BASIC 4, DFS 2.24, ADFS 2.03)"
        }
    }

    static func prop(_ type: String, _ description: String) -> JSONValue {
        ["type": .string(type), "description": .string(description)]
    }

    /// Screen text plus the state an agent needs to know what happened.
    static func summary(_ session: MachineSession, extra: String = "") -> String {
        let text = session.machine.screenText()
        var lines = text
        while lines.last?.isEmpty == true { lines.removeLast() }
        let time = String(format: "%.2f", Double(session.machine.cycles) / 2_000_000)
        return (extra.isEmpty ? "" : extra + "\n") + "[t=\(time)s] screen:\n" + lines.joined(separator: "\n")
    }

    static let tools: [Tool] = [
        Tool(definition: ToolDefinition(
            name: "get_status",
            description: "Machine state: emulated time, CPU registers, screen mode, discs in the drives, whether it's waiting for input.",
            inputSchema: schema()
        )) { context, _ in
            .text(try context.perform { session in
                let m = session.machine, cpu = m.cpu
                // At an instruction boundary the PC has already moved past
                // the opcode being fetched.
                let pc = cpu.isAboutToExecute ? cpu.abus : cpu.pc
                let discs = (0..<2).map { drive -> String in
                    guard let disc = m.drives[drive].disc else { return "drive \(drive): empty" }
                    let title = (try? DFSDisc(side: disc.toSSDOrDSD(force: true)).title) ?? "?"
                    return "drive \(drive): \"\(title)\""
                }
                return """
                model: \(modelDescription(m.model))
                emulated time: \(String(format: "%.3f", Double(m.cycles) / 2_000_000))s
                PC=&\(hex(pc, 4)) A=&\(hex(cpu.a)) X=&\(hex(cpu.x)) Y=&\(hex(cpu.y)) S=&\(hex(cpu.s)) P=&\(hex(cpu.p))
                screen mode: \(m.peek(0x355))
                \(discs.joined(separator: "\n"))
                recording: \(session.isRecording)
                """
            })
        },

        Tool(definition: ToolDefinition(
            name: "power_cycle",
            description: "Switch the BBC off and on again. Discs stay in the drives. Runs until the BASIC prompt. With model, switches to that machine: model_b (OS 1.20, BASIC 2, DFS 1.20) or master_128 (MOS 3.20, BASIC 4, DFS 2.24, ADFS, View, ViewSheet, Edit; 1770 disc controller, shadow RAM, sideways RAM in banks 4-7).",
            inputSchema: schema(["model": ["type": "string", "enum": ["model_b", "master_128"],
                                           "description": "Machine to switch to (default: keep the current one)"] as JSONValue])
        )) { context, args in
            var model: BBCMicro.Model?
            if let name = args["model"]?.stringValue {
                guard let named = agentModels[name] else { throw ToolFailure("model must be model_b or master_128") }
                model = named
            }
            let configuration = model.map(BeebROMs.configuration(for:))
            return .text(try context.perform { session in
                session.powerCycle(configuration: configuration)
                runUntilIdle(session, maxSeconds: 10)
                return summary(session)
            })
        },

        Tool(definition: ToolDefinition(
            name: "press_break",
            description: "Press Break (soft reset; BASIC programs survive with OLD). With shift=true, Shift-Break boots the disc in drive 0. Then runs until the machine waits for input (up to max_seconds).",
            inputSchema: schema(["shift": prop("boolean", "Hold Shift to boot the disc"),
                                 "max_seconds": prop("number", "Longest to wait for input (default 30)")])
        )) { context, args in
            let shift = args["shift"]?.boolValue ?? false
            let maxSeconds = args["max_seconds"]?.doubleValue ?? 30
            return .text(try context.perform { session in
                if shift { session.machine.shiftBreak() } else { session.machine.pressBreak() }
                session.advance(seconds: 0.5)
                let idle = runUntilIdle(session, maxSeconds: maxSeconds)
                return summary(session, extra: idle ? "" : "(still running after \(maxSeconds)s)")
            })
        },

        Tool(definition: ToolDefinition(
            name: "load_disc",
            description: "Put a .ssd/.dsd disc image file in a drive. With boot=true (default, drive 0 only), Shift-Break to boot it and run until it waits for input. Returns the disc's catalogue.",
            inputSchema: schema(["path": prop("string", "Path to the .ssd or .dsd file"),
                                 "drive": prop("integer", "0 or 1 (default 0)"),
                                 "boot": prop("boolean", "Shift-Break to boot it (default true for drive 0)"),
                                 "max_seconds": prop("number", "Longest to wait after booting (default 30)")],
                                required: ["path"])
        )) { context, args in
            guard let path = args["path"]?.stringValue else { throw ToolFailure("path is required") }
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            let bytes = [UInt8](try Data(contentsOf: url))
            let doubleSided = url.pathExtension.lowercased() == "dsd"
            let drive = args["drive"]?.intValue ?? 0
            guard drive == 0 || drive == 1 else { throw ToolFailure("drive must be 0 or 1") }
            let boot = args["boot"]?.boolValue ?? (drive == 0)
            let maxSeconds = args["max_seconds"]?.doubleValue ?? 30
            let catalogue = catalogueText(bytes, doubleSided: doubleSided)
            return .text(try context.perform { session in
                let disc = doubleSided ? try Disc.fromDSD(bytes) : try Disc.fromSSD(bytes)
                session.machine.insertDisc(disc, drive: drive)
                guard boot else { return catalogue }
                session.machine.shiftBreak()
                session.advance(seconds: 0.5)
                let idle = runUntilIdle(session, maxSeconds: maxSeconds)
                return summary(session, extra: catalogue + (idle ? "" : "\n(still running after \(maxSeconds)s)"))
            })
        },

        Tool(definition: ToolDefinition(
            name: "eject_disc",
            description: "Remove the disc from a drive.",
            inputSchema: schema(["drive": prop("integer", "0 or 1 (default 0)")])
        )) { context, args in
            let drive = args["drive"]?.intValue ?? 0
            guard drive == 0 || drive == 1 else { throw ToolFailure("drive must be 0 or 1") }
            return .text(try context.perform { session in
                session.machine.insertDisc(nil, drive: drive)
                return "drive \(drive) empty"
            })
        },

        Tool(definition: ToolDefinition(
            name: "run_command",
            description: "Enter a line (BASIC or a * command) as if typed, fast, then run until the machine waits for input again. Returns the text the OS printed, and the screen. Use \\n in text for several lines; a final Return is added.",
            inputSchema: schema(["text": prop("string", "e.g. PRINT 6*7, CHAIN \"GAME\", *CAT"),
                                 "max_seconds": prop("number", "Longest to wait (default 30)")],
                                required: ["text"])
        )) { context, args in
            guard let text = args["text"]?.stringValue else { throw ToolFailure("text is required") }
            let maxSeconds = args["max_seconds"]?.doubleValue ?? 30
            return .text(try context.perform { session in
                let m = session.machine
                m.capturedOutput = []
                m.captureOutput = true
                defer { m.captureOutput = false }
                m.paste(text.hasSuffix("\n") ? text : text + "\n")
                let idle = runUntilIdle(session, maxSeconds: maxSeconds)
                let output = printable(m.capturedOutput)
                return summary(session, extra: "output:\n" + output + (idle ? "" : "\n(still running after \(maxSeconds)s)"))
            })
        },

        Tool(definition: ToolDefinition(
            name: "type_text",
            description: "Type text through the keyboard, key by key at a realistic speed (40ms per key, Shift as needed). Use for programs that read the keyboard directly; for commands, run_command is faster. \\n is Return. Then runs for settle_seconds.",
            inputSchema: schema(["text": prop("string", "Text to type"),
                                 "settle_seconds": prop("number", "Time to run after typing (default 0.5)")],
                                required: ["text"])
        )) { context, args in
            guard let text = args["text"]?.stringValue else { throw ToolFailure("text is required") }
            let settle = args["settle_seconds"]?.doubleValue ?? 0.5
            return .text(try context.perform { session in
                session.machine.type(text)
                _ = session.advance(until: { !session.machine.isTyping }, maxSeconds: 600)
                session.advance(seconds: settle)
                return summary(session)
            })
        },

        Tool(definition: ToolDefinition(
            name: "press_keys",
            description: "Hold keys down together, then release: e.g. [\"SHIFT\",\"F1\"], [\"CTRL\",\"G\"], [\"ESCAPE\"]. Names: RETURN SPACE SHIFT CTRL ESCAPE TAB DELETE COPY CAPSLOCK SHIFTLOCK UP DOWN LEFT RIGHT F0-F9 BREAK, or a single character.",
            inputSchema: schema(["keys": ["type": "array", "items": ["type": "string"], "description": "Key names"],
                                 "hold_seconds": prop("number", "How long to hold them (default 0.1)"),
                                 "settle_seconds": prop("number", "Time to run after release (default 0.2)")],
                                required: ["keys"])
        )) { context, args in
            guard let names = args["keys"]?.arrayValue?.compactMap(\.stringValue), !names.isEmpty else {
                throw ToolFailure("keys is required")
            }
            let keys = try names.map { name -> BeebKey in
                guard let key = BeebKey.named(name) else { throw ToolFailure("unknown key \(name)") }
                return key
            }
            let hold = args["hold_seconds"]?.doubleValue ?? 0.1
            let settle = args["settle_seconds"]?.doubleValue ?? 0.2
            return .text(try context.perform { session in
                for key in keys { session.machine.setKey(key, down: true) }
                session.advance(seconds: hold)
                for key in keys.reversed() { session.machine.setKey(key, down: false) }
                session.advance(seconds: settle)
                return summary(session)
            })
        },

        Tool(definition: ToolDefinition(
            name: "run",
            description: "Run the machine for some emulated time (seconds, or frames at 50 per second). Runs faster than real time.",
            inputSchema: schema(["seconds": prop("number", "Emulated seconds"),
                                 "frames": prop("integer", "Frames (1/50s each)")])
        )) { context, args in
            let seconds = args["seconds"]?.doubleValue ?? (args["frames"]?.doubleValue).map { $0 / 50 } ?? 1
            guard seconds >= 0 && seconds <= 3600 else { throw ToolFailure("seconds must be 0-3600") }
            return .text(try context.perform { session in
                session.advance(seconds: seconds)
                return summary(session)
            })
        },

        Tool(definition: ToolDefinition(
            name: "run_until_idle",
            description: "Run until the OS is waiting for a key (e.g. at the BASIC prompt or an INPUT), or max_seconds pass.",
            inputSchema: schema(["max_seconds": prop("number", "Longest to run (default 30)")])
        )) { context, args in
            let maxSeconds = args["max_seconds"]?.doubleValue ?? 30
            return .text(try context.perform { session in
                let idle = runUntilIdle(session, maxSeconds: maxSeconds)
                return summary(session, extra: idle ? "waiting for input" : "still running after \(maxSeconds)s")
            })
        },

        Tool(definition: ToolDefinition(
            name: "run_until_address",
            description: "Run until the CPU is about to execute the instruction at an address (e.g. \"&0E00\"), or max_seconds pass.",
            inputSchema: schema(["address": prop("string", "Address: &1900, $1900, 0x1900 or decimal"),
                                 "max_seconds": prop("number", "Longest to run (default 30)")],
                                required: ["address"])
        )) { context, args in
            guard let address = args["address"]?.intValue, (0...0xFFFF).contains(address) else {
                throw ToolFailure("address must be 0-&FFFF")
            }
            let maxSeconds = args["max_seconds"]?.doubleValue ?? 30
            return .text(try context.perform { session in
                let m = session.machine
                m.watch(address: UInt16(address))
                defer { m.watch(address: nil) }
                let reached = session.advance(until: { m.reachedWatchAddress }, maxSeconds: maxSeconds)
                return summary(session, extra: reached ? "reached &\(hex(UInt16(address), 4))" : "didn't reach &\(hex(UInt16(address), 4)) in \(maxSeconds)s")
            })
        },

        Tool(definition: ToolDefinition(
            name: "screenshot",
            description: "The screen as a PNG image (736x576; the BBC's pixels are a little narrower than square).",
            inputSchema: schema()
        )) { context, _ in
            let png = try context.perform { session -> Data? in
                Screenshot.png(session.tv)
            }
            guard let png else { throw ToolFailure("no frame yet") }
            return ToolResult(content: [.png(png)], isError: false)
        },

        Tool(definition: ToolDefinition(
            name: "read_screen_text",
            description: "The text on the screen, in any mode (bitmap modes are matched against the OS font; ? marks cells that aren't characters).",
            inputSchema: schema()
        )) { context, _ in
            .text(try context.perform { session in
                var lines = session.machine.screenText()
                while lines.last?.isEmpty == true { lines.removeLast() }
                return lines.joined(separator: "\n")
            })
        },

        Tool(definition: ToolDefinition(
            name: "peek",
            description: "Read memory (as the CPU sees it, without side effects). Returns a hex dump.",
            inputSchema: schema(["address": prop("string", "Start address: &1900, $1900, 0x1900 or decimal"),
                                 "length": prop("integer", "Bytes (default 64, max 4096)")],
                                required: ["address"])
        )) { context, args in
            guard let address = args["address"]?.intValue, (0...0xFFFF).contains(address) else {
                throw ToolFailure("address must be 0-&FFFF")
            }
            let length = min(max(args["length"]?.intValue ?? 64, 1), 4096)
            return .text(try context.perform { session in
                let bytes = (0..<length).map { session.machine.peek(UInt16(truncatingIfNeeded: address + $0)) }
                return hexDump(bytes, address: address)
            })
        },

        Tool(definition: ToolDefinition(
            name: "poke",
            description: "Write bytes to RAM (&0000-&7FFF).",
            inputSchema: schema(["address": prop("string", "Start address"),
                                 "bytes": ["type": "array", "items": ["type": "integer"], "description": "Values 0-255"]],
                                required: ["address", "bytes"])
        )) { context, args in
            guard let address = args["address"]?.intValue, (0..<0x8000).contains(address) else {
                throw ToolFailure("address must be in RAM, 0-&7FFF")
            }
            guard let bytes = args["bytes"]?.arrayValue?.compactMap(\.intValue), bytes.allSatisfy({ (0...255).contains($0) }) else {
                throw ToolFailure("bytes must be an array of 0-255")
            }
            return .text(try context.perform { session in
                session.machine.load(bytes.map { UInt8($0) }, at: UInt16(address))
                return "wrote \(bytes.count) bytes at &\(hex(UInt16(address), 4))"
            })
        },

        Tool(definition: ToolDefinition(
            name: "disassemble",
            description: "Disassemble 6502 code from an address (default: the current PC).",
            inputSchema: schema(["address": prop("string", "Start address"),
                                 "count": prop("integer", "Instructions (default 16)")])
        )) { context, args in
            let count = min(max(args["count"]?.intValue ?? 16, 1), 256)
            let start = args["address"]?.intValue
            return .text(try context.perform { session in
                let m = session.machine
                let disassembler = M6502Disassembler(variant: .nmos)
                var address = UInt16(truncatingIfNeeded: start ?? Int(m.cpu.opcodePC))
                var lines: [String] = []
                for _ in 0..<count {
                    let (text, length) = disassembler.disassemble(at: address, read: m.peek)
                    let bytes = (0..<length).map { hex(m.peek(address &+ UInt16($0))) }.joined(separator: " ")
                    lines.append("\(hex(address, 4))  \(bytes.padding(toLength: 9, withPad: " ", startingAt: 0))  \(text)")
                    address &+= UInt16(length)
                }
                return lines.joined(separator: "\n")
            })
        },

        Tool(definition: ToolDefinition(
            name: "load_program",
            description: "Load a file from a disc image straight into memory, without the disc system: BASIC at PAGE (then use run_command RUN), machine code at its load address (then CALL it).",
            inputSchema: schema(["path": prop("string", "Path to the .ssd file"),
                                 "file": prop("string", "File name on the disc, e.g. GAME or $.GAME")],
                                required: ["path", "file"])
        )) { context, args in
            guard let path = args["path"]?.stringValue, let file = args["file"]?.stringValue else {
                throw ToolFailure("path and file are required")
            }
            let bytes = [UInt8](try Data(contentsOf: URL(fileURLWithPath: (path as NSString).expandingTildeInPath)))
            return .text(try context.perform { session in
                switch session.machine.loadProgram(disc: bytes, file: file) {
                case .success(let f):
                    return "loaded \(f.fullName): \(f.length) bytes, load &\(String(f.loadAddress & 0xFFFF, radix: 16, uppercase: true)), exec &\(String(f.executionAddress & 0xFFFF, radix: 16, uppercase: true))"
                case .failure(let error):
                    throw ToolFailure("\(error)")
                }
            })
        },

        Tool(definition: ToolDefinition(
            name: "save_snapshot",
            description: "Remember the machine's exact state under a name (in memory), to come back to with restore_snapshot. Restoring continues exactly, cycle for cycle: good for trying things.",
            inputSchema: schema(["name": prop("string", "Snapshot name (default \"default\")")])
        )) { context, args in
            let name = args["name"]?.stringValue ?? "default"
            let file = try context.perform { session in SaveStateFile(session.machine) }
            slots.withLock { $0[name] = file }
            return .text("saved snapshot \"\(name)\" at t=\(String(format: "%.2f", Double(file.snapshot.cycles) / 2_000_000))s")
        },

        Tool(definition: ToolDefinition(
            name: "restore_snapshot",
            description: "Go back to a snapshot taken with save_snapshot (machine, memory and discs).",
            inputSchema: schema(["name": prop("string", "Snapshot name (default \"default\")")])
        )) { context, args in
            let name = args["name"]?.stringValue ?? "default"
            guard let file = slots.withLock({ $0[name] }) else { throw ToolFailure("no snapshot named \(name)") }
            return .text(try context.perform { session in
                session.replace(with: try file.makeMachine())
                session.advance(cycles: 0)
                return summary(session, extra: "restored \"\(name)\"")
            })
        },

        Tool(definition: ToolDefinition(
            name: "save_state",
            description: "Save the machine's exact state (including ROMs and discs) to a .beebstate file.",
            inputSchema: schema(["path": prop("string", "Output path")], required: ["path"])
        )) { context, args in
            guard let path = args["path"]?.stringValue else { throw ToolFailure("path is required") }
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            let data = try context.perform { session in try SaveStateFile(session.machine).data() }
            try data.write(to: url, options: .atomic)
            return .text("saved \(data.count) bytes to \(url.path)")
        },

        Tool(definition: ToolDefinition(
            name: "load_state",
            description: "Load a .beebstate file, replacing the machine.",
            inputSchema: schema(["path": prop("string", "Path to the .beebstate file")], required: ["path"])
        )) { context, args in
            guard let path = args["path"]?.stringValue else { throw ToolFailure("path is required") }
            let file = try SaveStateFile(data: Data(contentsOf: URL(fileURLWithPath: (path as NSString).expandingTildeInPath)))
            return .text(try context.perform { session in
                session.replace(with: try file.makeMachine())
                session.advance(cycles: 0)
                return summary(session, extra: "loaded state from \(file.created)")
            })
        },

        Tool(definition: ToolDefinition(
            name: "start_recording",
            description: "Start recording video and sound to a movie file (.mp4 is H.264; .mov is ProRes). Time is emulated time, so recordings play at the right speed even though emulation runs faster.",
            inputSchema: schema(["path": prop("string", "Output file path")], required: ["path"])
        )) { context, args in
            guard let path = args["path"]?.stringValue else { throw ToolFailure("path is required") }
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            let codec: VideoRecorder.Codec = url.pathExtension.lowercased() == "mov" ? .proRes : .h264
            return .text(try context.perform { session in
                try session.startRecording(to: url, codec: codec)
                return "recording to \(url.path)"
            })
        },

        Tool(definition: ToolDefinition(
            name: "stop_recording",
            description: "Stop recording and finish the movie file.",
            inputSchema: schema()
        )) { context, _ in
            .text(try context.perform { session in
                guard session.isRecording else { return "not recording" }
                try session.stopRecording()
                return "recording finished"
            })
        },
    ]

    // MARK: Helpers

    /// Runs through the session (so recording and the display keep up)
    /// until the OS waits for a key.
    @discardableResult
    static func runUntilIdle(_ session: MachineSession, maxSeconds: Double) -> Bool {
        let m = session.machine
        m.watchForIdle(true)
        let idle = session.advance(until: { m.reachedIdle }, maxSeconds: maxSeconds)
        m.watchForIdle(false)
        if idle {
            session.advance(seconds: 0.01)
        }
        return idle
    }

    static func printable(_ bytes: [UInt8]) -> String {
        var text = ""
        for byte in bytes {
            switch byte {
            case 13: text.append("\n")
            case 10: break
            case 32..<127: text.append(Character(UnicodeScalar(byte)))
            default: break
            }
        }
        return text
    }

    static func catalogueText(_ bytes: [UInt8], doubleSided: Bool) -> String {
        guard let sides = try? DFSDisc.sides(ofImage: bytes, doubleSided: doubleSided) else {
            return "(not a DFS disc)"
        }
        return sides.enumerated().map { index, side in
            let options = ["off", "*LOAD", "*RUN", "*EXEC"][side.bootOption]
            let files = side.files.map { file in
                "  \(file.fullName.padding(toLength: 10, withPad: " ", startingAt: 0)) load &\(String(file.loadAddress & 0xFFFF, radix: 16, uppercase: true)) exec &\(String(file.executionAddress & 0xFFFF, radix: 16, uppercase: true)) \(file.length) bytes"
            }
            return "side \(index): \"\(side.title)\", boot \(options)\n" + files.joined(separator: "\n")
        }.joined(separator: "\n")
    }

    static func hexDump(_ bytes: [UInt8], address: Int) -> String {
        stride(from: 0, to: bytes.count, by: 16).map { offset in
            let row = bytes[offset..<min(offset + 16, bytes.count)]
            let hexBytes = row.map { hex($0) }.joined(separator: " ")
            let ascii = String(row.map { $0 >= 32 && $0 < 127 ? Character(UnicodeScalar($0)) : "." })
            return "\(hex(UInt16(truncatingIfNeeded: address + offset), 4))  \(hexBytes.padding(toLength: 47, withPad: " ", startingAt: 0))  \(ascii)"
        }.joined(separator: "\n")
    }
}

func hex(_ value: UInt8) -> String { hex(UInt16(value), 2) }

func hex(_ value: UInt16, _ width: Int) -> String {
    let digits = String(value, radix: 16, uppercase: true)
    return String(repeating: "0", count: max(0, width - digits.count)) + digits
}
