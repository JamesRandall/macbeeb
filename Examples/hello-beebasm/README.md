# Hello, BeebAsm

The same program as hello-ca65, for BeebAsm. MacBeeb assembles it itself
(BeebAsm is built into the app), so there's nothing to install:

- In VS Code, with the MacBeeb extension: open this folder, set a breakpoint
  in hello.asm, press F5. It's assembled to a disc, put in drive 0, and
  *RUN.
- From an agent: `assemble` with `source: hello.asm`, then
  `set_breakpoint hello.asm:23` and `run_command *RUN HELLO`.

By hand: `beebasm -i hello.asm -do hello.ssd -boot HELLO`.

BeebAsm doesn't record which source line made each byte, so MacBeeb lines
its listing up with the source (following INCLUDEs, macros and FOR loops).
