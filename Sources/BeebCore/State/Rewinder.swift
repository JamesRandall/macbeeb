// Rewind: go back to any cycle in the last minute or so.
//
// The machine is deterministic, so all that's needed is a snapshot every
// so often and the inputs since: keys and joysticks are logged with the
// cycle they arrived on; anything else that changes the machine from
// outside (typing, loading, poking, discs, tapes, the debugger) takes a
// fresh snapshot. To reach a cycle, the nearest snapshot before it is
// restored and run forward, replaying the inputs.
//
// Seeking keeps the history, so it's possible to go back and forward
// again; running on after a seek (or any new input) discards what came
// after.

public final class Rewinder {
    public struct Point: Sendable {
        public var cycle: UInt64
        /// Events from this sequence number on came after the snapshot.
        var nextEvent: Int
        public var snapshot: BBCMicro.Snapshot
        /// The TV picture then, at a quarter size (or empty).
        public var thumbnail: [UInt32]
    }

    enum Input: Sendable {
        case key(BeebKey, down: Bool)
        case joystick(Int, x: Double, y: Double, fire: Bool)
        case releaseAllKeys
        case mouseMove(dx: Int, dy: Int)
        case mouseButtons(AMXMouse.Buttons)
    }

    struct Event: Sendable {
        var sequence: Int
        var cycle: UInt64
        var input: Input
    }

    public static let thumbnailWidth = TVOutput.width / 4
    public static let thumbnailHeight = TVOutput.height / 4

    unowned let machine: BBCMicro
    /// Cycles between snapshots.
    public let interval: UInt64
    /// Snapshots kept.
    public let capacity: Int
    public private(set) var points: [Point] = []
    private(set) var events: [Event] = []
    /// True while restoring and replaying, when nothing's recorded.
    public private(set) var isReplaying = false
    private var nextPointCycle: UInt64 = 0
    private var nextSequence = 0
    private var keyframePending = false

    /// Keeps `seconds` of history, with a snapshot every `interval` seconds.
    init(machine: BBCMicro, seconds: Double, interval: Double) {
        self.machine = machine
        self.interval = UInt64(interval * 2_000_000)
        capacity = max(2, Int(seconds / interval) + 1)
        points.reserveCapacity(capacity)
    }

    /// The earliest cycle that can be reached.
    public var earliestCycle: UInt64? { points.first?.cycle }

    // MARK: Recording

    func record(_ input: Input) {
        guard !isReplaying else { return }
        discardFuture()
        events.append(Event(sequence: nextSequence, cycle: machine.cycles, input: input))
        nextSequence += 1
    }

    /// A snapshot after a change from outside. It's taken when the machine
    /// next runs, so a burst of changes (poking many bytes) takes one.
    func keyframe() {
        guard !isReplaying else { return }
        keyframePending = true
    }

    func flushKeyframe() {
        guard keyframePending, !isReplaying else { return }
        keyframePending = false
        discardFuture()
        addPoint()
    }

    /// Called as the machine runs.
    func tick() {
        guard !isReplaying else { return }
        if machine.cycles >= nextPointCycle {
            discardFuture()
            addPoint()
        }
    }

    private func addPoint() {
        let cycle = machine.cycles
        nextPointCycle = cycle + interval
        let point = Point(cycle: cycle, nextEvent: nextSequence, snapshot: machine.snapshot(), thumbnail: thumbnail())
        if let last = points.last, last.cycle == cycle {
            points[points.count - 1] = point
        } else {
            points.append(point)
        }
        if points.count > capacity {
            points.removeFirst(points.count - capacity)
            let oldest = points[0].cycle
            if let keep = events.firstIndex(where: { $0.cycle >= oldest }) {
                events.removeFirst(keep)
            } else {
                events.removeAll()
            }
        }
    }

