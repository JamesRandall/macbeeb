\ WORKER: computes tiles of the Mandelbrot set for a coordinator (MANDEL),
\ in Q8.8 fixed point, on this BBC's own 6502. WBOOT loads it from the
\ file server when a launcher says START, and leaves it the coordinator's
\ station. It registers (HELLO), asks for work (READY), computes what it's
\ given (ASSIGN), and sends the counts back (RESULT) until they're taken
\ (ACK). Its screen says what it's doing.
\
\ &3000 up: code and buffers. &4000-&4FFF: the table of squares, made at
\ start-up. MODE 7.

INCLUDE "common.asm"

ORG WORKER_ORG
GUARD SQUARES

\ Zero page while computing (after the hand-off's been taken).
zx = &80 : zy = &82 : x2 = &84 : y2 = &86 : cr = &88 : ci = &8A : ss = &8C
n = &8E : mx = &8F
out = &70                   \ where the next count goes
sqlp = &72 : sqhp = &74     \ building the table

S_WAIT = 0 : S_HELLO = 1 : S_READY = 2 : S_COMPUTING = 3 : S_SENT = 4 : S_DONE = 5

.worker
    LDA #LO(failed) : STA BRKV : LDA #HI(failed) : STA BRKV+1
    \ From WBOOT: the coordinator, the launcher and its nonce.
    LDA #0 : STA coord : STA launcher
    LDA HANDOFF_MARK : CMP #'W' : BNE worker2
    LDA HANDOFF_COORD : STA coord
    LDA HANDOFF_LAUNCHER : STA launcher
    LDX #3
.worker1
    LDA HANDOFF_NONCE,X : STA nonce,X
    DEX : BPL worker1
.worker2
    LDA #0 : STA HANDOFF_MARK
    LDA #0 : LDX #1 : LDY #&FF : JSR OSBYTE : STX machine
    JSR getstn
    JSR screen
    JSR squares
    LDA #LO(rxm) : STA ptr : LDA #HI(rxm) : STA ptr+1
    LDA #PORT_MGMT : JSR openrx : STA mblk
    LDA #LO(rxc) : STA ptr : LDA #HI(rxc) : STA ptr+1
    LDA #PORT_WORKER : JSR openrx : STA cblk
    LDA launcher : BEQ worker3
    JSR running
.worker3
    LDA #S_WAIT : LDX coord : BEQ worker4
    LDA #S_HELLO
.worker4
    JSR setstate
    JSR now : JSR duenow

\ Listen to both ports, and send what's due.
.loop
    LDX mblk : JSR pollrx : BPL loop1
    LDX mblk : JSR readrx
    JSR management
    LDA #LO(rxm) : STA ptr : LDA #HI(rxm) : STA ptr+1
    LDA #PORT_MGMT : JSR openrx : STA mblk
.loop1
    LDX cblk : JSR pollrx : BPL loop2
    LDX cblk : JSR readrx
    LDA rxstn : CMP coord : BNE loop1a
    JSR coordinator
.loop1a
    LDA #LO(rxc) : STA ptr : LDA #HI(rxc) : STA ptr+1
    LDA #PORT_WORKER : JSR openrx : STA cblk
.loop2
    LDA state : BEQ loop
    CMP #S_COMPUTING : BEQ loop
    JSR now
    SEC : LDA clk : SBC due : LDA clk+1 : SBC due+1 : BMI loop
    LDA state
    CMP #S_READY : BEQ loop3
    CMP #S_SENT : BEQ loop4
    JSR hello : JMP loop5
.loop3
    JSR ready : JMP loop5
.loop4
    LDA #LO(txr) : STA ptr : LDA #HI(txr) : STA ptr+1
    LDA coord : LDX #PORT_COORD : JSR send
.loop5
    JSR schedule
    JMP loop

\ After sending (result in A): next time after the state's interval if
\ it went, or soon if it didn't (the coordinator's busy or not there).
.schedule
    PHA : JSR now : PLA
    BEQ schedule1
    LDA mystn : AND #7 : ASL A : ASL A : ADC #20 : JMP after
.schedule1
    LDX state : LDA intervals,X
\ due := clk + A.
.after
    CLC : ADC clk : STA due
    LDA clk+1 : ADC #0 : STA due+1
    RTS
.duenow
    LDA #0 : JMP after
.intervals EQUB 0, 100, 200, 0, 200, 250

