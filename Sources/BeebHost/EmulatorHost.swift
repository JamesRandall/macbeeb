import BeebCapture
import BeebCore
import Foundation
import Synchronization

/// Runs a BBC Micro on its own thread. Everything else talks to it through
/// commands (in) and published frames and audio samples (out); the machine
/// itself is only touched on the emulation thread.
public final class EmulatorHost: MachineContext, @unchecked Sendable {
    public enum Command: Sendable {
        case key(BeebKey, down: Bool)
        case paste(String)
        case type(String)
        case releaseAllKeys
        case joystick(Int, x: Double, y: Double, fire: Bool)
        /// Power off and on again. Discs stay in their drives.
        case powerCycle
        /// Power cycles into a different machine (e.g. another model).
        case changeMachine(BBCMicro.Configuration)
        case loadProgram(disc: [UInt8], file: String)
        /// Puts a disc image in a drive; nil ejects. `onWrite` gets the
        /// updated image whenever the BBC writes to the disc.
        case insertDisc(image: [UInt8]?, doubleSided: Bool, drive: Int, onWrite: (@Sendable ([UInt8]) -> Void)?)
        case shiftBreak
        case pressBreak
        case setPaused(Bool)
        case setSpeedLimited(Bool)
        /// Starts recording a movie.
        case startRecording(URL, VideoRecorder.Codec)
        /// Stops recording; `completion` gets any error (on the emulation
        /// thread).
        case stopRecording(completion: @Sendable (Error?) -> Void)
        /// Saves the machine's state to a file; `completion` gets any error.
        case saveState(URL, completion: @Sendable (Error?) -> Void)
        /// Replaces the machine with one restored from a save state.
        case loadState(SaveStateFile)
        /// Runs a closure on the emulation thread with the session.
        case perform(@Sendable (MachineSession) -> Void)
    }

    public struct Frame: Sendable {
        public var pixels: [UInt32]
        public var number: Int
        /// While inspecting: where each 8x2-pixel cell came from (see
        /// `VideoSource`), `TVOutput.metadataWidth` per row.
        public var metadata: [UInt32]?
        public static let width = TVOutput.width
        public static let height = TVOutput.height
    }

    public let audioRing: SampleRing
    public let sampleRate: Int

    private let makeMachine: @Sendable () -> BBCMicro
    private let commands = Mutex<[Command]>([])
    let latestFrame = Mutex<Frame?>(nil)
    private let latestLights = Mutex(BBCMicro.Lights())
    private let latestDebugStop = Mutex<StopReason?>(nil)
    private let inspecting = Atomic<Bool>(false)

    /// Turns on frame metadata, so the screen can be inspected.
    public func setInspecting(_ on: Bool) {
        inspecting.store(on, ordering: .relaxed)
    }

    var isInspecting: Bool { inspecting.load(ordering: .relaxed) }
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

    /// Runs `body` on the emulation thread and waits for the result. Don't
    /// call from the emulation thread.
    public func perform<T: Sendable>(_ body: @escaping @Sendable (MachineSession) throws -> T) throws -> T {
        let result = Mutex<Result<T, Error>?>(nil)
        let done = DispatchSemaphore(value: 0)
        send(.perform { session in
            let value = Result { try body(session) }
            result.withLock { $0 = value }
            done.signal()
        })
        done.wait()
        return try result.withLock { $0! }.get()
    }

    // MARK: Emulation thread

    private func threadMain() {
        let session = HostSession(host: self, makeMachine: makeMachine)
        var paused = false
        var speedLimited = true
        let clock = ContinuousClock()
        var wallStart = clock.now
        var wallStartCycles = session.machine.cycles

        // Run in slices of 1ms of emulated time.
        let sliceCycles = 2_000
        // Keep this much audio queued: enough to ride out scheduling hiccups.
        let audioTarget = sampleRate * 40 / 1000

        func resetWallClock() {
            wallStart = clock.now
            wallStartCycles = session.machine.cycles
        }

        while running.load(ordering: .acquiring) {
            for command in commands.withLock({ list -> [Command] in
                defer { list.removeAll() }
                return list
            }) {
                let machine = session.machine
                switch command {
                case .key(let key, let down):
                    machine.setKey(key, down: down)
                case .paste(let text):
                    machine.paste(text)
                case .type(let text):
                    machine.type(text)
                case .releaseAllKeys:
                    machine.releaseAllKeys()
                case .joystick(let index, let x, let y, let fire):
                    machine.setJoystick(index, x: x, y: y, fire: fire)
                case .powerCycle:
                    session.powerCycle()
                    resetWallClock()
                case .changeMachine(let configuration):
                    session.powerCycle(configuration: configuration)
                    resetWallClock()
                case .loadProgram(let disc, let file):
                    machine.loadProgram(disc: disc, file: file)
                case .insertDisc(let image, let doubleSided, let drive, let onWrite):
                    session.insertDisc(image: image, doubleSided: doubleSided, drive: drive, onWrite: onWrite)
                case .shiftBreak:
                    machine.shiftBreak()
                case .pressBreak:
                    machine.pressBreak()
                case .setPaused(let value):
                    paused = value
                    resetWallClock()
                case .setSpeedLimited(let value):
                    speedLimited = value
                    resetWallClock()
                case .startRecording(let url, let codec):
                    do {
                        try session.startRecording(to: url, codec: codec)
                    } catch {
                        NSLog("MacBeeb: can't record: \(error)")
                    }
                case .stopRecording(let completion):
                    do {
                        try session.stopRecording()
                        completion(nil)
                    } catch {
                        completion(error)
                    }
                case .saveState(let url, let completion):
                    do {
                        try SaveStateFile(session.machine).data().write(to: url, options: .atomic)
                        completion(nil)
                    } catch {
                        completion(error)
                    }
                case .loadState(let file):
                    do {
                        session.replace(with: try file.makeMachine())
                        resetWallClock()
                    } catch {
                        NSLog("MacBeeb: can't load state: \(error)")
                    }
                case .perform(let body):
                    body(session)
                    resetWallClock()
                }
            }

            let stop = session.machine.debuggerIfCreated?.stopReason
            latestDebugStop.withLock { $0 = stop }
            if paused || stop != nil {
                Thread.sleep(forTimeInterval: 0.005)
                resetWallClock()
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
                    resetWallClock()
                } else {
                    let elapsed = clock.now - wallStart
                    let elapsedCycles = Int(Double(elapsed.components.seconds) * 2e6
                        + Double(elapsed.components.attoseconds) / 1e18 * 2e6)
                    if Int(session.machine.cycles - wallStartCycles) >= elapsedCycles {
                        Thread.sleep(forTimeInterval: 0.001)
                        continue
                    }
                }
            }

            session.advance(cycles: sliceCycles)
        }
    }

    fileprivate func didAdvance(_ session: HostSession) {
        emulatedCycles.store(Int(session.machine.cycles), ordering: .relaxed)
        let lights = session.machine.lights
        latestLights.withLock { $0 = lights }
    }

    /// Why the debugger has stopped the machine, if it has.
    public var debugStop: StopReason? {
        latestDebugStop.withLock { $0 }
    }

    /// Runs `body` on the emulation thread, without blocking the caller.
    public func performAsync<T: Sendable>(_ body: @escaping @Sendable (MachineSession) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            send(.perform { session in
                continuation.resume(with: Result { try body(session) })
            })
        }
    }

    /// The machine's indicator lights, as of the last slice.
    public var lights: BBCMicro.Lights {
        latestLights.withLock { $0 }
    }
}

