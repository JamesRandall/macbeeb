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
        let now = machine.cycles
        var found: UInt64?
        search(rewinder, before: now) { found = nil } observe: { which, _, access in
            // The cycle count after this step: the state just after the
            // fetch, about to execute.
            if which == cpu && access == .opcode && self.machine.cycles + 1 < now {
                found = self.machine.cycles + 1
            }
        } done: {
            found != nil
        }
        if let found {
            try? rewinder.seek(to: found)
            stop(.stepped(cpu))
        } else {
            atHistoryStart(rewinder)
        }
    }

    /// Runs backwards to the last breakpoint hit before now, and stops there
    /// (as if it had just hit). Log points and hit counts don't count.
    public func reverseContinue() throws(ReverseError) {
        guard let rewinder = machine.rewinder else { throw .noHistory }
        let now = machine.cycles
        var found: (cycle: UInt64, reason: StopReason)?
        search(rewinder, before: now) { found = nil } observe: { cpu, address, access in
            let kind: Breakpoint.Kind
            switch access {
            case .opcode: kind = .execute
            case .write: kind = .write
            case .data, .address: kind = .read
            default: return
            }
            let flags = cpu == .host ? self.hostFlags[Int(address)] : self.parasiteFlags[Int(address)]
            guard flags & kind.rawValue != 0, self.machine.cycles + 1 < now else { return }
            if let index = self.matchingBreakpoints(cpu, address, kind).first(where: { self.breakpoints[$0].logMessage == nil }) {
                found = (self.machine.cycles + 1, .breakpoint(id: self.breakpoints[index].id, cpu: cpu, address: address, kind: kind))
            }
        } done: {
            found != nil
        }
        if let found {
            try? rewinder.seek(to: found.cycle)
            stop(found.reason)
        } else {
            atHistoryStart(rewinder)
        }
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
