# ROMs, Cartridges and Saved Machines

A BBC Micro came with BASIC and a filing system in its ROM sockets, and
owners plugged in more: word processors, spreadsheets, languages,
utilities. In MacBeeb you add your ROM image files to a **ROM Library**,
then plug them into the sockets each model really has. On the Master 128
you can also plug in cartridges, and set the links that turn some of its
sideways RAM into ROM sockets. When a machine is set up as you like it, save
it as a **machine configuration** to use again, in a window or a network.

MacBeeb doesn't come with these ROMs: use images of ROMs you own.

## Quick start

1. Choose **Machine ▸ Hardware…** (⌥⌘E).
2. Under **ROM Sockets**, click **Plug In** beside an empty socket and choose
   **Add ROM File…**, or drop a `.rom` file onto the socket. The file is
   copied into the ROM Library.
3. Click **Restart BBC**. The BBC restarts with the ROM in its socket, as if
   you'd switched it off, fitted the chip and switched it on again.
4. Type `*HELP` (or `*ROMS` on a Master) to see it there.

The **Model** menu at the top of the window changes which BBC Micro it is,
along with everything else, when you click **Restart BBC**.

To take a ROM out, choose **Empty Socket** from the socket's menu (or **Put
Back BASIC 2** for one of the standard ROMs) and restart.

## The ROM Library

**Machine ▸ ROM Library…** lists the ROMs you've added. MacBeeb keeps its
own copy of each, so moving or deleting the original file doesn't matter.
Drop files on the window, or click **+**, to add more. You can rename them;
the **ROM** column shows what the ROM's own header calls it.

**Layout** says how a ROM goes into a machine:

| Layout | What it is |
| --- | --- |
| 16K | One sideways ROM, 16K or less, in one bank. An 8K ROM repeats to fill its 16K, as an 8K chip does in a 16K socket. |
| Two 16K ROMs (32K) | Two ROMs in one 32K chip, for a socket that takes two banks (the B+'s, the Master's IC37 and IC41, and cartridges): the first 16K in the lower bank, the second in the upper. |
| Inter-Word (32K), Inter-Base (64K), Spellmaster (128K), … | A ROM bigger than 16K in one bank, with hardware on its board or cartridge that switches which 16K shows when the ROM's code touches particular addresses. Computer Concepts' Inter-Word and Inter-Base are like this. |

MacBeeb guesses the layout from the file's size and headers: a 32K file
with the same ROM's name in both halves is switched (as Inter-Word is), one
with two different ROMs is a pair. Change it in the **Layout** column if the
guess is wrong. The switched layouts are the ones the b2 emulator supports,
named after a ROM that uses each: Inter-Word (also AMX Design and the
Beebug Master ROM), Inter-Base (also PMS The Publisher), Spellmaster (also
Mega3), Quest Paint (also ConQuest and PCB Designer), Wapping Editor, TED,
ABE+, ABE, View Trilogy and Mini Office II.

## Each model's sockets

The Hardware window shows the sockets as the hardware has them. A socket
something else needs is locked and shows what has it: a sideways RAM
module, the Watford board's ROM, or on a network, the Econet ROM.

**Model A and Model B:** four sockets on the motherboard, banks 12 (on the
left) to 15. BASIC 2 is in 15 and the DFS in 14; you can take either out
and use its socket. With the Aries B32 the sockets answer as banks 12, 9,
10 and 11; with the Aries B12, their ROMs move to its sockets 9 to 12, and
its sockets 1 to 8 are free for more.

**B+:** five sockets that each take a 32K chip, two banks each: IC35
(banks 2 and 3), IC44 (4 and 5), IC57 (6 and 7), IC62 (8 and 9) and IC68
(10 and 11). Put a 16K ROM in either bank, or a 32K pair in both. BASIC and
the DFS are in 15 and 14.

**Master 128:** its own ROMs (MOS, BASIC 4, View, ViewSheet, Edit, ADFS,
DFS, Terminal) are built in, in banks 9 to 15. For yours:

- **Cartridges.** The two slots at the front of the keyboard take a
  **ROM Cartridge** (sockets for two banks: 0 and 1 in the front slot, 2 and
  3 in the rear) or a **Sideways RAM Cartridge** (16K in the slot's lower
  bank, or 32K in both). Choose what's in each slot from its menu.
- **Links LK19 and LK18.** As standard, banks 4 to 7 are sideways RAM.
  Setting LK19 East makes banks 4 and 5 the ROM socket IC37 instead, and
  LK18 East makes 6 and 7 the ROM socket IC41. Click **ROM Socket** to set
  a link East.

**Master Compact:** MacBeeb doesn't model its sockets.

## Machine configurations

Once a machine is set up (model, second processor, disc interface, boards,
ROMs, cartridges and VideoNuLA), save it under a name:

- **Machine ▸ Machine Configurations ▸ Save Configuration…**, or **Save
  Configuration** in the Hardware window's toolbar.
- To set a window's machine up as a saved one, choose it from **Machine ▸
  Machine Configurations**. The BBC restarts as that machine.
- **Manage Configurations…** lists them, to rename or remove.

In the **Network Studio**, saved configurations are under **My Machines**
in the palette: click one, or drag it onto the network, to add a station
set up that way. A station's inspector has a **Configuration** menu to set
it up as a saved one, or save it as one. A network keeps its own copies of
the ROMs its machines use, so it still works if you remove them from the
library, or open the network on another Mac.
