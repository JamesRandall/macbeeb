// macbeeb-mcp: an MCP server that lets AI agents drive a BBC Micro.
//
//   macbeeb-mcp            run a headless BBC Micro of its own
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
    let os = BeebROMs.data(.os12), basic = BeebROMs.data(.basic2), dfs = BeebROMs.data(.dfs12)
    let session = HeadlessSession {
        BBCMicro(os: os, sidewaysROMs: [15: basic, 14: dfs])
    }
    session.machine.runUntilIdle()
    tools = AgentTools(context: session)
}

MCPServer(tools: tools, instructions: mcpInstructions).run()