/// The emulation thread's state.
final class HostSession: MachineSession {
    private unowned let host: EmulatorHost
    private var makeMachine: () -> BBCMicro
    private(set) var machine: BBCMicro
    private(set) var tv: TVOutput
    private var recorder: MachineRecorder?
    private var lastPublishedFrame = 0

    init(host: EmulatorHost, makeMachine: @escaping () -> BBCMicro) {
        self.host = host
        self.makeMachine = makeMachine
        machine = makeMachine()
        tv = TVOutput()
        attach()
    }

    private func attach() {
        machine.tv = tv
        if machine.rewinder == nil {
            machine.enableRewind()
        }
        machine.attachAudio(sampleRate: host.sampleRate, ring: host.audioRing)
        lastPublishedFrame = 0
    }

    func advance(cycles: Int) {
        // Slices of 1ms keep recording, the display and the cycle count
        // current during long runs.
        var remaining = cycles
        while remaining > 0 {
            let slice = min(remaining, 2_000)
            machine.run(cycles: slice)
            remaining -= slice
            if let active = recorder {
                do {
                    try active.capture()
                } catch {
                    NSLog("MacBeeb: recording failed: \(error)")
                    recorder = nil
                }
            }
            let inspecting = host.isInspecting
            if tv.recordsMetadata != inspecting {
                tv.recordsMetadata = inspecting
            }
            if tv.frameCount != lastPublishedFrame {
                lastPublishedFrame = tv.frameCount
                let frame = EmulatorHost.Frame(pixels: tv.lastFrame, number: tv.frameCount,
                                               metadata: inspecting ? tv.lastMetadata : nil)
                host.latestFrame.withLock { $0 = frame }
            }
        }
        host.didAdvance(self)
    }

    func powerCycle(configuration: BBCMicro.Configuration?) {
        if let configuration {
            makeMachine = { BBCMicro(configuration: configuration) }
        }
        let discs = (0..<2).map { machine.drives[$0].disc }
        try? recorder?.finish()
        recorder = nil
        machine = makeMachine()
        tv = TVOutput()
        attach()
        for (drive, disc) in discs.enumerated() {
            machine.insertDisc(disc, drive: drive)
        }
    }

    func insertDisc(image: [UInt8]?, doubleSided: Bool, drive: Int, onWrite: (@Sendable ([UInt8]) -> Void)?) {
        guard let image else {
            machine.insertDisc(nil, drive: drive)
            return
        }
        do {
            let disc = doubleSided ? try Disc.fromDSD(image) : try Disc.fromSSD(image)
            if let onWrite {
                disc.onTrackWritten = { [unowned disc] _, _ in
                    if let bytes = try? disc.toSSDOrDSD() {
                        onWrite(bytes)
                    }
                }
            }
            machine.insertDisc(disc, drive: drive)
        } catch {
            NSLog("MacBeeb: bad disc image: \(error)")
        }
    }

    func startRecording(to url: URL, codec: VideoRecorder.Codec) throws {
        try recorder?.finish()
        recorder = try MachineRecorder(machine: machine, tv: tv, url: url, codec: codec, sampleRate: host.sampleRate)
    }

    func stopRecording() throws {
        defer { recorder = nil }
        try recorder?.finish()
    }

    var isRecording: Bool { recorder != nil }

    func replace(with newMachine: BBCMicro) {
        try? recorder?.finish()
        recorder = nil
        machine = newMachine
        // Power cycles keep to the new machine's model and ROMs.
        let configuration = newMachine.configuration
        makeMachine = { BBCMicro(configuration: configuration) }
        tv = TVOutput()
        attach()
    }
}
