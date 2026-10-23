# ROM images

These are copyright Acorn Computers and their successors, not GPL. They're
included, as b2 and jsbeeb do, so the emulator works out of the box.

| File | ROM | Source |
| --- | --- | --- |
| os12.rom | BBC Model B MOS 1.20 | b2 |
| basic2.rom | BBC BASIC 2 | b2 |
| dfs12.rom | Acorn DFS 1.20 (8271) | jsbeeb |
| dfs226.rom | Acorn DFS 2.26 (1770) | b2 |
| bplus-mos.rom | BBC Model B+ MOS 2.00 | b2 |
| mos510-*.rom | Master Compact MOS 5.10 set: MOS, Utils (F), BASIC 4 (E), ADFS (D) | b2 |
| watford-ddfs153.rom, watford-ddfs154t.rom | Watford DDFS for the DDB2 and DDB3 1770 boards | b2 |
| opus-ddos345.rom | Opus DDOS 3.45 for the Opus 1770 board | b2 |
| tube110.rom | 6502 Second Processor Tube OS 1.10 | b2 |
| z80-121.rom | Z80 Second Processor client ROM 1.21 (J.G. Harston's fixes to Acorn's 1.20) | BeebEm |
| master512-bios.rom | Master 512 80186 BIOS (16K) | BeebEm (BIOS.rom) |
| armeval-100.rom | ARM Evaluation System supervisor ROM 1.00 | BeebEm (ARMeval_100.rom) |
| master-turbo-parasite.rom | Master Turbo 65C102 Co-Processor Tube OS 1.20 | b2 (MasterTurboParasite.rom) |
| mos320-*.rom | Master 128 MOS 3.20 set: MOS, Terminal (F), View (E), ADFS (D), BASIC 4 (C), Edit (B), ViewSheet (A), DFS 2.24 (9) | b2 |
| watford-32kram-240.rom | Watford Electronics 32K RAM board: Shadow RAM OS 2.40, (C)1985 Ian Smith (8K) | mdfs.net (WERAMv240); = MAME's we32kram_v2.40.rom |
| aries-b32-100.rom | Aries B32: ARIES-B32 1.00, (C)1985 David Barnett & Chris Jordan (16K) | mdfs.net (Aries32v10); = MAME's aries-b32_v2.2.rom |
| dnfs.rom | Acorn DNFS: DFS 1.20 and NFS 3.00 in one ROM, for the Model B's Econet module | BeebEm (BBC/DNFS.rom) |
| anfs425.rom | Acorn ANFS 4.25, the Master's Econet filing system | jsbeeb (master/anfs-4.25.rom) = BeebEm (M128/ANFS-4.25-2201351.rom) |

## Expansion boards' controller ROMs

These two come from J.G. Harston's archive (mdfs.net/System/ROMs/Display/ShadowRAM/)
and match the images MAME uses byte for byte (SHA-1 below). They're bundled
so the boards work without hunting for firmware, on the same basis as the
ROMs above, and the user can replace them. **Redistribution permission
hasn't been found** for either (the Aries manual forbids copying its ROM),
so this is recorded here for review. `Firmware.swift` holds the known
versions and their hashes.

| File | SHA-1 | SHA-256 | Status |
| --- | --- | --- | --- |
| watford-32kram-240.rom | 0a5efb084eb1ae353b9c79c026e9e26cd7695293 | a2e7c05f809e62faf980096459165fa356cf7c253265131ec68a91bcd2f8bfcb | Copyright Watford Electronics/Ian Smith; permission not found |
| aries-b32-100.rom | 466e3b68f1a8e0287ae095cb3c16dac6afc89dcb | 8f1e288c08a706f76a43bd8ae296bfb7dce0a3f6244d8f95831261be97a78051 | Copyright Chris Jordan and David Barnett; permission not found |

