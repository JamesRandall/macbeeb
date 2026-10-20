// Reverse debugging, by searching the rewind history.

extension Debugger {
    public enum ReverseError: Error, CustomStringConvertible {
        case noHistory

        public var description: String { "rewind isn't on, so there's no history to go back through" }
    }

    /// Goes back to the previous instruction on `cpu` (or the start of the
    /// current one, if stopped in the middle of it), and stops there.
    public func stepBack(_ cpu: DebugCPU = .host) throws(ReverseError) {
        guard let rewinder = machine.rewinder else { throw .noHistory }
        let now = position
        var found: Position?
        search(rewinder, before: machine.cycles) { found = nil } observe: { which, _, access in
            if which == cpu && access == .opcode, self.currentPosition(after: false) < now {
                found = self.currentPosition(after: false)
            }
        } done: {
            found != nil
        }
        if let found {
            seek(rewinder, to: found, z80Instruction: cpu == .parasite)
            stop(.stepped(cpu))
        } else {
            atHistoryStart(rewinder)
        }
    }

    /// Runs backwards to the last breakpoint hit before now, and stops there
    /// (as if it had just hit). Log points and hit counts don't count.
    public func reverseContinue() throws(ReverseError) {
        guard let rewinder = machine.rewinder else { throw .noHistory }
        let now = position
        var found: (position: Position, reason: StopReason)?
        search(rewinder, before: machine.cycles) { found = nil } observe: { cpu, address, access in
            let kind: Breakpoint.Kind
            switch access {
            case .opcode: kind = .execute
            case .write: kind = .write
            case .data, .address: kind = .read
            default: return
            }
            let flags = cpu == .host ? self.hostFlags[Int(address)] : self.parasiteFlags[Int(address)]
            // A Z80 stops after the instruction that accessed it.
            let here = self.currentPosition(after: cpu == .parasite && kind != .execute)
            guard flags & kind.rawValue != 0, here < now else { return }
            if let index = self.matchingBreakpoints(cpu, address, kind).first(where: { self.breakpoints[$0].logMessage == nil }) {
                found = (here, .breakpoint(id: self.breakpoints[index].id, cpu: cpu, address: address, kind: kind))
            }
        } done: {
            found != nil
        }
        if let found {
            if case .breakpoint(_, let cpu, _, let kind) = found.reason {
                seek(rewinder, to: found.position, z80Instruction: cpu == .parasite && kind == .execute)
            }
            stop(found.reason)
        } else {
            atHistoryStart(rewinder)
        }
    }

    /// A point in history a stop can be at: the host cycle a stop
    /// happened in, and with a Z80, the instructions it had run in that
    /// cycle (a host stop comes before any).
    typealias Position = (cycle: UInt64, step: Int)

    /// Where the machine is now.
    private var position: Position {
        if let z = machine.z80Processor {
            return (z.stepCycle, z.executed)
        }
        return (machine.cycles &- 1, 0)
    }

    /// During a search, the position a stop at this access would leave;
    /// `after` for a Z80 data access (it stops after the instruction).
    private func currentPosition(after: Bool) -> Position {
        if let z = machine.z80Processor {
            return (machine.cycles, z.executed + (after ? 1 : 0))
        }
        return (machine.cycles, 0)
    }

    /// Goes back to `p`. With a Z80, that's into its cycle: as far as the
    /// instruction (and the next is about to run, so `z80Instruction`
    /// doesn't stop there again on resuming).
    private func seek(_ rewinder: Rewinder, to p: Position, z80Instruction: Bool) {
        guard machine.z80Processor != nil else {
            try? rewinder.seek(to: p.cycle + 1)
            return
        }
        try? rewinder.seek(to: p.cycle)
        resume()
        z80SeekTarget = p.step
        forceHooks = true
        // Run the cycle as `run` would, without starting a new future.
        if machine.cycles % 1000 == 0 { machine.processKeyEvents() }
        machine.step()
        z80SeekTarget = nil
        forceHooks = false
        z80Skip = z80Instruction && machine.z80Processor?.stoppedEarly == true
    }

    /// Replays windows of history, latest first, until `done`: each window
    /// runs from a rewind point to the next (or `end`), with `observe`
    /// seeing every access.
    private func search(_ rewinder: Rewinder, before end: UInt64, reset: () -> Void,
                        observe: @escaping (DebugCPU, UInt16, M6502.BusAccess) -> Void, done: () -> Bool) {
        rewinder.flushKeyframe()
        forceHooks = true
        replayObserver = observe
        defer {
            replayObserver = nil
            forceHooks = false
        }
        let points = rewinder.points
        guard var index = points.lastIndex(where: { $0.cycle < end }) else { return }
        while true {
            let windowEnd = index + 1 < points.count ? min(points[index + 1].cycle, end) : end
            reset()
            rewinder.replay(from: index, to: windowEnd)
            if done() || index == 0 { break }
            index -= 1
        }
    }

    private func atHistoryStart(_ rewinder: Rewinder) {
        if let earliest = rewinder.earliestCycle {
            try? rewinder.seek(to: earliest)
        }
        stop(.historyStart)
    }
}
