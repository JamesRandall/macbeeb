import BeebCapture
import BeebCore
import Foundation

/// A machine plus what's attached to it, used on one thread. Tools that
/// drive a machine (agents, tests) work through this, so they can run
/// headless or inside the app.
public protocol MachineSession: AnyObject {
    var machine: BBCMicro { get }
    var tv: TVOutput { get }
    /// Runs the machine, keeping attached things (recording, display) up
    /// to date.
    func advance(cycles: Int)
    /// Power off and on again, optionally as a different machine. Discs
    /// stay in their drives.
    func powerCycle(configuration: BBCMicro.Configuration?)
    func startRecording(to url: URL, codec: VideoRecorder.Codec) throws
    func stopRecording() throws
    var isRecording: Bool { get }
    /// Swaps in a different machine (e.g. one restored from a save state).
    func replace(with machine: BBCMicro)
    /// Whether the machine is held still between tool calls, rather than
    /// running in real time (in the app). A headless machine only ever
    /// runs in tool calls.
    var heldBetweenCalls: Bool { get set }
    /// Whether `heldBetweenCalls` can be turned off.
    var runsBetweenCalls: Bool { get }
}

extension MachineSession {
    public func powerCycle() {
        powerCycle(configuration: nil)
    }

    public func advance(seconds: Double) {
        advance(cycles: Int(seconds * 2_000_000))
    }

    /// Advances until `done()` or `maxSeconds` pass. Returns whether
    /// `done()` happened.
    public func advance(until done: () -> Bool, maxSeconds: Double) -> Bool {
        let deadline = machine.cycles + UInt64(maxSeconds * 2_000_000)
        while !done() {
            // A debugger stop holds the machine still.
            if machine.cycles >= deadline || machine.isStoppedByDebugger { return false }
            advance(cycles: 10_000)
        }
        return true
    }
}

/// Gives a tool exclusive access to a session, on the session's thread.
public protocol MachineContext: Sendable {
    func perform<T: Sendable>(_ body: @escaping @Sendable (MachineSession) throws -> T) throws -> T
}

/// A machine with nothing else running: the caller's thread drives it.
public final class HeadlessSession: MachineSession, MachineContext, @unchecked Sendable {
    public private(set) var machine: BBCMicro
    public private(set) var tv: TVOutput
    private var makeMachine: () -> BBCMicro
    private var recorder: MachineRecorder?
    private let lock = NSLock()

    public init(makeMachine: @escaping () -> BBCMicro) {
        self.makeMachine = makeMachine
        machine = makeMachine()
        tv = TVOutput()
        machine.tv = tv
        machine.enableRewind()
    }

    public func perform<T: Sendable>(_ body: @escaping @Sendable (MachineSession) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(self)
    }

    public func advance(cycles: Int) {
        guard let recorder else {
            machine.run(cycles: cycles)
            return
        }
        // Capture each 1/50s so frames and sound are kept.
        var remaining = cycles
        while remaining > 0 {
            let slice = min(remaining, 40_000)
            machine.run(cycles: slice)
            remaining -= slice
            try? recorder.capture()
        }
    }

    public func powerCycle(configuration: BBCMicro.Configuration?) {
        if let configuration {
            makeMachine = { BBCMicro(configuration: configuration) }
        }
        let old = machine
        let recording = recorder
        recorder = nil
        try? recording?.finish()
        machine = makeMachine()
        tv = TVOutput()
        machine.tv = tv
        machine.enableRewind()
        machine.insertDiscs(from: old)
        if let debugger = old.debuggerIfCreated {
            machine.debugger.adopt(debugger)
        }
    }

    public func startRecording(to url: URL, codec: VideoRecorder.Codec) throws {
        try recorder?.finish()
        // The recorder taps the mixer's output; nothing else listens.
        machine.attachAudio(sampleRate: 48_000, ring: SampleRing(capacity: 1))
        recorder = try MachineRecorder(machine: machine, tv: tv, url: url, codec: codec)
    }

    public func stopRecording() throws {
        defer { recorder = nil }
        try recorder?.finish()
    }

    public var isRecording: Bool { recorder != nil }

    public var heldBetweenCalls: Bool {
        get { true }
        set {}
    }

    public var runsBetweenCalls: Bool { false }

    public func replace(with newMachine: BBCMicro) {
        try? recorder?.finish()
        recorder = nil
        machine = newMachine
        // Power cycles keep to the new machine's model and ROMs.
        let configuration = newMachine.configuration
        makeMachine = { BBCMicro(configuration: configuration) }
        tv = TVOutput()
        machine.tv = tv
        machine.enableRewind()
    }
}