.hello
    LDA #LO(txc) : STA ptr : LDA #HI(txc) : STA ptr+1
    LDA #1 : STA txc+HEADER         \ a worker
    LDA machine : STA txc+HEADER+1
    LDA #1 : STA txc+HEADER+2       \ Q8.8
    LDA #1 : STA txc+HEADER+3       \ version 1
    LDA #4 : STA plen
    LDA #T_HELLO : JSR hdr
    LDA coord : LDX #PORT_COORD : JMP send

.ready
    LDA #LO(txc) : STA ptr : LDA #HI(txc) : STA ptr+1
    LDA mystn : STA txc+HEADER
    LDA #1 : STA plen
    LDA #T_READY : JSR hdr
    LDA coord : LDX #PORT_COORD : JMP send

\ STATUS running, to the launcher (a few tries: it may be busy).
.running
    LDA #2
.status
    STA txc+HEADER+4
    LDA #LO(txc) : STA ptr : LDA #HI(txc) : STA ptr+1
    JSR putnonce
    LDA #1 : STA txc+HEADER+5
    LDA coord : STA txc+HEADER+6
    LDA #7 : STA plen
    LDA #T_STATUS : JSR mhdr
    LDA #10 : STA attempts
.status1
    LDA launcher : LDX #PORT_LAUNCHER : JSR send
    BEQ status3
    JSR now : LDA #20 : JSR after
.status2
    JSR now : SEC : LDA clk : SBC due : LDA clk+1 : SBC due+1 : BMI status2
    DEC attempts : BNE status1
.status3
    RTS

\ A frame on the management port.
.management
    LDA #LO(rxm) : STA ptr : LDA #HI(rxm) : STA ptr+1
    JSR check : BCS management9
    CMP #T_DISCOVER : BEQ discover
    CMP #T_START : BEQ start
    CMP #T_STOP : BNE management9
    JMP stop
.management9
    RTS

.discover
    LDA plen : CMP #6 : BNE management9
    LDA #LO(txc) : STA ptr : LDA #HI(txc) : STA ptr+1
    LDX #3
.discover1
    LDA rxm+HEADER,X : STA txc+HEADER,X
    DEX : BPL discover1
    LDA mystn : STA txc+HEADER+4
    LDA #2 : STA txc+HEADER+5       \ running
    LDA #1 : STA txc+HEADER+6 : STA txc+HEADER+7
    LDA #8 : STA plen
    LDA #T_BOOT_HELLO : JSR mhdr
    LDA rxstn : LDX #PORT_LAUNCHER : JMP send

\ START while running: take the new coordinator and start again.
.start
    LDA plen : CMP #6 : BNE management9
    LDA rxm+HEADER+4 : CMP mystn : BNE management9
    JSR takenonce
    LDA rxm+HEADER+5 : STA coord
    LDA rxstn : STA launcher
    LDA #LO(txc) : STA ptr : LDA #HI(txc) : STA ptr+1
    JSR putnonce
    LDA #1 : STA txc+HEADER+4       \ already running
    LDA #5 : STA plen
    LDA #T_START_ACK : JSR mhdr
    LDA rxstn : LDX #PORT_LAUNCHER : JSR send
    JSR running
    JSR showcoord
    LDA #S_HELLO : JSR setstate
    JSR now : JMP duenow

\ STOP: say so, and go back to the bootstrap.
.stop
    LDA plen : CMP #4 : BEQ stop0
    RTS
.stop0
    JSR takenonce
    LDA rxstn : STA launcher
    LDA #3 : JSR status
    LDX mblk : JSR delrx
    LDX cblk : JSR delrx
    LDX #LO(wboot) : LDY #HI(wboot) : JMP OSCLI

.takenonce
    LDX #3
.takenonce1
    LDA rxm+HEADER,X : STA nonce,X
    DEX : BPL takenonce1
    RTS

.putnonce
    LDX #3
.putnonce1
    LDA nonce,X : STA txc+HEADER,X
    DEX : BPL putnonce1
    RTS

\ A frame from the coordinator.
.coordinator
    LDA #LO(rxc) : STA ptr : LDA #HI(rxc) : STA ptr+1
    JSR check : BCS coordinator9
    CMP #T_WELCOME : BEQ welcome
    STA mtype
    JSR samerun : BNE coordinator9
    LDA mtype
    CMP #T_ASSIGN : BEQ toassign
    CMP #T_ACK : BEQ ack
    CMP #T_COMPLETE : BEQ complete
.coordinator9
    RTS
.toassign
    JMP assign

