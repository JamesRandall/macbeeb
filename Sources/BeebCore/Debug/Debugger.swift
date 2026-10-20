// Breakpoints, stepping and tracing, for the host CPU and the second
// processor.
//
// The machine calls in only while something is set (breakpoints, a step in
// progress, tracing), so an idle debugger costs one test per cycle. Stops
// happen on the exact cycle: for an execute breakpoint, the cycle the
// opcode is fetched, so the CPU is about to execute it; for a read or
// write, the cycle of the access, mid-instruction.
//
// A stop is sticky: the machine won't run again until `resume()`.

public enum DebugCPU: String, CaseIterable, Codable, Sendable {
    case host
    case parasite
}

public struct Breakpoint: Codable, Sendable, Equatable, Identifiable {
    public struct Kind: OptionSet, Codable, Sendable, Hashable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let execute = Kind(rawValue: 1)
        public static let read = Kind(rawValue: 2)
        public static let write = Kind(rawValue: 4)
        public static let access: Kind = [.read, .write]
    }

    public var id: Int
    public var cpu: DebugCPU
    public var kind: Kind
    public var start: UInt16
    public var end: UInt16
    /// Host only: only while this sideways bank is paged in at &8000-&BFFF.
    public var romBank: Int?
    /// Only stop (or log) when this expression is true.
    public var condition: String?
    /// Only stop once hit this many times.
    public var hitTarget: Int?
    /// Log this (with {expression} replaced by its value) instead of
    /// stopping.
    public var logMessage: String?
    public var enabled = true
    public var hitCount = 0

    public init(id: Int = 0, cpu: DebugCPU = .host, kind: Kind = .execute, start: UInt16, end: UInt16? = nil,
                romBank: Int? = nil, condition: String? = nil, hitTarget: Int? = nil, logMessage: String? = nil) {
        self.id = id
        self.cpu = cpu
        self.kind = kind
        self.start = start
        self.end = end ?? start
        self.romBank = romBank
        self.condition = condition
        self.hitTarget = hitTarget
        self.logMessage = logMessage
    }

    func covers(_ address: UInt16) -> Bool {
        start <= end ? (start...end).contains(address) : address >= start || address <= end
    }
}

public enum StopReason: Equatable, Sendable, CustomStringConvertible {
    case breakpoint(id: Int, cpu: DebugCPU, address: UInt16, kind: Breakpoint.Kind)
    /// A step finished.
    case stepped(DebugCPU)
    case frame
    case scanline
    /// An interrupt (or reset) sequence is about to start.
    case interrupt(DebugCPU)
    /// Stopped on request (e.g. Pause in the debugger).
    case requested
    /// Went back as far as the rewind history goes.
    case historyStart

    public var description: String {
        switch self {
        case .breakpoint(let id, let cpu, let address, let kind):
            let what = kind == .execute ? "execute" : kind == .read ? "read" : "write"
            return "breakpoint \(id) (\(what) &\(Self.hex(address))) on the \(cpu.rawValue)"
        case .stepped(let cpu): return "step finished on the \(cpu.rawValue)"
        case .frame: return "start of frame"
        case .scanline: return "start of scanline"
        case .interrupt(let cpu): return "interrupt on the \(cpu.rawValue)"
        case .requested: return "stopped"
        case .historyStart: return "reached the start of the rewind history"
        }
    }

    static func hex(_ value: UInt16) -> String {
        let digits = String(value, radix: 16, uppercase: true)
        return String(repeating: "0", count: max(0, 4 - digits.count)) + digits
    }
}

/// What the debugger can do with the machine.
public enum RunCommand: Equatable, Sendable {
    /// Run until a breakpoint (or the time limit).
    case `continue`
    /// To the next instruction.
    case stepInstruction
    /// Over a JSR (to the instruction after it); otherwise as
    /// `stepInstruction`.
    case stepOver
    /// Until the current subroutine (or interrupt handler) returns.
    case stepOut
    /// One 2MHz host cycle.
    case stepCycle
    case runToAddress(UInt16)
    case nextScanline
    case nextFrame
    case nextInterrupt
}

