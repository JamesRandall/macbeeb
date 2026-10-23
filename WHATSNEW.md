# What's New in MacBeeb

<!--
One section per release, newest first: "## VERSION" (optionally "— DATE"),
then a line of introduction if wanted, then "- " bullets. Inline Markdown
(**bold**, *italic*, `code`, [links](https://…)) is fine. The app shows the
sections since the version a user last ran; scripts/release.sh uses the
release's section for the GitHub release and Sparkle's update window, and
won't build a release without one.
-->

## 1.5

- **Hardware expansions:** Machine ▸ Hardware Expansions… (⌥⌘E) fits a memory board to the Model B: a 16K or 32K sideways RAM module, Watford Electronics' 32K Shadow RAM board, or the Aries B32, with or without the B12 ROM board. The window shows the board's memory to scale, the sixteen sideways banks as the BBC uses them, and for shadow RAM, what programs and the screen each see. Load ROM images into sideways RAM from the Mac, or from the BBC with DFS 2.26's `*SRLOAD` or the Aries `*RLOAD`.
- **The boards' own ROMs:** the Watford board comes with Shadow RAM OS 2.40 and the Aries B32 with ARIES-B32 1.00, so their commands work as the manuals describe (`*HELP RAMSTATUS`, `*XON 16`, `*XSTATUS`, `*RWRITE`), and the Aries' own `*XTEST` passes.
- **VideoNuLA:** on any model, each of the sixteen colours can be any of 4,096. Turn it on under Video in the same window; the window shows the colours as programs set them.
- **Hardware Expansion Guide:** Help ▸ Hardware Expansion Guide explains each board with examples, and the developer reference has the memory maps and registers.
- **For AI agents (MCP):** `get_hardware`, `power_cycle` with `memory_board` and `video_nula`, `load_sideways_bank`, `save_sideways_bank`, `video_nula`, `set_video_nula_palette`, `set_video_nula_control`, and `bus_write` to write any register as the BBC's CPU would.
- **Ctrl-Break:** Machine ▸ Ctrl-Break (⌃⌘B), a hard reset that keeps memory.
- **Fixed:** the debugger's Video ULA view showed the wrong physical colour for each logical colour.

## 1.4.1

- **Double-click to play:** in the Game Library, double-click a game you've got to start it.
- **Break with a second processor:** the 6502s now disable interrupts on reset, as the real chips do (and the 65C02s clear decimal mode). Before, a Tube interrupt pending when you pressed Break could leave the co-processor stuck at a `*` prompt.
- **For AI agents (MCP):** `screenshot` can show the picture as far as the beam has drawn it, frame-exact at a breakpoint, or screen memory as it is now, and no longer comes back black straight after `restore_snapshot`. `peek` can write up to 64K to a file. New tools: `measure_cycles`, a stopwatch between two addresses, and `key_sequence`, for keys down and up on a timeline in one call. `load_symbols` with `clear` only clears the CPU it's loading for, and `start_recording` makes the folder it records into.

## 1.4

- **Green and amber screens:** View ▸ Monitor puts the picture on a monochrome monitor with a green (P1) or amber (P3) phosphor, with any display style. Like the real thing, there's no colour grille, colours become shades by their brightness, and the phosphor glows on briefly.
- **New Disc:** File ▸ New Disc… (⌘N) makes a blank disc, formatted and ready to save to: DFS on 40 or 80 tracks, single or double sided, or ADFS S, M or L. Give it a title and choose a drive to put it in.
- **Disc contents:** File ▸ Show Disc Contents (⇧⌘I) lists the files on a disc, DFS or ADFS. Drag files out to Finder, each with a .inf file holding its BBC name and addresses, or drag Mac files in. Rename, relock, readdress and delete files, make ADFS directories, and set the title and boot option, all with undo. On ADFS, type `*MOUNT` afterwards, as you would after swapping a real disc.
- **BASIC as text:** drop a `.bas` text file on a disc and it becomes a BASIC program, tokenised just as BBC BASIC would. Export as Text… turns a program back into a listing.
- **Quick Look:** select a disc image in Finder and press space to see what's on it: the title, boot option and files on each side or in each directory.
- **Game Library:** File ▸ Game Library (⇧⌘K) has a shelf of BBC Micro Classics: the twenty favourite games chosen by the StarDot community and published by [BBCMicro.co.uk](https://bbcmicro.co.uk/), from Elite (the 6502 Second Processor edition) to Snapper, plus a book for the whole archive. Get a game from its BBCMicro.co.uk page in your browser, and MacBeeb notices the download and adds it to the shelf (if you let it look in Downloads; or import or drag in the disc yourself). Play sets up the right machine, such as a Second Processor for Elite or a Master 128 for Exile, and boots the disc. MacBeeb never downloads or includes the games itself. To make it a games machine, set Settings ▸ Games ▸ When MacBeeb opens to show only the Game Library.
- **Author's Picks:** a second shelf of twenty favourites, chosen by MacBeeb's author, from Elite and Exile to Holed Out!!, SimCity, U.I.M. and Knight Lore. They come from BBCMicro.co.uk in the same way, and a game that's on both shelves only needs getting once.
- **My Games:** your own games, in the Game Library's third tab. Drag in a disc image, a cover picture, or both together (a disc and a picture with the same name make one game), then give it a title and choose the machine and how it starts: booting the disc, typing a command such as `CHAIN "GAME"`, or just putting the disc in. Add the missing disc or cover later by dropping it on the game.
- **Quick Save and Quick Load:** File ▸ Quick Save (⇧⌘F6) saves the game in drive 0 exactly as it is, discs included, and Quick Load (⇧⌘F5) goes straight back to it. Each disc keeps its last five, with a screenshot and the time, and they survive quitting. In the Game Library, a game with a snapshot says Resume under its cover, and its details show all five as screenshots: click Resume to carry on from the newest, or a screenshot to carry on from there. F5 and F6 on their own still go to the BBC.

## 1.3.1 — 22 October 2026

- **What's New:** this window opens after an update, and Help ▸ What's New in MacBeeb opens it any time.
- **Master Turbo:** the Master 128's internal 65C102 Co-Processor, a 4MHz 65C02 on the Master's internal Tube.
- **Disc drive sounds:** the drives spin up, run and step as they work, from MAME's recordings of 5.25" drives (3.5" on the Compact). Machine ▸ Disc Drive Sounds turns them off.
- **Open Recent Disc:** File ▸ Open Recent Disc lists the last ten disc images and boots the one you choose.
- **Controls for each disc:** key mappings and gamepad settings can belong to a disc image, and apply while it's in drive 0. Set them in Settings ▸ Keyboard and Settings ▸ Gamepad, or from Machine ▸ Controls for This Disc.
- **Gamepads on keys:** a game controller's buttons and directions can press BBC keys, alongside the analogue joystick or instead of it. Controllers drive the window in front.
- **AI agents:** MCP ▸ Connect an AI Agent… shows the commands to connect Claude Code or Codex to the running app. MCP ▸ Activity Log lists every tool call, and a light in the toolbar shows when an agent's connected. The debugger's breakpoints and symbols survive an agent restoring snapshots, loading states and power cycling.
- **Fixes:** the Master 512 can only be fitted to a Master 128, and code in main RAM no longer disassembles from shadow RAM on a B+ or Master.
- **About MacBeeb** links to the source on GitHub, and the app includes the GPLv3 licence.
