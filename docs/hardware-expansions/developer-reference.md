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

## Inspection and the debugger

| Space (`peek`/`poke` `space`, debugger) | What it reads |
| --- | --- |
| `host` | The CPU's logical view now: the selected bank at &8000 |
| `main` | Main RAM, &0000–&7FFF |
| `bank0`…`bankF` | A sideways bank's physical storage, at &8000–&BFFF, whatever's selected |
| `os` | The OS ROM |

Peeks never have side effects: I/O registers are peeked, not read. `poke`
writes storage directly, ROM included (to patch it), but never I/O. The
debugger's Hardware view has an "Expansion board" section with the board,
ROMSEL and each RAM bank's contents.

## MCP tools

| Tool | What it does |
| --- | --- |
| `get_hardware` | The model, second processor, disc interface, memory board and its wiring, and all sixteen banks: kind, owner, when writable, ROM title, which is selected |
| `power_cycle` | With `memory_board` (`none`, `sideways_ram_16`, `sideways_ram_32`), `sideways_ram_socket` (12 or 13) and `second_bank_below` (4 or 8), fits a board (Model B only) and restarts. Without them, the board is kept |
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
- `AgentHardwareToolsTests`: the MCP round trip.
