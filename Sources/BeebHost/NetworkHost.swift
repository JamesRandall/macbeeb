import BeebCore
import BeebPrint
import Foundation
import Synchronization

/// Runs a network's machines together on one thread, in lockstep: every
/// station runs to the same point in emulated time before any goes further,
/// so none can get ahead of another and miss what it sends. Each station is
/// an `EmulatorHost` without a thread of its own, so windows, debuggers and
/// agents use it just as they use a standalone machine's.
public final class NetworkHost: @unchecked Sendable {
    /// What the network's thread is told to do.
    enum Command {
        case add(UUID, EmulatorHost)
        case remove(UUID)
        /// The Econet's clock rate (bits a second), or nil for none.
        case setClock(Int?)
    }

    /// The network's state as of its last quantum.
    public struct Status: Sendable, Equatable {
        /// Emulated 2MHz cycles since the network started.
        public var cycles: UInt64 = 0
        /// Emulated time against wall time over the last second or so (1 is
        /// real time).
        public var speed: Double = 0
        /// The whole network is paused, by the user or a debugger stop.
        public var paused = false
        /// The stations stopped by their debuggers.
        public var stoppedStations: Set<UUID> = []
        /// What each Econet station has put on the line, by station number.
        public var traffic: [UInt8: Traffic] = [:]

        public init() {}
    }

    /// A station's transmissions so far.
    public struct Traffic: Sendable, Equatable {
        public var bytes = 0
        /// Each frame ends with two check bytes.
        var checkBytes = 0
        public var frames: Int { checkBytes / 2 }
        /// Byte-times spoiled by collisions.
        public var collisions = 0
    }

    public let sampleRate: Int
    private let commands = Mutex<[Command]>([])
    private let pausedFlag = Atomic<Bool>(false)
    private let speedLimitedFlag = Atomic<Bool>(true)
    private let pauseOnBreakpointFlag = Atomic<Bool>(true)
    private let running = Atomic<Bool>(true)
    private let latestStatus = Mutex(Status())
    /// The station whose sound is heard, which paces the network while
    /// it plays.
    private let audioStation = Mutex<UUID?>(nil)
    private var thread: Thread?

    /// Emulated cycles each station runs before the others catch up:
    /// short enough, with an Econet, for the line's timing.
    public let quantum: Int
    /// The network's Econet, if its machines have one. Used only on the
    /// network's thread.
    let bus: EconetBus?
    /// Sees every symbol on the line (on the network's thread).
    public var lineObserver: ((EconetLineEvent) -> Void)?
    private var traffic: [UInt8: Traffic] = [:]

    /// The frames on the line, as the inspector and agents read them.
    private let trace = EconetTrace()
    private let traceLock = NSLock()

    /// Frames after `id` (all kept, if nil), newest last.
    public func frames(after id: Int? = nil, limit: Int = .max) -> [EconetFrame] {
        traceLock.withLock { trace.frames(after: id, limit: limit) }
    }

    /// Frames seen since the trace began (including any no longer kept).
    public var frameCount: Int { traceLock.withLock { trace.count } }

    public var isTracing: Bool { traceLock.withLock { trace.recording } }

    public func setTracing(_ on: Bool) {
        traceLock.withLock { trace.recording = on }
    }

    public func clearTrace() {
        traceLock.withLock { trace.clear() }
    }

    private func observe(_ event: EconetLineEvent) {
        traceLock.withLock { trace.observe(event) }
        switch event.symbol {
        case .byte: traffic[event.station, default: Traffic()].bytes += 1
        case .check: traffic[event.station, default: Traffic()].checkBytes += 1
        default: break
        }
        if event.collided {
            traffic[event.station, default: Traffic()].collisions += 1
        }
        lineObserver?(event)
    }

    public init(sampleRate: Int = 48_000, quantum: Int = 2_000, econetClockRate: Int?? = nil) {
        self.sampleRate = sampleRate
        if let clock = econetClockRate {
            let bus = EconetBus(clockRate: clock)
            self.bus = bus
            self.quantum = bus.delay
        } else {
            bus = nil
            self.quantum = quantum
        }
        bus?.observer = { [unowned self] event in observe(event) }
    }

