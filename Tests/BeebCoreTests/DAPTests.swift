import Foundation
import Synchronization
import Testing
import BeebAgentKit
import BeebCore
@testable import BeebDAP
import BeebHost
import BeebROMs

final class MessageBox: Sendable {
    let list = Mutex<[JSONValue]>([])
}

/// A scripted DAP client talking to a session.
final class DAPClient: Sendable {
    let box = MessageBox()
    let session: DAPSession
    let host: EmulatorHost
    private let nextSeq = Atomic<Int>(1)

    init(model: BBCMicro.Model = .modelB) {
        let configuration = BeebROMs.configuration(for: model)
        host = EmulatorHost { BBCMicro(configuration: configuration) }
        host.start()
        host.send(.setSpeedLimited(false))
        let box = self.box
        session = DAPSession(host: host, send: { message in box.list.withLock { $0.append(message) } })
    }

    deinit {
        host.stop()
    }

    /// Sends a request and waits for its response.
    func request(_ command: String, _ arguments: JSONValue = .object([:])) async throws -> JSONValue {
        let seq = nextSeq.add(1, ordering: .relaxed).oldValue
        await session.handle(["type": "request", "seq": .number(Double(seq)), "command": .string(command), "arguments": arguments])
        let response = box.list.withLock { list in list.first { $0["type"] == "response" && $0["request_seq"]?.intValue == seq } }
        return try #require(response, "no response to \(command)")
    }

    /// Waits for (and removes) the next event called `name`.
    func event(_ name: String, timeout: Double = 20) async throws -> JSONValue {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let found = box.list.withLock { list -> JSONValue? in
                guard let index = list.firstIndex(where: { $0["type"] == "event" && $0["event"]?.stringValue == name }) else { return nil }
                return list.remove(at: index)
            }
            if let found { return found }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("no \(name) event")
        throw CancellationError()
    }
}

struct DAPTests {
    var resources: String { Bundle.module.resourceURL!.appendingPathComponent("Resources/symbols").path }

    @Test func framing() throws {
        var buffer = try DAPServer.frame(["a": 1]) + DAPServer.frame(["b": "two"])
        let partial = try DAPServer.frame(["c": true])
        buffer += partial.prefix(10)
        let messages = DAPServer.messages(from: &buffer)
        #expect(messages == [["a": 1], ["b": "two"]])
        buffer += partial.dropFirst(10)
        #expect(DAPServer.messages(from: &buffer) == [["c": true]])
        #expect(buffer.isEmpty)
    }

