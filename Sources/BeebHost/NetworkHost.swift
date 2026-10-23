import BeebCore
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

        public init() {}
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

    /// Emulated cycles each station runs before the others catch up.
    public let quantum: Int

    public init(sampleRate: Int = 48_000, quantum: Int = 2_000) {
        self.sampleRate = sampleRate
        self.quantum = quantum
    }

    deinit {
        stop()
    }

    /// A new station, run by this network from its next quantum. Don't
    /// `start` it: the network runs it.
    public func addStation(id: UUID, discDriveSounds: (@Sendable (BBCMicro.Model) -> DiscDriveSounds?)? = nil,
                           discDriveSoundsOn: Bool = true, keepsRewind: Bool = false,
                           makeMachine: @escaping @Sendable () -> BBCMicro) -> EmulatorHost {
        let host = EmulatorHost(sampleRate: sampleRate, discDriveSounds: discDriveSounds,
                                discDriveSoundsOn: discDriveSoundsOn, makeMachine: makeMachine)
        host.isNetworkStation = true
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
                stations.removeAll { $0.id == id }
            }
        }
    }

    /// Runs one quantum: every station that's ready runs `quantum` cycles,
    /// in turn. Returns whether anything ran.
    @discardableResult
    func runQuantum() -> Bool {
        runCommands()
        var ready: [EmulatorHost] = []
        var stopped: Set<UUID> = []
        for station in stations {
            station.host.runCommands()
            if station.host.readyToRun() {
                ready.append(station.host)
            } else if station.host.debugStop != nil {
                stopped.insert(station.id)
            }
        }
        let paused = isPaused || (!stopped.isEmpty && pausesOnBreakpoint)
        latestStatus.withLock {
            $0.paused = paused
            $0.stoppedStations = stopped
        }
        guard !paused else { return false }
        for host in ready {
            host.drivingSession().advance(cycles: quantum)
        }
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

        while running.load(ordering: .acquiring) {
            let now = clock.now
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
                }
            }

            if !runQuantum() {
                Thread.sleep(forTimeInterval: 0.005)
                resetWallClock()
            }
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