    /// Changes the Econet's clock (nil takes it away).
    public func setClock(_ rate: Int?) {
        commands.withLock { $0.append(.setClock(rate)) }
    }

    deinit {
        stop()
    }

    /// A new station, run by this network from its next quantum. Don't
    /// `start` it: the network runs it.
    public func addStation(id: UUID, discDriveSounds: (@Sendable (BBCMicro.Model) -> DiscDriveSounds?)? = nil,
                           discDriveSoundsOn: Bool = true, keepsRewind: Bool = false,
                           printer: (name: String, jobs: @Sendable (PrintJob) -> Void)? = nil,
                           makeMachine: @escaping @Sendable () -> BBCMicro) -> EmulatorHost {
        let host = EmulatorHost(sampleRate: sampleRate, discDriveSounds: discDriveSounds,
                                discDriveSoundsOn: discDriveSoundsOn, makeMachine: makeMachine)
        if let printer {
            host.printerName = printer.name
            host.printJobs = printer.jobs
        }
        host.isNetworkStation = true
        host.network = self
        host.keepsRewind = keepsRewind
        commands.withLock { $0.append(.add(id, host)) }
        return host
    }

    /// Takes a station off the network: it stops running.
    public func removeStation(id: UUID) {
        commands.withLock { $0.append(.remove(id)) }
    }

    public func start() {
        guard thread == nil else { return }
        let thread = Thread { [unowned self] in self.threadMain() }
        thread.name = "BBC Micro network"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
    }

    public func stop() {
        running.store(false, ordering: .releasing)
    }

    /// Pauses every station together: no emulated time passes anywhere,
    /// so nothing on the network times out.
    public func setPaused(_ paused: Bool) {
        pausedFlag.store(paused, ordering: .releasing)
    }

    public var isPaused: Bool { pausedFlag.load(ordering: .acquiring) }

    /// Real time (true), or as fast as the Mac can go.
    public func setSpeedLimited(_ limited: Bool) {
        speedLimitedFlag.store(limited, ordering: .releasing)
    }

    /// Whether a debugger stop on one station pauses the whole network (the
    /// default), or lets the others run on and perhaps time out.
    public func setPauseOnBreakpoint(_ on: Bool) {
        pauseOnBreakpointFlag.store(on, ordering: .releasing)
    }

    public var pausesOnBreakpoint: Bool { pauseOnBreakpointFlag.load(ordering: .acquiring) }

    /// The station whose sound is playing (its audio output is active), or
    /// nil.
    public func setAudioStation(_ id: UUID?) {
        audioStation.withLock { $0 = id }
    }

    public var status: Status {
        latestStatus.withLock { $0 }
    }

    // MARK: The network's thread

    /// The stations, in the order they run: by ID, so runs repeat.
    private var stations: [(id: UUID, host: EmulatorHost)] = []
    private var networkCycles: UInt64 = 0
    /// The machine each station has on the line (a power cycle makes a new
    /// one).
    private var attached: [UUID: BBCMicro] = [:]

    private func runCommands() {
        for command in commands.withLock({ list -> [Command] in
            defer { list.removeAll() }
            return list
        }) {
            switch command {
            case .add(let id, let host):
                stations.removeAll { $0.id == id }
                stations.append((id, host))
                stations.sort { $0.id.uuidString < $1.id.uuidString }
                _ = host.drivingSession()
            case .remove(let id):
                if let station = stations.first(where: { $0.id == id }), let machine = attached[id] {
                    bus?.detach(machine)
                    attached[id] = nil
                    _ = station
                }
                stations.removeAll { $0.id == id }
            case .setClock(let rate):
                bus?.clockRate = rate
            }
        }
    }

