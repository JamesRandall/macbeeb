# System discs

The co-processors' system discs, put in drive 0 when the machine starts so
it boots. Like the ROMs, these aren't GPL: CP/M and DOS Plus are copyright
Digital Research (and their successors), their BIOSes and utilities Acorn
Computers. They're included, as BeebEm does, so the emulator works out of
the box.

| File | Disc | Source |
| --- | --- | --- |
| cpm-utilities.dsd | Acorn CP/M 2.2 (BIOS 1.20) and utilities, for the Z80 Second Processor | BeebEm (CPM_Utilities_Disc.dsd) |
| dosplus-boot.adl | Acorn Master 512 DOS Plus 1.2 boot disc (disc 1) | BeebEm (BBCMaster512-Disc1-DosPlusBoot.adl) |

BeebEm's other Master 512 discs (GEM applications, GEM data, miscellaneous)
are 800K DOS-format `.img` images, which the emulator doesn't read yet.
