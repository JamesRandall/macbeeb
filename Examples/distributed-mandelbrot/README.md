# Distributed Mandelbrot

BBC Micros on an Econet drawing the Mandelbrot set between them. One BBC,
the **coordinator**, hands out 16 × 8 tiles of a 160 × 256 picture. Each
**worker** works its tiles out in its own 6502 and sends the counts back
over the network. The coordinator draws them on its MODE 5 screen as they
arrive. Every pixel is computed by an emulated BBC, and every message goes
through Acorn's network filing system and the emulated ADLC: MacBeeb only
watches.

The Network Studio's **Distributed Mandelbrot** template is this, set up:
eight workers, a Guide machine with instructions, and a Level 2 file
server with the programs. See the Network Studio guide (docs/network-studio) for
using it; this file is for the programs themselves.

## The programs

They live in the file server's library (`$.LIBRARY`), so any station
that's logged on can run them as `*` commands.

| Program | Source | Where it runs | What it does |
| --- | --- | --- | --- |
| `WORKER` | worker.asm | &3000 up, squares table &4000–&4FFF, MODE 7 | Registers with its coordinator, takes tiles, computes them and sends the counts back until they're acknowledged. Its screen shows its state, tile, progress and counters. `STOP` sends it back to BASIC. |
| `CLUSTER` | cluster.asm → launcher.asm | &3000, any mode | On the BBC that's to be the coordinator. It probes stations 1–16, except itself and the servers. It adopts any worker already running, and takes over each BBC at BASIC by **remote control** (below), then waits to hear WORKER's running there. It ends by saying to run `*MANDEL`; Mandelbrot in Colour's server has its own CLUSTER (cluster2.asm, saved as CLUSTC and put on that server as CLUSTER), which says `*MANDEL2`. |
| `WORKERS` | workers.asm → launcher.asm | &3000 | Lists the workers, and the BBCs at BASIC. |
| `STOPWK` | stopwk.asm → launcher.asm | &3000 | Stops every worker, sending it back to BASIC. (Named when the demo ran on Level 1, whose names have at most 7 letters.) |
| `MANDEL` | mandel.asm → coordinator.asm | &3000–&57FF, MODE 5 | The coordinator. It registers workers, keeps the queue of 320 tiles with an epoch for each assignment, reassigns a tile out for more than 20 emulated seconds, rejects stale results, and draws accepted tiles straight into screen memory. While drawing, it looks at one worker that's stopped answering a second: if it's at BASIC again (switched off and on), MANDEL starts it again by remote control. When the picture's done, it sends COMPLETE and keeps the picture until a key is pressed, then shows a MODE 7 summary. |
| `MANDEL2` | mandel2.asm → coordinator.asm | &1B00–&2FFF, MODE 2 | The same coordinator in MODE 2, for a BBC with VideoNuLA. It sets NuLA to direct palette (`&FE22=&11`) with sixteen of its 4,096 colours: black inside the set, then fifteen that go round (blues, cyan, white, yellow, orange, red, purple), coloured `1 + (n − 1) MOD 15`. When the picture's complete it **cycles** them, the classic way: every third frame, at the vertical sync (`*FX19`), each colour takes the next one's shade, so the bands flow. Only NuLA's palette changes, not screen memory. A key resets NuLA (`&40`) for the summary. Without VideoNuLA the colours are wrong, as with any NuLA program on a stock BBC. |

`common.asm` has the shared definitions: ports, message types, zero page and
where each program lives. `lib.asm` has the Econet and printing routines
each program includes:
- OSWORD &10 (transmit), &11 (receive blocks) and &13 (station numbers);
- OSBYTE &32 to &34.

`remote.asm` is the remote control, which CLUSTER and MANDEL include.

## Remote control

The workers are BBCs that have only been switched on: BASIC, with DFS
selected. Nothing of the demo runs on them until CLUSTER takes them over
with Econet's **immediate operations**. NFS answers these itself, in its
interrupt handlers, whatever the BBC's doing. OSWORD &10 sends them, to
port 0, with the remote address in bytes 12–15 of its control block:

