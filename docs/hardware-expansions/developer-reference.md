# Developer Reference

For programmers, debugger users and AI agents: what each expansion does to
the memory map, its registers, how MacBeeb models it, and the MCP tools.
Internal evidence and open questions are in
`docs/development/expansion-hardware-notes.md`.

## Configuration

A Model B's expansions are part of its configuration
(`BBCMicro.Configuration.expansions`, a `BBCMicro.Expansions`): the memory
board, and for sideways RAM its socket and second-bank wiring. Other models
ignore them. Save states carry the whole configuration, ROMs included, and
older save states without expansions load as a stock Model B.

| Board | `MemoryBoard` | MCP `memory_board` | Extra RAM |
| --- | --- | --- | --- |
| None (stock Model B) | `none` | `none` | 0 |
| Sideways RAM 16K | `sidewaysRAM16` | `sideways_ram_16` | 16K |
| Sideways RAM 32K | `sidewaysRAM32` | `sideways_ram_32` | 32K |
| Watford Electronics 32K Shadow RAM | `watford32K` | `watford_32k` | 32K |
| Aries B32 | `ariesB32` | `aries_b32` | 32K |
| Aries B32 + B12 | `ariesB32B12` | `aries_b32_b12` | 48K |

## Sideways RAM

### Memory map

| Address | Contents |
| --- | --- |
| &0000–&7FFF | Main RAM (unchanged) |
| &8000–&BFFF | The bank selected in ROMSEL: ROM, sideways RAM, or nothing |
| &C000–&FFFF | The OS ROM (unchanged) |

| Board | Banks | Settings |
| --- | --- | --- |
| Sideways RAM 16K | *s* | socket *s* = 12 or 13 |
| Sideways RAM 32K | *s*, *s* − *d* | *d* = 4 (lead on IC76 pin 12) or 8 (pin 11) |

### Registers

| Address | Write | Read |
| --- | --- | --- |
| &FE30–&FE3F | ROMSEL: bits 0–3 select the bank for reads and writes | Nothing (as stock) |

There's no write-protect register: a RAM bank is written whenever ROMSEL
selects it. ROM banks and empty sockets ignore writes. An empty socket
leaves the data bus as it was (open bus), as on the stock Model B.

### Physical storage

Each RAM bank is its own 16K, distinct from main RAM and from the other
banks. Power on clears it to zeros, then loads any power-on images. Break
and Ctrl-Break leave it alone. Save states and the rewind history include
it.

## Watford Electronics 32K Shadow RAM

### Memory map (the CPU's view)

| Latch | &0000–&2FFF | &3000–&7FFF | Set by a write to |
| --- | --- | --- | --- |
| `bbc` | Main RAM | Main RAM | &FFFE |
| `upper` | Main RAM | Board RAM &3000–&7FFF | &FFFF |
| `all` | Board RAM &0000–&2FFF | Board RAM &3000–&7FFF | &FFFC |

The video always reads main RAM. &8000–&FFFF is unchanged. Board RAM
address *n* is the board's byte *n*: it stands in for main RAM at the same
address.

### Registers

| Address | Write | Read |
| --- | --- | --- |
| &FFFC, &FFFE, &FFFF | Set the latch (by the address; the data is ignored). The OS ROM there ignores the write | The OS ROM, as stock |
| &FFFD | Decoded by the board, effect unknown: ignored and counted (`watfordFFFDWrites`) | The OS ROM |

Only CPU writes move the latch. `peek`, `poke` and the debugger never do.
Power on starts it at `bbc`; Break and Ctrl-Break leave it alone (the ROM
sets it as it needs).

### The ROM

Shadow RAM OS 2.40 in bank 13 (`Firmware.standard(for: .watford32K)`, 8K,
SHA-256 `a2e7c05f…bfcb`). Its OS interface, from the ROM's own `*HELP RAMFX`
and the manual:

