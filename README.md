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
| `Sources/BeebCapture` | Screenshots |
| `Sources/beeb` | Headless command-line BBC Micro |
| `Sources/M6502GenKit`, `Sources/m6502-gen` | Generator for the 6502's per-cycle state machine |
| `Sources/beeb-bench` | Core speed benchmark |
| `Tests/BeebCoreTests` | CPU suites (Lorenz, Dormann, CMOS ADC/SBC from real hardware, datasheet timings), VIA and timing tests against real-hardware results |
| `Tests/Oracle6502Tests` | Cycle-by-cycle comparison with [perfect6502](https://github.com/mist64/perfect6502) |

## Building and testing

```
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
```

`--pcs` and `--trace N` show where the CPU is spending its time.

## The Model B

`BBCMicro` follows b2's per-cycle machine loop: CPU with 1MHz cycle
stretching, system and user VIAs, 6845 CRTC, Video ULA, SAA5050, keyboard
matrix, addressable latch and uPD7002 ADC. The video stream feeds a
simulated TV (`TVOutput`) that locks to sync like a real monitor.

Checked against real hardware with scarybeasts' VIA tests, dp111's and Tom
Seddon's timing suites, RMW and BCD tests, jsbeeb's IRQ timing results, and
an IRQ-load test where real Model Bs give 1066-1072 (macbeeb: 1070).

Still to come: sound, discs, tape, serial (the ACIA is a stub).

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
