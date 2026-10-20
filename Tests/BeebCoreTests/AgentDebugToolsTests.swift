import Foundation
import Testing
@testable import BeebAgentKit
@testable import BeebCore
import BeebHost
import BeebROMs

struct AgentDebugToolsTests {
    func makeTools(_ model: BBCMicro.Model = .modelB, secondProcessor: Bool = false) -> AgentTools {
        let configuration = BeebROMs.configuration(for: model, secondProcessor: secondProcessor)
        let session = HeadlessSession { BBCMicro(configuration: configuration) }
        session.machine.runUntilIdle()
        return AgentTools(context: session)
    }

    func text(_ result: ToolResult) -> String {
        result.content.compactMap { if case .text(let t) = $0 { t } else { nil } }.joined()
    }

    /// LDA #5 : STA &70 : JSR &2010 : RTS / LDA &70 : ADC #1 : STA &71 : RTS
    func loadProgram(_ tools: AgentTools) {
        _ = tools.call("poke", arguments: ["address": "&2000", "bytes": [0xA9, 5, 0x85, 0x70, 0x20, 0x10, 0x20, 0x60]])
        _ = tools.call("poke", arguments: ["address": "&2010", "bytes": [0xA5, 0x70, 0x18, 0x69, 1, 0x85, 0x71, 0x60]])
    }

    @Test func breakpointsAndStepping() {
        let tools = makeTools()
        loadProgram(tools)
        let set = text(tools.call("set_breakpoint", arguments: ["address": "&2010"]))
        #expect(set.hasPrefix("breakpoint 1: execute &2010"), "\(set)")

        // run_command waits for idle, so it reports the stop.
        let run = text(tools.call("run_command", arguments: ["text": "CALL &2000"]))
        #expect(run.contains("stopped in the debugger: breakpoint 1"), "\(run)")

        let registers = text(tools.call("registers", arguments: [:]))
        #expect(registers.contains("host: PC=&2010 A=&05"), "\(registers)")

        let step = text(tools.call("step", arguments: ["kind": "instruction", "count": 3]))
        #expect(step.contains("> 2015  85 71"), "\(step)")
        #expect(step.contains("A=&06"), "\(step)")

        let out = text(tools.call("step", arguments: ["kind": "out"]))
        #expect(out.contains("> 2007"), "\(out)")

        let list = text(tools.call("list_breakpoints", arguments: [:]))
        #expect(list.contains("hit 1 times"), "\(list)")
        _ = tools.call("delete_breakpoint", arguments: ["all": true])
        let resumed = text(tools.call("continue", arguments: ["max_seconds": .number(0.5)]))
        #expect(resumed.contains("still running"), "\(resumed)")
    }

    @Test func watchpointsConditionsAndLogs() {
        let tools = makeTools()
        loadProgram(tools)
        _ = tools.call("set_breakpoint", arguments: ["address": "&2013", "log_message": "A={A}"])
        _ = tools.call("set_breakpoint", arguments: ["address": "&71", "type": "write", "condition": "A == 6"])
        // Typing runs the machine, so the stop shows there.
        let typed = text(tools.call("type_text", arguments: ["text": "CALL &2000\n"]))
        #expect(typed.contains("stopped in the debugger: breakpoint 2 (write &0071)"), "\(typed)")
        let registers = text(tools.call("registers", arguments: [:]))
        #expect(registers.contains("A=&06") && registers.contains("mid-instruction"), "\(registers)")
        #expect(text(tools.call("debug_log", arguments: [:])).contains("A=&5"))
        let bad = tools.call("set_breakpoint", arguments: ["address": "&2000", "condition": "A =="])
        #expect(bad.isError)
    }

    @Test func memoryInEverySpace() {
        let tools = makeTools(.master128)
        #expect(text(tools.call("memory_regions", arguments: [:])).contains("hazel"))
        #expect(!tools.call("poke", arguments: ["address": "&3000", "bytes": [0x42], "space": "shadow"]).isError)
        #expect(text(tools.call("peek", arguments: ["address": "&3000", "length": 1, "space": "shadow"])).hasPrefix("3000  42"))
        #expect(!text(tools.call("peek", arguments: ["address": "&3000", "length": 1, "space": "main"])).hasPrefix("3000  42"))
        #expect(tools.call("peek", arguments: ["address": "&9000", "space": "hazel"]).isError)
        // Expressions as addresses.
        let mos = BeebROMs.data(.mos320)
        let reset = String(Int(mos[0x3FFC]) | Int(mos[0x3FFD]) << 8, radix: 16, uppercase: true)
        #expect(text(tools.call("peek", arguments: ["address": "{&FFFC}", "length": 1])).hasPrefix(reset))
        // I/O isn't written.
        #expect(tools.call("poke", arguments: ["address": "&FE4E", "bytes": [0]]).isError)
    }

    @Test func disassemblesForTheRightCPU() {
        // PHX (&DA) is a 65C12 instruction; on the NMOS B it's undocumented.
        let master = makeTools(.master128)
        _ = master.call("poke", arguments: ["address": "&2000", "bytes": [0xDA]])
        #expect(text(master.call("disassemble", arguments: ["address": "&2000", "count": 1])).contains("PHX"))
        let b = makeTools()
        _ = b.call("poke", arguments: ["address": "&2000", "bytes": [0xDA]])
        #expect(!text(b.call("disassemble", arguments: ["address": "&2000", "count": 1])).contains("PHX"))
    }

    @Test func secondProcessor() {
        let tools = makeTools(secondProcessor: true)
        let registers = text(tools.call("registers", arguments: [:]))
        #expect(registers.contains("parasite: PC=&"), "\(registers)")
        _ = tools.call("poke", arguments: ["address": "&2000", "bytes": [0xA9, 0x42, 0x60], "space": "parasite_ram"])
        _ = tools.call("set_breakpoint", arguments: ["address": "&2002", "cpu": "parasite"])
        let typed = text(tools.call("type_text", arguments: ["text": "CALL &2000\n"]))
        #expect(typed.contains("on the parasite"), "\(typed)")
        let stopped = text(tools.call("registers", arguments: [:]))
        #expect(stopped.contains("parasite: PC=&2002 A=&42"), "\(stopped)")
        let trace = text(tools.call("trace", arguments: ["enable": 100]))
        #expect(trace.contains("tracing"))
        _ = tools.call("step", arguments: ["cpu": "parasite", "count": 5])
        // Five instructions after the RTS (which was fetched before tracing
        // started), back in BASIC.
        let lines = text(tools.call("trace", arguments: ["cpu": "parasite", "count": 10])).split(separator: "\n")
        #expect(lines.count == 5, "\(lines)")
    }
}
