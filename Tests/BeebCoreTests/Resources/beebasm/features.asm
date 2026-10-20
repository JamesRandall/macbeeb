\ Exercises the listing aligner: scopes, loops, macros, includes, and
\ several statements on a line.
CONST = 42
ORG &1900

.outer
{
.inner
    LDA #CONST
    RTS
}

.loops
FOR n, 0, 2
    NOP
    INX
NEXT
.after LDA #1:STA &70     ; two statements, label and code on one line

MACRO TWICE
    INY
    INY
ENDMACRO

.mac
    TWICE
    RTS

INCLUDE "features-inc.asm"
.end
SAVE "FEAT", outer, end
