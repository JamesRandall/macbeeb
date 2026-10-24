# AI Agents

MacBeeb comes with an MCP server, `macbeeb-mcp`, that lets AI agents such as
Claude Code and Codex use a BBC Micro: type and press keys, load discs and
tapes, run BASIC, read the screen as text, take screenshots, peek and poke
memory, set breakpoints and step through the 6502, assemble with BeebAsm, and
record video. Every tool takes emulated time, so an agent's waits are exact.

The server is inside the app, at:

```
/Applications/MacBeeb.app/Contents/MacOS/macbeeb-mcp
```

(If MacBeeb isn't in Applications, use where it is: **MCP ▸ Connect an AI
Agent…** shows the commands with the right path.)

It works in one of two ways.

## Attached: the BBC Micro in front of you

With `--attach`, the agent drives MacBeeb itself while it's open: the BBC
Micro in the window, as you watch, or a station in a network. You can type
and play between its tool calls, and **MCP ▸ Activity Log** shows everything
it does.

```
claude mcp add macbeeb -- /Applications/MacBeeb.app/Contents/MacOS/macbeeb-mcp --attach
```

Choose this to work alongside an agent: to have it explain what's on the
screen, set up a program you then play, or debug with you. With a network
open, its tools can reach every station, the network's traffic, and its
print jobs.

## Headless: a BBC Micro of its own

Without `--attach`, the server runs a hidden BBC Micro of its own. MacBeeb
doesn't need to be open, and nothing appears on screen.

```
claude mcp add macbeeb-headless -- /Applications/MacBeeb.app/Contents/MacOS/macbeeb-mcp
```

It starts as a Model B; add `--master` for a Master 128. Its `power_cycle`
tool can switch it to another model, fit a second processor or a memory
board, and VideoNuLA.

Choose this for work an agent does on its own:

- **Fast.** The machine only runs during tool calls, and then as fast as the
  Mac allows, many times real time, rather than at the BBC's own speed.
- **Exact.** Nothing happens between calls, so the same calls give the same
  result, cycle for cycle: good for testing a program, or comparing before
  and after a change.
- **Out of your way.** It doesn't touch the BBC Micro you're using, so an
  agent can boot a pile of discs or run a long test while you get on.

A headless machine has no network: the Network Studio's tools need the app.

Both can be set up at once, under different names, as above.

## Codex, and other agents

For Codex:

```
codex mcp add macbeeb -- /Applications/MacBeeb.app/Contents/MacOS/macbeeb-mcp --attach
```

Other agents that speak MCP over standard input and output can run the same
command, with or without `--attach`.
