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

## Econet

Every machine on a network has an Econet module, with its station number,
and Acorn's network filing system: DNFS on a Model B (it's DFS 1.20 as
well), ANFS 4.25 on a Master. It's the real hardware, emulated: the
machines' own network software does everything, just as on a 1980s
network.

- **The clock**: an Econet carries nothing without one. Every template has
  one. Take it away and the machines' network software reports "No clock".
- **The file server**: Acorn's Level 1 file server, running on its BBC
  (station 254), from its disc. It starts itself when the network's
  switched on: its console (on its card, or in its window) says `Ready`.
  Every other machine shares its directory, A.
- **Using it**: on any machine, type `*NET` to change to the network
  filing system. Then `SAVE "PROG"`, `LOAD "PROG"`, `CHAIN "PROG"`, `*CAT`,
  `*SAVE` and `*LOAD` work over the network. Save on one machine and load
  on another.
- **Traffic**: a machine sending on the network glows green on the canvas,
  with a radio-wave sign on its card.
- **When things go wrong**: the network software's own messages, as on a
  real network. With the file server off, `*CAT` says "Not listening".
  Switch it back on and it starts again, with its files still on its disc.

To start the server by hand (after Break, for example), choose **Start File
Server** in its inspector or right-click menu.

## Printing

**Window ▸ Print Centre** (⌥⌘P) shows everything the BBCs have printed, on
paper as the printer would have put it, and keeps it after MacBeeb quits.

- **On a network**: the printer server (station 235) runs MacBeeb's printer
  server on its BBC, with a printer on its printer port. On any other
  machine, `*FX5,4` chooses the network printer; then `VDU 2` starts
  printing and `VDU 3` stops, and `CTRL-B` and `CTRL-C` do the same. In
  between, whatever the BBC prints goes to the printer server, and from it
  to its printer. The job appears in the Print Centre as it prints.
- **On its own**: every MacBeeb BBC has a printer on its printer port.
  `*FX5,1` chooses it (it's the default on a Model B), then `VDU 2` and
  `VDU 3`.
- **One job at a time**: the printer server prints one station's job at a
  time. Another station printing at once gets its network filing system's
  "No reply", as with a real server; print again when the first is done.
- **A job ends** when the printer's been quiet for three seconds of BBC
  time.
- **On paper**: Clean or Dot Matrix (the dots in the BBC's own characters),
  on A4, US Letter or fanfold. 66 lines a page, 10 characters an inch.
  Carriage returns, line feeds, tabs, form feeds, and Epson's bold and
  underline are understood. Other printer codes are kept in the job, but not
  drawn: the Print Centre lists them.
- **Export PDF**, **Print** (on the Mac's printer) and **Raw Bytes** (exactly
  what the BBC sent) are in the toolbar. PDFs have their text, so they can
  be searched.

MacBeeb's printer server is a BBC BASIC program (on the printer server's
disc, `PSERV`), written for MacBeeb because Acorn's own printer server
isn't included. It speaks the printer server protocol Acorn's network
filing systems use: status enquiries on port &9F, answered on &9E, and the
job's data on port &D1.

## Tiles

Click **Tiles** in the toolbar to see the machines that are on side by
side, each big enough to use. Click a tile to type into it: it gets a blue
ring, and it's the one you hear. ⌥⌘] and ⌥⌘[ move the keyboard to the next
or previous machine. **Show** chooses which machines have tiles, and
**Columns** how they're laid out.

## Traffic

Click **Traffic** in the toolbar to see every frame that's crossed the
network, newest last. Econet sends everything as a **four-way handshake**:
a **scout** asking to send (who it's for, a control byte and a port), an
**acknowledgement**, the **data**, and another acknowledgement. The
Traffic view reads frames that way, numbers each transaction, and names the
well-known ports (the file server's, the printer server's).

- Choose a frame to see its bytes and what they mean. The machines it's
  between are selected on the canvas too.
- **Station**, **Problems only** (collided or abandoned frames) and the
  search box (text or hex) narrow the list.
- **Recording** stops and starts the capture; **Clear** empties it. The
  last 4,096 frames are kept.
- **Export…** saves the frames as JSON: MacBeeb's own format (`format`,
  `network`, `cyclesPerSecond`, and `frames`, each with its `start` and
  `end` in 2MHz cycles, `transmitter`, `bytes`, `status`, `kind` and
  `transaction`). It isn't PCAP.

## AI agents (MCP)

Agents connected to MacBeeb (**MCP ▸ Connect an AI Agent…**) can work with
networks too:

- Every tool takes a `machine`: a station's name ("BBC 2"), number ("2") or
  id, or "Network/name" when two networks have one alike. Without it, a
  tool drives the standalone window's machine, as before. A tool that runs
  a station (such as `run_command`) runs its whole network with it, so the
  other machines don't miss what it sends.
- `list_machines`, `network_status`, `network_power` (on, off, cold boot,
  Break, suspend, resume, start a server), `network_pause`,
  `network_trace` (frames, decoded, with `after` for polling),
  `econet_status` (a station's ADLC registers and NMI state),
  `print_jobs`, `print_job` and `export_print_job_pdf`, and
  `network_create` and `network_open`.
- Errors say what's wrong: `not_found:`, `ambiguous_machine:`,
  `powered_off:`, `no_machine:`.

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

A network's machines run together, in step: every 16 microseconds of BBC
time each one runs, and then the network passes on what they sent. One
core runs about 14 Model Bs at full speed (fewer Masters or busy servers).
When a network needs more than that, MacBeeb spreads its machines over
more cores, adding one at a time while it helps (up to one fewer than the
Mac's performance cores), and gives them back when they're not needed. The
window's subtitle shows the network's speed, and how many cores it's
using when it's more than one. Which core runs which machine never changes
what they do.
