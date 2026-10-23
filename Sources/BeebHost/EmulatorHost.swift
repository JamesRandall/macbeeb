import BeebCapture
import BeebCore
import BeebPrint
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
        /// Moves the AMX mouse by counts (right and down positive).
        case mouseMove(dx: Int, dy: Int)
        case mouseButtons(AMXMouse.Buttons)
        /// Power off and on again. Discs stay in their drives.
        case powerCycle
        /// Power cycles into a different machine (e.g. another model).
        case changeMachine(BBCMicro.Configuration)
        case loadProgram(disc: [UInt8], file: String)
        /// Puts a disc image in a drive; nil ejects. `onWrite` gets the
        /// updated image whenever the BBC writes to the disc.
        case insertDisc(image: [UInt8]?, format: Disc.ImageFormat, drive: Int, onWrite: (@Sendable ([UInt8]) -> Void)?)
        case shiftBreak
        case pressBreak
        case setPaused(Bool)
        case setSpeedLimited(Bool)
        /// Turns the disc drives' noises on or off.
        case setDiscDriveSounds(Bool)
        /// Starts recording a movie.
        case startRecording(URL, VideoRecorder.Codec)
        /// Stops recording; `completion` gets any error (on the emulation
        /// thread).
        case stopRecording(completion: @Sendable (Error?) -> Void)
        /// Saves the machine's state to a file; `completion` gets any error.
        case saveState(URL, completion: @Sendable (Error?) -> Void)
        /// Replaces the machine with one restored from a save state.
        case loadState(SaveStateFile)
        /// Restores a save state (a quick save): builds the machine first, so
        /// a state that can't be restored leaves the running one alone.
        /// The restored discs in `writeBacks`' drives are written back
        /// through them, and keys held at the save are released.
        /// `completion` gets any error (on the emulation thread).
        case restoreState(SaveStateFile, writeBacks: [Int: WriteBack], completion: @Sendable (Error?) -> Void)
        /// Runs a closure on the emulation thread with the session.
        case perform(@Sendable (MachineSession) -> Void)
    }

    /// Where a drive's disc goes when the BBC writes to it.
    public struct WriteBack: Sendable {
        public var format: Disc.ImageFormat
        public var onWrite: @Sendable ([UInt8]) -> Void

        public init(format: Disc.ImageFormat, onWrite: @escaping @Sendable ([UInt8]) -> Void) {
            self.format = format
            self.onWrite = onWrite
        }
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
    private let latestMouse = Mutex(Mouse())
    private let latestDebugStop = Mutex<(reason: StopReason?, count: Int)>((nil, 0))
    private let inspecting = Atomic<Bool>(false)

    /// Turns on frame metadata, so the screen can be inspected.
    public func setInspecting(_ on: Bool) {
        inspecting.store(on, ordering: .relaxed)
    }

    var isInspecting: Bool { inspecting.load(ordering: .relaxed) }
    private let running = Atomic<Bool>(true)
    private let heldForAgent = Atomic<Bool>(false)

    /// Whether an agent is holding the machine still between its tool calls
    /// (it runs only while they do).
    public var isHeldForAgent: Bool { heldForAgent.load(ordering: .acquiring) }

    public func setHeldForAgent(_ held: Bool) {
        heldForAgent.store(held, ordering: .releasing)
    }
    private let audioActive = Atomic<Bool>(false)
    private let emulatedCycles = Atomic<Int>(0)
    private var thread: Thread?

    /// `makeMachine` builds the machine (on the emulation thread), for
    /// start-up and power cycles.
    /// The disc drives' noises for a model, if they're to be heard (see
    /// `setDiscDriveSounds`). Read on the emulation thread.
    let discDriveSounds: (@Sendable (BBCMicro.Model) -> DiscDriveSounds?)?
    fileprivate var discDriveSoundsOn: Bool

    public init(sampleRate: Int = 48_000, discDriveSounds: (@Sendable (BBCMicro.Model) -> DiscDriveSounds?)? = nil,
                discDriveSoundsOn: Bool = true, makeMachine: @escaping @Sendable () -> BBCMicro) {
        self.sampleRate = sampleRate
        self.discDriveSounds = discDriveSounds
        self.discDriveSoundsOn = discDriveSoundsOn
        self.makeMachine = makeMachine
        // 0.5s of audio.
        audioRing = SampleRing(capacity: sampleRate / 2)
    }

    deinit {
        stop()
    }

    /// Whether a `NetworkHost` drives this machine (so it has no thread of
    /// its own).
    public internal(set) var isNetworkStation = false
    /// Where what the machine prints goes: a printer on its printer port,
    /// whose jobs go here (on the emulation thread). Set before it starts.
    public var printJobs: (@Sendable (PrintJob) -> Void)?
    /// The printer's name in its jobs.
    public var printerName = "Printer"
    /// Whether the machine keeps rewind snapshots. A network's stations
    /// don't by default: each keeps its own, and they add up.
    public internal(set) var keepsRewind = true

    public func start() {
        // A station's network runs it: a thread here would run it twice.
        guard thread == nil, !isNetworkStation else { return }
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

    // The machine is driven either by this host's own thread (`start`) or,
    // as a station of a network, by the network's thread (`NetworkHost`).
    // Either way, these are only touched by the driving thread.
    private var session: HostSession?
    /// Paused from the menu (in a network: this station is suspended).
    private(set) var paused = false
    private(set) var speedLimited = true

    /// The machine's session, made on first use by the driving thread.
    func drivingSession() -> HostSession {
        if let session { return session }
        let made = HostSession(host: self, makeMachine: makeMachine)
        session = made
        return made
    }

    /// Runs the queued commands, on the driving thread. Returns whether
    /// emulated time jumped or the machine changed (so wall-clock pacing
    /// starts again).
    @discardableResult
    func runCommands() -> Bool {
        let session = drivingSession()
        var restart = false
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
            case .mouseMove(let dx, let dy):
                machine.moveMouse(dx: dx, dy: dy)
            case .mouseButtons(let buttons):
                machine.setMouseButtons(buttons)
            case .powerCycle:
                session.powerCycle()
                restart = true
            case .changeMachine(let configuration):
                session.powerCycle(configuration: configuration)
                restart = true
            case .loadProgram(let disc, let file):
                machine.loadProgram(disc: disc, file: file)
            case .insertDisc(let image, let format, let drive, let onWrite):
                session.insertDisc(image: image, format: format, drive: drive, onWrite: onWrite)
            case .shiftBreak:
                machine.shiftBreak()
            case .pressBreak:
                machine.pressBreak()
            case .setPaused(let value):
                paused = value
                restart = true
            case .setSpeedLimited(let value):
                speedLimited = value
                restart = true
            case .setDiscDriveSounds(let on):
                discDriveSoundsOn = on
                session.applyDiscDriveSounds()
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
                    let restored = try file.makeMachine()
                    if let debugger = session.machine.debuggerIfCreated {
                        restored.debugger.adopt(debugger)
                    }
                    session.replace(with: restored)
                    restart = true
                } catch {
                    NSLog("MacBeeb: can't load state: \(error)")
                }
            case .restoreState(let file, let writeBacks, let completion):
                do {
                    let restored = try file.makeMachine()
                    if let debugger = session.machine.debuggerIfCreated {
                        restored.debugger.adopt(debugger)
                    }
                    session.replace(with: restored)
                    restored.releaseAllKeys()
                    for (drive, writeBack) in writeBacks {
                        session.attachWriteBack(drive: drive, writeBack)
                    }
                    restart = true
                    completion(nil)
                } catch {
                    completion(error)
                }
            case .perform(let body):
                body(session)
                restart = true
            }
        }
        return restart
    }

    /// Publishes the debugger's state and says whether the machine should
    /// run now: not paused, stopped by the debugger or held for an agent.
    func readyToRun() -> Bool {
        let debugger = drivingSession().machine.debuggerIfCreated
        let stop = debugger?.stopReason
        let stopCount = debugger?.stopCount ?? 0
        latestDebugStop.withLock { $0 = (stop, stopCount) }
        return !paused && stop == nil && !isHeldForAgent
    }

    /// Whether the audio output is playing this machine's sound.
    var isAudioActive: Bool { audioActive.load(ordering: .acquiring) }

    private func threadMain() {
        let session = drivingSession()
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
            if runCommands() {
                resetWallClock()
            }
            if !readyToRun() {
                Thread.sleep(forTimeInterval: 0.005)
                resetWallClock()
                continue
            }

            // Pace: by the audio queue if audio is playing, else by the wall
            // clock.
            if speedLimited {
                if isAudioActive {
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
        let mouse = Mouse(inUse: session.machine.mouseInUse, tvPixelsPerCount: session.machine.mouseTVPixelsPerCount)
        latestMouse.withLock { $0 = mouse }
    }

    /// What the software is doing with the AMX mouse, as of the last slice.
    public struct Mouse: Sendable {
        public var inUse = false
        public var tvPixelsPerCount = 2.0
    }

    public var mouse: Mouse {
        latestMouse.withLock { $0 }
    }

    /// Why the debugger has stopped the machine, if it has.
    public var debugStop: StopReason? {
        latestDebugStop.withLock { $0.reason }
    }

    /// The debugger's stop count with the reason: changes with every stop,
    /// even two for the same reason.
    public var debugStopState: (reason: StopReason?, count: Int) {
        latestDebugStop.withLock { $0 }
    }

    /// Runs `body` on the emulation thread, without blocking the caller.
    public enum DiscChange: Sendable {
        case changed(before: DiscVolume, after: DiscVolume)
        /// The drive's been used too recently: try again shortly.
        case busy
        case noDisc
    }

    /// What's on the disc in `drive`: nil if it's empty.
    public func readVolume(drive: Int) async throws -> DiscVolume? {
        try await performAsync { session in
            guard let disc = session.machine.drives[drive].disc else { return nil }
            return try DiscVolume(disc: disc)
        }
    }

    /// Changes the files on the disc in `drive` (see HostSession.changeVolume).
    public func changeVolume(drive: Int,
                             _ change: @escaping @Sendable (inout DiscVolume) throws -> Void) async throws -> DiscChange {
        try await performAsync { session in
            guard let session = session as? HostSession else { return .noDisc }
            return try session.changeVolume(drive: drive, change)
        }
    }

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

    private var spooler: PrintSpooler?

    private func attach() {
        machine.tv = tv
        spooler?.machineStopped()
        if let printJobs = host.printJobs {
            let spooler = PrintSpooler(printer: host.printerName, onJob: printJobs)
            self.spooler = spooler
            machine.printer = ParallelPrinter { byte, cycle in spooler.receive(byte, at: cycle) }
        }
        if machine.rewinder == nil && host.keepsRewind {
            machine.enableRewind()
        }
        machine.attachAudio(sampleRate: host.sampleRate, ring: host.audioRing)
        applyDiscDriveSounds()
        lastPublishedFrame = 0
    }

    func applyDiscDriveSounds() {
        machine.discDriveSounds = host.discDriveSoundsOn ? host.discDriveSounds?(machine.model) : nil
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
        // (A network's stations run in short quanta: the lights and the
        // rest needn't be published every one.)
        cyclesSincePublished += cycles
        if cyclesSincePublished >= 2_000 {
            cyclesSincePublished = 0
            host.didAdvance(self)
            spooler?.idle(at: machine.cycles)
        }
    }

    private var cyclesSincePublished = 0

    func powerCycle(configuration: BBCMicro.Configuration?) {
        if let configuration {
            makeMachine = { BBCMicro(configuration: configuration) }
        }
        let old = machine
        try? recorder?.finish()
        recorder = nil
        machine = makeMachine()
        tv = TVOutput()
        attach()
        machine.insertDiscs(from: old)
        if let debugger = old.debuggerIfCreated {
            machine.debugger.adopt(debugger)
        }
    }

    func insertDisc(image: [UInt8]?, format: Disc.ImageFormat, drive: Int, onWrite: (@Sendable ([UInt8]) -> Void)?) {
        guard let image else {
            machine.insertDisc(nil, drive: drive)
            return
        }
        do {
            insert(try Disc.fromImage(image, format: format), format: format, drive: drive, onWrite: onWrite)
        } catch {
            NSLog("MacBeeb: bad disc image: \(error)")
        }
    }

    /// Where each drive's disc is written back to, while it's still the
    /// disc that was put in with it (an agent's load_disc puts others in
    /// without).
    private struct WriteBack {
        weak var disc: Disc?
        var format: Disc.ImageFormat
        var write: @Sendable ([UInt8]) -> Void
    }
    private var writeBacks: [Int: WriteBack] = [:]

    private func insert(_ disc: Disc, format: Disc.ImageFormat, drive: Int, onWrite: (@Sendable ([UInt8]) -> Void)?) {
        if let onWrite {
            attach(disc, format: format, drive: drive, onWrite: onWrite)
        } else {
            writeBacks[drive] = nil
        }
        machine.insertDisc(disc, drive: drive)
    }

    private func attach(_ disc: Disc, format: Disc.ImageFormat, drive: Int, onWrite: @escaping @Sendable ([UInt8]) -> Void) {
        disc.onTrackWritten = { [unowned disc] _, _ in
            if let bytes = try? disc.toImage(format) {
                onWrite(bytes)
            }
        }
        writeBacks[drive] = WriteBack(disc: disc, format: format, write: onWrite)
    }

    /// Writes the disc already in `drive` back through `writeBack`, now and
    /// whenever the BBC writes to it (after restoring a state, whose discs
    /// are its own).
    func attachWriteBack(drive: Int, _ writeBack: EmulatorHost.WriteBack) {
        guard let disc = machine.drives[drive].disc else { return }
        attach(disc, format: writeBack.format, drive: drive, onWrite: writeBack.onWrite)
        if let bytes = try? disc.toImage(writeBack.format) {
            writeBack.onWrite(bytes)
        }
    }

    /// Changes the files on the disc in `drive`, as if it were swapped for
    /// a disc with the change made (ADFS's with a new disc ID), once the
    /// drive's idle. A disc put in with a write-back goes back to it.
    func changeVolume(drive: Int, _ change: (inout DiscVolume) throws -> Void) throws -> EmulatorHost.DiscChange {
        guard let old = machine.drives[drive].disc else { return .noDisc }
        guard machine.discIsIdle(drive: drive) else { return .busy }
        let before = try DiscVolume(disc: old)
        var volume = before
        try change(&volume)
        if case .adfs(var adfs) = volume {
            adfs.changeDiscID()
            volume = .adfs(adfs)
        }
        let disc = try Disc.fromImage(volume.image, format: volume.format)
        disc.writeProtected = old.writeProtected
        let writeBack = writeBacks[drive].flatMap { $0.disc === old ? $0 : nil }
        insert(disc, format: writeBack?.format ?? volume.format, drive: drive, onWrite: writeBack?.write)
        if let writeBack, let bytes = try? disc.toImage(writeBack.format) {
            writeBack.write(bytes)
        }
        return .changed(before: before, after: volume)
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

    var heldBetweenCalls: Bool {
        get { host.isHeldForAgent }
        set { host.setHeldForAgent(newValue) }
    }

    var runsBetweenCalls: Bool { true }

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
