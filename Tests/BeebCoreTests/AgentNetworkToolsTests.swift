// MCP with several machines: `machine` picks one, network tools go to the
// app's directory, and errors say what's wrong.

import Foundation
import Testing
import BeebAgentKit
import BeebCore
import BeebHost
import BeebROMs

/// A directory with two named stations.
final class FakeDirectory: MachineDirectory, @unchecked Sendable {
    let stations: [String: HeadlessSession]
    var networkCalls: [String] = []

    init(_ stations: [String: HeadlessSession]) {
        self.stations = stations
    }

    func machines() -> [AgentMachine] {
        stations.keys.sorted().map { AgentMachine(id: $0, name: $0, network: "Test", station: nil, role: "BBC Micro", model: "BBC Model B", poweredOn: true) }
    }

    func context(for name: String) -> Result<MachineContext, AgentToolError> {
        stations[name].map { .success($0) } ?? .failure(AgentToolError("not_found: no station \"\(name)\""))
    }

    func networkTool(_ name: String, arguments: JSONValue) -> ToolResult {
        networkCalls.append(name)
        return .text("handled \(name)")
    }
}

struct AgentNetworkToolsTests {
    let support = AgentToolsTests()

    func station(_ number: Int) -> HeadlessSession {
        let configuration = BeebROMs.configuration(for: .modelB, econetStation: number)
        let session = HeadlessSession { BBCMicro(configuration: configuration) }
        session.advance(seconds: 1)
        return session
    }

    @Test func machineArgumentPicksTheStation() {
        let one = station(1), two = station(2)
        let tools = AgentTools(defaultContext: { nil }, directory: FakeDirectory(["BBC 1": one, "BBC 2": two]))
        _ = tools.call("poke", arguments: ["machine": "BBC 2", "address": "&3000", "bytes": [42]])
        #expect(two.machine.peek(0x3000) == 42)
        #expect(one.machine.peek(0x3000) != 42)
        let missing = tools.call("get_status", arguments: ["machine": "BBC 9"])
        #expect(missing.isError && support.text(missing).hasPrefix("not_found:"))
        let noDefault = tools.call("get_status", arguments: [:])
        #expect(noDefault.isError && support.text(noDefault).hasPrefix("no_machine:"))
    }

    @Test func networkToolsGoToTheDirectory() {
        let directory = FakeDirectory([:])
        let tools = AgentTools(defaultContext: { nil }, directory: directory)
        #expect(support.text(tools.call("network_trace", arguments: [:])) == "handled network_trace")
        #expect(directory.networkCalls == ["network_trace"])
        let headless = AgentTools(context: station(1))
        let refused = headless.call("list_machines", arguments: [:])
        #expect(refused.isError && support.text(refused).hasPrefix("not_available:"))
    }

    @Test func everyToolTakesAMachine() {
        for definition in AgentTools.definitions where !["list_machines", "network_status", "network_pause", "network_trace", "print_jobs",
                                                         "print_job", "export_print_job_pdf", "network_create", "network_open"].contains(definition.name) {
            #expect(definition.inputSchema["properties"]?["machine"] != nil, "\(definition.name)")
        }
        #expect(AgentTools.definitions.contains { $0.name == "econet_status" })
    }

    @Test func econetStatusReportsTheADLC() {
        let tools = AgentTools(context: station(7))
        let text = support.text(tools.call("econet_status", arguments: [:]))
        #expect(text.contains("station: 7"), "\(text)")
        #expect(text.contains("no clock (/DCD high)"), "\(text)")
        #expect(text.contains("SR2 "), "\(text)")
        let plain = AgentTools(context: HeadlessSession { BBCMicro(configuration: BeebROMs.configuration(for: .modelB)) })
        #expect(support.text(plain.call("econet_status", arguments: [:])).hasPrefix("No Econet module"))
    }
}
