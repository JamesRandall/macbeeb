// What an agent can set up and rely on: the debugger surviving a restore,
// tools carrying on from a debugger stop, holding the app's machine still
// between calls, and code read as it runs (not through the current
// instruction's shadow RAM).

import BeebAgentKit
@testable import BeebCore
import BeebHost
import BeebROMs
import Foundation
import Testing

struct AgentEnvironmentTests {
    func makeSession() -> HeadlessSession {
        let os = BeebROMs.data(.os12), basic = BeebROMs.data(.basic2), dfs = BeebROMs.data(.dfs12)
        let session = HeadlessSession { BBCMicro(os: os, sidewaysROMs: [15: basic, 14: dfs]) }
        session.machine.runUntilIdle()
        return session
    }

    func text(_ result: ToolResult) -> String {
        result.content.compactMap { if case .text(let t) = $0 { t } else { nil } }.joined()
    }

    @Test func restoringKeepsTheDebugger() throws {
        let session = makeSession()
        let tools = AgentTools(context: session)
        let labels = FileManager.default.temporaryDirectory.appendingPathComponent("restore-labels-\(UUID()).txt")
        try "player_x = $70\n".write(to: labels, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: labels) }
        #expect(!tools.call("load_symbols", arguments: ["path": .string(labels.path)]).isError)
        #expect(!tools.call("set_breakpoint", arguments: ["address": "player_x", "type": "write"]).isError)
        #expect(!tools.call("save_snapshot", arguments: [:]).isError)
        let old = session.machine

        #expect(!tools.call("restore_snapshot", arguments: [:]).isError)
        #expect(session.machine !== old)
        #expect(text(tools.call("list_breakpoints", arguments: [:])).contains("write &0070"))
        #expect(text(tools.call("lookup_symbol", arguments: ["name": "player_x"])).contains("&70"))
        // And it still stops there.
        let stopped = text(tools.call("run_command", arguments: ["text": "?&70=1"]))
        #expect(stopped.contains("stopped in the debugger"), "\(stopped)")

        // Unless asked not to.
        #expect(!tools.call("restore_snapshot", arguments: ["keep_debugger": false]).isError)
        #expect(text(tools.call("list_breakpoints", arguments: [:])) == "no breakpoints")
        #expect(tools.call("lookup_symbol", arguments: ["name": "player_x"]).isError)
    }

    @Test func powerCyclesKeepBreakpoints() {
        let session = makeSession()
        let tools = AgentTools(context: session)
        #expect(!tools.call("set_breakpoint", arguments: ["address": "&1900"]).isError)
        #expect(!tools.call("power_cycle", arguments: ["model": "master_128"]).isError)
        #expect(text(tools.call("list_breakpoints", arguments: [:])).contains("execute &1900"))
    }

    @Test func toolsCarryOnFromAStop() {
        let session = makeSession()
        let tools = AgentTools(context: session)
        session.machine.debugger.requestStop()
        session.advance(cycles: 1)
        let stopped = session.machine.cycles

        // resume: false leaves it stopped, so no time passes.
        #expect(text(tools.call("press_keys", arguments: ["keys": ["A"], "resume": false])).contains("stopped in the debugger"))
        #expect(session.machine.cycles == stopped)

        // By default it carries on: the key's typed.
        let pressed = text(tools.call("press_keys", arguments: ["keys": ["A"]]))
        #expect(!pressed.contains("stopped in the debugger") && pressed.contains(">A"), "\(pressed)")

        // Profiling too.
        session.machine.debugger.requestStop()
        session.advance(cycles: 1)
        let profile = text(tools.call("profile", arguments: ["seconds": .number(0.1)]))
        #expect(profile.contains("profiled 0.10s"), "\(profile)")
    }

    @Test func headlessMachinesAlwaysHold() {
        let tools = AgentTools(context: makeSession())
        #expect(text(tools.call("set_real_time", arguments: ["on": false])).contains("headless"))
        #expect(text(tools.call("get_status", arguments: [:])).contains("between tool calls: held still"))
    }

    /// In the app the machine runs between calls until an agent holds it.
    @Test func theAppsMachineHoldsBetweenCalls() throws {
        let os = BeebROMs.data(.os12), basic = BeebROMs.data(.basic2)
        let host = EmulatorHost { BBCMicro(os: os, sidewaysROMs: [15: basic]) }
        host.start()
        defer { host.stop() }
        let tools = AgentTools(context: host)
        Thread.sleep(forTimeInterval: 0.2)
        #expect(!tools.call("set_real_time", arguments: ["on": false]).isError)
        #expect(host.isHeldForAgent)
        let held = host.cycles
        Thread.sleep(forTimeInterval: 0.2)
        #expect(host.cycles == held)
        // Tool calls still run it.
        #expect(!tools.call("run", arguments: ["seconds": .number(0.5)]).isError)
        #expect(host.cycles == held + 1_000_000)
        #expect(!tools.call("set_real_time", arguments: ["on": true]).isError)
        Thread.sleep(forTimeInterval: 0.2)
        #expect(host.cycles > held + 1_000_000)
    }

    /// On a Master with ACCCON E set, code in the VDU drivers sees shadow
    /// RAM at &3000-&7FFF; code elsewhere sees main RAM. Stopped in the VDU
    /// drivers, the CPU's view is theirs, but code in main RAM must still
    /// disassemble as main RAM.
    @Test func codeIsReadAsItRuns() {
        let m = BBCMicro(configuration: BeebROMs.configuration(for: .master128))
        m.run(seconds: 0.5)
        #expect(m.debugWrite(.mainRAM, 0x3000, 0xA9))
        #expect(m.debugWrite(.shadowRAM, 0x3000, 0x00))
        m.acccon = 0x02
        m.updatePaging()
        // As if running in the VDU drivers.
        m.pageTable = 16
        #expect(m.debugRead(.cpu(.host), 0x3000) == 0x00)
        #expect(m.codeRead(.host, 0x3000) == 0xA9)
        // The VDU drivers' own code reads as theirs.
        #expect(m.codeRead(.host, 0xC000) == m.debugRead(.cpu(.host), 0xC000))
    }
}