\ WELCOME: this run's.
.welcome
    LDA plen : CMP #8 : BNE coordinator9
    LDX #3
.welcome1
    LDA rxc+4,X : STA runid,X
    DEX : BPL welcome1
    JSR showrun
    LDA #S_READY : JSR setstate
    JSR now : JMP duenow

.ack
    LDA plen : CMP #5 : BNE coordinator9
    LDA state : CMP #S_SENT : BNE coordinator9
    LDX #3
.ack1
    LDA rxc+HEADER,X : CMP txr+HEADER,X : BNE coordinator9
    DEX : BPL ack1
    LDA rxc+HEADER+4 : BNE ack2     \ (a duplicate or stale: not ours to count)
    INC done : BNE ack2 : INC done+1
.ack2
    JSR showdone
    LDA #S_READY : JSR setstate
    JSR now : JMP duenow

.complete
    LDA plen : CMP #2 : BNE coordinator9
    LDA #S_DONE : JSR setstate
    JSR now : LDA #250 : JMP after

\ ASSIGN tile2 epoch2 x y w h startReal2 startImag2 stepReal2 stepImag2
\ max format: compute it, and send the counts.
.assign
    LDA plen : CMP #18 : BNE assign9
    LDA rxc+HEADER+17 : CMP #1 : BNE assign9
    LDA rxc+HEADER+16 : BEQ assign9
    LDA rxc+HEADER+6 : BEQ assign9
    CMP #TILE_W+1 : BCS assign9
    LDA rxc+HEADER+7 : BEQ assign9
    CMP #TILE_H+1 : BCC assign1
.assign9
    RTS
.assign1
    \ The RESULT's head: the tile, as assigned.
    LDX #7
.assign2
    LDA rxc+HEADER,X : STA txr+HEADER,X
    DEX : BPL assign2
    LDA #1 : STA txr+HEADER+8
    LDA #LO(txr+HEADER+9) : STA out : LDA #HI(txr+HEADER+9) : STA out+1
    LDA rxc+HEADER+16 : STA mx
    LDA #S_COMPUTING : JSR setstate
    JSR showtile
    \ Row by row from the top.
    LDA rxc+HEADER+10 : STA ci : LDA rxc+HEADER+11 : STA ci+1
    LDA #0 : STA row
.assign3
    LDA rxc+HEADER+8 : STA cr : LDA rxc+HEADER+9 : STA cr+1
    LDA #0 : STA column
.assign4
    JSR count
    LDY #0 : STA (out),Y
    INC out : BNE assign5 : INC out+1
.assign5
    CLC : ADC iterations : STA iterations
    BCC assign6
    INC iterations+1 : BNE assign6 : INC iterations+2 : BNE assign6 : INC iterations+3
.assign6
    CLC : LDA cr : ADC rxc+HEADER+12 : STA cr
    LDA cr+1 : ADC rxc+HEADER+13 : STA cr+1
    INC column : LDA column : CMP rxc+HEADER+6 : BNE assign4
    CLC : LDA ci : ADC rxc+HEADER+14 : STA ci
    LDA ci+1 : ADC rxc+HEADER+15 : STA ci+1
    JSR showrow
    INC row : LDA row : CMP rxc+HEADER+7 : BNE assign3
    \ Send it.
    SEC : LDA out : SBC #LO(txr+HEADER) : STA plen
    LDA #LO(txr) : STA ptr : LDA #HI(txr) : STA ptr+1
    LDA #T_RESULT : JSR hdr
    JSR showiterations
    LDA #S_SENT : JSR setstate
    JSR now : JMP duenow

\ The escape count of cr + ci i, up to mx: see protocol.md. Returns it
\ in A. S(a) = a*a DIV 256 is looked up: the table's page is patched
\ into each LDA.
.count
    LDA #0 : STA zx : STA zx+1 : STA zy : STA zy+1 : STA n
    BEQ iterate
.escaped
    LDA n
    RTS
.iterate
    \ x2 = S(|x|)
    LDA zx+1 : BPL count1
    SEC : LDA #0 : SBC zx : TAY : LDA #0 : SBC zx+1 : JMP count2
.count1
    LDY zx
.count2
    CMP #8 : BCS escaped
    ORA #HI(SQUARES) : STA xlo+2 : ORA #8 : STA xhi+2
