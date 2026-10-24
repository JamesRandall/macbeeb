\ WBOOT: a worker's bootstrap. !BOOT runs it after the station logs on;
\ it waits on the management port for a launcher (CLUSTER) to say START,
\ then loads WORKER from the file server, as *WORKER, through NFS. It
\ answers DISCOVER so a launcher can see it's prepared.
\
\ Lives at &6000-&67FF, clear of WORKER (&3000-&4FFF) and MODE 7's screen.

INCLUDE "common.asm"

ORG WBOOT_ORG
GUARD &6800

.wboot
    LDA #&77 : JSR OSBYTE           \ close !BOOT's *EXEC
    JSR getstn
    LDA #LO(failed) : STA BRKV : LDA #HI(failed) : STA BRKV+1
    JSR screen
    LDA #0 : STA HANDOFF_LAUNCHER

.listen
    LDA #LO(rxm) : STA ptr : LDA #HI(rxm) : STA ptr+1
    LDA #PORT_MGMT : JSR openrx
    STA blk
    BEQ listen
.wait
    LDX blk : JSR pollrx : BPL wait
    LDX blk : JSR readrx
    LDA #LO(rxm) : STA ptr : LDA #HI(rxm) : STA ptr+1
    JSR check : BCS listen
    CMP #T_DISCOVER : BEQ discover
    CMP #T_START : BEQ start
    JMP listen

\ DISCOVER nonce4 target launcher: say we're a bootstrap, waiting.
.discover
    LDA plen : CMP #6 : BNE listen
    JSR takenonce
    \ Listening again before answering: START can follow at once, and
    \ would find no block open ("not listening").
    LDA #LO(rxm) : STA ptr : LDA #HI(rxm) : STA ptr+1
    LDA #PORT_MGMT : JSR openrx : STA blk
    LDA #LO(txm) : STA ptr : LDA #HI(txm) : STA ptr+1
    JSR putnonce
    LDA mystn : STA txm+HEADER+4
    LDA #1 : STA txm+HEADER+5       \ waiting
    LDA #1 : STA txm+HEADER+6       \ bootstrap version
    LDA #0 : STA txm+HEADER+7       \ no worker yet
    LDA #8 : STA plen
    LDA #T_BOOT_HELLO : JSR mhdr
    LDA rxstn : LDX #PORT_LAUNCHER : JSR send
    JSR event : JSR pstr : EQUS "Seen by station ", 0 : LDA rxstn : JSR pstn : JSR clearline
    LDA blk : BEQ discover9
    JMP wait
.discover9
    JMP listen

\ START nonce4 target coordinator: load WORKER, leaving it who to work
\ for.
.start
    LDA plen : CMP #6 : BEQ start0
    JMP listen
.start0
    LDA rxm+HEADER+4 : CMP mystn : BNE tolisten
    JSR takenonce
    LDX #3
.start1
    LDA nonce,X : STA HANDOFF_NONCE,X
    DEX : BPL start1
    LDA rxm+HEADER+5 : STA HANDOFF_COORD
    LDA rxstn : STA HANDOFF_LAUNCHER
    LDA #'W' : STA HANDOFF_MARK
    LDA #LO(txm) : STA ptr : LDA #HI(txm) : STA ptr+1
    JSR putnonce
    LDA #0 : STA txm+HEADER+4       \ loading
    LDA #5 : STA plen
    LDA #T_START_ACK : JSR mhdr
    LDA rxstn : LDX #PORT_LAUNCHER : JSR send
    JSR event : JSR pstr : EQUS "START from ", 0 : LDA rxstn : JSR pstn : JSR pstr : EQUS ": loading WORKER", 0 : JSR clearline
    LDX blk : JSR delrx
    LDX #LO(command) : LDY #HI(command) : JSR OSCLI
    \ (WORKER doesn't come back.)
.tolisten
    JMP listen

\ An error, most likely loading WORKER: tell the launcher, show it, and
\ wait again.
.failed
    LDX #&FF : TXS : CLI
    LDA #&7E : JSR OSBYTE           \ (an Escape)
    LDA #LO(txm) : STA ptr : LDA #HI(txm) : STA ptr+1
    JSR putnonce
    LDY #0 : LDA (&FD),Y : STA txm+HEADER+4
    LDX #0
.failed1
    INY : LDA (&FD),Y : BEQ failed2
    STA txm+HEADER+5,X
    INX : CPX #40 : BNE failed1
.failed2
    TXA : CLC : ADC #5 : STA plen
    LDA #T_LAUNCH_ERROR : JSR mhdr
    LDA HANDOFF_LAUNCHER : BEQ failed3
    LDX #PORT_LAUNCHER : JSR send
.failed3
    JSR event : JSR pstr : EQUS "Couldn't load WORKER:", 0
    LDX #2 : LDY #15 : JSR tab : LDA #129 : JSR OSWRCH
    LDY #1
.failed4
    LDA (&FD),Y : BEQ failed5
    JSR OSWRCH : INY : CPY #36 : BNE failed4
.failed5
    JSR clearline
    LDA #0 : STA HANDOFF_MARK
    JMP listen

.takenonce
    LDX #3
.takenonce1
    LDA rxm+HEADER,X : STA nonce,X
    DEX : BPL takenonce1
    RTS

.putnonce
    LDX #3
.putnonce1
    LDA nonce,X : STA txm+HEADER,X
    DEX : BPL putnonce1
    RTS

\ The status line.
.event
    LDX #0 : LDY #13 : JSR tab
    LDA #131 : JMP OSWRCH

.clearline
    LDA #8 : JMP spaces

.screen
    VDUS 12 : EQUB 22, 7, 23, 1, 0, 0, 0, 0, 0, 0, 0, 0
    LDY #0 : JSR title
    LDY #1 : JSR title
    LDX #0 : LDY #3 : JSR tab
    JSR pstr : EQUS 134, "Worker bootstrap (WBOOT)", 13, 13, 0
    JSR pstr : EQUS 130, "Station ", 135, 0
    LDA mystn : JSR pstn
    JSR pstr : EQUS 13, 13, 135, "Waiting for *CLUSTER on any BBC.", 13, 0
    JSR pstr : EQUS 134, "It asks this BBC to load WORKER from", 13, 0
    JSR pstr : EQUS 134, "the file server, over Econet.", 13, 0
    LDX #0 : LDY #20 : JSR tab
    JSR pstr : EQUS 132, 157, 135, "Listening on port &B3", 13, 0
    RTS

.title
    LDX #0 : JSR tab
    JSR pstr : EQUS 132, 157, 131, 141, "  MANDELBROT CLUSTER", 0
    RTS

.command EQUS "WORKER", 13
.blk    EQUB 0
.nonce  EQUD 0
.rxm    SKIP FRAME
.txm    SKIP 64

INCLUDE "lib.asm"
SAVE "WBOOT", WBOOT_ORG, P%, WBOOT_ORG
