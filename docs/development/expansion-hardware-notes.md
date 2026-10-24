# Model B hardware expansions: audit and evidence

Internal notes for the Model B expansion work: sideways RAM, the Watford
Electronics 32K RAM board, the Aries B32 and B12, and VideoNuLA. This is the
Phase 0 audit. Later phases add their findings below, under the same
headings. The user guides are in [`docs/hardware-expansions/`](../hardware-expansions/README.md).

## Where things are in MacBeeb

| Concern | Where |
| --- | --- |
| CPU reads, writes and opcode fetches | `BBCMicro.step()` in `Sources/BeebCore/Machine/BBCMicro.swift`: 4K pages through `readPages`/`writePages`, two tables (the second for code in &C000-&DFFF on the B+ and Master) |
| Paging (ROMSEL, ACCCON, shadow) | `BBCMicro.updatePaging()`, rebuilt on every ROMSEL/ACCCON write: no per-access cost |
| I/O decode | `readIO`/`writeIO` (A, B, B+), `readIOMaster`/`writeIOMaster`. On the B, &FE30-&FE3F all write ROMSEL (`value & 0x0F`) |
| Video fetch | `BBCMicro.updateVideo`: `ram[address & videoAddressMask + videoRAMOffset]`. On the B, `videoRAMOffset` is always 0 (main RAM) |
| Physical RAM | One allocation, `ram`: main 32K, a 32K shadow area (used by the B+ and Master), ANDY, HAZEL. On the Model B, the shadow area is unused |
| Sideways banks | `sidewaysBanks[0...15]`, nil for an empty socket; `sidewaysRAMBanks` are written whenever selected (as the B+ and Master's sideways RAM) |
| Empty sockets | Reads leave the data bus alone on the B (open bus); MacBeeb doesn't model the B's partial ROMSEL decode (banks 0-11 aliasing the four sockets) |
| Debugger memory | `MemorySpace` and `debugRead`/`debugWrite`/`memoryRegions` in `Sources/BeebCore/Debug/BBCMicro+Debug.swift`. `debugRead(.cpu)` peeks I/O without side effects; physical spaces read storage directly |
| Hardware state panel | `Sources/BeebCore/Debug/HardwareState.swift` |
| Video ULA | `Sources/BeebCore/Video/VideoULA.swift`, a port of the non-NuLA part of b2's `VideoULA.cpp`. Pixels are 12-bit RGB (4 bits a channel) in `VideoUnit`, expanded by nibble duplication in `TVOutput` |
| Palette timing | Writes take effect at the CPU cycle they happen, and pixels are produced every 2MHz cycle, so palette changes part way along a line show where they happen |
| Snapshots | `BBCMicro.Snapshot` (`Sources/BeebCore/State/BBCMicro+State.swift`): the whole `ram` buffer, sideways RAM, latches. Save state files (`SaveStateFile`) carry the full `Configuration`, ROMs included |
| Rewind and replay | `Rewinder`: keyframe snapshots plus recorded inputs, so anything in `Snapshot` survives rewinding |
| Reset | Break: `applyKey(.breakKey)` halts then resets the CPUs, and RAM is kept. Power cycle: a new `BBCMicro` from the same `Configuration`, with RAM cleared |
| Machine configuration | `BBCMicro.Configuration` (model, ROMs, sideways RAM banks, co-processor, disc interface); `BeebROMs.configuration(for:)` builds the standard ones |
| App choice of machine | `MachineController` (remembered in UserDefaults; `changeMachine()` power cycles), the Model menu and toolbar |
| MCP | `Sources/BeebAgentKit`: `power_cycle` (model, co-processor, disc interface), `peek`/`poke` with `space`, `memory_regions`, `get_status`, `screenshot` |
| Help | The app has no help book: Help ▸ What's New only |

## Baseline

Taken before any expansion code (23 October 2026):

- 498 tests, all passing (`swift test`).
- `StockBaselineTests`: frame hashes of a booted Model B, a MODE 2
  colour-bar picture (all sixteen colours, flashing ones included) on the
  Model B and the Master 128, and the stock Model B's memory map. These must
  never change.

## References used

| Source | What it gave |
| --- | --- |
| MAME `src/devices/bus/bbc/internal/we32kram.cpp` | Watford: writes to &FFFC, &FFFE, &FFFF select the mapping by address; firmware versions 1.00 to 2.40 and their hashes |
| MAME `src/devices/bus/bbc/internal/aries.cpp` | Aries B12/B20/B32: ROMSEL at &FE30, a separate write bank at &FE32, shadow off/on at &FE3E/&FE3F, stubs at &FE34-&FE3A; B32 RAM in banks 13 and 14 |
| *Watford Electronics 32K RAM Extension Board* manual (chrisacorns.computinghistory.org.uk) | The commands, OSBYTE 34 (`*FX34`), and "Direct control": &FFFF selects the board's RAM at &3000-&7FFF, &FFFE the BBC's, &FFFC the whole of &0000-&7FFF |
| *ARIES-B32* manual (ibid.) | The three allocations, pending changes applied on MODE or BREAK, the commands, OSBYTE &6F, the bank numbering (13 and 14 RAM, 15 its ROM, the motherboard's sockets renumbered 12, 9, 10, 11), *RWRITE write-through, use markers |
| *ARIES-B12* manual (ibid.) | Sockets 1-12 and RAM 0L/0H (bank 0), the four motherboard ROMs moved to sockets 9-12, write-through on its own (all writes to &8000-&BFFF go to bank 0) |
| BeebMaster 32K Sideways RAM fitting instructions | A real module's wiring: first bank its socket (12-15), second bank four or eight below, by which pin of IC76 its lead goes to; write enable wired to R/W (writable whenever selected); RAMLOAD, RAMCLR, RAMTEST |
| b2 (`reference/b2`): `VideoULA.cpp`, `BBCMicro.cpp`, `etc/b2_tests/5` | VideoNuLA: registers at &FE22/&FE23 (A1 set) on the B and B+, the full implementation, and test programs with expected pictures |
| jsbeeb (`reference/jsbeeb`): `video.js` | A second NuLA implementation to compare with |

## Firmware

Both control ROMs were found on J.G. Harston's archive
(mdfs.net/System/ROMs/Display/ShadowRAM/) and match MAME's hashes exactly:

| File | ROM header | Size | SHA-1 (= MAME's) | SHA-256 |
| --- | --- | --- | --- | --- |
| WERAMv240 | Shadow RAM OS 2.40 (C)1985 Ian Smith | 8K | `0a5efb084eb1ae353b9c79c026e9e26cd7695293` (`we32kram_v2.40.rom`) | `a2e7c05f809e62faf980096459165fa356cf7c253265131ec68a91bcd2f8bfcb` |
| Aries32v10 | ARIES-B32 1.00 (C)1985 David Barnett & Chris Jordan | 16K | `466e3b68f1a8e0287ae095cb3c16dac6afc89dcb` (`aries-b32_v2.2.rom`) | `8f1e288c08a706f76a43bd8ae296bfb7dce0a3f6244d8f95831261be97a78051` |

MAME labels the Aries image "v2.2", but its header says 1.00, as the
manual's examples do ("ARIES-B32 1.00"). We call it 1.00.

**Redistribution:** both are copyright (Watford Electronics/Ian Smith;
Chris Jordan and David Barnett), and the Aries manual forbids copying. No
permission has been found. MacBeeb already bundles third-party ROMs on the
same basis as b2 and jsbeeb (see `Sources/BeebROMs/ROMs/README.md`). These
are bundled the same way and listed in the manifest, so the decision can be
reviewed. A user can replace them with their own dumps, which are checked
against the known hashes.

## Questions this work has to answer

- **Aries 16K/20K shadow.** The manual says shadow RAM is taken from bank 13
  first, and the 20K mode takes the top 4K of bank 14 as well (bank 14 is then
  12K, from &8000). MAME maps &3000-&7FFF linearly onto the first 20K, which
  would overlap the bottom of bank 14 instead, and it stubs &FE34-&FE3A
  ("switch"). The hardware must have a 16K/20K switch: find it from what the
  real ROM writes, not by guessing.
- **Aries write protection.** `*RWRITE OFF` write-protects all sideways RAM,
  and `*RWRITE n` sends writes to bank n whichever bank is being read. What
  the ROM writes to &FE32 for each decides the model.
- **Watford &FFFD.** MAME decodes it but does nothing sensible with it. The
  manual doesn't mention it. Leave it alone unless the ROM uses it.
- **Watford power-on state.** MAME starts in "BBC RAM" (&FFFE); the manual says
  the board is active at power on, which is the ROM's doing.

## Plan

1. Sideways RAM 16K/32K: the existing sideways RAM banks, in the BeebMaster
   module's documented wiring (a socket bank and the bank four or eight below
   it), writable whenever selected as that module is.
2. Watford: the board's 32K in the `ram` buffer's shadow area (physically
   separate from main RAM), mapped by a latch set by writes to &FFFC-&FFFF.
   The video always reads main RAM. Its ROM in a motherboard socket.
3. Aries: the 32K pool in the shadow area, mapped into &3000-&7FFF and banks
   13 and 14 as the ROM and manual show; ROMSEL and the write bank separate;
   B12 as bank 0 RAM and sockets 1-12.
4. VideoNuLA: a port of b2's NuLA into `VideoULA`, mapped at &FE22/&FE23 only
   when fitted.

Each phase: core, tests (unit, in-emulator with the real ROMs, picture
hashes), save states, debugger and MCP, the app's Hardware Expansions
window, and its guide.

## Phase 1 findings: sideways RAM

- OS 1.20 scans the sideways banks on every Break, not only on a hard reset:
  a ROM image put into RAM is found after a plain Break (tested).
- DFS 2.26's SRAM 1.05 (`*SRLOAD` and the rest) works with BeebMaster-style
  RAM, written whenever selected. It's the in-guest loader for the tests.
- Not modelled: the Model B's partial ROMSEL decode (banks 0-11 aliasing
  the four sockets). Stock MacBeeb never modelled it, and adding it would
  change the stock machine.

## Phase 2 findings: Watford

- The board is on from power on (the ROM's doing; MAME's latch starts at
  BBC RAM, as MacBeeb's does). `*HELP RAMSTATUS` reports "RAM board active",
  PAGE &1A00 (a page of workspace), HIMEM &8000.
- At the prompt the latch is at BBC RAM (&FFFE): the ROM switches to the
  board only while a program runs. The UI's live latch shows this.
- Ctrl-Break turns the board off ("On CTRL-BREAK the whole system is
  disabled and no workspace is claimed"): HIMEM &3000 and PAGE &1900 until
  `*RAMON` and Break. Plain Break keeps its state. Both tested.
- &FFFD: Shadow RAM OS 2.40 never wrote it in any test (counted). Left
  unimplemented and documented.
- ROM order: the manual suggests the DFS in the lowest-priority socket and
  the board's ROM next to it. MacBeeb keeps the DFS in 14 and the board's ROM
  in 13. SAVE and LOAD of a program past &3000 in MODE 1 were tested with
  both orders, and both work.
- Software-visible results: a 16K array in MODE 1 with the drawing unchanged
  by frame hash; `*FX34` data areas land in the right physical RAM; the
  guide's example program fails with "DIM space" on a stock Model B and runs
  with the board.

## Phase 3 findings: Aries B32 and B12

How the registers were worked out, without guessing:

1. **What the ROM writes.** A scan of ARIES-B32 1.00 for absolute accesses
   to &FE30–&FE3F finds only writes: &FE30, &FE32, &FE3E/&FE3F, and a few of
   &FE36, &FE38 and &FE3A. The routine at &AB68 also writes &FE30+X from a
   table at &AC85, one pair of registers for each of the ROM's four states:
   &FE3C+&FE34, &FE3A+&FE36, &FE3A+&FE34, &FE3C+&FE36. (One write to &FFFE at
   &8C3C is data: `*XKLUDGE`'s pattern for patching B20 ROMs.)
2. **What `*XTEST` expects.** Its state test writes distinct values to &3000,
   &4000 and &7000 with shadow on and off, then compares what it reads back
   with a table (&A72A). That gives the shadow pieces exactly: &FE36/&FE34 are
   &7000–&7FFF on/off, &FE3A/&FE3C &3000–&3FFF on/off, and &4000–&6FFF is
   always shadowed.
3. **The pool.** `*XTEST`'s RAM test treats 20K of shadow RAM plus bank 14's
   &8000–&AFFF as one 32K with no overlap. The manual says shadow RAM comes
   from bank 13 first, and 20K takes the top 4K of bank 14. So &4000–&7FFF is
   bank 13, and &3000–&3FFF is &B000–&BFFF of bank 14. MAME's linear map would
   overlap bank 14's 12K.
4. **The start-up link.** The detection routine (&839A) writes &FE38 and
   checks whether &7FFF then reads shadow RAM with shadow off. That result
   becomes "Start-up link: ON/OFF". So &FE38 sets shadow as the link does.
5. **RAMSEL.** Run under MacBeeb: `*RWRITE 14` writes 14 to &FE32, `*RWRITE
   OFF` writes 15 (the ROM socket, so writes are lost), and `*RWRITE EXTERNAL`
   writes 0. The ROM's table at &AEFD (0, 13, 14, 15, then 00, 13, 14, 15 as
   BCD digits for printing) agrees. So 0–12 pass writes on to the BBC's bus,
   which is where the B12's write-through RAM sits.

A first guess that RAMSEL had a "write enable" bit made the ROM's power-on
use markers vanish, and `*XSTATUS S` then showed bank 14 as 8K + 8K instead
of the manual's 12K. With the decode above it shows "14: RAM 12K Unused". So
the manual's examples catch mistakes the code alone might not.

Checked against the ROM and the manual:

- `*XTEST` passes, B32 alone (no RAM in bank 0) and with the B12 (16K in bank
  0, `RWRITE 0 OK`).
- `*XSTATUS` at power on gives the manual's example: 20K, 26112 bytes from
  &1A00 to &8000, "14: RAM 12K Unused", "Start-up link: ON".
- `*XON 16` is pending until MODE, then 16K. MODE 1 then leaves 22016 bytes
  (&1A00 to &7000). `*XOFF` and Break leave 5888 bytes (&1900 to &3000) in
  MODE 1. `*XOFF 2` leaves 25088 bytes (&1A00 to &7C00) in MODE 7. All as the
  manual says.
- `*RLOAD` of a 16K image says "B32: Not enough RAM" with 20K of shadow RAM,
  and fits after `*XON 16`; `*XON 20` then says "B32: RAM in use". As the
  manual says.

Not emulated: the B20, the B12 without a B32, a RAM chip in the B32's ROM
socket, and reads of the board's registers (the ROM never reads them).

## Boards with a sideways RAM module

Boards and modules are separate (`Expansions.board`, `Expansions.sidewaysRAM`),
as on the real machine: the boards take the 6502's socket, a module a free
ROM socket. Older configurations with `"board": "sidewaysRAM16"/"sidewaysRAM32"`
decode as no board and that module.

- **Watford + module**: the board's ROM goes in the free socket the module
  doesn't take (13, or 12 with the module in 13); the module is written
  whenever selected, as without a board.
- **Aries B32 + module**: the B32 renumbers the motherboard sockets 12, 9,
  10, 11, so the module's first bank is 12 or 9. The B32 decodes every write
  to &8000-&BFFF through RAMSEL: 13 and 14 its own RAM, 15 nowhere, 0-12 on
  to the bus (`*RWRITE EXTERNAL`), where the module takes the write if
  ROMSEL selects it (`WritePolicy.whenSelectedAndPassedOn`). The B12's RAM
  takes every bus write, as its manual says.
- **Assumed, not documented**: where a 32K module's second bank (wired from
  IC76) lands with the B32's renumbering. MacBeeb moves it with the first,
  4 or 8 below; the window and `get_hardware` say it's an assumption.
- **B12 + module**: refused (`Expansions.problem`); the B12's cable takes all
  four motherboard sockets.

## Phase 4 findings: VideoNuLA

- b2's `VideoULA.cpp` is a full NuLA (MacBeeb's stock ULA was already a port
  of its non-NuLA half), so NuLA is a port of the rest. The state is one
  optional struct (`VideoULA.nula`): nil on a machine without it, so the
  stock path costs one predictable test per cycle, and older snapshots load.
- b2's picture tests (`etc/b2_tests/5`) compare directly: MacBeeb's TV is
  b2's, 736×576. All 368 NuLA pictures and the 16 stock ULA ones match pixel
  for pixel. The one difference found on the way was mine: b2 marks units as
  12MHz pixels whenever attribute mode 1 is on, in every pixel mode, and at
  4MHz writes nothing into the scroll buffer but still outputs it.
- A long-standing debugger bug fixed in passing: the Hardware view showed
  each logical colour's physical colour EOR 7 (MODE 2's red as "6 (cyan)").
  The ULA's palette holds the physical colour; the OS writes it EOR 7 and
  the ULA inverts it back.
