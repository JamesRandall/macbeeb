# Hardware Expansions

The BBC Micro Model B came with 32K of RAM and four sockets for ROM chips.
Owners soon added more: sideways RAM to load ROM images from disc instead of
buying chips, and shadow RAM boards so programs kept their memory in the
graphics modes. MacBeeb can fit some of these to its Model B.

## Quick start

1. Choose **Machine ▸ Hardware Expansions…** (⌥⌘E), or **Hardware
   Expansions…** in the toolbar's Model menu.
2. Click a board, such as **Sideways RAM 32K**.
3. Click **Restart BBC**. The BBC restarts with the board fitted, as if you'd
   switched it off and on again. Discs stay in their drives.

To take it out again, choose **None (stock Model B)** and restart.

## What's available

| Board | What it adds | Guide |
| --- | --- | --- |
| None (stock Model B) | Nothing: the Model B as it came | |
| Sideways RAM 16K | One 16K bank of RAM in a ROM socket | [Sideways RAM](sideways-ram.md) |
| Sideways RAM 32K | Two 16K banks on one module | [Sideways RAM](sideways-ram.md) |
| Watford Electronics 32K Shadow RAM | 32K of shadow RAM, with its ROM (Shadow RAM OS 2.40) | [Watford Shadow RAM](watford-shadow-ram.md) |

Only one memory board can be fitted at a time: on a real BBC they all plug
into the same places. Expansion boards are for the Model B. The B+ and the
Masters have shadow and sideways RAM built in, and the Model A can't take
them.

## Sideways RAM and shadow RAM

The BBC's 6502 can address 64K at once. The top 16K is the operating system,
and &8000 to &BFFF is a window, 16K wide, onto one of up to sixteen
**sideways banks**, chosen by the ROMSEL register at &FE30. BASIC and the
disc filing system (DFS) are ROMs in two of those banks.

**Sideways RAM** is a bank made of RAM instead of ROM. You can load a ROM
image into it from disc, and the BBC treats it like the real chip after the
next Break. It can also hold data.

**Shadow RAM** gives programs back the memory the screen uses. Without it,
MODE 0, 1 or 2 takes 20K for the screen, leaving under 6K for a BASIC
program with a DFS. A shadow RAM board puts more RAM at the same addresses
as the screen: programs use the board's RAM, and the screen stays in the
BBC's. Its ROM switches between them as the OS draws.

## Restarting

Fitting or removing a board changes where the BBC's memory is, so MacBeeb
restarts the BBC, as switching it off and on would. You choose the board in
the Hardware Expansions window first; nothing changes until you click
**Restart BBC** (or **Revert** to leave it as it was).

Loading or clearing a sideways RAM bank doesn't need a restart. The BBC finds
a new ROM image at the next **Break** (⌘B). **Ctrl-Break** (⌃⌘B, a hard reset
that keeps memory) works too.

| What you do | Memory | Sideways RAM | The board |
| --- | --- | --- | --- |
| Break | Kept | Kept; ROMs found again | Kept |
| Ctrl-Break | Kept (the OS clears its own workspace) | Kept; ROMs found again | Kept |
| Power Cycle (⇧⌘R) | Cleared | Cleared, then any power-on images loaded | Kept |
| A different board | Cleared | Cleared | Changed |

Boards with their own ROM may react to these too. The Watford board, for
example, turns itself off on Ctrl-Break, as the real one did.

MacBeeb remembers the board, like the model, for new windows and next time.
Save states (**File ▸ Save State…**) include the board and everything in
its RAM. Games from the Game Library always start on a stock Model B.

## For programmers and AI agents

The debugger's memory view, the `peek` MCP tool and others can read a bank
directly, without paging it in: see the [developer reference](developer-reference.md).
AI agents can fit boards and load sideways RAM with MacBeeb's MCP tools
(`get_hardware`, `power_cycle` with `memory_board`, `load_sideways_bank`).

## What is and isn't emulated

- The sideways RAM modules follow a real module's documented wiring
  (BeebMaster's 32K module). On a real Model B, bank numbers 0 to 11 also
  reach the four motherboard sockets, because the BBC only decodes part of
  ROMSEL. MacBeeb doesn't model that: each bank answers only to its own
  number, as on a machine with a ROM board.
- Boards with a ROM (the Watford board) come with a tested copy of their
  real ROM, checked by its hash. You can use your own dump instead.
- The Aries B32 and B12 and VideoNuLA are being added. They'll appear here
  when they're done and tested.