    @Test func debuggingASourceProgram() async throws {
        let client = DAPClient()
        let initialize = try await client.request("initialize", ["adapterID": "macbeeb"])
        #expect(initialize["body"]?["supportsStepBack"] == true)
        _ = try await client.event("initialized")

        let launch = try await client.request("launch", ["program": .string(resources + "/hello.bin")])
        #expect(launch["success"] == true, "\(launch)")
        let output = try await client.event("output")
        #expect(output["body"]?["output"]?.stringValue?.contains("source lines") == true)

        // A breakpoint on a blank line moves to the next with code.
        let set = try await client.request("setBreakpoints", ["source": ["path": .string(resources + "/hello.s")],
                                                              "breakpoints": [["line": 17]]])
        let breakpoint = try #require(set["body"]?["breakpoints"]?.arrayValue?.first)
        #expect(breakpoint["verified"] == true && breakpoint["line"] == 19, "\(set)")
        _ = try await client.request("configurationDone")

        let stopped = try await client.event("stopped")
        #expect(stopped["body"]?["reason"] == "breakpoint" && stopped["body"]?["threadId"] == 1, "\(stopped)")

        let threads = try await client.request("threads")
        #expect(threads["body"]?["threads"]?.arrayValue?.count == 1)

        let trace = try await client.request("stackTrace", ["threadId": 1])
        let frames = try #require(trace["body"]?["stackFrames"]?.arrayValue)
        #expect(frames[0]["name"] == "print" && frames[0]["line"] == 19, "\(frames)")
        #expect(frames[0]["source"]?["path"]?.stringValue == resources + "/hello.s")
        // Called from loop's JSR at hello.s:12.
        #expect(frames.count >= 2 && frames[1]["line"] == 12 && frames[1]["name"] == "loop+5", "\(frames)")

        let registers = try await client.request("variables", ["variablesReference": 1])
        let a = registers["body"]?["variables"]?.arrayValue?.first { $0["name"] == "A" }
        #expect(a?["value"] == "&48 (72)", "\(registers)") // "H"

        let evaluated = try await client.request("evaluate", ["expression": "message", "context": "hover"])
        #expect(evaluated["body"]?["result"]?.stringValue?.hasPrefix("&2017 (8215)  [48 45 4C 4C") == true, "\(evaluated)")

        let memory = try await client.request("readMemory", ["memoryReference": "0x2017", "count": 5])
        #expect(memory["body"]?["data"]?.stringValue.flatMap { Data(base64Encoded: $0) } == Data("HELLO".utf8))

        let code = try await client.request("disassemble", ["memoryReference": "0x2011", "instructionCount": 2])
        let lines = try #require(code["body"]?["instructions"]?.arrayValue)
        #expect(lines.map { $0["instruction"]?.stringValue } == ["INC count", "JMP OSWRCH"], "\(lines)")
        #expect(lines[0]["line"] == 19)
        let before = try await client.request("disassemble", ["memoryReference": "0x2011", "instructionOffset": -2, "instructionCount": 3])
        // Two before the reference, then the reference.
        #expect(before["body"]?["instructions"]?.arrayValue?.map { $0["address"] } == ["0x200D", "0x2010", "0x2011"], "\(before)")

        // Step, then back again.
        _ = try await client.request("next", ["threadId": 1])
        #expect(try await client.event("stopped")["body"]?["reason"] == "step")
        let afterStep = try await client.request("stackTrace", ["threadId": 1])
        #expect(afterStep["body"]?["stackFrames"]?.arrayValue?.first?["line"] == 20)
        _ = try await client.request("stepBack", ["threadId": 1])
        _ = try await client.event("stopped")
        let back = try await client.request("stackTrace", ["threadId": 1])
        #expect(back["body"]?["stackFrames"]?.arrayValue?.first?["line"] == 19)

        // Watch count, and log at loop instead of stopping there.
        let info = try await client.request("dataBreakpointInfo", ["name": "count"])
        let dataId = try #require(info["body"]?["dataId"]?.stringValue)
        _ = try await client.request("setBreakpoints", ["source": ["path": .string(resources + "/hello.s")],
                                                        "breakpoints": [["line": 10, "logMessage": "X={X}"]]])
        _ = try await client.request("setDataBreakpoints", ["breakpoints": [["dataId": .string(dataId), "accessType": "write"]]])
        // (It stops again before a poll could see it running, so there's no
        // continued event; the client asked to continue, so needn't be told.)
        _ = try await client.request("continue", ["threadId": 1])
        // At INC count, so the watchpoint hits at once; next time round,
        // the log point runs first.
        let watch = try await client.event("stopped")
        #expect(watch["body"]?["reason"] == "data breakpoint", "\(watch)")
        _ = try await client.request("continue", ["threadId": 1])
        _ = try await client.event("stopped")
        let log = try await client.event("output")
        #expect(log["body"]?["output"] == "X=&1\n", "\(log)")

        _ = try await client.request("disconnect")
        try await Task.sleep(for: .milliseconds(100))
        #expect(client.host.debugStop == nil)
    }

    @Test func stopOnEntryAndSettingRegisters() async throws {
        let client = DAPClient()
        _ = try await client.request("initialize")
        _ = try await client.request("launch", ["program": .string(resources + "/hello.bin"), "stopOnEntry": true])
        _ = try await client.request("configurationDone")
        let stopped = try await client.event("stopped")
        #expect(stopped["body"]?["reason"] == "entry", "\(stopped)")
        let set = try await client.request("setVariable", ["variablesReference": 1, "name": "A", "value": "&41"])
        #expect(set["body"]?["value"] == "&41 (65)")
        let function = try await client.request("setFunctionBreakpoints", ["breakpoints": [["name": "done"], ["name": "nowhere"]]])
        let results = function["body"]?["breakpoints"]?.arrayValue
        #expect(results?.map { $0["verified"] } == [true, false])
        _ = try await client.request("continue")
        let done = try await client.event("stopped")
        #expect(done["body"]?["reason"] == "breakpoint")
        let pc = try await client.request("evaluate", ["expression": "PC"])
        #expect(pc["body"]?["result"]?.stringValue?.hasPrefix("&200D") == true)
        _ = try await client.request("disconnect")
    }
}
