# Sideways RAM example

`hello-rom.asm` is a tiny service ROM for trying sideways RAM. It adds a line
to `*HELP` and a command, `*HELLO`, which says which bank it's running in.

- `hello.rom`: the image, to load into a sideways RAM bank from the Mac
  (Machine ▸ Hardware Expansions…, then Load ROM Image…).
- `hello-rom.ssd`: a disc with the image as the file `HELLO`, to load from the
  BBC with DFS 2.26: `*SRLOAD HELLO 8000 9`.

The [Sideways RAM guide](../../docs/hardware-expansions/sideways-ram.md) walks
through both.

To rebuild them with BeebAsm:

```
beebasm -i hello-rom.asm -do hello-rom.ssd
beebasm -i hello-rom.asm        # writes HELLO; rename it hello.rom
```
