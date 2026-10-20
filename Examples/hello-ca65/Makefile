# Needs cc65 (brew install cc65).
hello.bin: hello.s bbc.cfg
	ca65 -g hello.s -o hello.o
	ld65 -C bbc.cfg -o hello.bin --dbgfile hello.dbg -Ln hello.lbl hello.o

clean:
	rm -f hello.o hello.bin hello.dbg hello.lbl