public struct TraceEntry: Sendable, Equatable {
    public var cycle: UInt64
    public var pc: UInt16
    public var a: UInt8
    public var x: UInt8
    public var y: UInt8
    public var s: UInt8
    public var p: UInt8
    /// The instruction's bytes when it ran.
    public var bytes: (UInt8, UInt8, UInt8)
    /// True for an interrupt starting (the fetch at `pc` was discarded).
    public var interrupt: Bool

    public static func == (l: TraceEntry, r: TraceEntry) -> Bool {
        l.cycle == r.cycle && l.pc == r.pc && l.a == r.a && l.x == r.x && l.y == r.y && l.s == r.s && l.p == r.p
            && l.bytes == r.bytes && l.interrupt == r.interrupt
    }
}

/// The last `capacity` instructions.
public struct TraceBuffer: Sendable {
    public let capacity: Int
    private var entries: [TraceEntry] = []
    private var next = 0

    public init(capacity: Int) {
        self.capacity = capacity
        entries.reserveCapacity(capacity)
    }

    mutating func append(_ entry: TraceEntry) {
        if entries.count < capacity {
            entries.append(entry)
        } else {
            entries[next] = entry
        }
        next = (next + 1) % capacity
    }

    /// The newest `count` entries, oldest first.
    public func last(_ count: Int) -> [TraceEntry] {
        let n = min(count, entries.count)
        if entries.count < capacity {
            return Array(entries.suffix(n))
        }
        return (0..<n).map { entries[(next - n + $0 + capacity) % capacity] }
    }

    public var count: Int { entries.count }

    mutating func removeAll() {
        entries.removeAll(keepingCapacity: true)
        next = 0
    }
}

public struct DebugLogEntry: Sendable, Equatable {
    public var cycle: UInt64
    public var cpu: DebugCPU
    public var text: String
}

public final class Debugger {
    unowned let machine: BBCMicro

    public private(set) var breakpoints: [Breakpoint] = []
    private var nextBreakpointID = 1
    var conditions: [Int: DebugExpression] = [:]
    /// Per CPU, per address: the breakpoint kinds set there.
    var hostFlags = [UInt8](repeating: 0, count: 0x10000)
    var parasiteFlags = [UInt8](repeating: 0, count: 0x10000)

    public private(set) var stopReason: StopReason?
    /// Counts stops, so two in a row for the same reason can be told apart.
    public private(set) var stopCount = 0
    private var command: RunCommand?
    private var commandCPU = DebugCPU.host
    private var stepTarget: UInt16 = 0
    private var stepStack: UInt8 = 0

    /// Opcode fetches seen per CPU (while the hooks are on), and the
    /// instruction a data breakpoint last stopped in: read-modify-write
    /// instructions write twice, but one stop per instruction is enough.
    private var fetches: [DebugCPU: Int] = [:]
    private var lastDataStop: (cpu: DebugCPU, address: UInt16, fetch: Int)?

    /// Log points' output, oldest first.
    public private(set) var log: [DebugLogEntry] = []
    public static let logLimit = 1000
    /// Symbols and source lines, per CPU (the OS's and hardware's built
    /// in).
    public private(set) lazy var hostSymbols = SymbolTable.builtIn(model: machine.model, cpu: .host)
    public private(set) lazy var parasiteSymbols = SymbolTable.builtIn(model: machine.model, cpu: .parasite)

    public func symbols(_ cpu: DebugCPU) -> SymbolTable {
        cpu == .host ? hostSymbols : parasiteSymbols
    }

    /// Adds symbols (e.g. from `SymbolTable.load(path:)`) for code on `cpu`.
    public func addSymbols(_ table: SymbolTable, cpu: DebugCPU = .host) {
        if cpu == .host {
            hostSymbols.merge(table)
        } else {
            parasiteSymbols.merge(table)
        }
    }

    /// Back to just the built-in symbols.
    public func clearSymbols() {
        hostSymbols = SymbolTable.builtIn(model: machine.model, cpu: .host)
        parasiteSymbols = SymbolTable.builtIn(model: machine.model, cpu: .parasite)
    }

