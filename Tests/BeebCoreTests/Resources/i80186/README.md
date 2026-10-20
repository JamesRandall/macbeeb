SingleStepTests 8086 subset
---------------------------

`sst8086-subset.json.gz` holds the first 12 tests from each file of Daniel
Balsom's SingleStepTests 8086 suite, version 1.0.1
(https://github.com/SingleStepTests/8086, the `v1` directory): tests captured
from a real Intel P80C86A-2, each giving the machine state before and after
one instruction. The cycle traces and prefetch queue contents are removed,
and each test carries the mask of the flags that metadata.json says are
defined for its opcode (`mask`). It was made with:

    python3 subset.py <suite>/v1 sst8086-subset.json.gz 12

where subset.py reads each `*.json.gz`, keeps `name`, `bytes`, `initial` and
`final` of the first 12 tests, and adds `file` (the source file's name) and
`mask`.

There is no 80186 suite yet (https://github.com/SingleStepTests/80186 is
empty), so the 8086's is used where the two chips agree; I80186Tests.swift
skips the tests the 80186 does differently (its own opcodes in place of the
8086's aliases, masked shift counts, undefined opcode traps, the most
negative IDIV quotient, the 8086's REP MUL/DIV quirk).

To run the whole suite (648,000 tests), download it and set I80186_SST_DIR
to its v1 directory.

The suite is MIT licensed:

MIT License

Copyright (c) 2025 Daniel Balsom

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
