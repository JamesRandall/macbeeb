# Network Studio: implementation plan

Phase 0 of `MacBeeb_Network_Studio_Specification.md`: what the repository has
now, what changes, in what order, and how each step is tested. Written
2026-10-23 against commit bea0eb1.

## 1. What's there now

### Core (BeebCore)

- **`BBCMicro` is a class that owns every piece of mutable hardware state**:
  CPU, RAM (`ram`, allocated per instance), OS ROM and the sixteen sideways
  banks (`sidewaysBanks`, allocated per instance, so sideways RAM is never
  shared), VIAs, CRTC, ULA/NuLA, sound, keyboard, FDCs, Tube and second
  processor, debugger, rewinder. The only globals are immutable tables
  (`M6502.nmosTable` etc., the Z80 flag tables). **Two machines in one process
  already work**: the tests build hundreds, and the app can open several
  machine windows. No extraction refactor is needed in the core.
- **Time**: everything counts 2MHz cycles (`machine.cycles`), on every model,
  so a network's common time base is simply the 2MHz cycle count. The Tube
  parasites run inside their host's `run`.
- **NMI**: `cpu.setNMI(NMIDevice.fdc, …)` already combines NMI sources by
  bit, so Econet becomes a second source (`NMIDevice.econet`).
- **Missing hardware**: no MC6854 ADLC, nothing decodes &FEA0–&FEBF, and the
  Econet station-ID/INTOFF (&FE18 on the B, &FE38 on the Master) and INTON
  (&FE20 read on the B, &FE3C on the Master) aren't decoded. **Nothing is
  attached to the printer port**: the user VIA's port A and CA1/CA2 are
  emulated, but no Centronics printer is attached.
- **Performance** (`make bench`, this Mac, release build): a Model B with TV
  output and rewind runs at **16.5× real time on one core**; headless, 18.5×;
  with a 6502 second processor, 10×. On one thread, then, eight stations
  leave about 2× headroom, and sixteen don't run at full speed. See §4.3.

### Host (BeebHost)

- `EmulatorHost`: **one thread per machine**. It runs in 1ms slices
  (`sliceCycles = 2_000`), paced by the audio ring or the wall clock, and
  takes commands through a mutex-guarded queue. It publishes the latest frame
  (`latestFrame`), lights, mouse and debugger stop under mutexes. `perform` and
  `performAsync` run closures on the emulation thread with a `MachineSession`.
- `MachineSession`/`MachineContext`: what tools (MCP, tests) drive.
  `HeadlessSession` runs on the caller's thread.

### App (MacBeeb)

- `WindowGroup(MachineWindow)`: each window has a `MachineController`, which
  owns an `EmulatorHost`, an `AudioOutput` and a Metal `Renderer` (an
  observer of `host.frame`). **File ▸ New BBC Micro Window** already runs
  several machines at once, each on its own thread with its own audio.
- **App-wide "current machine" assumptions**:
  - `MachineController.frontmost`, where the Game Library plays games;
  - `MachineController.all`;
  - `Joysticks.shared.machine`, set by the first window;
  - `MachineController.agentServer`: the MCP socket serves **only the first
    window's machine**;
  - `DocumentationCapture`, the DAP server and the debugger window are each
    keyed by `machine.id`.

  Menu commands go to the focused scene through `focusedSceneValue`.
- **MCP** (BeebAgentKit): `AgentTools(context:)` is bound to one
  `MachineContext`, and has no machine argument.

### Reference material (in the gitignored `reference/`)

- **BeebEm** `Src/Econet.cpp` (GPLv2+, portable): the MC6854 register model
  (CR1–CR4, SR1/SR2, the FIFOs, address/control, prioritised status, the NMI
  output). It also has the Model B and Master decoding in `BeebMem.cpp`. Its
  transport is IP datagrams, with a "four-way handshake" state machine that
  *fakes* flag fill and acknowledgements. That's what makes it flaky (its help
  page warns of "Net Error" and "Line Jammed"), and it's what we must not
  copy.
- **jsbeeb** `src/econet.js` (GPLv3): the same model, ported from BeebEm.
- **Firmware and software**:
  - DNFS (Model B), ANFS 4.25 (Master), from BeebEm and jsbeeb;
  - BeebEm's `econet_level_1_utils.ssd`: the Level 1 file server (`FS`) and
    **the printer server (`PS`)**, plus `NETMON`, `NOTIFY`, `REMOTE`, `VIEW`
    and `PROT`;
  - `econet_level_2_utils.ssd` (the Level 2 server; needs a 6502 second
    processor and a double-sided master disc).