.xlo LDA SQUARES,Y : STA x2
.xhi LDA SQUARES+&800,Y : STA x2+1
    \ y2 = S(|y|)
    LDA zy+1 : BPL count3
    SEC : LDA #0 : SBC zy : TAY : LDA #0 : SBC zy+1 : JMP count4
.count3
    LDY zy
.count4
    CMP #8 : BCS escaped
    ORA #HI(SQUARES) : STA ylo+2 : ORA #8 : STA yhi+2
.ylo LDA SQUARES,Y : STA y2
.yhi LDA SQUARES+&800,Y : STA y2+1
    \ Out if x2 + y2 > 1024 (4).
    CLC : LDA x2 : ADC y2 : TAX : LDA x2+1 : ADC y2+1
    CMP #4 : BCC count5 : BNE escaped
    TXA : BNE escaped
.count5
    \ s = S(|x + y|)
    CLC : LDA zx : ADC zy : STA ss : LDA zx+1 : ADC zy+1 : BPL count6
    TAX : SEC : LDA #0 : SBC ss : TAY : TXA : EOR #&FF : ADC #0 : JMP count7
.count6
    LDY ss
.count7
    CMP #8 : BCC count7a
    JMP escaped
.count7a
    ORA #HI(SQUARES) : STA slo+2 : ORA #8 : STA shi+2
.slo LDA SQUARES,Y : STA ss
.shi LDA SQUARES+&800,Y : STA ss+1
    \ y = s - x2 - y2 + ci
    SEC : LDA ss : SBC x2 : TAX : LDA ss+1 : SBC x2+1 : STA ss+1
    TXA : SEC : SBC y2 : TAX : LDA ss+1 : SBC y2+1 : STA ss+1
    TXA : CLC : ADC ci : STA zy : LDA ss+1 : ADC ci+1 : STA zy+1
    \ x = x2 - y2 + cr
    SEC : LDA x2 : SBC y2 : TAX : LDA x2+1 : SBC y2+1 : STA zx+1
    TXA : CLC : ADC cr : STA zx : LDA zx+1 : ADC cr+1 : STA zx+1
    INC n : LDA n : CMP mx : BEQ count8
    JMP iterate
.count8
    RTS

\ The table of squares: S(a) for a = 0 to 2047, by adding odd numbers.
.squares
    LDA #0 : STA sq : STA sq+1 : STA sq+2 : STA odd+1 : STA sqlp : STA sqhp
    LDA #1 : STA odd
    LDA #HI(SQUARES) : STA sqlp+1 : LDA #HI(SQUARES)+8 : STA sqhp+1
    LDY #0
.squares1
    LDA sq+1 : STA (sqlp),Y
    LDA sq+2 : STA (sqhp),Y
    CLC : LDA sq : ADC odd : STA sq
    LDA sq+1 : ADC odd+1 : STA sq+1
    LDA sq+2 : ADC #0 : STA sq+2
    CLC : LDA odd : ADC #2 : STA odd : BCC squares2 : INC odd+1
.squares2
    INY : BNE squares1
    INC sqhp+1 : INC sqlp+1 : LDA sqlp+1 : CMP #HI(SQUARES)+8 : BNE squares1
    RTS

\ An error (an Escape, say): show it and carry on.
.failed
    LDX #&FF : TXS : CLI
    LDA #&7E : JSR OSBYTE
    LDX #0 : LDY #21 : JSR tab : LDA #129 : JSR OSWRCH
    LDY #1
.failed1
    LDA (&FD),Y : BEQ failed2
    JSR OSWRCH : INY : CPY #36 : BNE failed1
.failed2
    JMP loop

\ The screen.
.screen
    VDUS 12 : EQUB 22, 7, 23, 1, 0, 0, 0, 0, 0, 0, 0, 0
    LDY #0 : JSR title
    LDY #1 : JSR title
    LDX #0 : LDY #3
.screen1
    \ The labels.
    STY row : JSR tab
    LDX row : LDA labels,X : BEQ screen2
    LDA #134 : JSR OSWRCH
    LDA labels,X : TAX
.screen1a
    LDA labeltext,X : BEQ screen2
    JSR OSWRCH : INX : BNE screen1a
.screen2
    LDX #0 : LDY row : INY : CPY #17 : BNE screen1
    LDX #15 : LDY #3 : JSR tab : LDA #135 : JSR OSWRCH
    LDA mystn : JSR pstn
    JSR showcoord
    LDX #0 : LDY #18 : JSR tab
    JSR pstr : EQUS 130, "Each tile: 16 x 8 pixels, worked out", 13
    EQUS 130, "here in 6502 code and sent back.", 13, 0
    LDX #0 : LDY #23 : JSR tab
    JSR pstr : EQUS 132, 157, 135, "*STOPWK on any BBC stops workers", 0
    RTS

