# What's New in MacBeeb

<!--
One section per release, newest first: "## VERSION" (optionally "— DATE"),
then a line of introduction if wanted, then "- " bullets. Inline Markdown
(**bold**, *italic*, `code`, [links](https://…)) is fine. The app shows the
sections since the version a user last ran; scripts/release.sh uses the
release's section for the GitHub release and Sparkle's update window, and
won't build a release without one.
-->

## 1.4

- **Green and amber screens:** View ▸ Monitor puts the picture on a monochrome monitor with a green (P1) or amber (P3) phosphor, with any display style. Like the real thing, there's no colour grille, colours become shades by their brightness, and the phosphor glows on briefly.
- **New Disc:** File ▸ New Disc… (⌘N) makes a blank disc, formatted and ready to save to: DFS on 40 or 80 tracks, single or double sided, or ADFS S, M or L. Give it a title and choose a drive to put it in.
- **Disc contents:** File ▸ Show Disc Contents (⇧⌘I) lists the files on a disc, DFS or ADFS. Drag files out to Finder, each with a .inf file holding its BBC name and addresses, or drag Mac files in. Rename, relock, readdress and delete files, make ADFS directories, and set the title and boot option, all with undo. On ADFS, type `*MOUNT` afterwards, as you would after swapping a real disc.
- **BASIC as text:** drop a `.bas` text file on a disc and it becomes a BASIC program, tokenised just as BBC BASIC would. Export as Text… turns a program back into a listing.

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
