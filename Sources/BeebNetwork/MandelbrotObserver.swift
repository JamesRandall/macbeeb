import BeebCore

/// Follows a Distributed Mandelbrot render from the frames on the line:
/// who's working, what they've been given, what they've sent back, and
/// the picture so far. It only watches. The picture is made of the counts
/// the workers sent, for the tiles the coordinator accepted; a tile that
/// wasn't accepted stays missing, and nothing is ever worked out here.
///
/// Feed it every frame, in order (`EconetTrace`'s ids); it pairs each
/// data frame with its scout itself.
public struct MandelbrotObserver: Sendable {
    /// A tile and the epoch it was handed out in.
    public struct TileEpoch: Sendable, Hashable, Comparable {
        public var tile: Int
        public var epoch: Int
        public init(tile: Int, epoch: Int) { self.tile = tile; self.epoch = epoch }
        public static func < (a: TileEpoch, b: TileEpoch) -> Bool { (a.tile, a.epoch) < (b.tile, b.epoch) }
    }

    public struct Assignment: Sendable, Equatable {
        public var tile: Int
        public var epoch: Int
        public var station: UInt8
        public var x: Int, y: Int, width: Int, height: Int
        /// When the coordinator sent it (2MHz cycles).
        public var cycles: UInt64
    }

    /// A RESULT as a worker sent it (the first copy: resends are the same).
    public struct Received: Sendable, Equatable {
        public var station: UInt8
        public var tile: Int
        public var epoch: Int
        public var x: Int, y: Int, width: Int, height: Int
        public var counts: [UInt8]
        public var cycles: UInt64
    }

    /// A tile the coordinator accepted (an ACK with status 0, or 1 for one
    /// whose acceptance wasn't heard).
    public struct Accepted: Sendable, Equatable {
        public var epoch: Int
        public var station: UInt8
        public var cycles: UInt64
        /// Whether its RESULT was seen too, so it's in the picture.
        public var drawn: Bool
    }

    public struct Worker: Sendable, Equatable, Identifiable {
        public enum State: String, Sendable {
            /// Waiting for work, or with none to do.
            case idle
            /// Given a tile, and nothing back yet.
            case computing
            /// Sent its RESULT, and not acknowledged yet.
            case sending
            /// Had its tile longer than the coordinator waits (20s).
            case unresponsive
        }

        public var station: UInt8
        public var id: UInt8 { station }
        /// OSBYTE 0's X, from its HELLO.
        public var machine: UInt8?
        /// The tile it's on, if any, and whether it's sent it back.
        public var current: TileEpoch?
        public var sent = false
        /// When it was given its current tile.
        public var assignedAt: UInt64 = 0
        /// When it last sent anything.
        public var lastHeard: UInt64 = 0
        var stalled = false

        /// Tiles the coordinator accepted from it, their pixels, and the
        /// sum of their counts (the iterations it did for them).
        public var tiles = 0
        public var pixels = 0
        public var iterations = 0
        /// The Mandelbrot messages' bytes it sent (headers included,
        /// Econet's own bytes not), and how many times it sent a RESULT.
        public var bytes = 0
        public var resultsSent = 0
        /// ACKs that said duplicate (1) or stale (2).
        public var duplicates = 0
        public var stale = 0

        public var state: State {
            if stalled { return .unresponsive }
            guard current != nil else { return .idle }
            return sent ? .sending : .computing
        }
    }

    /// How long the coordinator waits for a tile.
    public static let timeout: UInt64 = 20 * 2_000_000

    /// The coordinator's station, once something's gone to or from it.
    public private(set) var coordinator: UInt8?
    /// The render being followed (the coordinator's runId).
    public private(set) var runId: UInt32?
    public private(set) var maxIterations = MandelbrotProtocol.defaultMaxIterations
    public private(set) var workers: [UInt8: Worker] = [:]
    /// Each tile's latest assignment.
    public private(set) var assignments: [Int: Assignment] = [:]
    /// RESULTs received, whether or not the coordinator took them.
    public private(set) var received: [TileEpoch: Received] = [:]
    /// Tiles the coordinator accepted.
    public private(set) var accepted: [Int: Accepted] = [:]
    /// The coordinator sent COMPLETE.
    public private(set) var completeSeen = false
    /// When the run began (its first message from the coordinator), and
    /// when it was complete.
    public private(set) var runStart: UInt64?
    public private(set) var completedAt: UInt64?
    /// The latest time seen, from a frame or `advance(to:)`.
    public private(set) var now: UInt64 = 0
    /// Frames on the demo's ports that weren't messages, and frames that
    /// went from the trace before they were read (so may be missing).
    public private(set) var malformed = 0
    public private(set) var missedFrames = 0
    /// Mandelbrot messages read.
    public private(set) var messages = 0

