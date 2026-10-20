; Prints a message, for trying the debugger: load hello.bin at &2000 and
; CALL &2000 (or use the VS Code launch configuration).

OSWRCH = $FFEE
OSNEWL = $FFE7

        .segment "CODE"

start:  ldx #0
loop:   lda message,x
        beq done
        jsr print
        inx
        bne loop
done:   jsr OSNEWL
        rts

; Prints A, counting characters in `count`.
print:  inc count
        jmp OSWRCH

        .segment "DATA"

message:
        .byte "HELLO WORLD", 0
count:  .byte 0
