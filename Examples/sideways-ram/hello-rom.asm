\ A tiny sideways ROM, for trying sideways RAM: load it into a RAM bank,
\ press Break, and *HELP lists it and *HELLO says which bank it's running
\ in. Assembles to HELLO (a 16K-bank image starting at &8000) on a disc.
\
\   beebasm -i hello-rom.asm -do hello-rom.ssd -opt 3
\
\ The service entry handles two calls:
\   9  *HELP: with nothing after it, prints the title and version.
\   4  an unrecognised * command: claims *HELLO.

OSWRCH = &FFEE
OSNEWL = &FFE7
romsel_copy = &F4               \ the MOS's copy of ROMSEL: our bank
cmdline = &F2                   \ (&F2),Y is the command line

ORG &8000
GUARD &C000

.start
    EQUB 0, 0, 0                \ no language entry
    JMP service
    EQUB &82                    \ service entry, 6502 code
    EQUB copyright - start
    EQUB 1                      \ binary version
.title
    EQUS "MacBeeb Hello", 0
.version
    EQUS "1.00"
.copyright                      \ byte 7 points at this zero, before "(C)"
    EQUB 0
    EQUS "(C)2026 MacBeeb", 0

.service
    CMP #9
    BEQ help
    CMP #4
    BEQ command
    RTS

\ *HELP with no keyword: a line with the title and version.
.help
    PHA
    LDA (cmdline),Y
    CMP #13
    BNE not_ours
    TYA
    PHA
    TXA
    PHA
    JSR OSNEWL
    LDX #0
.help_title
    LDA title,X
    BEQ help_space
    JSR OSWRCH
    INX
    BNE help_title
.help_space
    LDA #' '
    JSR OSWRCH
    LDX #0
.help_version
    LDA version,X
    BEQ help_done
    JSR OSWRCH
    INX
    BNE help_version
.help_done
    JSR OSNEWL
    PLA
    TAX
    PLA
    TAY
.not_ours
    PLA
    RTS

\ An unrecognised command: is it HELLO?
.command
    PHA
    TYA
    PHA
    LDX #0
.compare
    LDA hello,X
    BEQ matched
    CMP (cmdline),Y
    BNE no_match
    INY
    INX
    BNE compare
.matched
    LDA (cmdline),Y             \ the word must end here
    CMP #13
    BEQ claim
    CMP #' '
    BNE no_match
.claim
    LDX #0
.say
    LDA message,X
    BEQ say_bank
    JSR OSWRCH
    INX
    BNE say
.say_bank
    LDA romsel_copy
    AND #15
    CMP #10
    BCC digit
    LDA #'1'                    \ banks 10-15 are two digits
    JSR OSWRCH
    LDA romsel_copy
    AND #15
    SEC
    SBC #10
.digit
    ORA #'0'
    JSR OSWRCH
    JSR OSNEWL
    PLA                         \ discard Y and A: claimed (A=0)
    PLA
    LDA #0
    RTS
.no_match
    PLA
    TAY
    PLA
    RTS

.hello
    EQUS "HELLO", 0
.message
    EQUS "Hello from sideways RAM bank ", 0
.end

SAVE "HELLO", start, end, &8000, &8000
