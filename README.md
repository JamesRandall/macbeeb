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
`load_program`, `run`, `run_until_idle`, `run_until_address`,
`read_screen_text`, `screenshot`, `peek`, `poke`, `disassemble`,
`get_status`, `press_break`, `power_cycle` (which can switch model),
`save_snapshot`, `restore_snapshot`, `save_state`, `load_state`,
`start_recording`, `stop_recording`.

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

The Master 128 (Machine > Model) adds the 65C12, MOS 3.20 and its ROMs,
b2's paging (shadow RAM, ANDY, HAZEL, the VDU driver's view of shadow RAM),
sideways RAM in banks 4-7, the MC146818 clock and CMOS RAM, the keypad, and
a WD1770 (ported from jsbeeb/beebjit) with DFS 2.24 and ADFS.

Save states (`.beebstate`) and snapshots capture everything, discs and disc
controllers included, so a restored machine carries on cycle for cycle.

Still to come: tape and serial (the ACIA is a stub).

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
