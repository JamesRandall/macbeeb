\ Prints a message, for trying the debugger: assembles to a disc with
\ HELLO at &2000, or load hello.bin at &2000 and CALL &2000.

OSWRCH = &FFEE
OSNEWL = &FFE7

ORG &2000

.start
    LDX #0
.loop
    LDA message,X
    BEQ done
    JSR print
    INX
    BNE loop
.done
    JSR OSNEWL
    RTS

\ Prints A, counting characters in count.
.print
    INC count
    JMP OSWRCH

.message
    EQUS "HELLO WORLD", 0
.count
    EQUB 0
.end

SAVE "HELLO", start, end
