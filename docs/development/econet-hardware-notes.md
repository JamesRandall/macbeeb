# Econet: hardware notes

Internal notes on MacBeeb's Econet: what's modelled, where it came from,
and what's a compromise. Network Studio phase 2 (see
NetworkStudio-Implementation-Plan.md).

## Sources

- MC6854 datasheet's register model (as recalled and cross-checked below).
- **Acorn DNFS, annotated disassembly** (BeebEm's `Documents/Econet.zip`,
  `dnfs.txt`): the register values DNFS actually writes and the statuses it
  tests, which decide most of the details.
- **MAME `mc6854.cpp`** (BSD-3-Clause, Antoine Mine): FIFO structure, the
  receiver's 24-bit hold-back, TDRA prioritised by CTS.
- **BeebEm `Econet.cpp`** (GPLv2+, Rob O'Donnell, Mike Wyatt): prioritised
  status order, interrupt causes (rising edges, cleared by the CPU's
  clears), /CTS as NAND(clock, no collision, RTS), INTON/INTOFF decoding.
  Its UDP transport and its faked four-way handshake and flag fill are *not*
  used.
- **jsbeeb `econet.js`** (GPLv3): the Master's decoding (&FE38 station and
  INTOFF, &FE3C INTON).

## Machine wiring

| | Model B (and B+) | Master 128 / Compact |
| --- | --- | --- |
| ADLC | &FEA0-&FEBF, register = A1-A0 | &FEA0-&FEBF |
| Station number + INTOFF | any access to &FE18-&FE1F | &FE38-&FE3B |
| INTON | a read of &FE20-&FE2F | &FE3C-&FE3F |
| ADLC /IRQ | to NMI through the INTON/INTOFF flip-flop (`NMIDevice.econet`, beside the FDC's) | same |
| Reset | Break and power on reset the ADLC and turn NMI off | same |
| Network ROM | DNFS (DFS 1.20 + NFS 3.00) in place of DFS 1.20 in bank 14; with another disc interface, bank 13 | ANFS 4.25 in bank 8 |

The B+ takes the module, but no B+ NFS ROM is bundled, so a B+ station has
the hardware and no software yet.

## The ADLC (`MC6854.swift`)

- CR1–CR4, SR1/SR2, three-byte FIFOs each way, address-present marks,
  frame ends, 1- and 2-byte TDRA/RDA, frame-complete mode, TX last (by
  register 3 or CR2 bit 4), CR4 abort, CR1 discontinue, RX and TX reset.
- **Prioritised status** (CR2 bit 0), as BeebEm and DNFS need it: FV, abort,
  error, DCD or overrun hide idle, AP and RDA; idle hides AP and RDA; AP
  hides RDA. (BeebEm also steps the priority on each clear; not needed.)
- **Interrupts**: a status bit rising, with its section enabled, becomes a
  cause; IRQ is asserted while any cause's bit is still up. The CPU's
  Clear RX/TX Status (and resets) drop the causes they clear, so level
  conditions that stay up (idle, DCD, CTS) don't interrupt again. Enabling
  TIE with TDRA already up interrupts (DNFS relies on it).
- **/CTS** = high unless (clock present, no collision, and /RTS *output*
  active). The RTS output stays on until a frame's closing flag has gone,
  as the datasheet says; using the RTS *bit* broke DNFS, which drops it with
  the last byte.
- **Receiver hold-back**: a byte reaches the FIFO three byte-times after it
  arrives (MAME's 24 bits), so a frame's last byte arrives with its closing
  flag and FV together. DNFS's scout handler requires exactly that.
- **Idle**: 15 bit-times with nothing on the line, counted from the later of
  the last symbol's end and the receiver leaving reset. The line is busy
  from a symbol's first bit (a flag starts with a 0), though its byte is
  only in at its last.
- **FV** shows when the frame's last byte is at the head of the FIFO (or the
  frame's been read). New bytes wait until FV/ERR is cleared.

## The line (`EconetBus.swift`) and timing

- Symbols are byte-times: flag, byte, check byte (two per frame, value not
  modelled), abort, garbage. Zero insertion, NRZI and the CRC's value aren't
  modelled; a frame's check bytes take their time.
- Stations run in **lockstep quanta of 32 cycles** (16µs) while Econet's
  fitted. What one sends reaches the others **32 cycles after its last
  bit**, so it's never in a station's past, and the order stations run in
  can't matter. Runs repeat exactly.
- Why 32: after a scout, the sender treats 15 idle bits (150 cycles at
  200 kbit/s) after it re-enables its receiver as "not listening"; the
  receiver must have flags on the line by then. Each hop costs the delay,
  so it must stay well under 75 cycles. A variable delay (long quanta while
  quiet) can't work: the first burst after a quiet spell would arrive late
  and the reply would miss the sender's idle window.
- Cost: about 10% (beeb-bench network). On one thread, 8 Model Bs run at
  1.7× real time, 16 at 0.9×.
- **More threads** (LockstepWorkers): when one thread can't keep up, the
  network's machines are shared among extra threads (balanced by measured
  cost), each running its machines through the quantum, then meeting the
  network's thread (a spin barrier: quanta are far too short to sleep
  between; workers spin up to 300µs, then park). The line's delivery stays
  on the network's thread, so results don't depend on the threads (a test
  checks). The network's thread looks at a station's commands and state
  only when it's flagged (a command, being held, a debugger stop); otherwise
  it reuses the ready list, as the serial part is what limits scaling. A
  thread is added a second at a time while the network's short of real time
  and never rests, kept if machine time a second rises 5% (judged on machine
  time, so adding machines during a trial doesn't fail it).
  Measured (M-series, 12 performance cores), with Econet:

  | Machines | 1 thread | 2 | 4 | 6 |
  | --- | --- | --- | --- | --- |
  | 16 Model Bs | 0.9× | 1.4× | 1.8× | |
  | 37 (31 Masters) | 0.4× | 0.7× | 1.1× | 1.3× |

  (A Master costs the same as a Model B.) Eight threads is slower than six
  at 37 machines; the trials find the best.
- **Frames**: the TV keeps two frame buffers and alternates, so publishing
  a frame doesn't make the next one copy-on-write (1.7MB, a large
  allocation, every frame, which across many machines queued on the
  kernel's virtual memory).
- **Collisions**: two stations' byte-times overlapping on the line spoil
  both (delivered as garbage, an error at the receiver) and raise both
  transmitters' /CTS until they're cleared.
- **No clock**: /DCD high; DNFS reports "No clock" (&43) when it tries to
  send.
- A suspended station isn't listening: what's sent meanwhile is lost to it.

## Verified with Acorn's own software

- OSWORD &10/&11 between two DNFS stations: the full four-way handshake,
  data delivered, result 0; "not listening" (&42) with nobody at the
  station; "no clock" (&43) without a clock.
- Acorn's **Level 1 file server** (bundled disc, `CH."FS"`) on a Model B at
  station 254: `*CAT`, `SAVE`/`CHAIN` of BASIC, `*SAVE`/`*LOAD` of 1K binary
  byte for byte, between two stations sharing a directory; a Master 128
  with ANFS 4.25 saving for a Model B to run. The server writes its disc
  (8271 NMIs) while the network's busy.
- Server off: the client gets DNFS's "Not listening"; switched on and
  restarted, it serves the same disc again.
- Level 1 gives each station its own directory and refuses others' names
  ("Bad file name"), so files are shared by giving stations the same
  directory.
- Level 1 has no boot options (`*OPT 4,3`: "Bad command") and can't open a
  file for `*EXEC` ("Bad command"), so a station can't run a `!BOOT` from
  it. `*name` runs `name` from the station's directory or the library
  (`&`).
- DNFS: OSWORD &13 function 8 reads the station number, functions 0 and 2
  the file and printer servers'. A transmission to a station that isn't
  listening fails in about 4 centiseconds. About eight receive blocks can
  be open at once; reading a block that's received frees it. (Found by
  the Distributed Mandelbrot demo, Examples/distributed-mandelbrot.)

## Not done (yet)

- Loop mode, address extension, logical control fields, NRZI, CRC values,
  flag-detect status timing (FD's set on every flag when enabled).
- Level 2 file server (needs a 6502 Second Processor and a double-sided
  master disc) isn't tested.
