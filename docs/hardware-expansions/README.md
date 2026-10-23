# Hardware Expansions

The BBC Micro Model B came with 32K of RAM and four sockets for ROM chips.
Owners soon added more: sideways RAM to load ROM images from disc instead of
buying chips, and shadow RAM boards so programs kept their memory in the
graphics modes. MacBeeb can fit some of these to its Model B.

## Quick start

**Video:** turn on **VideoNuLA fitted** under **Video** in the same window,
on any model, and **Restart BBC**. See [VideoNuLA](videonula.md).

**Memory:**

1. Choose **Machine ▸ Hardware Expansions…** (⌥⌘E), or **Hardware
   Expansions…** in the toolbar's Model menu.
2. Click a board under **In the 6502's Socket**, such as **Watford
   Electronics 32K Shadow RAM**, a module under **In a ROM Socket**, such as
   **Sideways RAM 32K**, or one of each.
3. Click **Restart BBC**. The BBC restarts with them fitted, as if you'd
   switched it off and on again. Discs stay in their drives.

To take them out again, choose **None** and **No Sideways RAM**, and restart.

## What's available

In the 6502's socket, a shadow RAM board (one at a time; the board plugs in
where the 6502 was, and the 6502 into the board):

| Board | What it adds | Guide |
| --- | --- | --- |
| None (stock Model B) | Nothing: the Model B as it came | |
| Watford Electronics 32K Shadow RAM | 32K of shadow RAM, with its ROM (Shadow RAM OS 2.40) | [Watford Shadow RAM](watford-shadow-ram.md) |
| Aries B32 | 32K shared between shadow and sideways RAM (20K + 12K, 16K + 16K or 0 + 32K), with its ROM (ARIES-B32 1.00) | [Aries B32 and B12](aries-b32-b12.md) |
| Aries B32 + B12 | The B32, plus twelve ROM sockets and 16K of sideways RAM | [Aries B32 and B12](aries-b32-b12.md) |

In a free motherboard ROM socket, a sideways RAM module, with or without a
board:

| Module | What it adds | Guide |
| --- | --- | --- |
| Sideways RAM 16K | One 16K bank of RAM in a ROM socket | [Sideways RAM](sideways-ram.md) |
| Sideways RAM 32K | Two 16K banks on one module | [Sideways RAM](sideways-ram.md) |

And for video, on any model:

| Upgrade | What it adds | Guide |
| --- | --- | --- |
| VideoNuLA | Each of the 16 colours any of 4,096 | [VideoNuLA](videonula.md) |

A module goes with no board, the Watford board (its ROM takes the other free
socket) or the Aries B32 (which renumbers the sockets, and passes writes on to
the module after `*RWRITE EXTERNAL`). It can't go with the B12, whose cable
plugs into all four ROM sockets; the B12 has 16K of sideways RAM of its own.
VideoNuLA is separate: it goes with any of them, or none. Expansion boards are for the Model B. The B+ and the
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
example, turns itself off on Ctrl-Break, as the real one did, and the Aries
B32 goes back to 20K of shadow RAM.

MacBeeb remembers the board, like the model, for new windows and next time.
Save states (**File ▸ Save State…**) include the board and everything in
its RAM. Games from the Game Library always start on a stock Model B.

## For programmers and AI agents

The debugger's memory view, the `peek` MCP tool and others can read a bank
directly, without paging it in: see the [developer reference](developer-reference.md).
AI agents can fit boards and load sideways RAM with MacBeeb's MCP tools
(`get_hardware`, `power_cycle` with `memory_board` and `sideways_ram`,
`load_sideways_bank`).

## What is and isn't emulated

- The sideways RAM modules follow a real module's documented wiring
  (BeebMaster's 32K module). On a real Model B, bank numbers 0 to 11 also
  reach the four motherboard sockets, because the BBC only decodes part of
  ROMSEL. MacBeeb doesn't model that: each bank answers only to its own
  number, as on a machine with a ROM board.
- Boards with a ROM (the Watford and Aries boards) come with a tested copy of
  their real ROM, checked by its hash. You can use your own dump instead.
- The Aries B32's registers were worked out from what its real ROM does, and
  its own `*XTEST` passes. Each guide lists what isn't emulated.
- VideoNuLA is a port of b2's, and b2's NuLA picture tests pass pixel for
  pixel. Its guide lists the few functions that aren't emulated.
