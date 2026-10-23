# Distributed Mandelbrot

BBC Micros on an Econet drawing the Mandelbrot set between them. One BBC,
the **coordinator**, hands out 16 × 8 tiles of a 160 × 256 picture. Each
**worker** works its tiles out in its own 6502 and sends the counts back
over the network. The coordinator draws them on its MODE 5 screen as they
arrive. Every pixel is computed by an emulated BBC, and every message goes
through Acorn's network filing system and the emulated ADLC: MacBeeb only
watches.

The Network Studio's **Distributed Mandelbrot** template is this, set up:
eight workers, a Guide machine with instructions, and a file server with
the programs. See the Network Studio guide (docs/network-studio) for
using it; this file is for the programs themselves.

## The programs

All six live in the file server's library (`&`), so any station can run
them as `*` commands.

| Program | Source | Where it runs | What it does |
| --- | --- | --- | --- |
| `WBOOT` | wboot.asm | &6000–&67FF, MODE 7 | A worker's bootstrap. The station's `!BOOT` runs it at log-on. It listens on port &B3: it answers DISCOVER, and on START it loads `WORKER` from the server (`*WORKER`, through NFS). A load that fails is reported to the launcher, and it carries on listening. |
| `WORKER` | worker.asm | &3000 up, squares table &4000–&4FFF, MODE 7 | Registers with its coordinator, takes tiles, computes them and sends the counts back until they're acknowledged. Its screen shows its state, tile, progress and counters. `STOP` sends it back to `WBOOT`. |
| `CLUSTER` | cluster.asm → launcher.asm | &3000, any mode | On the BBC that's to be the coordinator. It probes stations 1–16, except itself and the servers, then STARTs each waiting bootstrap, waits to hear it's running, and adopts any worker already running. |
| `WORKERS` | workers.asm → launcher.asm | &3000 | Lists the bootstraps and workers. |
| `STOPWK` | stopwk.asm → launcher.asm | &3000 | Stops every worker, sending it back to its bootstrap. (Level 1's DFS-style names have at most 7 letters, so not STOPWORK.) |
| `MANDEL` | mandel.asm | &3000–&57FF, MODE 5 | The coordinator. It registers workers, keeps the queue of 320 tiles with an epoch for each assignment, reassigns a tile out for more than 20 emulated seconds, rejects stale results, and draws accepted tiles straight into screen memory. While drawing, it recruits bootstraps that appear: one candidate station a second gets a DISCOVER, and a bootstrap that answers gets a START. When the picture's done, it sends COMPLETE and keeps the picture until a key is pressed, then shows a MODE 7 summary. |

`common.asm` has the shared definitions: ports, message types, zero page and
where each program lives. `lib.asm` has the Econet and printing routines
each program includes:
- OSWORD &10 (transmit), &11 (receive blocks) and &13 (station numbers);
- OSBYTE &32 to &34.

The protocol is [protocol.md](protocol.md), version 1, frozen. MacBeeb's
decoder (`BeebNetwork/MandelbrotProtocol.swift`) and the tests follow it
byte for byte.

## Arithmetic

Q8.8 fixed point. The squares come from a table of `S(a) = a² DIV 256` for
`a < 2048`, built by each worker when it starts. The cross term `2xy` comes
from `S(|x+y|) − S(|x|) − S(|y|)`, so an iteration is three table lookups
and some adds: about 200 cycles, where shift-and-add multiplies would take
about 1,500. The spec asked for 16 × 16 → 32 multiplication. This does
something different but exactly defined (protocol.md), and the reference
in the tests (`MandelbrotReference`) computes the same: 580,816 iterations
for the whole picture at 64 iterations a pixel.

## Memory

- **Model B with DNFS:**
  - PAGE is &1900, and every program loads at &3000 or above.
  - MODE 7's screen is at &7C00, and MODE 5's at &5800, which MANDEL's `GUARD` keeps it below.
  - WBOOT is at &6000, clear of WORKER (code below &4000, with its table at &4000–&4FFF).
- **Zero page:** the programs use only &70–&8F, BASIC's user area. NFS keeps &90 up.
- **WBOOT to WORKER:** WBOOT leaves WORKER the coordinator's station (&70), the launcher's nonce (&71–&74) and station (&75), and a mark (&76 = 'W').
- **Receive blocks:** NFS has room for eight. MANDEL uses six on its own port and one for recruiting; a worker uses two; a launcher uses two.

## Building

The assembled bytes are in `Sources/BeebNetwork/MandelbrotGuestFiles.swift`.
After changing a source, regenerate them with:

```
MACBEEB_WRITE_MANDELBROT=1 make test
```

`MandelbrotGuestTests` assembles the sources with BeebAsm (`make beebasm`
builds it) and fails if they don't match. An AI agent can assemble any of
them on a station with MacBeeb's `assemble` tool (MCP), which loads the
symbols for source-level debugging.

## On a Level 1 file server

Acorn's Level 1 server has no boot options: `*OPT 4,3` gives "Bad command",
and it can't `*EXEC` a file either. So a station can't run its `!BOOT`. The
Studio stands in for the server: once the file server says it's ready, it
types into each worker what a boot would do: `*NET`, `*I AM BOOT`, and the
lines of the server's `A.!BOOT` (here, `*WBOOT`). Everything after that is
the guests' own Econet traffic.

## Tests

`MandelbrotNetworkTests` runs the demo through Acorn's software on EconetRig,
typing at the BBCs as a person would:
- launch, render, a second `*CLUSTER` adopting the running workers, `*WORKERS`, and `*STOPWK`;
- a station without a bootstrap reported as not prepared;
- the coordinator's screen memory compared with the reference picture, pixel for pixel;
- a worker switched off part way: its tile is reassigned after the timeout. Switched on and booted again, it's recruited and joins in.

`MANDELBROT_BENCH=1` times renders with 1, 2, 4 and 8 workers. Measured
(Model B workers, emulated seconds from the first tile handed out to the
last accepted):

| Workers | Render | Speed-up |
| --- | --- | --- |
| 1 | 116.1s | 1× |
| 2 | 61.1s | 1.9× |
| 4 | 34.9s | 3.3× |
| 8 | 20.7s | 5.6× |

It falls short of linear for three reasons:
- the tiles aren't equal work: those inside the set take 64 iterations a pixel;
- the last tiles leave workers idle;
- the coordinator handles one message at a time, and each transmission holds it up while the four-way handshake completes.
