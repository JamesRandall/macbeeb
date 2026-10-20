import BeebAgentKit
import BeebCore
import BeebHost
import BeebROMs
import Foundation
import Testing

struct AgentToolsTests {
    func makeTools() -> AgentTools {
        let os = BeebROMs.data(.os12), basic = BeebROMs.data(.basic2), dfs = BeebROMs.data(.dfs12)
        let session = HeadlessSession { BBCMicro(os: os, sidewaysROMs: [15: basic, 14: dfs]) }
        session.machine.runUntilIdle()
        return AgentTools(context: session)
    }

    func text(_ result: ToolResult) -> String {
        result.content.compactMap { if case .text(let t) = $0 { t } else { nil } }.joined()
    }

    @Test func runCommandReturnsOutput() {
        let tools = makeTools()
        let result = tools.call("run_command", arguments: ["text": "PRINT 6*7"])
        #expect(!result.isError)
        #expect(text(result).contains("42"))
    }

    @Test func powerCycleKeepsTheMaster512ToTheMaster() {
        let session = HeadlessSession {
            BBCMicro(configuration: BeebROMs.configuration(for: .master128, secondProcessor: true, coprocessor: .master512,
                                                           systemDisc: false))
        }
        let tools = AgentTools(context: session)
        // Asked for on a B: refused.
        let refused = tools.call("power_cycle", arguments: ["model": "model_b", "coprocessor": "master512"])
        #expect(refused.isError && text(refused).contains("master_128"), "\(text(refused))")
        // Kept from the Master: the B gets a 6502 instead.
        #expect(!tools.call("power_cycle", arguments: ["model": "model_b"]).isError)
        #expect(session.machine.model == .modelB && session.machine.master512 == nil && session.machine.secondProcessor != nil)
    }

    @Test func peekAndPoke() {
        let tools = makeTools()
        #expect(!tools.call("poke", arguments: ["address": "&3000", "bytes": [0x12, 0xAB]]).isError)
        #expect(text(tools.call("peek", arguments: ["address": "&3000", "length": 2])).contains("12 AB"))
        // ROM can be patched; I/O can't be poked.
        #expect(!tools.call("poke", arguments: ["address": "&C000", "bytes": [1]]).isError)
        #expect(text(tools.call("peek", arguments: ["address": "&C000", "length": 1])).contains("C000  01"))
        #expect(tools.call("poke", arguments: ["address": "&FE40", "bytes": [1]]).isError)
    }

    @Test func runUntilAddressStopsThere() {
        let tools = makeTools()
        _ = tools.call("run_command", arguments: ["text": "P%=&3000:[OPT0:.L INX:JMP L:]"])
        _ = tools.call("type_text", arguments: ["text": "CALL &3000\n", "settle_seconds": 0])
        let result = tools.call("run_until_address", arguments: ["address": "&3001"])
        #expect(text(result).contains("reached &3001"))
        #expect(text(tools.call("get_status", arguments: [:])).contains("PC=&3001"))
    }

    @Test func pressKeysAndScreenshot() throws {
        let tools = makeTools()
        _ = tools.call("press_keys", arguments: ["keys": ["SHIFT", "A"]])
        #expect(text(tools.call("read_screen_text", arguments: [:])).contains(">A"))
        let shot = tools.call("screenshot", arguments: [:])
        guard case .png(let data) = try #require(shot.content.first) else {
            Issue.record("no image")
            return
        }
        #expect(data.count > 1000)
    }

    @Test func loadDiscBoots() throws {
        let tools = makeTools()
        let path = Bundle.module.resourceURL!.appendingPathComponent("Resources/discs/beeb_6502_timing_tests.ssd").path
        let result = tools.call("load_disc", arguments: ["path": .string(path), "max_seconds": 60])
        #expect(!result.isError)
        #expect(text(result).contains("TIMINGS"))
        #expect(text(result).contains("Total: 81"))
    }

    @Test func loadTapeChainsTheProgram() throws {
        let tools = makeTools()
        let path = Bundle.module.resourceURL!.appendingPathComponent("Resources/tapes/pugwash.uef").path
        let result = tools.call("load_tape", arguments: ["path": .string(path), "max_seconds": 40])
        #expect(!result.isError)
        #expect(text(result).contains("Pugwash Tune"), "\(text(result))")
        #expect(text(tools.call("rewind_tape", arguments: [:])) == "rewound")
    }

    @Test func recording() throws {
        let tools = makeTools()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("macbeeb-agent-test.mp4")
        #expect(!tools.call("start_recording", arguments: ["path": .string(url.path)]).isError)
        _ = tools.call("run_command", arguments: ["text": "PRINT \"RECORDED\""])
        _ = tools.call("run", arguments: ["seconds": 1])
        #expect(text(tools.call("stop_recording", arguments: [:])) == "recording finished")
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0
        #expect(size > 10_000)
    }

    @Test func mcpProtocol() {
        let server = MCPServer(tools: makeTools(), instructions: "test")
        let initialize = server.handle(["jsonrpc": "2.0", "id": 1, "method": "initialize",
                                        "params": ["protocolVersion": "2025-06-18"]])
        #expect(initialize?["result"]?["protocolVersion"]?.stringValue == "2025-06-18")
        #expect(server.handle(["jsonrpc": "2.0", "method": "notifications/initialized"]) == nil)
        let list = server.handle(["jsonrpc": "2.0", "id": 2, "method": "tools/list"])
        #expect((list?["result"]?["tools"]?.arrayValue?.count ?? 0) > 15)
        let unknown = server.handle(["jsonrpc": "2.0", "id": 3, "method": "nope"])
        #expect(unknown?["error"]?["code"]?.intValue == -32601)
    }
}

struct AgentSnapshotTests {
    @Test func snapshotAndRestore() {
        let tools = AgentToolsTests().makeTools()
        _ = tools.call("run_command", arguments: ["text": "A%=1"])
        _ = tools.call("save_snapshot", arguments: ["name": "before"])
        _ = tools.call("run_command", arguments: ["text": "A%=2"])
        let restored = tools.call("restore_snapshot", arguments: ["name": "before"])
        #expect(!restored.isError)
        let output = AgentToolsTests().text(tools.call("run_command", arguments: ["text": "PRINT A%"]))
        #expect(output.contains("         1"))
    }
}