- Not emulated, because nothing shows how they look: attribute modes 2 and 3
  and the text attribute mode (b2 stores but doesn't draw them; its
  `ShiftAttributeText` is never used), and functions E and F (border and blank
  colours: jsbeeb stubs them, b2 ignores them). jsbeeb renders less than b2:
  the palette, direct mode and flash flags, but not offset or blanking.
- The Bitshifters gallery (bbcnula1.ssd) programs a 16-colour palette and
  shows its pictures with NuLA; without it, its writes to &FE23 reach the
  stock palette (the mirror of &FE21), as on a real Model B. Not committed (the
  pictures are third-party art): the test reads it from reference/.
- b2's pictures are b2's own output (its harness can infer them), so matching
  them is agreement with b2, not proof against real hardware.

## Phase 5: completion

- Performance: NuLA's state first lived inside `VideoULA`, and the stock
  Model B ran about 5% slower (`beeb-bench`, headless 18.0× to 17.2×). It now
  lives beside it (`BBCMicro.nula`, `VideoNuLA.swift`), with one test of a
  constant at each of the three places video touches it. That's within the
  benchmark's run-to-run spread (17.3–17.4× against 17.6–18.0×). Phases 1–3
  measured the same as before.
- Help: every section of the Hardware window has a Learn More link
  to its guide page, as well as the toolbar's Guide button and Help ▸ Hardware
  Expansion Guide.
- Not done (no reference, or not practical yet): watchpoints that report the
  physical bank as well as the address; separate trace entries for video
  fetches. The debugger's Hardware view does list the last writes to a
  board's registers.

## Firmware and test material used

| What | Version | SHA-256 | Where |
| --- | --- | --- | --- |
| Watford Shadow RAM OS | 2.40 | a2e7c05f809e62faf980096459165fa356cf7c253265131ec68a91bcd2f8bfcb | Bundled (BeebROMs/ROMs) |
| ARIES-B32 | 1.00 (MAME: v2.2) | 8f1e288c08a706f76a43bd8ae296bfb7dce0a3f6244d8f95831261be97a78051 | Bundled |
| b2's NuLA and ULA test programs | b2 master | — | Tests/BeebCoreTests/Resources/nula (GPLv3) |
| b2's expected pictures | b2 master | — | 25 in Resources/nula/wanted; all 384 from reference/b2 |
| Bitshifters VideoNuLA Gallery 1 | GitHub master | — | reference/bitshifters-nula (not committed) |