    public private(set) var hostTrace = TraceBuffer(capacity: 1)
    public private(set) var parasiteTrace = TraceBuffer(capacity: 1)
    public private(set) var tracing = false

    init(machine: BBCMicro) {
        self.machine = machine
    }

    // MARK: Breakpoints

    /// Adds a breakpoint; returns it with its ID. Throws if its condition
    /// doesn't parse.
    @discardableResult
    public func add(_ breakpoint: Breakpoint) throws(DebugExpression.ParseError) -> Breakpoint {
        var b = breakpoint
        b.id = nextBreakpointID
        b.hitCount = 0
        if let condition = b.condition {
            conditions[b.id] = try DebugExpression(condition)
        }
        nextBreakpointID += 1
        breakpoints.append(b)
        updateFlags()
        return b
    }

    /// Replaces a breakpoint (same ID), keeping its hit count.
    public func update(_ breakpoint: Breakpoint) throws(DebugExpression.ParseError) {
        guard let index = breakpoints.firstIndex(where: { $0.id == breakpoint.id }) else { return }
        conditions[breakpoint.id] = try breakpoint.condition.map { (c) throws(DebugExpression.ParseError) in try DebugExpression(c) }
        var b = breakpoint
        b.hitCount = breakpoints[index].hitCount
        breakpoints[index] = b
        updateFlags()
    }

    public func remove(id: Int) {
        breakpoints.removeAll { $0.id == id }
        conditions[id] = nil
        updateFlags()
    }

    public func removeAllBreakpoints() {
        breakpoints = []
        conditions = [:]
        updateFlags()
    }

    private func updateFlags() {
        hostFlags = [UInt8](repeating: 0, count: 0x10000)
        parasiteFlags = [UInt8](repeating: 0, count: 0x10000)
        for b in breakpoints where b.enabled {
            var address = b.start
            while true {
                if b.cpu == .host {
                    hostFlags[Int(address)] |= b.kind.rawValue
                } else {
                    parasiteFlags[Int(address)] |= b.kind.rawValue
                }
                if address == b.end { break }
                address &+= 1
            }
        }
        updateHooks()
    }

    var profiler: Profiler? {
        didSet { profilingActive = profiler != nil }
    }
    var profilingActive = false

    /// Forces the hooks on (for searching history).
    var forceHooks = false {
        didSet { updateHooks() }
    }

    func updateHooks() {
        let any = breakpoints.contains { $0.enabled } || command != nil || tracing || forceHooks || profilingActive
        machine.debugHooks = any
        machine.debugVideoHooks = command == .nextFrame || command == .nextScanline || profilingActive
        machine.secondProcessor?.debugger = any ? self : nil
    }

    // MARK: Running

    /// Clears the stop, so the machine can run.
    public func resume() {
        stopReason = nil
        machine.stopRequested = false
    }

    /// Stops the machine at the end of the current cycle.
    public func requestStop() {
        stop(.requested)
    }

    /// Starts `command` on `cpu` and returns at once: the machine stops
    /// when it's done, as it runs normally. (`.stepCycle` isn't
    /// supported: run one cycle instead.)
    public func begin(_ command: RunCommand, cpu: DebugCPU = .host) {
        precondition(command != .stepCycle)
        resume()
        arm(command, cpu: cpu)
    }

    /// Whether a command from `begin` is still running.
    public var isRunningCommand: Bool { command != nil }

    /// Runs `command` on `cpu`, using `advance` to run the machine (so
    /// recording and the display keep up), for at most `maxCycles`. Returns
    /// why it stopped, or nil if the time ran out.
    @discardableResult
    public func run(_ command: RunCommand, cpu: DebugCPU = .host, maxCycles: Int,
                    advance: (Int) -> Void) -> StopReason? {
        resume()
        arm(command, cpu: cpu)
        defer { disarm() }
        if command == .stepCycle {
            advance(1)
            if stopReason == nil {
                stop(.stepped(cpu))
            }
            return stopReason
        }
        var remaining = maxCycles
        while stopReason == nil && remaining > 0 {
            let before = machine.cycles
            advance(min(remaining, 20_000))
            let ran = Int(machine.cycles - before)
            remaining -= max(ran, 1)
        }
        return stopReason
    }

