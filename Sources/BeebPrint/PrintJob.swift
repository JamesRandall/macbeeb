import Foundation

/// What a BBC sent to a printer: the bytes exactly as they arrived, when,
/// and from where. Rendering is separate (`Printout`), so a job is never
/// changed by how it's drawn.
public struct PrintJob: Codable, Sendable, Identifiable, Equatable {
    public enum Status: String, Codable, Sendable {
        /// Bytes are still arriving.
        case printing
        /// The printer went quiet: the job's done.
        case finished
        /// The machine was switched off or reset part way through.
        case interrupted
        /// Too big: the rest was dropped.
        case truncated
    }

    public var id = UUID()
    /// Which printer: "Printer server (station 235)", "BBC Model B".
    public var printer: String
    /// Who sent it, when that's known: "station 1".
    public var source: String?
    public var started: Date
    public var finished: Date?
    public var status = Status.printing
    public var bytes: [UInt8] = []
    /// Each byte's arrival, in emulated 2MHz cycles since the first.
    public var cycles: [UInt32] = []

    public init(printer: String, source: String? = nil, started: Date = Date()) {
        self.printer = printer
        self.source = source
        self.started = started
    }

    /// The most a job keeps: 4MB is thousands of pages.
    public static let limit = 4 << 20
}

/// Collects a printer's bytes into jobs: a job starts with the first byte
/// after a quiet spell, and ends when the printer's been quiet for
/// `quietCycles` of emulated time. (A printer can't know when a job ends;
/// MacBeeb waits, as a person at the printer would.)
public final class PrintSpooler: @unchecked Sendable {
    public let printer: String
    /// Emulated time without a byte that ends a job (2MHz cycles).
    public var quietCycles: UInt64
    /// Called with each job as it changes (on the emulation thread).
    public var onJob: (PrintJob) -> Void

    private var job: PrintJob?
    private var firstCycle: UInt64 = 0
    private var lastCycle: UInt64 = 0
    private var reported = 0

    public init(printer: String, quietCycles: UInt64 = 6_000_000, onJob: @escaping (PrintJob) -> Void) {
        self.printer = printer
        self.quietCycles = quietCycles
        self.onJob = onJob
    }

    /// A byte arrived at `cycle`.
    public func receive(_ byte: UInt8, at cycle: UInt64) {
        if job != nil && cycle - lastCycle > quietCycles {
            finish(.finished)
        }
        if job == nil {
            job = PrintJob(printer: printer)
            firstCycle = cycle
        }
        lastCycle = cycle
        guard var current = job else { return }
        if current.bytes.count < PrintJob.limit {
            current.bytes.append(byte)
            current.cycles.append(UInt32(clamping: cycle - firstCycle))
        } else {
            current.status = .truncated
        }
        job = current
        // Report at most every 64 bytes while it prints.
        if current.bytes.count - reported >= 64 {
            reported = current.bytes.count
            onJob(current)
        }
    }

    /// Time passes (call now and then): a job that's gone quiet ends.
    public func idle(at cycle: UInt64) {
        if job != nil && cycle - lastCycle > quietCycles {
            finish(.finished)
        } else if let job, job.bytes.count != reported {
            reported = job.bytes.count
            onJob(job)
        }
    }

    /// The machine's gone: a job in progress is marked as interrupted.
    public func machineStopped() {
        if job != nil { finish(.interrupted) }
    }

    private func finish(_ status: PrintJob.Status) {
        guard var done = job else { return }
        if done.status == .printing || status == .interrupted { done.status = status }
        done.finished = Date()
        job = nil
        reported = 0
        onJob(done)
    }
}
