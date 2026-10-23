# Distributed Mandelbrot: protocol, version 1 (frozen)

Everything here is what the guest programs (`*.asm` beside this file) do.
The Swift side (the traffic decoder and the test oracle) must match it
byte for byte. Change it only with a new protocol version.

## Ports

| Port | Who listens | For |
| --- | --- | --- |
| &B0 | the coordinator (`MANDEL`) | HELLO, READY, RESULT |
| &B1 | a worker (`WORKER`) | WELCOME, ASSIGN, ACK, COMPLETE |
| &B2 | the launcher (`CLUSTER`, `WORKERS`, `STOPWORK`) | BOOT_HELLO, START_ACK, LAUNCH_ERROR, STATUS |
| &B3 | a bootstrap (`WBOOT`) or worker (management) | DISCOVER, START, STOP |

These are application choices, not Acorn-assigned ports. Frames go with
OSWORD &10 using control byte &80. Receivers use OSWORD &11 blocks that
accept any station, and check the station the frame came from.

## Header (14 bytes, little-endian)

| Offset | Size | Field |
| --- | --- | --- |
| 0 | 2 | `"MB"` (&4D &42) |
| 2 | 1 | version = 1 |
| 3 | 1 | type |
| 4 | 4 | runId. 0 on the management ports (&B2/&B3) |
| 8 | 2 | messageId: the sender's counter, modulo 65536 |
| 10 | 1 | sender station (diagnostic only) |
| 11 | 1 | flags = 0 |
| 12 | 2 | payload length |

A receiver ignores a frame unless:
- it's at least 14 bytes;
- the magic and version are right;
- 14 + payload length equals the received length;
- the payload length is exactly what its type needs (RESULT: 9 + width × height).

## Messages and payloads