    /// After a seek, running on starts a new future.
    private func discardFuture() {
        let now = machine.cycles
        if let last = points.last, last.cycle > now {
            points.removeAll { $0.cycle > now }
        }
        if let last = events.last, last.cycle > now {
            events.removeAll { $0.cycle > now }
        }
        if nextPointCycle > now + interval {
            nextPointCycle = now + interval
        }
    }

    private func thumbnail() -> [UInt32] {
        guard let frame = machine.tv?.lastFrame, frame.count == TVOutput.width * TVOutput.height else { return [] }
        var small = [UInt32](repeating: 0, count: Self.thumbnailWidth * Self.thumbnailHeight)
        for y in 0..<Self.thumbnailHeight {
            for x in 0..<Self.thumbnailWidth {
                small[y * Self.thumbnailWidth + x] = frame[(y * 4) * TVOutput.width + x * 4]
            }
        }
        return small
    }

    /// Clears the history (e.g. after loading a save state).
    public func reset() {
        points.removeAll()
        events.removeAll()
        nextPointCycle = machine.cycles
        keyframePending = true
    }

    // MARK: Seeking

    public enum SeekError: Error, CustomStringConvertible {
        case tooEarly(earliest: UInt64?)

        public var description: String {
            switch self {
            case .tooEarly(let earliest):
                earliest.map { "can only go back to cycle \($0)" } ?? "no history yet"
            }
        }
    }

    /// Puts the machine in the state it was in at `cycle` (at most the
    /// current cycle, or a later one recorded before a previous seek).
    /// `observe` sees each cycle on the way (for reverse debugging).
    public func seek(to cycle: UInt64, observe: ((BBCMicro) -> Void)? = nil) throws(SeekError) {
        flushKeyframe()
        guard let index = points.lastIndex(where: { $0.cycle <= cycle }) else {
            throw .tooEarly(earliest: earliestCycle)
        }
        replay(from: index, to: cycle, observe: observe)
    }

    /// Restores point `index` and runs on to `cycle`, replaying inputs.
    func replay(from index: Int, to cycle: UInt64, observe: ((BBCMicro) -> Void)? = nil) {
        let point = points[index]
        isReplaying = true
        defer { isReplaying = false }
        machine.debuggerIfCreated?.resume()
        // A point restores into this same machine, so this can't fail.
        try? machine.restore(point.snapshot)
        // The state at a cycle includes the inputs that arrived at it.
        var pending = events.filter { $0.sequence >= point.nextEvent && $0.cycle <= cycle }[...]
        while true {
            let next = min(pending.first?.cycle ?? cycle, cycle)
            if next > machine.cycles {
                if let observe {
                    while machine.cycles < next {
                        if machine.cycles % 1000 == 0 { machine.processKeyEvents() }
                        machine.step()
                        observe(machine)
                    }
                } else {
                    machine.replay(cycles: Int(next - machine.cycles))
                }
            }
            if let event = pending.first, event.cycle == machine.cycles {
                pending.removeFirst()
                apply(event.input)
                continue
            }
            if machine.cycles >= cycle { break }
        }
    }

    private func apply(_ input: Input) {
        switch input {
        case .key(let key, let down): machine.applyKey(key, down: down)
        case .joystick(let index, let x, let y, let fire): machine.applyJoystick(index, x: x, y: y, fire: fire)
        case .releaseAllKeys: machine.applyReleaseAllKeys()
        case .mouseMove(let dx, let dy): machine.mouse.move(dx: dx, dy: dy)
        case .mouseButtons(let buttons): machine.mouse.buttons = buttons
        }
    }
}

extension BBCMicro {
    /// Starts keeping rewind history.
    public func enableRewind(seconds: Double = 60, interval: Double = 0.25) {
        rewinder = Rewinder(machine: self, seconds: seconds, interval: interval)
        rewinder?.reset()
    }

    /// Runs exactly `count` cycles, ignoring debugger stops and watches.
    func replay(cycles count: Int) {
        var remaining = count
        while remaining > 0 {
            if cycles % 1000 == 0 {
                processKeyEvents()
            }
            step()
            remaining -= 1
        }
    }
}
