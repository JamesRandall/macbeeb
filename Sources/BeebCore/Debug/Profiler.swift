// Where the time goes: cycles per instruction address (stretched cycles
// included), how often each ran, time in interrupt handlers, and frames,
// for each CPU.

public struct ProfileReport: Sendable {
    public struct Entry: Sendable, Identifiable {
        public var address: UInt16
        public var cycles: Int
        public var executions: Int
        public var id: UInt16 { address }
    }

    public struct Routine: Sendable, Identifiable {
        /// A symbol, or "&XX00 page" where there's none.
        public var name: String
        public var cycles: Int
        public var id: String { name }
    }

    public var cpu: DebugCPU
    public var totalCycles: Int
    public var interruptCycles: Int
    /// Frames (vsyncs) seen while profiling.
    public var frames: Int
    /// The busiest instructions, most cycles first.
    public var hottest: [Entry]
    public var routines: [Routine]
    /// Cycles at every address, for heat maps.
    public var cyclesByAddress: [UInt16: Int]

    public var cyclesPerFrame: Double { frames > 0 ? Double(totalCycles) / Double(frames) : 0 }
}

final class Profiler {
    private(set) var hostCycles = [UInt32](repeating: 0, count: 0x10000)
    private(set) var hostExecutions = [UInt32](repeating: 0, count: 0x10000)
    private(set) var parasiteCycles = [UInt32](repeating: 0, count: 0x10000)
    private(set) var parasiteExecutions = [UInt32](repeating: 0, count: 0x10000)
    // Per CPU: 0 the host, 1 the second processor.
    private var totals = [0, 0]
    private var interrupt = [0, 0]
    private var interruptDepth = [0, 0]
    private var lastOpcode: [UInt8?] = [nil, nil]
    private(set) var frames = 0

    /// A cycle of `cpu`, in the instruction at `pc`.
    @inline(__always)
    func cycle(_ cpu: DebugCPU, pc: UInt16) {
        let i = cpu == .host ? 0 : 1
        if i == 0 {
            hostCycles[Int(pc)] &+= 1
        } else {
            parasiteCycles[Int(pc)] &+= 1
        }
        totals[i] += 1
        if interruptDepth[i] > 0 {
            interrupt[i] += 1
        }
    }

    /// An opcode fetch (or, `interrupt`, a fetch dropped for an interrupt).
    func fetch(_ cpu: DebugCPU, _ address: UInt16, opcode: UInt8, interrupt starting: Bool) {
        let i = cpu == .host ? 0 : 1
        // The instruction before was an RTI: out of a handler.
        if lastOpcode[i] == 0x40 && interruptDepth[i] > 0 {
            interruptDepth[i] -= 1
        }
        if starting {
            interruptDepth[i] += 1
            lastOpcode[i] = nil
            return
        }
        lastOpcode[i] = opcode
        if i == 0 {
            hostExecutions[Int(address)] &+= 1
        } else {
            parasiteExecutions[Int(address)] &+= 1
        }
    }

    func frame() {
        frames += 1
    }

    func report(_ cpu: DebugCPU, symbols: SymbolTable, top: Int = 40) -> ProfileReport {
        let cycles = cpu == .host ? hostCycles : parasiteCycles
        let executions = cpu == .host ? hostExecutions : parasiteExecutions
        var byAddress: [UInt16: Int] = [:]
        var entries: [ProfileReport.Entry] = []
        var routines: [String: Int] = [:]
        for address in 0..<0x10000 where cycles[address] > 0 {
            let a = UInt16(address)
            let n = Int(cycles[address])
            byAddress[a] = n
            entries.append(ProfileReport.Entry(address: a, cycles: n, executions: Int(executions[address])))
            let routine = symbols.nearest(below: a)?.name ?? "&" + String(format: "%02X", address >> 8) + "00 page"
            routines[routine, default: 0] += n
        }
        entries.sort { $0.cycles > $1.cycles }
        let i = cpu == .host ? 0 : 1
        return ProfileReport(cpu: cpu, totalCycles: totals[i], interruptCycles: interrupt[i],
                             frames: frames, hottest: Array(entries.prefix(top)),
                             routines: routines.map { ProfileReport.Routine(name: $0.key, cycles: $0.value) }.sorted { $0.cycles > $1.cycles },
                             cyclesByAddress: byAddress)
    }
}

extension Debugger {
    /// Starts profiling (from zero).
    public func startProfiling() {
        profiler = Profiler()
        profilingActive = true
        updateHooks()
    }

    /// Stops profiling; the results stay until the next start.
    public func stopProfiling() {
        profilingActive = false
        updateHooks()
    }

    public var isProfiling: Bool { profiler != nil && profilingActive }

    /// What's been profiled so far (nil if never started).
    public func profileReport(_ cpu: DebugCPU = .host, top: Int = 40) -> ProfileReport? {
        profiler?.report(cpu, symbols: symbols(cpu), top: top)
    }
}