    /// Runs one quantum: every station that's ready runs `quantum` cycles,
    /// in turn. Returns whether anything ran. `caller`: a station whose
    /// tool asked for time, which runs (with the network) even if it's held
    /// or the network's paused.
    @discardableResult
    func runQuantum(caller: EmulatorHost? = nil) -> Bool {
        runCommands()
        var ready: [EmulatorHost] = []
        var stopped: Set<UUID> = []
        for station in stations {
            if station.host !== caller {
                station.host.runCommands()
            }
            if station.host === caller || station.host.readyToRun() {
                ready.append(station.host)
            } else if station.host.debugStop != nil {
                stopped.insert(station.id)
            }
        }
        let paused = (caller == nil && isPaused) || (!stopped.isEmpty && pausesOnBreakpoint)
        latestStatus.withLock {
            $0.paused = paused
            $0.stoppedStations = stopped
        }
        guard !paused else { return false }
        if let bus {
            for station in stations {
                let machine = station.host.drivingSession().machine
                if attached[station.id] !== machine {
                    if let old = attached[station.id] { bus.detach(old) }
                    bus.attach(machine)
                    attached[station.id] = machine
                }
            }
            let running = Set(ready.compactMap { $0.drivingSession().machine.econet }.map(ObjectIdentifier.init))
            bus.beginQuantum { running.contains(ObjectIdentifier($0)) }
        }
        for host in ready {
            host.drivingSession().step(cycles: quantum)
        }
        bus?.endQuantum(cycles: quantum)
        networkCycles += UInt64(quantum)
        return true
    }

    private func threadMain() {
        let clock = ContinuousClock()
        var wallStart = clock.now
        var wallStartCycles = networkCycles
        // For the speed reading.
        var sampleStart = clock.now
        var sampleCycles = networkCycles
        let audioTarget = sampleRate * 40 / 1000

        func resetWallClock() {
            wallStart = clock.now
            wallStartCycles = networkCycles
        }

        var trafficPublished = clock.now
        while running.load(ordering: .acquiring) {
            let now = clock.now
            if now - trafficPublished >= .milliseconds(100) {
                trafficPublished = now
                let traffic = traffic
                latestStatus.withLock { $0.traffic = traffic }
            }
            if now - sampleStart >= .seconds(1) {
                let elapsed = now - sampleStart
                let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                let speed = Double(networkCycles - sampleCycles) / 2e6 / seconds
                latestStatus.withLock {
                    $0.speed = speed
                    $0.cycles = networkCycles
                }
                sampleStart = now
                sampleCycles = networkCycles
            }

            // Pace: by the heard station's sound while it plays, else by the
            // wall clock.
            if speedLimitedFlag.load(ordering: .acquiring) {
                let heard = audioStation.withLock { $0 }.flatMap { id in stations.first { $0.id == id }?.host }
                if let heard, heard.isAudioActive, !heard.paused {
                    if heard.audioRing.count >= audioTarget {
                        runCommandsOnly()
                        Thread.sleep(forTimeInterval: 0.001)
                        continue
                    }
                    resetWallClock()
                } else {
                    let elapsed = clock.now - wallStart
                    let elapsedCycles = UInt64(max(0, Double(elapsed.components.seconds) * 2e6
                        + Double(elapsed.components.attoseconds) / 1e18 * 2e6))
                    if networkCycles - wallStartCycles >= elapsedCycles {
                        runCommandsOnly()
                        Thread.sleep(forTimeInterval: 0.001)
                        continue
                    }
                    // More than 0.1s behind (the Mac was busy): carry on
                    // from now rather than rushing to catch up.
                    if elapsedCycles - (networkCycles - wallStartCycles) > 200_000 {
                        resetWallClock()
                    }
                }
            }

            if !runQuantum() {
                Thread.sleep(forTimeInterval: 0.005)
                resetWallClock()
            }
        }
    }

    /// A station's tool wants `cycles` of time (on the network's thread,
    /// in the middle of the station's commands): the network runs that
    /// long, as fast as it can. If it can't (another station's stopped in
    /// its debugger, holding the network), the caller runs on alone.
    func runNested(cycles: Int, caller: EmulatorHost) {
        var left = cycles
        while left > 0 {
            guard runQuantum(caller: caller) else {
                caller.drivingSession().step(cycles: left)
                return
            }
            left -= quantum
        }
    }

    /// Keeps windows and tools responsive while the network waits for the
    /// wall clock.
    private func runCommandsOnly() {
        runCommands()
        for station in stations {
            station.host.runCommands()
        }
    }
}
