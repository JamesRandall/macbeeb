# macbeeb

A cycle-exact BBC Micro emulator for the Mac, written in Swift.

Licensed under the GNU GPL v3. Parts are derived from
[b2](https://github.com/tom-seddon/b2) (Tom Seddon, GPLv3); see the file
headers.

## Layout

| Path | What |
| --- | --- |
| `Sources/BeebCore` | The emulation core: pure Swift, no UI frameworks |
| `Sources/M6502GenKit`, `Sources/m6502-gen` | Generator for the 6502's per-cycle state machine |
| `Sources/beeb-bench` | Core speed benchmark |
| `Tests/BeebCoreTests` | CPU test suites (Lorenz, Dormann, CMOS ADC/SBC from real hardware, datasheet timings) |
| `Tests/Oracle6502Tests` | Cycle-by-cycle comparison with [perfect6502](https://github.com/mist64/perfect6502) |

## Building and testing

```
make build
make test      # optimised; the CPU suites run billions of cycles
make bench
```

`Sources/BeebCore/CPU/M6502+Generated.swift` is generated. After changing
`Sources/M6502GenKit`, run `make generate`; a test fails if it's stale.

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
