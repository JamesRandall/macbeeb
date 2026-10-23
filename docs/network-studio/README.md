# Network Studio

In the 1980s, schools linked their BBC Micros with **Econet**: every machine
in the room on one cable, sharing a file server's discs and a printer.
MacBeeb's Network Studio builds networks like that on your Mac. Each machine
is a real, complete MacBeeb BBC Micro, running all the time, not a picture
of one.

## Quick start

1. Choose **File ▸ New Network…** (⇧⌘N).
2. Click **School Classroom**. MacBeeb makes the network and saves it in
   **Documents ▸ MacBeeb Networks**.
3. The network opens on the **canvas**: four BBC Micros, a file server, a
   printer server and the network's clock, all switched on, their screens
   live.
4. Double-click **BBC 1** to open it in its own window, and type into it as
   into any MacBeeb.

## Templates

| Template | What's in it |
| --- | --- |
| Two BBCs | Two Model Bs, stations 1 and 2, and a clock: the smallest network |
| School Classroom | Four Model Bs (stations 1–4), a file server (254), a printer server (235) and a clock |
| BBC and Master | A Model B and a Master 128, a file server and a clock |
| Empty Network | Just the clock |

## The canvas

- **Add a machine**: drag one from the **Add** palette onto the canvas, or
  click it to add it in the middle. New machines take the next free station
  number and are switched on.
- **Arrange**: drag machines around. Hold ⌘ or ⇧ and click to select more
  than one, and drag them together. **Snap to grid** is in the inspector.
- **Move round**: drag the background, or scroll. Pinch, or ⌘-scroll, to
  zoom. The buttons at the bottom right zoom, and the last shows the whole
  network.
- **Open a machine**: double-click it. Its window has all of MacBeeb's menus,
  the debugger and Hardware Expansions. Closing the window doesn't stop the
  machine: it carries on, on the canvas.
- **Right-click a machine** for Power On/Off, Cold Boot, Break, Suspend,
  Open Window, the debugger, Hardware Expansions, discs, Duplicate and
  Remove.
- The line along the middle is the network's shared cable. A machine that's
  on joins it with a solid line; one that's off, with a dashed line.
- **Problems** show at the top of the canvas, for example two machines with
  the same station number, or a network without a clock.

## Tiles

Click **Tiles** in the toolbar to see the machines that are on side by
side, each big enough to use. Click a tile to type into it: it gets a blue
ring, and it's the one you hear. ⌥⌘] and ⌥⌘[ move the keyboard to the next
or previous machine. **Show** chooses which machines have tiles, and
**Columns** how they're laid out.

## The inspector

With nothing selected, the inspector shows the network: its name, how many
machines are on, its speed, and any problems. Select a machine to change:

- its **name** and **station number** (1 to 254, one each);
- its **role**: an ordinary station, the file server or the printer server;
- its **model**;
- its **power**, and whether it's **suspended**;
- its **discs**.

Select the clock to set the network's speed.

## Power, pausing and suspending

- **Power On All**, **Power Off All** and **Break All** are in the
  toolbar. Switching a machine off loses what's in its memory, as on a
  real BBC; its discs are kept.
- **Pause Network** stops time on every machine at once. Nothing on the
  network can time out while it's paused.
- **Suspend** (in the inspector or the right-click menu) stops one machine
  where it is while the others carry on. To the others it's as if it had
  hung, so a machine waiting for an answer from it gives up.
- When a machine stops in its **debugger**, the whole network pauses with it,
  so the others don't time out while you look. Turn this off under
  Debugging in the inspector.

## Discs

A network keeps its **own copies** of its discs, inside the network file.
When you put a disc in a network machine (from its window, the inspector,
or by dragging one onto its window), MacBeeb copies it into the network, and
the machine writes to the copy. **Your original disc file is never
changed.**

## Saving

Networks save themselves as you work: what's on the network, each
machine's hardware, station number, discs and place on the canvas, and the
tiles. A network file (`.macbeebnet`) is a package. To keep a copy
somewhere else, use **File ▸ Save Network As…**. **File ▸ Open Recent
Network** and **Window ▸ Network Studio** (⌥⌘0) bring back the last ones.

What's in the machines' memory isn't saved: when you open a network again,
its machines start up afresh, as when they're switched on.

## Performance

All of a network's machines run together, in step, on one of the Mac's
processor cores. On an M-series Mac a network runs at full speed with up to
about 16 Model Bs, and a small one has plenty to spare. The window's subtitle
shows the network's speed.