| Code | Name | Payload |
| --- | --- | --- |
| 1 | HELLO | role u8 (1 = worker), machine u8 (OSBYTE 0's X), numeric formats u8 (bit 0 = Q8.8), worker version u8 (1). **4 bytes** |
| 2 | WELCOME | width u16 (160), height u16 (256), maxIterations u8, tileWidth u8 (16), tileHeight u8 (8), numericFormat u8 (1). **8 bytes** |
| 3 | READY | station u8. **1 byte** |
| 4 | ASSIGN | tileId u16, epoch u16, x u8, y u8, width u8, height u8, startReal i16, startImag i16, stepReal i16, stepImag i16, maxIterations u8, numericFormat u8 (1). **18 bytes** |
| 5 | RESULT | tileId u16, epoch u16, x u8, y u8, width u8, height u8, format u8 (1 = raw 8-bit counts), then width × height counts, row-major from the top. **9 + 128 bytes** |
| 6 | ACK | tileId u16, epoch u16, status u8 (0 = accepted, also for a resend of the accepted epoch, whose first ACK was lost; 1 = duplicate, done by another assignment; 2 = stale epoch or not assigned to you). **5 bytes** |
| 8 | COMPLETE | tiles u16 (320). **2 bytes** |
| 11 | DISCOVER | nonce u32, target u8, launcher u8. **6 bytes** |
| 12 | BOOT_HELLO | nonce u32, station u8, state u8 (1 = bootstrap waiting, 2 = worker running), bootstrap version u8 (1), worker version u8 (0 from a bootstrap, 1 from a worker). **8 bytes** |
| 13 | START | nonce u32, target u8, coordinator u8. **6 bytes** |
| 14 | START_ACK | nonce u32, status u8 (0 = loading WORKER, 1 = already running: adopted the new coordinator). **5 bytes** |
| 15 | LAUNCH_ERROR | nonce u32, error number u8, then the error message (ASCII, at most 40 bytes, no terminator). **5 + n bytes** |
| 16 | STOP | nonce u32. **4 bytes** |
| 17 | STATUS | nonce u32, state u8 (2 = running, 3 = stopping: returning to the bootstrap), worker version u8, coordinator u8. **7 bytes** |

Types 7 (PROGRESS), 9 (ERROR) and 10 (CANCEL) are reserved; v1 doesn't send them.

## Image and arithmetic

- 160 × 256 pixels: 10 × 32 tiles of 16 × 8. Tile `id = row × 10 + column`; its origin is `x = column × 16`, `y = row × 8`.
- Q8.8 signed: `cReal(x) = -576 + 5x` and `cImag(y) = 384 - 3y`. ASSIGN carries `startReal = cReal(tile.x)`, `startImag = cImag(tile.y)`, `stepReal = 5`, `stepImag = -3`.
  - A worker works these out by repeated addition: `cReal = startReal + dx × stepReal`, `cImag = startImag + dy × stepImag`.
- Default maxIterations is 64.
- The squares are exact, then truncated. `S(a) = floor(a² / 256)` for `0 ≤ a < 2048`; a worker builds the table at start-up.
- The escape count of `(cr, ci)` with limit `max`:

```
x = 0, y = 0
for n in 0 ..< max:
    if |x| >= 2048 or |y| >= 2048: return n
    x2 = S(|x|), y2 = S(|y|)
    if x2 + y2 > 1024: return n          # |z|² > 4
    s = |x + y|
    if s >= 2048: return n
    xy = S(s) - x2 - y2                  # 2xy, by (x+y)² - x² - y²
    y = xy + ci
    x = x2 - y2 + cr
return max
```

  All values stay within signed 16 bits. The result is 1 … max, because n = 0 never escapes.

- MODE 5 colour of a count `n`: 0 if `n == max`, otherwise `1 + (n - 1) mod 3`. The coordinator's palette:
  - 0 = black;
  - 1 = blue;
  - 2 = cyan;
  - 3 = yellow (VDU 19).

## Exchanges

- **Launch** (`CLUSTER` at station C):
  1. C probes each candidate station 1–16, except itself, the file server and the printer server, with DISCOVER on &B3. A transmit failure means "not prepared".
  2. C waits up to 1s for BOOT_HELLO on &B2.
  3. C sends START and waits up to 2s for START_ACK, then up to 30s for STATUS running. Or it gets LAUNCH_ERROR.
  4. A bootstrap on START: it closes its block, then does `*WORKER`, which goes through NFS and the library. The coordinator and launcher stations, and the nonce, are left for WORKER at &70 (coordinator), &71–&74 (nonce), &75 (launcher) and &76 = &57 ('W', present).
  5. A worker that gets START (it's running already) answers START_ACK 1, takes the new coordinator, sends STATUS and starts again with HELLO.
- **Render:**
  - Workers send HELLO to the coordinator every 1s until WELCOME.
  - The coordinator answers HELLO with WELCOME, and keeps it registered. A worker it knew that sends HELLO again has its tile, if any, put back in the queue.
  - On WELCOME a worker takes the header's runId and sends READY.
  - The coordinator answers READY with ASSIGN:
    - the worker's tile in flight, if it has one (the same epoch);
    - otherwise the next pending tile, whose epoch then goes up by 1 (the first assignment is epoch 1);
    - otherwise nothing: the worker is idle.
  - The worker computes, sends RESULT, and resends it every 2s until it gets an ACK with the same tile and epoch. Then it sends READY.
  - Unanswered READY is resent every 2s.
  - A worker's HELLO, READY or RESULT with another runId is answered with WELCOME, which a worker always obeys: it gives up its current tile.
- **Timeouts** (emulated time, the MOS clock): a tile in flight for more than 20s goes back in the queue, and its worker is marked unresponsive. A RESULT with an old epoch is answered with ACK status 2 and isn't drawn.
- **Completion:** when all 320 tiles are accepted, the coordinator sends COMPLETE to every worker it knows.
  - It then answers READY or HELLO in that run with COMPLETE.
  - A worker that gets COMPLETE says so, and sends HELLO every 3s, so a new run of MANDEL can take it on.
  - The coordinator keeps its image until a key is pressed, then shows a MODE 7 summary and returns to BASIC.
- **Stop** (`STOPWORK`): STOP to each running worker. It answers STATUS 3 and does `*WBOOT` (back to waiting).
