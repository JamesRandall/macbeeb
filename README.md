# macbeeb

A cycle-exact BBC Micro emulator for the Mac, written in Swift.

Licensed under the GNU GPL v3. Parts are derived from
[b2](https://github.com/tom-seddon/b2) (Tom Seddon, GPLv3); see the file
headers.

## Layout

| Path | What |
| --- | --- |
| `Sources/BeebCore` | The emulation core: pure Swift, no UI frameworks |
| `Sources/BeebROMs` | Bundled ROM images (Acorn copyright, not GPL) |
| `Sources/BeebCapture` | Screenshots and video recording |
| `Sources/BeebHost` | Runs a machine on its own thread, paced by audio |
| `Sources/BeebAgentKit`, `Sources/macbeeb-mcp` | Agent tools and the MCP server |
| `Sources/BeebDAP`, `Tools/vscode-macbeeb` | The Debug Adapter Protocol server and the VS Code extension |
| `Sources/MacBeeb` | The Mac app |
| `Sources/beeb` | Headless command-line BBC Micro |
| `Sources/M6502GenKit`, `Sources/m6502-gen` | Generator for the 6502's per-cycle state machine |
| `Sources/beeb-bench` | Core speed benchmark |
| `Tests/BeebCoreTests` | CPU suites (Lorenz, Dormann, CMOS ADC/SBC from real hardware, datasheet timings), VIA and timing tests against real-hardware results |
| `Tests/Oracle6502Tests` | Cycle-by-cycle comparison with [perfect6502](https://github.com/mist64/perfect6502) |

## Building and testing

```
scripts/make-app.sh   # builds and signs .build/app/MacBeeb.app
make build
make test      # optimised; the CPU suites run billions of cycles
make bench
```

### Releases

`scripts/release.sh 1.0` builds a universal app signed with the Developer
ID, notarises and staples it and a DMG, and makes the Sparkle update zip and
`appcast.xml` (keeping earlier releases listed). `--publish` then tags the
commit and creates the GitHub release with all three. The app checks
`https://github.com/JamesRandall/macbeeb/releases/latest/download/appcast.xml`,
so updates reach users only once the repo's releases are public.

It reads `APPLE_ID`, `APPLE_APP_SPECIFIC_PASSWORD`, `APPLE_TEAM_ID` and
`CSC_NAME` from `.env.local` (ignored by git). The Sparkle EdDSA key is in
the login keychain under the account `macbeeb`; create it once with
`.build/artifacts/sparkle/Sparkle/bin/generate_keys --account macbeeb`, and
keep a backup (`-x FILE` exports it): losing it means existing installs
can't verify new updates.

`Sources/BeebCore/CPU/M6502+Generated.swift` is generated. After changing
`Sources/M6502GenKit`, run `make generate`; a test fails if it's stale.

## The command line

```
swift run -c release beeb --type 'PRINT 1+1\n' --text
swift run -c release beeb --type 'MODE 2\nDRAW 640,512\n' --screenshot out.png
swift run -c release beeb --load disc.ssd:PROGRAM --type 'RUN\n' --seconds 5 --text
swift run -c release beeb --master --type '*ROMS\n' --text
```

`--pcs` and `--trace N` show where the CPU is spending its time.

## AI agents (MCP)

`macbeeb-mcp` is a Model Context Protocol server that lets agents such as
Claude Code drive a BBC Micro: boot discs, type, run BASIC, read the screen
as text, take screenshots, peek and poke memory, disassemble, record video.
Time is emulated time, so waits are exact and run faster than real time.

```
swift build -c release --product macbeeb-mcp
claude mcp add macbeeb -- "$(pwd)/.build/release/macbeeb-mcp"            # its own headless BBC (--master for a Master 128)
claude mcp add macbeeb -- "$(pwd)/.build/release/macbeeb-mcp" --attach   # the app's BBC, as you watch
```

The app bundle includes it too, at `MacBeeb.app/Contents/MacOS/macbeeb-mcp`.
`--attach` talks to the app over a user-only socket in
`~/Library/Application Support/MacBeeb/`.

Tools: `run_command`, `type_text`, `press_keys`, `load_disc`, `eject_disc`,
`load_tape`, `rewind_tape`,
`load_program`, `run`, `run_until_idle`, `run_until_address`,
`read_screen_text`, `screenshot`, `peek`, `poke`, `disassemble`,
`get_status`, `press_break`, `power_cycle` (which can switch model),
`save_snapshot`, `restore_snapshot`, `save_state`, `load_state`,
`start_recording`, `stop_recording`; and for debugging, `set_breakpoint`,
`list_breakpoints`, `delete_breakpoint`, `continue`, `step` (including
back), `reverse_continue`, `rewind`, `registers`,
`set_register`, `memory_regions`, `trace`, `debug_log`, `load_symbols`,
`lookup_symbol` (with `peek`,
`poke` and `disassemble` taking a CPU and address space).

## Source-level debugging (VS Code)

MacBeeb serves the Debug Adapter Protocol on localhost port 6502 (Settings >
Debugging). The extension in `Tools/vscode-macbeeb` connects VS Code to it:
breakpoints in assembler source (from ld65 `--dbgfile` debug info, which
maps every byte to its line), conditions, hit counts and log points;
stepping over, into, out and back, reverse continue; call stacks from the
6502 stack; registers and flags to edit; memory and disassembly; data
breakpoints on any address; and the hardware state. The CPUs are threads.
`Examples/hello-ca65` is a program to try it on.

Symbols (ld65 debug info, or label files from ld65 `-Ln`, VICE or
`name = $1234` lists) work in the app's debugger and the agent tools too:
`load_symbols`, then names in addresses and expressions, `hello.s:19` as a
breakpoint address, and labelled disassembly. The OS entry points and
hardware registers are always known.

## Rewind

The machine keeps the last minute: a snapshot every quarter second (with a
thumbnail), and every key and joystick change with the cycle it arrived on.
Anything else from outside (typing, loading, poking, discs, tapes, the
debugger) takes a fresh snapshot. Emulation is deterministic, so restoring
the nearest snapshot and replaying the inputs reaches any cycle exactly;
tests check this against random input on a Master with a second processor.
Machine > Rewind 5 Seconds (⌥⌘←), the toolbar's Rewind button, and the
timeline (⇧⌥⌘←) go back; running on replaces what came after. It costs
nothing measurable, and about 30MB (65MB for a Master with a second
processor).

The debugger uses it to step back (⇧F7) and reverse-continue (⇧⌃⌘Y: back to
the last time a breakpoint hit, e.g. "who wrote this byte?").

## Debugging

Debug > Show Debugger (⌥⌘D) opens the debugger for a machine window. It has
disassembly with a breakpoint gutter, a memory editor for every address
space with changes highlighted, registers and flags you can edit, the
stack, breakpoints (ranges, watchpoints, conditions, log points), every
device's state, the instruction trace and log output, for either CPU.
Continue/pause is ⌃⌘Y, step over/into/out are F6/F7/F8, and the Step By
menu goes by cycle, scanline, frame or interrupt. While it's open, the
machine window shows the screen address under the mouse.

`Debugger` (in BeebCore) does breakpoints on execute, read or write, over
ranges, with conditions (`A == &41 && [&70] > 3`), hit counts, ROM bank
qualifiers and log points; stepping by instruction, over, out, cycle,
scanline, frame and interrupt; register editing; and instruction traces.
It works on the host CPU and the second processor, stops on the exact
cycle, and costs one test per cycle when nothing is set. Memory can be
read and written in each address space (the CPU's view, or main, shadow,
ANDY, HAZEL, each sideways bank, the OS ROM, parasite RAM) without side
effects.

## The machines

`BBCMicro` follows b2's per-cycle machine loop: CPU with 1MHz cycle
stretching, system and user VIAs, 6845 CRTC, Video ULA, SAA5050, keyboard
matrix, addressable latch and uPD7002 ADC. The video stream feeds a
simulated TV (`TVOutput`) that locks to sync like a real monitor.

Checked against real hardware with scarybeasts' VIA tests, dp111's and Tom
Seddon's timing suites, RMW and BCD tests, jsbeeb's IRQ timing results, and
an IRQ-load test where real Model Bs give 1066-1072 (macbeeb: 1070).

Sound is the SN76489 through b2's filter model; discs are an Intel 8271
(ported from jsbeeb/beebjit) with DFS 1.20. Analogue joysticks come from
game controllers.

The B+ 128K adds shadow RAM, its 12K of paged RAM, sideways RAM in banks 0,
1, 12 and 13, and an Acorn 1770 (DFS 2.26).

The Master 128 (Machine > Model) adds the 65C12, MOS 3.20 and its ROMs,
b2's paging (shadow RAM, ANDY, HAZEL, the VDU driver's view of shadow RAM),
sideways RAM in banks 4-7, the MC146818 clock and CMOS RAM, the keypad, and
a WD1770 (ported from jsbeeb/beebjit) with DFS 2.24 and ADFS.

The keyboard goes by key position (the BBC's layout on the Mac's keys) or,
in Settings > Keyboard, by the character the Mac's layout types, with the
BBC's Shift pressed or released per key as needed. Custom mappings put any
BBC key on any Mac key, in either mode.

Any of them can have a 6502 Second Processor (Machine > Model, `--tube`):
a 3MHz 65C02 with 64K on the Tube, booting Tube OS 1.10, following b2.

Save states (`.beebstate`) and snapshots capture everything, discs and disc
controllers included, so a restored machine carries on cycle for cycle.

Cassettes (.uef, including gzipped, and .csw) play through a 6850 ACIA and
serial ULA that decode the tape's tones as the real hardware does, so
`*TAPE` and `CHAIN ""` load at real speed on both models (File > Load Tape,
or `--tape` for `beeb`). b2 doesn't emulate tape; this design follows the
datasheet, with carrier detect timing from jsbeeb's and BeebEm's
measurements. Nothing is attached to RS423.

## The 6502

`M6502` is a port of b2's simulator: each `tick()` runs one bus cycle and
leaves the next access on `abus`/`access`/`dbus` for the host to perform, so
the machine sees every cycle (for 1MHz stretching and device timing).
Variants: NMOS with undocumented instructions (Model B), CMOS 65C12 (Master),
and Rockwell 65C02 (6502 Second Processor).

It's checked against:

- Wolfgang Lorenz's test suite (all 222 tests, including undocumented NMOS
  instructions).
- Klaus Dormann's functional and decimal tests, on every variant.
- Every ADC/SBC input on a real Master 128's 65C12.
- WDC/Rockwell datasheet cycle counts for CMOS-specific timings.
- perfect6502, a simulation of the NMOS chip's transistors: every stable
  opcode with random operands, flags and memory, IRQ/NMI at every cycle
  offset, NMI hijacking BRK/IRQ, and random code under random interrupts,
  compared on every cycle. This found three interrupt-timing differences
  from b2, now fixed (see `M6502+Special.swift`).
