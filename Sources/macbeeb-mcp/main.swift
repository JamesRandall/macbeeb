// macbeeb-mcp: an MCP server that lets AI agents drive a BBC Micro.
//
//   macbeeb-mcp            run a headless BBC Micro of its own (a Model B,
//                          or with --master a Master 128)
//   macbeeb-mcp --attach   drive the running MacBeeb app's machine
//
// Add to Claude Code with: claude mcp add macbeeb -- /path/to/macbeeb-mcp

import BeebAgentKit
import BeebCore
import BeebHost
import BeebROMs
import Foundation

let arguments = CommandLine.arguments.dropFirst()

let tools: ToolProvider
if arguments.contains("--attach") {
    tools = AppConnection()
} else {
    let configuration = BeebROMs.configuration(for: arguments.contains("--master") ? .master128 : .modelB)
    let session = HeadlessSession {
        BBCMicro(configuration: configuration)
    }
    session.machine.runUntilIdle()
    tools = AgentTools(context: session)
}

MCPServer(tools: tools, instructions: mcpInstructions).run()