    /// Escape counts, 160 × 256, row by row; only those in `accepted` (and
    /// drawn) tiles mean anything: see `count(x:y:)`.
    public private(set) var image = [UInt8](repeating: 0, count: MandelbrotProtocol.imageWidth * MandelbrotProtocol.imageHeight)
    /// Which pixels are in the picture.
    public private(set) var covered = [Bool](repeating: false, count: MandelbrotProtocol.imageWidth * MandelbrotProtocol.imageHeight)

    private var traffic = MandelbrotTraffic()
    private var lastFrame: Int?

    public init() {}

    /// Nothing of the demo's seen yet.
    public var isEmpty: Bool { messages == 0 && malformed == 0 }

    public var tilesCompleted: Int { accepted.count }

    public var sortedWorkers: [Worker] { workers.values.sorted { $0.station < $1.station } }

    /// Tiles given out and not yet accepted.
    public var inFlight: [Assignment] {
        workers.values.compactMap { worker in
            guard let current = worker.current, accepted[current.tile] == nil,
                  let assignment = assignments[current.tile], assignment.epoch == current.epoch else { return nil }
            return assignment
        }
        .sorted { $0.tile < $1.tile }
    }

    /// The run so far, or until it was complete, in 2MHz cycles.
    public var elapsedCycles: UInt64? {
        runStart.map { start in (completedAt ?? now) - min(start, completedAt ?? now) }
    }

    public var elapsedSeconds: Double? { elapsedCycles.map { Double($0) / 2_000_000 } }

    /// A pixel's count, if its tile's in the picture.
    public func count(x: Int, y: Int) -> UInt8? {
        guard x >= 0, y >= 0, x < MandelbrotProtocol.imageWidth, y < MandelbrotProtocol.imageHeight else { return nil }
        let i = y * MandelbrotProtocol.imageWidth + x
        return covered[i] ? image[i] : nil
    }

    public mutating func observe<Frames: Sequence<EconetFrame>>(_ frames: Frames) {
        for frame in frames { observe(frame) }
    }

    public mutating func observe(_ frame: EconetFrame) {
        if let lastFrame, frame.id > lastFrame + 1 { missedFrames += frame.id - lastFrame - 1 }
        lastFrame = max(lastFrame ?? frame.id, frame.id)
        advance(to: frame.end)
        guard let reading = traffic.read(frame) else { return }
        guard case .success(let message) = reading.message else {
            malformed += 1
            return
        }
        messages += 1
        handle(message, port: reading.port, from: reading.from, to: reading.to, at: frame.start, length: frame.payload.count)
    }

    /// Time passing with nothing on the line (a worker can still time out).
    public mutating func advance(to cycles: UInt64) {
        now = max(now, cycles)
        for station in workers.keys {
            if let worker = workers[station], worker.current != nil, !worker.stalled,
               now > worker.assignedAt + Self.timeout {
                workers[station]?.stalled = true
            }
        }
    }

    // MARK: Messages

    private mutating func handle(_ message: MandelbrotMessage, port: UInt8, from: UInt8, to: UInt8?, at cycles: UInt64, length: Int) {
        switch MandelbrotProtocol.Port(rawValue: port) {
        case .coordinator:
            fromWorker(message, station: from, coordinator: to, at: cycles, length: length)
        case .worker:
            if let to { fromCoordinator(message, station: from, worker: to, at: cycles) }
        case .launcher, .bootstrap, nil:
            // Launching and stopping: workers come and go, but there's
            // nothing of the render in them.
            break
        }
    }

    /// HELLO, READY and RESULT, on &B0.
    private mutating func fromWorker(_ message: MandelbrotMessage, station: UInt8, coordinator: UInt8?, at cycles: UInt64, length: Int) {
        if let coordinator, self.coordinator == nil { self.coordinator = coordinator }
        var worker = workers[station] ?? Worker(station: station)
        worker.lastHeard = cycles
        worker.bytes += length
        // Is it in this run? (The coordinator sends one that isn't a
        // WELCOME, and it gives up what it had.)
        let current = runId == nil || message.header.runId == runId
        switch message.body {
        case .hello(let hello):
            worker.machine = hello.machine
            // Registering again: its tile goes back in the queue.
            worker.current = nil
            worker.sent = false
            worker.stalled = false
        case .ready:
            if current {
                worker.current = nil
                worker.sent = false
                worker.stalled = false
            }
        case .result(let result):
            worker.resultsSent += 1
            let key = TileEpoch(tile: Int(result.tileId), epoch: Int(result.epoch))
            if current {
                if received[key] == nil {
                    received[key] = Received(station: station, tile: key.tile, epoch: key.epoch, x: Int(result.x), y: Int(result.y),
                                             width: Int(result.width), height: Int(result.height), counts: result.counts, cycles: cycles)
                }
                if worker.current == key {
                    worker.sent = true
                    worker.stalled = false
                }
            }
        default:
            break
        }
        workers[station] = worker
    }