- `*FX34,X` (also `*FX111,X`): bit 0 selects data area 0 (BBC RAM) or 1
  (the board's) at &3000–&7FFF; bit 6 reads instead of writing; bit 7 pushes
  or pops an 8-deep stack.
- `*FX32` and `*FX33,X`: like `*FX132` and `*FX133`, for the top of memory
  with the board.
- OSWORD &6E/&6F: read or write a byte in either data area.
- `*FX250,X,Y`: read or write the board's status byte.

### State

The latch and the &FFFD count are in the snapshot (`ExpansionState`,
versioned). The board's RAM is in the snapshot's RAM.

## Aries B32 and B12

### Banks

| Bank | B32 | B32 + B12 |
| --- | --- | --- |
| 0 | — | B12 RAM (16K, written only through &FE32) |
| 1–8 | — | B12 sockets (empty) |
| 9–12 | Motherboard sockets: DFS 10, BASIC 11 | B12 sockets: DFS 11, BASIC 12 |
| 13 | Pool &0000–&3FFF | The same |
| 14 | Pool &4000–&7FFF | The same |
| 15 | B32 socket: ARIES-B32 1.00 | The same |

### Shadow RAM (the CPU's view of &3000–&7FFF with shadow on)

| Range | Shadowed when | Pool offset (bank) |
| --- | --- | --- |
| &3000–&3FFF | &FE3A (off: &FE3C) | &7000–&7FFF (bank 14, &B000–&BFFF) |
| &4000–&6FFF | always | &0000–&2FFF (bank 13, &8000–&AFFF) |
| &7000–&7FFF | &FE36 (off: &FE34) | &3000–&3FFF (bank 13, &B000–&BFFF) |

| The ROM's setting | &3000 switch | &7000 switch | Sideways RAM left |
| --- | --- | --- | --- |
| 20K (`*XON`) | on | on | 12K in bank 14 (&8000–&AFFF) |
| 16K (`*XON 16`) | off | on | 16K in bank 14 |
| 0K (`*XOFF`) | off | off | 32K in banks 13 and 14 |

The video always reads main RAM.

### Registers (written by the ROM, never read)

| Address | Write |
| --- | --- |
| &FE30 | ROMSEL: the bank read at &8000–&BFFF |
| &FE32 | RAMSEL: where writes to &8000–&BFFF go. 13 or 14: the pool; 15: nowhere (the ROM's `*RWRITE OFF`); 0–12: passed on to the BBC's bus, where the B12's RAM takes them (`*RWRITE 0` and `EXTERNAL`) |
| &FE34 / &FE36 | Shadowing of &7000–&7FFF off / on |
| &FE38 | Shadow on if the start-up link is fitted, else off |
| &FE3A / &FE3C | Shadowing of &3000–&3FFF on / off |
| &FE3E / &FE3F | Shadow off / on (the CPU sees main RAM / the pool) |

Other addresses in &FE31–&FE3D aren't used by the ROM and do nothing.
Reads of &FE30–&FE3F are as on the stock Model B. The ROM keeps its own state
(the split, pending changes, `*RWRITE`) in &27F.

### Evidence

The registers come from the ROM itself: its detection routine (&839A), the
table of register pairs for each split (&AC85, written by &AB68), the
`*RWRITE` table (&AEFD) and `*XTEST`'s state test, which expects specific
values back from &3000, &4000 and &7000 for each split. With this model the
ROM's `*XTEST` passes (B32 and B32 + B12), and `*XSTATUS` gives the manual's
figures (26112 bytes from &1A00 to &8000; 22016 bytes to &7000 in MODE 1
with 16K; 5888 bytes from &1900 to &3000 with none; "14: RAM 12K Unused").
MAME's model has &FE30, &FE32 and &FE3E/&FE3F but stubs &FE34–&FE3A and maps
shadow RAM linearly onto the pool, which overlaps bank 14's 12K.

### State

`AriesState` (RAMSEL and the three switches) is in the snapshot's versioned
`ExpansionState`; the pool is in the snapshot's RAM. The start-up link is
part of the configuration (`Expansions.ariesStartUpLink`).

## Inspection and the debugger

| Space (`peek`/`poke` `space`, debugger) | What it reads |
| --- | --- |
| `host` | The CPU's logical view now: the selected bank at &8000 |
| `main` | Main RAM, &0000–&7FFF |
| `bank0`…`bankF` | A sideways bank's physical storage, at &8000–&BFFF, whatever's selected |
| `board` | The Watford board's RAM, &0000–&7FFF; or the Aries B32's pool (bank 13, then 14) |
| `os` | The OS ROM |

Peeks never have side effects: I/O registers are peeked, not read. `poke`
writes storage directly, ROM included (to patch it), but never I/O. The
debugger's Hardware view has an "Expansion board" section with the board,
ROMSEL and each RAM bank's contents.

## MCP tools

| Tool | What it does |
| --- | --- |
| `get_hardware` | The model, second processor, disc interface, memory board and its wiring, the controller ROM (name, version, bundled or not, SHA-256), the Watford latch, any problem, and all sixteen banks: kind, owner, when writable, ROM title, which is selected |
| `power_cycle` | With `memory_board` (`none`, `sideways_ram_16`, `sideways_ram_32`, `watford_32k`, `aries_b32`, `aries_b32_b12`), `aries_start_up_link`, `sideways_ram_socket` (12 or 13) and `second_bank_below` (4 or 8), fits a board (Model B only) and restarts. Without them, the board is kept |
| `load_sideways_bank` | `bank` and `path`: puts a ROM image (up to 16K) in a sideways RAM bank from outside the BBC. `clear: true` empties it. The OS finds a new ROM at the next Break |
| `save_sideways_bank` | `bank` and `path`: saves a bank's 16K, ROM or RAM |
| `press_break` | `ctrl: true` for Ctrl-Break, a hard reset that keeps RAM |
| `peek` / `poke` | `space: "bankD"` for a bank's physical storage, `space: "host"` for the CPU's view |
| `memory_regions` | Every space, each sideways bank (ROM or RAM) included |

Errors say what's wrong and what to do: loading a bank that isn't RAM lists
the RAM banks; asking for a board on another model says boards fit the
Model B only.

Example, fitting a 32K board and running a ROM from it:

```
power_cycle        {"memory_board": "sideways_ram_32"}
load_sideways_bank {"bank": 13, "path": "Examples/sideways-ram/hello.rom"}
press_break        {}
run_command        {"text": "*HELLO"}       -> Hello from sideways RAM bank 13
peek               {"address": "&8009", "length": 13, "space": "bank13"}
```

## Reset semantics

| Event | CPU | Main and board RAM | Latches |
| --- | --- | --- | --- |
| Break | Reset | Kept | ROMSEL as the OS sets it |
| Ctrl-Break | Reset (the OS starts as at power on) | Kept | As Break |
| Power cycle | Reset | Cleared, then power-on images | Reset |
| A different board | New machine | New and cleared | Reset |

## Tests

- `StockBaselineTests`: the stock Model B's and Master's pictures and the
  Model B's memory map, pinned before any expansion code.
- `SidewaysRAMTests`: bank wiring, isolation at offsets &0000, &1FFF and
  &3FFF, ROM and empty sockets unwritable, image loading and its errors,
  a ROM image found and run at power on, in-guest writes through ROMSEL from
  BASIC, DFS 2.26's `*SRLOAD` then Ctrl-Break, and save states.
- `WatfordShadowRAMTests`: the latch at &2FFF/&3000/&7FFF and in all
  three settings, only CPU writes switching, the real ROM's `*HELP`,
  `*HELP RAMSTATUS` and `*HELP RAM`, a 16K array in MODE 1 with the picture
  untouched (frame hash) and HIMEM &8000, `*FX34`, `*RAMOFF`/`*RAMON`, SAVE
  and LOAD of a program past &3000, Break and Ctrl-Break, save states, the
  firmware hashes, a board without its ROM, and the guide's example (out of
  memory on a stock Model B, fine with the board).
- `AriesTests`: the manual's `*XSTATUS` figures at power on, `*XON 16`
  pending until MODE, `*XOFF` and `*XON` with Break, `*XOFF 2`, `*RWRITE`
  separating reads from writes, `*RLOAD` then Break, 16K images and the
  manual's "Not enough RAM" and "RAM in use", shadow RAM in MODE 1 with the
  picture unchanged, the pool layout, the start-up link, the B12, Ctrl-Break,
  save states, the firmware, and the ROM's own `*XTEST` (in optimised builds,
  or with `MACBEEB_SLOW_TESTS`).
- `AgentHardwareToolsTests`: the MCP round trip.
