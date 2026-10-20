import BeebCore
import Foundation
import Synchronization

/// Runs a BBC Micro on its own thread. Everything else talks to it through
/// commands (in) and published frames and audio samples (out); the machine
/// itself is only touched on the emulation thread.
public final class EmulatorHost: @unchecked Sendable {
    public enum Command: Sendable {
        case key(BeebKey, down: Bool)
        case paste(String)
        case type(String)
        case releaseAllKeys
        /// Power off and on again.
        case powerCycle
        case loadProgram(disc: [UInt8], file: String)
        case setPaused(Bool)
        case setSpeedLimited(Bool)
        /// Runs a closure on the emulation thread with the machine.
        case inspect(@Sendable (BBCMicro) -> Void)
    }

    public struct Frame: Sendable {
        public var pixels: [UInt32]
        public var number: Int
        public static let width = TVOutput.width
        public static let height = TVOutput.height
    }

    public let audioRing: SampleRing
    public let sampleRate: Int

    private let makeMachine: @Sendable () -> BBCMicro
    private let commands = Mutex<[Command]>([])
    private let latestFrame = Mutex<Frame?>(nil)
    private let running = Atomic<Bool>(true)
    private let audioActive = Atomic<Bool>(false)
    private let emulatedCycles = Atomic<Int>(0)
    private var thread: Thread?

    /// `makeMachine` builds the machine (on the emulation thread), for
    /// start-up and power cycles.
    public init(sampleRate: Int = 48_000, makeMachine: @escaping @Sendable () -> BBCMicro) {
        self.sampleRate = sampleRate
        self.makeMachine = makeMachine
        // 0.5s of audio.
        audioRing = SampleRing(capacity: sampleRate / 2)
    }

    deinit {
        stop()
    }

    public func start() {
        guard thread == nil else { return }
        let thread = Thread { [unowned self] in self.threadMain() }
        thread.name = "BBC Micro"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
    }

    public func stop() {
        running.store(false, ordering: .releasing)
    }

    public func send(_ command: Command) {
        commands.withLock { $0.append(command) }
    }

    /// The most recent complete frame.
    public var frame: Frame? {
        latestFrame.withLock { $0 }
    }

    /// Call when audio output starts or stops consuming `audioRing`. While
    /// audio is active it paces the emulation.
    public func setAudioActive(_ active: Bool) {
        audioActive.store(active, ordering: .releasing)
    }

    /// Total 2MHz cycles emulated.
    public var cycles: Int {
        emulatedCycles.load(ordering: .relaxed)
    }

    // MARK: Emulation thread

    private func threadMain() {
        var machine = makeMachine()
        var tv = TVOutput()
        machine.tv = tv
        machine.attachAudio(sampleRate: sampleRate, ring: audioRing)

        var paused = false
        var speedLimited = true
        var lastPublishedFrame = 0
        let clock = ContinuousClock()
        var wallStart = clock.now
        var wallStartCycles = machine.cycles

        // Run in slices of 1ms of emulated time.
        let sliceCycles = 2_000
        // Keep this much audio queued: enough to ride out scheduling hiccups.
        let audioTarget = sampleRate * 40 / 1000

        while running.load(ordering: .acquiring) {
            for command in commands.withLock({ list -> [Command] in
                defer { list.removeAll() }
                return list
            }) {
                switch command {
                case .key(let key, let down):
                    machine.setKey(key, down: down)
                case .paste(let text):
                    machine.paste(text)
                case .type(let text):
                    machine.type(text)
                case .releaseAllKeys:
                    machine.releaseAllKeys()
                case .powerCycle:
                    machine = makeMachine()
                    tv = TVOutput()
                    machine.tv = tv
                    machine.attachAudio(sampleRate: sampleRate, ring: audioRing)
                    lastPublishedFrame = 0
                    wallStart = clock.now
                    wallStartCycles = machine.cycles
                case .loadProgram(let disc, let file):
                    machine.loadProgram(disc: disc, file: file)
                case .setPaused(let value):
                    paused = value
                    wallStart = clock.now
                    wallStartCycles = machine.cycles
                case .setSpeedLimited(let value):
                    speedLimited = value
                    wallStart = clock.now
                    wallStartCycles = machine.cycles
                case .inspect(let body):
                    body(machine)
                }
            }

            if paused {
                Thread.sleep(forTimeInterval: 0.005)
                continue
            }

            // Pace: by the audio queue if audio is playing, else by the wall
            // clock.
            if speedLimited {
                if audioActive.load(ordering: .acquiring) {
                    if audioRing.count >= audioTarget {
                        Thread.sleep(forTimeInterval: 0.001)
                        continue
                    }
                    // Keep the wall clock in step for when audio stops.
                    wallStart = clock.now
                    wallStartCycles = machine.cycles
                } else {
                    let elapsed = clock.now - wallStart
                    let elapsedCycles = Int(Double(elapsed.components.seconds) * 2e6
                        + Double(elapsed.components.attoseconds) / 1e18 * 2e6)
                    if Int(machine.cycles - wallStartCycles) >= elapsedCycles {
                        Thread.sleep(forTimeInterval: 0.001)
                        continue
                    }
                }
            }

            machine.run(cycles: sliceCycles)
            emulatedCycles.store(Int(machine.cycles), ordering: .relaxed)

            if tv.frameCount != lastPublishedFrame {
                lastPublishedFrame = tv.frameCount
                let frame = Frame(pixels: tv.lastFrame, number: tv.frameCount)
                latestFrame.withLock { $0 = frame }
            }
        }
    }
}
