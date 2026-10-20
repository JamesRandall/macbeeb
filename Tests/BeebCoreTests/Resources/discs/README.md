# Test discs

| Disc | What | Source |
| --- | --- | --- |
| dp111-*.ssd | dp111's 6502/65C12 instruction timing tests, with and without the 1MHz bus; failures written to &FCD0 | https://github.com/dp111/6502Timing (GPLv3, commit 2cb005d) |
| beeb_6502_timing_tests.ssd | Tom Seddon's timing tests (dead cycles, page crossing, 1MHz bus) | https://github.com/tom-seddon/beeb_6502_timing_tests (GPLv3), via jsbeeb |
| TestTimings.ssd | IRQ timing results, compared with values from jsbeeb's tests | jsbeeb |
| RmwX.ssd | Read-modify-write behaviour (Ed Spittles) | jsbeeb |
| bcdtest.ssd | BCD behaviour (hoglet) | https://github.com/hoglet67/AtomSoftwareArchive, via jsbeeb |
| Irq-Timing.ssd | IRQ timing; a real Beeb gives about 1068, 1066, 1072 | stardot, via jsbeeb |