.title
    LDX #0 : JSR tab
    JSR pstr : EQUS 132, 157, 131, 141, "  MANDELBROT WORKER", 0
    RTS

\ For rows 3 to 16: an offset into labeltext, or 0 for none.
.labels
    EQUB 0, 0, 0
    EQUB l_station - labeltext, l_coord - labeltext, l_run - labeltext, 0
    EQUB l_state - labeltext, 0, l_tile - labeltext, l_where - labeltext
    EQUB l_epoch - labeltext, l_rows - labeltext, 0, l_done - labeltext
    EQUB l_iter - labeltext, 0
.labeltext
    EQUB 0
.l_station EQUS "Station", 0
.l_coord EQUS "Coordinator", 0
.l_run EQUS "Run", 0
.l_state EQUS "State", 0
.l_tile EQUS "Tile", 0
.l_where EQUS "Position", 0
.l_epoch EQUS "Epoch", 0
.l_rows EQUS "Rows", 0
.l_done EQUS "Tiles done", 0
.l_iter EQUS "Iterations", 0

\ Moves to the value column of row Y, in white.
.value
    LDX #15 : JSR tab : LDA #135 : JMP OSWRCH

.showcoord
    LDY #4 : JSR value
    LDA coord : BEQ showcoord1
    JSR pstn : LDA #6 : JMP spaces
.showcoord1
    JSR pstr : EQUS "none yet", 0
    RTS

.showrun
    LDY #5 : JSR value
    LDX #3
.showrun1
    LDA runid,X : JSR phex
    DEX : BPL showrun1
    RTS

.setstate
    STA state
    LDY #7 : LDX #15 : JSR tab
    LDX state : LDA statecolours,X : JSR OSWRCH
    LDA state : ASL A : ASL A : ASL A : ASL A : TAX
.setstate1
    LDA statetext,X : JSR OSWRCH
    INX : TXA : AND #15 : BNE setstate1
    RTS
.statecolours EQUB 131, 131, 131, 130, 133, 134
.statetext
    EQUS "waiting: no job "
    EQUS "registering     "
    EQUS "ready for a tile"
    EQUS "computing       "
    EQUS "sent the result "
    EQUS "run complete    "

.showtile
    LDY #9 : JSR value
    LDA rxc+HEADER : LDX rxc+HEADER+1 : JSR pdec16 : LDA #4 : JSR spaces
    LDY #10 : JSR value
    JSR pstr : EQUS "x ", 0
    LDA rxc+HEADER+4 : JSR pdec8
    JSR pstr : EQUS "  y ", 0
    LDA rxc+HEADER+5 : JSR pdec8 : LDA #4 : JSR spaces
    LDY #11 : JSR value
    LDA rxc+HEADER+2 : LDX rxc+HEADER+3 : JSR pdec16 : LDA #4 : JSR spaces
    LDY #12 : JSR value
    LDA #'.' : LDX rxc+HEADER+7
.showtile1
    JSR OSWRCH : DEX : BNE showtile1
    LDA #2 : JMP spaces

\ A row's done: its mark on the progress line.
.showrow
    LDA row : CLC : ADC #16 : TAX : LDY #12 : JSR tab
    LDA #'#' : JMP OSWRCH

.showdone
    LDY #14 : JSR value
    LDA done : LDX done+1 : JMP pdec16

.showiterations
    LDY #15 : JSR value
    LDX #3
.showiterations1
    LDA iterations,X : STA num,X
    DEX : BPL showiterations1
    JMP pdec32

.wboot  EQUS "WBOOT", 13
.coord  EQUB 0
.launcher EQUB 0
.nonce  EQUD 0
.machine EQUB 0
.state  EQUB 0
.mtype  EQUB 0
.due    EQUW 0
.attempts EQUB 0
.mblk   EQUB 0
.cblk   EQUB 0
.row    EQUB 0
.column EQUB 0
.done   EQUW 0
.iterations EQUD 0
.sq     SKIP 3
.odd    EQUW 0
.rxm    SKIP FRAME
.rxc    SKIP FRAME
.txc    SKIP 32
.txr    SKIP FRAME

INCLUDE "lib.asm"
SAVE "WORKER", WORKER_ORG, P%, WORKER_ORG