    private func arm(_ command: RunCommand, cpu: DebugCPU) {
        self.command = command == .continue ? nil : command
        commandCPU = cpu
        guard let target = machine.debugCPU(cpu) else { return }
        let pc = machine.instructionAddress(cpu)
        stepStack = target.s
        switch command {
        case .stepOver:
            // JSR: run to the instruction after it, at the same stack depth.
            if machine.debugRead(.cpu(cpu), Int(pc)) == 0x20 {
                stepTarget = pc &+ 3
            } else {
                self.command = .stepInstruction
            }
        case .runToAddress(let address):
            stepTarget = address
        default:
            break
        }
        updateHooks()
    }

    private func disarm() {
        command = nil
        updateHooks()
    }

    func stop(_ reason: StopReason) {
        guard stopReason == nil else { return }
        stopReason = reason
        stopCount += 1
        machine.stopRequested = true
        // Whatever was running is done.
        if command != nil {
            command = nil
            updateHooks()
        }
    }

    // MARK: Tracing

    /// Starts (or with 0, stops) recording the last `capacity` instructions
    /// of each CPU.
    public func setTracing(capacity: Int) {
        tracing = capacity > 0
        hostTrace = TraceBuffer(capacity: max(capacity, 1))
        parasiteTrace = TraceBuffer(capacity: max(capacity, 1))
        updateHooks()
    }

    public func trace(_ cpu: DebugCPU) -> TraceBuffer {
        cpu == .host ? hostTrace : parasiteTrace
    }

    // MARK: Expressions

    /// The context expressions on `cpu` are evaluated in.
    public func expressionContext(_ cpu: DebugCPU) -> DebugExpression.Context {
        let machine = self.machine
        let table = symbols(cpu)
        return DebugExpression.Context(
            register: { name in machine.register(name, cpu: cpu) },
            readByte: { machine.debugRead(.cpu(cpu), Int($0)) ?? 0xFF },
            symbol: { table.address(of: $0) })
    }