    /// WELCOME, ASSIGN, ACK and COMPLETE, on &B1.
    private mutating func fromCoordinator(_ message: MandelbrotMessage, station: UInt8, worker: UInt8, at cycles: UInt64) {
        if coordinator != station || runId != message.header.runId {
            begin(run: message.header.runId, coordinator: station, at: cycles)
        }
        var w = workers[worker] ?? Worker(station: worker)
        switch message.body {
        case .welcome(let welcome):
            maxIterations = Int(welcome.maxIterations)
            // A worker always obeys a WELCOME: it gives up its tile.
            w.current = nil
            w.sent = false
            w.stalled = false
        case .assign(let assign):
            maxIterations = Int(assign.maxIterations)
            let key = TileEpoch(tile: Int(assign.tileId), epoch: Int(assign.epoch))
            assignments[key.tile] = Assignment(tile: key.tile, epoch: key.epoch, station: worker, x: Int(assign.x), y: Int(assign.y),
                                               width: Int(assign.width), height: Int(assign.height), cycles: cycles)
            if w.current != key {
                w.current = key
                w.sent = false
                w.assignedAt = cycles
            }
            w.stalled = false
            // The tile was someone else's before: they don't have it now.
            for (other, them) in workers where other != worker && them.current?.tile == key.tile {
                workers[other]?.current = nil
                workers[other]?.sent = false
            }
        case .ack(let ack):
            let key = TileEpoch(tile: Int(ack.tileId), epoch: Int(ack.epoch))
            switch ack.status {
            case 0:
                accept(key, from: worker, into: &w, at: cycles)
            case 1:
                // Already done: an earlier ACK for it didn't get through (a
                // worker resends until it hears), so it was accepted then.
                w.duplicates += 1
                if accepted[key.tile] == nil {
                    accept(key, from: worker, into: &w, at: cycles)
                }
            case 2: w.stale += 1
            default: break
            }
            // It's still there, whatever it was answered.
            w.stalled = false
            if w.current == key {
                w.current = nil
                w.sent = false
            }
        case .complete:
            if !completeSeen {
                completeSeen = true
                completedAt = cycles
            }
            w.current = nil
            w.sent = false
            w.stalled = false
        default:
            break
        }
        workers[worker] = w
    }

    private mutating func accept(_ key: TileEpoch, from station: UInt8, into worker: inout Worker, at cycles: UInt64) {
        let result = received[key].flatMap { $0.station == station ? $0 : nil }
        if let previous = accepted[key.tile], previous.epoch == key.epoch { return }
        accepted[key.tile] = Accepted(epoch: key.epoch, station: station, cycles: cycles, drawn: result != nil)
        worker.tiles += 1
        if let result {
            worker.pixels += result.width * result.height
            worker.iterations += result.counts.reduce(0) { $0 + Int($1) }
            draw(result)
        } else if let assignment = assignments[key.tile] {
            worker.pixels += assignment.width * assignment.height
        }
    }

    private mutating func draw(_ result: Received) {
        let width = MandelbrotProtocol.imageWidth, height = MandelbrotProtocol.imageHeight
        for dy in 0 ..< result.height {
            for dx in 0 ..< result.width {
                let x = result.x + dx, y = result.y + dy
                guard x < width, y < height else { continue }
                image[y * width + x] = result.counts[dy * result.width + dx]
                covered[y * width + x] = true
            }
        }
    }

    /// A new coordinator, or a new run of MANDEL: start again, keeping
    /// the workers (but not what they'd done).
    private mutating func begin(run: UInt32, coordinator station: UInt8, at cycles: UInt64) {
        coordinator = station
        runId = run
        runStart = cycles
        completedAt = nil
        completeSeen = false
        assignments = [:]
        received = [:]
        accepted = [:]
        image = [UInt8](repeating: 0, count: image.count)
        covered = [Bool](repeating: false, count: covered.count)
        for station in workers.keys {
            let old = workers[station]!
            var fresh = Worker(station: station)
            fresh.machine = old.machine
            fresh.lastHeard = old.lastHeard
            workers[station] = fresh
        }
    }
}