1. **Machine type** (&88), which only reads, tells CLUSTER whether there's a
   BBC at the station. (DISCOVER first: if a worker's listening, it's
   adopted instead.)
2. **POKE** (&82) puts the hand-off in the BBC's zero page at &70–&76: the
   coordinator's station, the launcher's nonce and station, and a mark
   (`'W'`).
3. **POKE** puts a short stub at &0A00 (the RS423 input buffer, unused).
4. **JSR** (&83) calls the stub. DNFS wants at least a byte of arguments,
   and makes the call from an interrupt: it sets the system VIA's shift
   register shifting (ACR mode 2) and reads it, and the interrupt that
   ends the eight shifts calls the code. So the stub only puts
   `*NET`, `*I AM GUEST` and `*WORKER` in the keyboard buffer
   (OSBYTE &8A), and returns. BASIC then runs them as if they'd been typed.
   You see them typed on the worker's screen.

WORKER finds the hand-off and tells the launcher it's running (STATUS),
then registers with the coordinator.

DNFS has a protection mask (&0D63, a bit an operation) that can refuse
these. It's clear on a BBC that's just been switched on, so one accepts
them unless a program has set it.

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
  - MODE 2's screen fills &3000–&7FFF, so MANDEL2 loads at PAGE: &1B00 on a Model B with DNFS (not &1900: DNFS keeps &1900–&1AFF).
    - It must fit in 5K, so it works out its colours as it draws, without a table.
    - It has three receive blocks and room for twelve workers.
    - Page &0C is no good for data: NFS uses it.
  - WORKER's code is below &4000, with its table at &4000–&4FFF.
- **Zero page:** the programs use only &70–&8F, BASIC's user area. NFS keeps &90 up.
- **The hand-off:** a remote start leaves WORKER the coordinator's station (&70), the launcher's nonce (&71–&74) and station (&75), and a mark (&76 = 'W').
- **Receive blocks:** NFS has room for eight, and being logged on to Level 2 takes one more than Level 1. MANDEL uses five on its own port (MANDEL2 three); a worker uses two; a launcher uses two. (With six, and one more for the launcher's port, logged on to Level 2, the last block came back from OSWORD &11 as number 9, and nothing ever arrived on it.)

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

## The file server

Acorn's Level 2 server (`MandelbrotNetwork.fileServerDisc()` makes its
disc):
- **GUEST** is for everyone: the Guide, and the workers (the stub logs them on). Its directory has the guide programs, GUIDE and GUIDE2. The Guide's own copy selects the network and logs on as GUEST, trying again every second until the server answers.
- **`$.LIBRARY`** has the programs, readable by everyone.

## Tests

`MandelbrotNetworkTests` runs the demo through Acorn's software on EconetRig,
typing at the BBCs as a person would:
- launch by remote control, render, a second `*CLUSTER` adopting the running workers, `*WORKERS`, and `*STOPWK` back to BASIC;
- stations with no BBC reported as such;
- the coordinator's screen memory compared with the reference picture, pixel for pixel;
- a worker switched off part way: its tile is reassigned after the timeout. Switched on again, at BASIC, MANDEL starts it by remote control and it joins in.

`MANDELBROT_BENCH=1` times renders with 1, 2, 4 and 8 workers. Measured
(Model B workers, a Level 2 file server, emulated seconds from the first tile handed out to the
last accepted):

| Workers | Render | Speed-up |
| --- | --- | --- |
| 1 | 116.5s | 1× |
| 2 | 59.2s | 2.0× |
| 4 | 35.4s | 3.3× |
| 8 | 21.9s | 5.3× |

It falls short of linear for three reasons:
- the tiles aren't equal work: those inside the set take 64 iterations a pixel;
- the last tiles leave workers idle;
- the coordinator handles one message at a time, and each transmission holds it up while the four-way handshake completes.
