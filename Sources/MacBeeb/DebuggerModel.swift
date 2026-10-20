import BeebCore
import BeebHost
import Foundation
import Observation

/// The debugger window's view of one machine.
@MainActor
@Observable
final class DebuggerModel {
    private let host: EmulatorHost
    private(set) var snapshot: DebugSnapshot?
    /// The memory view's bytes as of the last stop, to show changes.
    private(set) var previousMemory: [UInt8?] = []
    var view = DebugView() {
        didSet { if view != oldValue { refresh() } }
    }
    /// The last error from a command, shown in the window.
    var message: String?
    /// True while the debugger window is on screen.
    var isVisible = false {
        didSet {
            host.setInspecting(isVisible)
            if isVisible { refresh() }
        }
    }
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private var refreshAgain = false
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastStop: StopReason?

    init(host: EmulatorHost) {
        self.host = host
        // While running, refresh a few times a second.
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isVisible else { return }
                if self.host.debugStop == nil || self.host.debugStop != self.lastStop {
                    self.refresh()
                }
            }
        }
    }

    var isStopped: Bool { snapshot?.stopReason != nil }
    var cpu: DebugCPU { view.cpu }

    /// Fetches a new snapshot from the emulation thread.
    func refresh() {
        guard !refreshing else {
            refreshAgain = true
            return
        }
        refreshing = true
        let view = self.view
        Task {
            let result = try? await host.performAsync { session in
                DebugSnapshot(machine: session.machine, view: view)
            }
            refreshing = false
            if let result {
                if result.stopReason != nil && result.stopReason != lastStop, let old = snapshot,
                   old.view.memorySpace == result.view.memorySpace, old.view.memoryAddress == result.view.memoryAddress {
                    previousMemory = old.memory
                }
                lastStop = result.stopReason
                snapshot = result
            }
            if refreshAgain {
                refreshAgain = false
                refresh()
            }
        }
    }

    /// Runs `body` on the emulation thread, then refreshes.
    private func command(_ body: @escaping @Sendable (BBCMicro) throws -> Void) {
        Task {
            do {
                try await host.performAsync { session in try body(session.machine) }
                message = nil
            } catch {
                message = "\(error)"
            }
            refresh()
        }
    }

    // MARK: Running

    func pauseOrContinue() {
        if isStopped {
            command { $0.debugger.resume() }
        } else {
            command { $0.debugger.requestStop() }
        }
    }

    func run(_ runCommand: RunCommand) {
        let cpu = view.cpu
        if runCommand == .stepCycle {
            command { m in
                m.debugger.resume()
                m.run(cycles: 1)
                if m.debugger.stopReason == nil {
                    m.debugger.requestStop()
                }
            }
        } else {
            command { $0.debugger.begin(runCommand, cpu: cpu) }
        }
    }

    // MARK: Breakpoints

    func toggleBreakpoint(at address: UInt16) {
        let cpu = view.cpu
        command { m in
            if let existing = m.debugger.breakpoints.first(where: { $0.cpu == cpu && $0.kind == .execute && $0.start == address && $0.end == address }) {
                m.debugger.remove(id: existing.id)
            } else {
                try m.debugger.add(Breakpoint(cpu: cpu, start: address))
            }
        }
    }

    func addBreakpoint(_ breakpoint: Breakpoint) {
        command { try $0.debugger.add(breakpoint) }
    }

    func updateBreakpoint(_ breakpoint: Breakpoint) {
        command { try $0.debugger.update(breakpoint) }
    }

    func removeBreakpoint(id: Int) {
        command { $0.debugger.remove(id: id) }
    }

    func removeAllBreakpoints() {
        command { $0.debugger.removeAllBreakpoints() }
    }

    // MARK: State

    func setRegister(_ name: String, to value: Int) {
        let cpu = view.cpu
        command { try $0.setRegister(name, cpu: cpu, to: value) }
    }

    func write(_ value: UInt8, at address: Int) {
        let space = view.memorySpace
        command { m in
            guard m.debugWrite(space, address, value) else {
                throw DebuggerError("can't write &\(String(address, radix: 16, uppercase: true)) there")
            }
        }
    }

    func setTracing(_ on: Bool) {
        command { $0.debugger.setTracing(capacity: on ? 100_000 : 0) }
    }

    /// A number, or else an expression evaluated now.
    func address(_ text: String) async -> Int? {
        if let n = parseNumber(text) {
            return n
        }
        return await evaluate(text)
    }

    /// Evaluates an address expression (registers, memory, symbols) now.
    func evaluate(_ text: String) async -> Int? {
        let cpu = view.cpu
        return try? await host.performAsync { session in
            try DebugExpression(text).evaluate(session.machine.debugger.expressionContext(cpu))
        }
    }
}

struct DebuggerError: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}
