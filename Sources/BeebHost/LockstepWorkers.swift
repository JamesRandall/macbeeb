import Foundation
import Synchronization

/// Extra threads that run some of a network's machines through each
/// quantum alongside the network's own thread, then meet it before the line
/// delivers what they sent. Between those meetings the machines don't touch
/// each other, so which thread runs which machine can't change a result.
///
/// Quanta are 16µs of emulated time, tens of thousands a second, so the
/// threads meet far too often to sleep in between: a thread waiting for the
/// next quantum spins, and only parks on a semaphore after it's been idle a
/// while (the network's ahead of real time, or paused).
final class LockstepWorkers: @unchecked Sendable {
    /// Each worker's machines for the coming quantum. Written by the
    /// network's thread before `generation` goes up; read by the worker after.
    private var groups: [[EmulatorHost]] = []
    private var cycles = 0
    private let generation = Atomic<Int>(0)
    private let finished = Atomic<Int>(0)
    private let stopping = Atomic<Bool>(false)
    private let leaving = Atomic<Int>(0)
    private var workers: [Worker] = []

    private final class Worker: @unchecked Sendable {
        let parked = Atomic<Bool>(false)
        let wake = DispatchSemaphore(value: 0)
        var thread: Thread?
    }

    /// How long a worker spins for the next round before parking: long
    /// enough that a busy network's workers never park (a park and a wake
    /// cost more than a round's work), short enough that an idle one's
    /// soon stop using their cores.
    static let spinNanoseconds: UInt64 = 300_000

    var count: Int { workers.count }

    deinit {
        stop()
    }

    /// Starts or stops workers until there are `count`.
    func resize(to count: Int) {
        if count < workers.count {
            stop()
        }
        while workers.count < count {
            let worker = Worker()
            let index = workers.count
            workers.append(worker)
            groups.append([])
            stopping.store(false, ordering: .sequentiallyConsistent)
            // The round it starts from is now's: the thread may not get
            // going until after the next round's begun.
            let start = generation.load(ordering: .sequentiallyConsistent)
            let thread = Thread { [unowned self] in run(worker, index: index, from: start) }
            thread.name = "BBC Micro network \(index + 2)"
            thread.qualityOfService = .userInteractive
            worker.thread = thread
            thread.start()
        }
    }

    func stop() {
        guard !workers.isEmpty else { return }
        stopping.store(true, ordering: .sequentiallyConsistent)
        generation.add(1, ordering: .sequentiallyConsistent)
        for worker in workers where worker.parked.exchange(false, ordering: .sequentiallyConsistent) {
            worker.wake.signal()
        }
        // They leave (they're between rounds: run waits for each round).
        while leaving.load(ordering: .acquiring) < workers.count {}
        leaving.store(0, ordering: .sequentiallyConsistent)
        workers = []
        groups = []
    }

    /// Runs `quantum` cycles of every machine: `groups[0]` on this thread,
    /// the rest on the workers, and returns when all are done.
    func run(_ groups: [[EmulatorHost]], cycles: Int) {
        precondition(groups.count == workers.count + 1)
        for index in workers.indices {
            self.groups[index] = groups[index + 1]
        }
        self.cycles = cycles
        finished.store(0, ordering: .relaxed)
        // (Sequentially consistent, with the worker's side: a worker
        // parking as a round starts either sees the round or is seen
        // parked, never neither.)
        generation.add(1, ordering: .sequentiallyConsistent)
        for worker in workers where worker.parked.exchange(false, ordering: .sequentiallyConsistent) {
            worker.wake.signal()
        }
        for host in groups[0] {
            host.timedStep(cycles: cycles)
        }
        while finished.load(ordering: .acquiring) < workers.count {}
    }

    private func run(_ worker: Worker, index: Int, from start: Int) {
        var seen = start
        while true {
            // Wait for the next round: spin, then park.
            var spins = 0
            var spinStart: UInt64 = 0
            while generation.load(ordering: .acquiring) == seen {
                spins &+= 1
                // (The clock's read only every 1,024 turns.)
                if spins & 1023 != 0 { continue }
                let now = DispatchTime.now().uptimeNanoseconds
                if spinStart == 0 { spinStart = now }
                if now - spinStart < Self.spinNanoseconds { continue }
                worker.parked.store(true, ordering: .sequentiallyConsistent)
                if generation.load(ordering: .sequentiallyConsistent) != seen {
                    // A round started as we parked: if the network saw us
                    // parked, it signalled, and that's to be used up.
                    if !worker.parked.exchange(false, ordering: .sequentiallyConsistent) {
                        worker.wake.wait()
                    }
                    break
                }
                worker.wake.wait()
                spins = 0
                spinStart = 0
            }
            seen = generation.load(ordering: .acquiring)
            if stopping.load(ordering: .acquiring) {
                leaving.add(1, ordering: .releasing)
                return
            }
            for host in groups[index] {
                host.timedStep(cycles: cycles)
            }
            finished.add(1, ordering: .releasing)
        }
    }

    /// Splits `hosts` into `count` groups of about equal cost, by their
    /// measured cost (the dearest first, each to the cheapest group).
    static func balance(_ hosts: [EmulatorHost], into count: Int) -> [[EmulatorHost]] {
        var groups = Array(repeating: [EmulatorHost](), count: count)
        var load = Array(repeating: 0.0, count: count)
        for host in hosts.sorted(by: { $0.stepCost > $1.stepCost }) {
            let index = load.indices.min { load[$0] < load[$1] }!
            groups[index].append(host)
            load[index] += max(host.stepCost, 1)
        }
        return groups
    }
}

extension EmulatorHost {
    /// Runs a quantum of this station, measuring it now and then (every
    /// 64th) for balancing.
    @inline(__always)
    func timedStep(cycles: Int) {
        stepCount &+= 1
        if stepCount & 63 == 0 {
            let start = DispatchTime.now().uptimeNanoseconds
            drivingSession().step(cycles: cycles)
            let spent = Double(DispatchTime.now().uptimeNanoseconds - start)
            stepCost = stepCost == 0 ? spent : stepCost * 0.9 + spent * 0.1
        } else {
            drivingSession().step(cycles: cycles)
        }
        // Stopped by its debugger in that quantum: the network should look.
        if drivingSession().machine.isStoppedByDebugger {
            needsAttention.store(true, ordering: .releasing)
        }
    }
}