    /// Replaces each {expression} in `text` with its value.
    public func interpolate(_ text: String, cpu: DebugCPU) -> String {
        var result = ""
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "{"), let close = rest[open...].firstIndex(of: "}") {
            result += rest[..<open]
            let source = String(rest[rest.index(after: open)..<close])
            if let expression = try? DebugExpression(source),
               let value = try? expression.evaluate(expressionContext(cpu)) {
                result += value >= 0 && value < 0x100 ? "&\(String(value, radix: 16, uppercase: true))" : "\(value)"
            } else {
                result += "{\(source)?}"
            }
            rest = rest[rest.index(after: close)...]
        }
        return result + rest
    }

    // MARK: Hooks

    /// While rewinding, sees accesses instead of the breakpoints.
    var replayObserver: ((DebugCPU, UInt16, M6502.BusAccess) -> Void)?

    /// Every host cycle, while the hooks are on.
    @inline(__always)
    func hostCycle() {
        if profilingActive, machine.rewinder?.isReplaying != true {
            profiler!.cycle(.host, pc: machine.cpu.opcodePC)
        }
    }

    @inline(never)
    func hostAccessed(_ address: UInt16, _ access: M6502.BusAccess) {
        if machine.rewinder?.isReplaying == true {
            replayObserver?(.host, address, access)
            return
        }
        accessed(.host, address, access, flags: hostFlags[Int(address)])
    }

    @inline(never)
    func parasiteAccessed(_ address: UInt16, _ access: M6502.BusAccess) {
        if machine.rewinder?.isReplaying == true {
            replayObserver?(.parasite, address, access)
            return
        }
        if profilingActive, let p = machine.secondProcessor {
            profiler!.cycle(.parasite, pc: p.cpu.opcodePC)
        }
        accessed(.parasite, address, access, flags: parasiteFlags[Int(address)])
    }

    private func accessed(_ cpu: DebugCPU, _ address: UInt16, _ access: M6502.BusAccess, flags: UInt8) {
        let kind: Breakpoint.Kind
        switch access {
        case .opcode:
            kind = .execute
            if profilingActive, let c = machine.debugCPU(cpu) {
                profiler!.fetch(cpu, address, opcode: c.dbus, interrupt: false)
            }
        case .interrupt:
            if profilingActive {
                profiler!.fetch(cpu, address, opcode: 0, interrupt: true)
            }
            if tracing { record(cpu, address, interrupt: true) }
            if command == .nextInterrupt && commandCPU == cpu {
                stop(.interrupt(cpu))
            }
            return
        case .write: kind = .write
        case .data, .address: kind = .read
        default: return
        }

        if kind == .execute {
            fetches[cpu, default: 0] += 1
            if tracing { record(cpu, address, interrupt: false) }
            if let command, commandCPU == cpu, let target = machine.debugCPU(cpu) {
                switch command {
                case .stepInstruction:
                    stop(.stepped(cpu))
                case .stepOver:
                    if address == stepTarget && target.s >= stepStack { stop(.stepped(cpu)) }
                case .stepOut:
                    if target.s > stepStack { stop(.stepped(cpu)) }
                case .runToAddress:
                    if address == stepTarget { stop(.stepped(cpu)) }
                default:
                    break
                }
            }
        }

        guard flags & kind.rawValue != 0 else { return }
        if kind != .execute, let last = lastDataStop, last.cpu == cpu, last.address == address,
           last.fetch == fetches[cpu, default: 0] {
            return
        }
        for index in matchingBreakpoints(cpu, address, kind) {
            breakpoints[index].hitCount += 1
            let b = breakpoints[index]
            if let target = b.hitTarget, b.hitCount < target { continue }
            if let message = b.logMessage {
                log.append(DebugLogEntry(cycle: machine.cycles, cpu: cpu, text: interpolate(message, cpu: cpu)))
                if log.count > Self.logLimit { log.removeFirst(log.count - Self.logLimit) }
                continue
            }
            if kind != .execute {
                lastDataStop = (cpu, address, fetches[cpu, default: 0])
            }
            stop(.breakpoint(id: b.id, cpu: cpu, address: address, kind: kind))
            return
        }
    }

    /// The enabled breakpoints matching an access, with their conditions
    /// true (hit counts aren't touched).
    func matchingBreakpoints(_ cpu: DebugCPU, _ address: UInt16, _ kind: Breakpoint.Kind) -> [Int] {
        var matches: [Int] = []
        for index in breakpoints.indices {
            let b = breakpoints[index]
            guard b.enabled, b.cpu == cpu, b.kind.contains(kind), b.covers(address) else { continue }
            if let bank = b.romBank, cpu == .host {
                guard address >= 0x8000 && address < 0xC000 && Int(machine.romsel & 0x0F) == bank else { continue }
            }
            if let condition = conditions[b.id] {
                guard (try? condition.isTrue(expressionContext(cpu))) == true else { continue }
            }
            matches.append(index)
        }
        return matches
    }

    func video(_ output: CRTC6845.Output, last: CRTC6845.Output) {
        if machine.rewinder?.isReplaying == true { return }
        if profilingActive && output.vsync && !last.vsync {
            profiler!.frame()
        }
        if command == .nextFrame && output.vsync && !last.vsync {
            stop(.frame)
        } else if command == .nextScanline && output.hsync && !last.hsync {
            stop(.scanline)
        }
    }

    private func record(_ cpu: DebugCPU, _ address: UInt16, interrupt: Bool) {
        guard let c = machine.debugCPU(cpu) else { return }
        let read = { (a: UInt16) in self.machine.debugRead(.cpu(cpu), Int(a)) ?? 0xFF }
        let entry = TraceEntry(cycle: machine.cycles, pc: address, a: c.a, x: c.x, y: c.y, s: c.s, p: c.p,
                               bytes: (read(address), read(address &+ 1), read(address &+ 2)),
                               interrupt: interrupt)
        if cpu == .host {
            hostTrace.append(entry)
        } else {
            parasiteTrace.append(entry)
        }
    }
}