- **Documents**: the AUG and Master Advanced Reference Manual (ADLC wiring),
  the DNFS and ANFS disassemblies (in BeebEm's `Econet.zip`), and the Printer
  Server and Level 2/3 manuals linked in the spec.

## 2. Architecture

```
MacBeeb.app
  NetworkDocument (.macbeebnet)      — configuration: nodes, layout, media
  NetworkStudioWindow                — canvas, tiles, inspector, print centre
  MachineController (existing)       — a detached station window: unchanged UI
        |  observes / sends commands
BeebHost
  StationHost   — one station's commands, frames, audio, lights (split out of EmulatorHost)
  EmulatorHost  — one StationHost on its own thread (today's behaviour, unchanged)
  NetworkHost   — N StationHosts + an EconetBus on one scheduler thread
BeebCore
  MC6854        — the ADLC, guest-visible registers, FIFOs, status, IRQ out
  EconetPort    — per-machine wiring: station links, INTON/INTOFF, NMI, clock/carrier
  EconetBus     — the shared half-duplex medium, clock, bytes in flight, trace
  PrinterPort   — Centronics on the user VIA (data, STROBE, ACK) to a sink
BeebPrint (new)
  PrintJob, spool, text renderer, PDF export
```

### 2.1 StationHost: one refactor, both hosts

Today's `EmulatorHost` does two jobs: it runs a thread with pacing, and it
handles one machine's commands, publishing its outputs. Split them:

- `StationHost` keeps the command queue, `HostSession`, frame, lights and
  debugger publishing, `perform`, the audio ring and the disc write-backs.
  Its public API is the same as today's `EmulatorHost`, as a protocol
  (`MachineHost`) that `MachineController` takes.
- `EmulatorHost` = one `StationHost` and today's thread loop. **Standalone
  MacBeeb is unchanged**, and so is its performance (the benchmark and tests
  run before and after).
- `NetworkHost` = many `StationHost`s and one scheduler thread.

So a detached station window is an ordinary `MachineController` and
`MachineWindow`, with every existing feature: the debugger, discs, recording,
screenshots and the hardware window. The only difference is that its host is
a station of a `NetworkHost`. Closing it removes an observer and doesn't stop
the station.

### 2.2 Scheduler (NetworkHost)

- **One thread, serial and deterministic** to start with. Stations run in
  **lockstep quanta** of emulated time: each runs to the same boundary in
  turn, in a fixed order (by node UUID). Nothing that crosses between
  stations takes effect before the next boundary.
- **The quantum is the bus's latency.** A byte a station transmits in quantum
  *k* reaches receivers' ADLCs from boundary *k+1*, timestamped. While the bus
  is quiet the quantum can be long (1ms, today's slice). While any station's
  transmitter is enabled, or a frame is in flight, it's one byte-time at the
  network clock (about 80 cycles at 200kbit/s, for example). The policy
  depends only on emulated state, so runs repeat exactly. Simultaneous
  transmitter starts in one quantum are a collision, tie-broken by station
  order (§5.2 of the spec).
- **Pacing**: against the wall clock. Audio paces only the focused station's
  ring, and the others' rings are drained and dropped. There's no per-machine
  warp in a network: the network's speed is one setting (real time, or as
  fast as possible for tests).
- **Pause the whole network**: the scheduler stops at a boundary, so no
  station's time advances and nothing times out. **Suspend a station**: the
  scheduler skips it, so its time stands still while its ADLC stays on the
  bus and stops answering, and peers time out as on a real network. **Off**:
  the station is detached from the bus, and power on is a fresh
  `BBCMicro(configuration:)`, as today's power cycle.
- **Debugger stops**: the default is *Pause Whole Network on Breakpoint*: a
  stop on any station stops the scheduler at the next boundary.
- **Later, in parallel**: each quantum's stations are independent until the
  boundary, so they could run on a thread pool with a barrier and still give
  the same results. Do it only if the §4.3 measurements call for it.

### 2.3 Econet hardware (BeebCore)

- **`MC6854`**: ported from BeebEm's register model (with attribution):
  - CR1–CR4 with the address-control bit;
  - three-byte TX/RX FIFOs with frame-end and address-present marks;
  - SR1 and SR2 with prioritised status (PSE);
  - TX underrun, RX overrun, abort, idle, flag fill;
  - frame valid and CRC status, CTS/DCD;
  - reset through CR1, and the IRQ output.

  Not ported: BeebEm's handshake state machine and IP code. The ADLC sends
  and receives **bytes on a line, at the line's clock**, and the guest ROM does
  the four-way handshake itself.
- **`EconetPort`**: per model, connecting the ADLC to the machine:
  - the Model B decodes &FEA0–&FEBF (A0–A1; aliases to be confirmed from the
    AUG circuit);
  - station-ID links and INTOFF: any access to &FE18 on the B, &FE38 on the
    Master;
  - INTON: reading &FE20 on the B, &FE3C on the Master;
  - the NMI flip-flop that gates the ADLC's IRQ onto NMI.

  It's `nil` (no Econet module fitted) unless the configuration asks for one,
  so existing machines and their decoding don't change.
- **`EconetBus`**: endpoints keyed by (network, station). It has:
  - the clock: present/absent and its rate, as a clock node on the canvas;
  - carrier detection: DCD comes from a clock being present, CTS from the
    line;
  - one transmitter at a time: a second is a collision, and both see the line
    corrupted;
  - line idle versus flag fill, frame boundaries, and an abort on reset or
    power off;
  - test-only loss and corruption injection.

  It **emits trace events** (frame start, bytes, end, abort, collision, with
  emulated timestamps) to an optional ring-buffer observer. With no observer
  that costs one branch.

### 2.4 Printing

- **`PrinterPort`** (BeebCore): the user VIA's port A to a printer. STROBE
  comes from CA2 in pulse or manual mode, and ACK goes to CA1. The printer
  takes bytes at a configurable rate and is BUSY while its buffer is full.
  Its sink receives `(byte, emulated time)`. This is useful in standalone
  MacBeeb too (`*FX5,1`, then **File ▸ Print Centre**), so it ships first and
  gets tested without Econet.
- **The authentic printer server**: a printer node is a hidden BBC station
  (default 235) running the Level 1 **`PS`** program from its disc. Its printer
  port feeds the virtual printer. **Show Server BBC** opens it like any
  station. Clients use `*FX5,4`, then `VDU 2`/`VDU 3`, through their real NFS.
- **`BeebPrint`**:
  - **`PrintJob`**: an ID, source station (from the server's reports where
    the server software makes it observable; otherwise "via station 235"),
    raw bytes with timestamps, start/end and completion reason.
  - **Job boundaries**: a printer-server job ends when the server's port goes
    quiet. Exactly how isn't settled: we'll observe what PS does (it may send
    a form feed or close-down sequence, or just stop), then define the rule
    and test it.
  - **The renderer**: text, CR/LF, tabs, form feed, A4 or fanfold, margins, a
    fixed-pitch face, and clean or dot-matrix looks. It draws with CoreText into
    a `CGContext` PDF context, and the preview uses the same drawing code, so
    they match. Unknown control bytes stay in the raw job and are listed as
    unrendered.

### 2.5 Studio UI

- **A document per network**: `.macbeebnet`, a package (`FileWrapper`) with:
  - `manifest.json`: schema version, project UUID, nodes with UUIDs, station
    numbers, machine `Configuration` descriptions (model, disc interface,
    expansions, ROM references by firmware ID), the clock, layout and zoom,
    the workspace's tiles, and print-history metadata;
  - `Media/`: copies of the server's and stations' discs, which the BBCs write
    to copy-on-write, so a user's original disc file is never changed. Links
    to outside files are security-scoped bookmarks, with a relink action.

  Open, save, recent files and unsaved changes come from SwiftUI's
  `DocumentGroup`/`ReferenceFileDocument`, so **File ▸ New Network…**, **Open
  Network…** and recents are standard. **File ▸ New Disc** keeps ⌘N, and New
  Network takes ⌥⌘N. **Window ▸ Network Studio** reopens the last project or
  the template chooser.
- **Canvas**: SwiftUI with pan and zoom (a `scaleEffect` and offset
  transform). Nodes are cards with live thumbnails and the station number. A
  shared-bus backbone is drawn, with a logical link from each node, and
  traffic pulses driven by real trace events. There's snap-to-grid,
  multi-select, a context menu, inline validation of duplicate station
  numbers, a missing clock, missing ROMs or software and inaccessible media,
  and accessibility labels.
- **Thumbnails**: a `ThumbnailCache` reads each visible station's
  `latestFrame` at most N times a second (10 by default) and downsamples it
  on a background queue into a `CGImage`. Offscreen nodes aren't sampled.
  Nothing happens per emulated instruction.
- **Tiles**: a grid of `EmulatorView`s over the same `StationHost`s. One has
  keyboard focus (a ring, and the title shows it); audio follows focus.
- **Inspector**: the overview counts, a frame/transaction list (scout, ack,
  data, ack correlated off the hot path), decoders for the file server
  (&99), printer server (&D1) and immediate operations, hex and ASCII, the
  timeline, filters, and JSON export. It's documented as a MacBeeb format,
  not PCAP.

### 2.6 MCP and debugger

- **Every machine tool takes an optional `machine`** (a station name, number
  or UUID). Without it, the standalone behaviour is unchanged. In a network,
  a destructive tool (`poke`, `power_cycle`, `load_*`, and so on) with no
  machine named returns a typed `ambiguous_machine:` error listing the
  stations, rather than guessing.
- **The routing**: `AgentTools` takes a `MachineContext` provider that
  resolves the machine argument, and `StationHost` is a `MachineContext`. The
  existing tools work unchanged on a station.
- **New tools**:
  - `list_machines`, `network_topology`;
  - `network_add_station`, `network_configure_station`,
    `network_remove_station`;
  - `network_power` (on/off/reset, all or one), `network_pause`,
    `network_suspend_station`;
  - `network_trace` (filter, cursor, limit), `network_capture`
    (start/stop/export);
  - `econet_status` (the ADLC registers, FIFOs, NMI, clock, bus owner);
  - `print_jobs`, `print_job`, `export_print_job_pdf`.
- **Debugger**: the window and DAP are already per machine (`machine.id`).
  In a network, the title says the station, and a stop pauses the whole
  network by default. The window says so, with a "let the others run" toggle
  that shows the timeout warning.

## 3. Phases, as committed milestones

Each one builds, passes `make test`, and is a commit. Not pushed.

**1. Multi-instance Studio (no Econet)**
- 1a `StationHost`/`EmulatorHost` split; `MachineController` on a `MachineHost`.
  Baseline benchmarks and the full tests before and after.
- 1b `NetworkHost`: the lockstep scheduler, power/suspend/pause, audio
  focus. Headless tests: 1, 2, 4 and 8 stations boot and run independently.
- 1c The `.macbeebnet` document, the model, migrations and templates (Two
  BBCs, School Classroom, BBC and Master, Empty).
- 1d The canvas, palette, thumbnails, inspector panel for properties, and
  detached windows (an existing `MachineWindow` on a station).
- 1e Tiles, focus routing, Focus Station… and next/previous, the toolbar
  (Power On All…), resource use. Docs.

*Demo*: four stations running different BASIC programs.

**2. ADLC and a working local Econet**
- 2a `MC6854` with register-level unit tests (the CR/SR side effects, the
  FIFOs, IRQ). `EconetPort` for the Model B and Master, with NMI and
  INTON/INTOFF tests through guest code.
- 2b `EconetBus`, the clock and the scheduler's quantum policy. Two stations
  with DNFS: station ID and clock reporting, an OSWORD &10/&11
  transmit/receive between them, and a missing recipient's "not listening".
  Diagnostic trace from the start.
- 2c The Level 1 file server on station 254 (from the server disc):
  `*I AM`, `*CAT`, `SAVE`/`LOAD`/`CHAIN`, binary files checked byte for byte,
  two clients, the server powered off ("No reply"), and back.
- 2d Studio integration: the Econet module and clock node, the file-server
  node with Open Server Console, status, and warnings.

*Demo*: A saves, B loads, the checksums match; the server off fails, and
back on recovers.

**3. Printing**
- 3a `PrinterPort` on the user VIA, `BeebPrint` jobs, the renderer, PDF, and
  the Print Centre, for **standalone** MacBeeb too (`*FX5,1`).
- 3b The printer node as a server station running Level 1 `PS`; clients
  print with `*FX5,4`, `VDU 2`/`VDU 3`. Two clients racing see "Printer busy"
  as the server reports it.

**4. Inspector, debugger and MCP**: the full inspector, decoders, timeline,
capture export, break on frame or port, machine-addressed MCP and the network
tools, docs.

**5. Polish and convenience**: a host-directory file server, a native
printer service, ESC/P, and benchmark-driven tuning.

**6. Remote networking** stays out of scope. Only the `EconetBus` endpoint
boundary is built now, and no remote UI is shown.

## 4. Tests, fixtures and measurements

### 4.1 Fixtures
- The ROM and server discs come from `reference/` when it's present, and the
  tests are skipped otherwise, as the NuLA gallery tests are. If they become
  bundled (§5), the tests always run.
- `Tests/BeebCoreTests/Resources/econet/`: small BASIC and assembler
  programs written for these tests (OSWORD &10/&11 send and receive, a binary
  file with a known checksum).

### 4.2 What's asserted
Guest-visible results throughout:
- screen text (`*CAT` listings, the ROM's error messages);
- memory checksums;
- ADLC registers as the guest reads them;
- NMI counts;
- trace events.

Nothing is asserted on internal return values alone.

### 4.3 Performance
- Before and after 1a: `make bench` and the full tests, and standalone must
  be no slower.
- In 1b: 1, 2, 4, 8 and 16 Model B stations running a MODE 2 drawing
  workload, timed for emulated speed, host CPU and memory. Rewind is off for
  stations by default: each keeps snapshots, so 16 of them is a lot of
  memory.
- In 1d: main-thread time with 8 visible thumbnails, and input latency in a
  tile.

## 5. Risks and open decisions

1. **Firmware and server software (needs your decision).** MacBeeb already
   bundles Acorn ROMs (OS, BASIC, DFS, ADFS), as b2 and jsbeeb do. The spec
   says not to bundle without verified permission. The candidates:
   - DNFS and ANFS 4.25: both bundled by jsbeeb and BeebEm;
   - the Level 1 and Level 2 server discs, including PS: bundled by BeebEm.

   If they're bundled, the templates work at once. If not, the Studio has an
   import checklist. Either way the code is the same.
2. **NFS timing**: the ROMs drive the ADLC from tight NMI handlers and
   time out on the four-way handshake. The quantum policy must make bytes
   arrive when the ROM expects them. The 2b tests find out, and the bus
   latency is a parameter.
3. **Single-thread speed**: 8 stations at about 2× headroom is fine, but 16
   isn't real time on one thread; that's what §2.2's parallel lockstep is for.
4. **MC6854 detail**: BeebEm's model was tuned for its datagram transport.
   Where its flag-fill, idle and CTS handling assumed that transport, the
   ADLC datasheet and the DNFS disassembly decide instead. Compromises go in
   `docs/development/econet-hardware-notes.md`.
5. **NMI sharing with the 8271/1770**: both are NMI sources. Regression tests
   do disc access while Econet traffic arrives.
6. **The document model**: `DocumentGroup` changes the File menu, so check
   that standalone windows and existing commands are unchanged.
7. **The printer server's job boundaries**: depend on how PS signals the
   end of a job; observe first, then define (§2.4).

## 6. As built (2026-10-23)

Phases 1–4 are done (commits from 57a1908). Where the build differs from
the plan above:

- **No separate StationHost class.** `EmulatorHost` itself is the station:
  its command handling and publishing are split from its thread, and a
  `NetworkHost` drives many of them (`isNetworkStation`). A tool that asks
  a station for time (`MachineSession.advance`) runs the whole network in
  lockstep (`NetworkHost.runNested`), never the station alone.
- **The quantum is fixed at 32 cycles with Econet** (no adaptive long
  quanta): a variable line delay breaks the handshake's idle window. See
  econet-hardware-notes.md.
- **The printer server is MacBeeb's own BASIC program** (`PrinterServer`),
  run on the printer server's BBC through its own DNFS, because Acorn's
  printer server software isn't available. The protocol follows
  PiEconetBridge's printer server (GPLv3) and DNFS's traffic.
- **Documents autosave** in Documents ▸ MacBeeb Networks rather than using
  `DocumentGroup` (which would have taken over File ▸ New and ⌘N).
- **The trace** is assembled from line events (`EconetTrace`, 4,096 frames)
  and exported as MacBeeb's own JSON.

Not done (phase 5 and later): a host-directory file server, a native
printer service, ESC/P graphics, Level 2 server tests, whole-network save
states, a B+ NFS ROM, parallel scheduling, and remote networking.
