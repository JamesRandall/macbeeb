\ The coordinator: MANDEL (MODE 5) and MANDEL2 (MODE 2, its sixteen colours
\ chosen with VideoNuLA) are this, assembled for SCREEN_MODE (which
\ mandel.asm and mandel2.asm set). Run it on the BBC CLUSTER started the workers
\ from. It takes the workers that register (HELLO), hands each the next
\ tile of 320 as it asks (READY -> ASSIGN), takes the counts back
\ (RESULT -> ACK), and draws them on its own MODE 5 screen. A tile in
\ flight for 20 seconds goes back in the queue for someone else; a late
\ RESULT from an old assignment (epoch) isn't drawn. When the image is
\ complete it tells the workers, and keeps the picture until a key's
\ pressed: then a summary, and back to BASIC. While it draws, a worker
\ that's stopped answering and is found at BASIC again (switched off and
\ on) is started again by remote control, to join in.
\
\ MANDEL: &3000 up, below MODE 5's screen at &5800. MANDEL2: from PAGE
\ (&1B00 on a Model B with DNFS) to MODE 2's screen at &3000, 5K: so it
\ works its colours out as it draws, without a table, and keeps fewer
\ receive blocks and workers.

INCLUDE "common.asm"

\ Text colours while registering: bright, middle and dim.
IF SCREEN_MODE = 5 : BRIGHT = 3 : MIDDLE = 2 : DIM = 1 : ELSE : BRIGHT = 7 : MIDDLE = 4 : DIM = 9 : ENDIF

IF SCREEN_MODE = 5
    SCREEN = &5800 : ROW_BYTES = 320
    ORG MANDEL_ORG
    GUARD SCREEN
    BLOCKS = 5              \ receive blocks on its port (NFS has eight, and logging on to Level 2 takes one)
    NW = 16                 \ workers it can keep track of
ELSE
    SCREEN = &3000 : ROW_BYTES = 640
    ORG MANDEL2_ORG
    GUARD SCREEN
    BLOCKS = 3
    NW = 12
ENDIF

TIMEOUT = 2000              \ centiseconds a tile may be out

\ Zero page.
tsp = &80 : tep = &82 : scr = &84 : smp = &86 : tid = &88

P_REGISTER = 0 : P_RENDER = 1 : P_DONE = 2
W_FREE = 0 : W_REGISTERED = 1 : W_IDLE = 2 : W_BUSY = 3 : W_UNRESPONSIVE = 4 : W_STARTING = 5

.mandel
    JSR getstn
    JSR getservers
    JSR now
    LDX #3
.mandel1
    LDA clk,X : STA runid,X
    DEX : BPL mandel1
    LDA mystn : EOR runid+3 : ORA #&10 : STA runid+3
    LDA #MAX_ITERATIONS : STA maxit
IF SCREEN_MODE = 5
    \ MODE 5: 0 black, 1 blue, 2 cyan, 3 yellow; no cursor.
    VDUS 30 : EQUB 22, 5, 23, 1, 0, 0, 0, 0, 0, 0, 0, 0
    EQUB 19, 1, 4, 0, 0, 0, 19, 2, 6, 0, 0, 0, 19, 3, 3, 0, 0, 0
ELSE
    \ MODE 2, no cursor, and VideoNuLA's colours: logical colours pick
    \ them straight (&11), sixteen written to &FE23 a byte pair each.
    VDUS 12 : EQUB 22, 2, 23, 1, 0, 0, 0, 0, 0, 0, 0, 0
    LDA #&11 : STA &FE22
    LDX #0
.nula1
    LDA nula,X : STA &FE23
    INX : CPX #32 : BNE nula1
ENDIF
    VDUS 2 : EQUB 17, BRIGHT
    JSR pstr : EQUS "MANDELBROT", 13, 0
    VDUS 2 : EQUB 17, MIDDLE
    JSR pstr : EQUS "Distributed over", 13, "Econet", 13, 13, 0
    VDUS 2 : EQUB 17, DIM
    JSR pstr : EQUS "Coordinator: ", 0
    LDA mystn : JSR pstn
    JSR pstr : EQUS 13, "160 x 256, ", 0
    LDA maxit : JSR pdec8
    JSR pstr : EQUS " iter.", 13, 13, 0
    VDUS 2 : EQUB 17, BRIGHT
    JSR pstr : EQUS "Registering", 13, "workers...", 13, 0
IF SCREEN_MODE = 5
    JSR colours
ENDIF
    \ Nothing's assigned or registered.
    LDA #0 : LDX #NW-1
.mandel2
    STA wstate,X
    DEX : BPL mandel2
    STA done : STA done+1 : STA phase : STA nworkers : STA said
    LDA #LO(tstate) : STA tsp : LDA #HI(tstate) : STA tsp+1
    LDX #HI(TILES*2)+1 : LDY #0 : LDA #0
.mandel3
    STA (tsp),Y
    INY : BNE mandel3
    INC tsp+1 : DEX : BNE mandel3
    \ Several receive blocks: a worker's frame needn't wait for another's.
    LDX #BLOCKS-1
.mandel4
    STX index
    JSR open
    DEX : BPL mandel4
    LDA #1 : STA candidate
    JSR now
    LDA clk : STA started : STA lastreg
    LDA clk+1 : STA started+1 : STA lastreg+1

.main
    JSR serve
    BIT &FF : BMI escape
    JSR now
    LDA phase : BEQ register
    CMP #P_RENDER : BNE main1
    JSR timeouts
    JSR recruit
    JMP main
.main1
    \ Done: a key ends it.
IF SCREEN_MODE = 2
    JSR cycle
ENDIF
    LDA #&81 : LDX #0 : LDY #0 : JSR OSBYTE
    CPY #0 : BNE main
    JMP summary
.escape
    LDA #&7E : JSR OSBYTE
    JMP summary

\ Registering: start 3 seconds in, once there's a worker and none has
\ joined for a second.
.register
    LDA #LO(started) : STA tm : LDA #HI(started) : STA tm+1
    JSR elapsed
    LDA el : CMP #LO(300) : LDA el+1 : SBC #HI(300) : BCC tomain

    LDA nworkers : BNE register2
    LDA said : BNE tomain
    INC said
    VDUS 2 : EQUB 17, DIM
    JSR pstr : EQUS 13, "None yet: *CLUSTER", 13, "starts them.", 13, 0
    JMP main
.register2
    LDA #LO(lastreg) : STA tm : LDA #HI(lastreg) : STA tm+1
    JSR elapsed
    LDA el+1 : BNE begin
    LDA el : CMP #100 : BCC tomain
.begin
    VDUS 1 : EQUB 12
    LDA #P_RENDER : STA phase
    LDA clk : STA rstart : LDA clk+1 : STA rstart+1
    LDX #NW-1
.begin1
    LDA wstate,X : CMP #W_IDLE : BNE begin2
    STX slot : JSR dispatch : LDX slot
.begin2
    DEX : BPL begin1
.tomain
    JMP main

\ Joining again: every second, the next worker that's stopped answering
\ (switched off, say). If nothing's listening for DISCOVER there, it isn't
\ running WORKER: if there's a BBC (at BASIC, as one switched on again
\ is), start it by remote control (remote.asm). It's left alone while it
\ starts, until it says HELLO.
.recruit
    JSR now
    LDA #LO(probed) : STA tm : LDA #HI(probed) : STA tm+1
    JSR elapsed
    LDA el+1 : BNE recruit3
    LDA el : CMP #100 : BCS recruit3
    RTS
.recruit3
    LDA clk : STA probed : LDA clk+1 : STA probed+1
    LDY #16
.recruit4
    INC candidate : LDA candidate : CMP #17 : BCC recruit5
    LDA #1 : STA candidate
.recruit5
    DEY : BEQ recruit9
    LDA candidate : STA rxstn : STY index
    JSR find : LDY index
    LDX slot : BMI recruit4
    LDA wstate,X : CMP #W_UNRESPONSIVE : BNE recruit4
    \ DISCOVER nonce target launcher
    JSR txptr
    JSR runnonce
    LDA candidate : STA txm+HEADER+4
    LDA mystn : STA txm+HEADER+5
    LDA #6 : STA plen
    LDA #T_DISCOVER : JSR mhdr
    LDA candidate : LDX #PORT_MGMT : JSR send : BEQ recruit9
    LDA candidate : JSR present : BNE recruit9
    LDA mystn : STA rhand : STA rhand+5
    LDX #3
.recruit6
    LDA runid,X : STA rhand+1,X
    DEX : BPL recruit6
    LDA #'W' : STA rhand+6
    LDA candidate : JSR remote : BNE recruit9
    LDX slot : LDA #W_STARTING : STA wstate,X
.recruit9
    RTS

.runnonce
    LDX #3
.runnonce1
    LDA runid,X : STA txm+HEADER,X
    DEX : BPL runnonce1
    RTS


\ Opens receive block index.
.open
    LDX index
    LDA rxlo,X : STA ptr : LDA rxhi,X : STA ptr+1
    LDA #PORT_COORD : JSR openrx
    LDX index : STA blks,X
    RTS

\ Takes whatever's arrived in the receive blocks.
.serve
    LDX #BLOCKS-1
.serve1
    STX index
    LDA blks,X : TAX : JSR pollrx : BPL serve2
    LDX index : LDA blks,X : TAX : JSR readrx
    LDX index : LDA rxlo,X : STA ptr : LDA rxhi,X : STA ptr+1
    JSR handle
    JSR open
.serve2
    LDX index : DEX : BPL serve1
    RTS

\ A frame from a worker, at ptr.
.handle
    JSR check : BCS handle9
    STA mtype
    JSR find
    LDA mtype
    CMP #T_HELLO : BEQ hello
    CMP #T_READY : BEQ toready
    CMP #T_RESULT : BNE handle9
    JMP result
.toready
    JMP ready
.handle9
    RTS

\ HELLO: register (again), and WELCOME.
.hello
    LDA phase : CMP #P_DONE : BNE hello1
    JSR samerun : BNE hello1
    JMP sendcomplete
.hello1
    LDX slot : BPL hello3
    \ A new worker.
    LDX #0
.hello2
    LDA wstate,X : BEQ hello2a
    INX : CPX #NW : BNE hello2
    RTS
.hello2a
    STX slot
    LDA rxstn : STA wstn,X
    LDA #0 : STA wtileslo,X : STA wtileshi,X
    STA witer0,X : STA witer1,X : STA witer2,X : STA witer3,X
    INC nworkers
    LDA clk : STA lastreg : LDA clk+1 : STA lastreg+1
    LDA phase : BNE hello3
    LDA #' ' : JSR OSWRCH
    LDA rxstn : JSR pstn
.hello3
    \ Its tile in flight, if any, goes back in the queue.
    LDX slot
    LDA wstate,X : CMP #W_BUSY : BNE hello4
    JSR tileof : LDY #0 : TYA : STA (tsp),Y
.hello4
    LDX slot
    LDA #W_REGISTERED : STA wstate,X
    \ WELCOME width2 height2 max tileW tileH format
    JSR txptr
    LDA #LO(160) : STA txm+HEADER : LDA #0 : STA txm+HEADER+1
    STA txm+HEADER+2 : LDA #1 : STA txm+HEADER+3
    LDA maxit : STA txm+HEADER+4
    LDA #TILE_W : STA txm+HEADER+5
    LDA #TILE_H : STA txm+HEADER+6
    LDA #1 : STA txm+HEADER+7
    LDA #8 : STA plen
    LDA #T_WELCOME : JSR hdr
    LDA rxstn : LDX #PORT_WORKER : JMP send

\ READY: its next tile (or the one it has).
.ready
    LDA plen : CMP #1 : BNE ready9
    JSR samerun : BNE tohello
    LDX slot : BMI tohello
    LDA phase : CMP #P_DONE : BNE ready0
    JMP sendcomplete
.ready0
    CMP #P_REGISTER : BNE ready1
    LDA #W_IDLE : STA wstate,X
.ready9
    RTS
.ready1
    LDA wstate,X : CMP #W_BUSY : BNE dispatch
    JMP sendassign
.tohello
    JMP hello

\ Gives worker slot the next pending tile, or marks it idle.
.dispatch
    LDA #LO(tstate) : STA tsp : LDA #HI(tstate) : STA tsp+1
    LDA #0 : STA tid : STA tid+1
    LDY #0
.dispatch1
    LDA (tsp),Y : BEQ dispatch3
    INC tsp : BNE dispatch2 : INC tsp+1
.dispatch2
    INC tid : BNE dispatch2a : INC tid+1
.dispatch2a
    LDA tid : CMP #LO(TILES) : BNE dispatch1
    LDA tid+1 : CMP #HI(TILES) : BNE dispatch1
    LDX slot : LDA #W_IDLE : STA wstate,X
    RTS
.dispatch3
    LDA #1 : STA (tsp),Y
    JSR tilepointers
    LDY #0 : LDA (tep),Y : CLC : ADC #1 : STA (tep),Y
    LDX slot
    LDA tid : STA wtilelo,X : LDA tid+1 : STA wtilehi,X
    LDA clk : STA wtimelo,X : LDA clk+1 : STA wtimehi,X
    LDA #W_BUSY : STA wstate,X
\ ASSIGN slot's tile: tile2 epoch2 x y w h startReal2 startImag2
\ stepReal2 stepImag2 max format.
.sendassign
    LDX slot : JSR tileof
    JSR txptr
    LDA tid : STA txm+HEADER : LDA tid+1 : STA txm+HEADER+1
    LDY #0 : LDA (tep),Y : STA txm+HEADER+2 : LDA #0 : STA txm+HEADER+3
    JSR place
    LDA column : ASL A : ASL A : ASL A : ASL A : STA txm+HEADER+4
    LDA row : ASL A : ASL A : ASL A : STA txm+HEADER+5
    LDA #TILE_W : STA txm+HEADER+6
    LDA #TILE_H : STA txm+HEADER+7
    \ startReal = -576 + 5x
    LDA txm+HEADER+4 : STA t16 : LDA #0 : STA t16+1
    ASL t16 : ROL t16+1 : ASL t16 : ROL t16+1
    CLC : LDA t16 : ADC txm+HEADER+4 : STA t16 : LDA t16+1 : ADC #0 : STA t16+1
    CLC : LDA t16 : ADC #LO(REAL0) : STA txm+HEADER+8
    LDA t16+1 : ADC #HI(REAL0) : STA txm+HEADER+9
    \ startImag = 384 - 3y
    LDA txm+HEADER+5 : STA t16 : LDA #0 : STA t16+1
    ASL t16 : ROL t16+1
    CLC : LDA t16 : ADC txm+HEADER+5 : STA t16 : LDA t16+1 : ADC #0 : STA t16+1
    SEC : LDA #LO(IMAG0) : SBC t16 : STA txm+HEADER+10
    LDA #HI(IMAG0) : SBC t16+1 : STA txm+HEADER+11
    LDA #LO(STEP_REAL) : STA txm+HEADER+12 : LDA #HI(STEP_REAL) : STA txm+HEADER+13
    LDA #LO(STEP_IMAG) : STA txm+HEADER+14 : LDA #HI(STEP_IMAG) : STA txm+HEADER+15
    LDA maxit : STA txm+HEADER+16
    LDA #1 : STA txm+HEADER+17
    LDA #18 : STA plen
    LDA #T_ASSIGN : JSR hdr
    LDX slot : LDA wstn,X : LDX #PORT_WORKER : JMP send

.sendcomplete
    JSR txptr
    LDA #LO(TILES) : STA txm+HEADER : LDA #HI(TILES) : STA txm+HEADER+1
    LDA #2 : STA plen
    LDA #T_COMPLETE : JSR hdr
    LDA rxstn : LDX #PORT_WORKER : JMP send

\ RESULT tile2 epoch2 x y w h format counts: checked, drawn and counted
\ if it's the tile's current assignment; acknowledged whatever.
.result
    JSR samerun : BNE result0
    LDX slot : BPL result00
.result0
    JMP hello
.result00
    LDA plen : CMP #9+TILE_W*TILE_H : BEQ resultlen
    RTS
.resultlen
    LDY #HEADER : LDA (ptr),Y : STA tid
    INY : LDA (ptr),Y : STA tid+1
    CMP #HI(TILES) : BCC result1 : BNE result9
    LDA tid : CMP #LO(TILES) : BCS result9
.result1
    \ Where it says it is must be where that tile is.
    JSR place
    LDA column : ASL A : ASL A : ASL A : ASL A
    LDY #HEADER+4 : CMP (ptr),Y : BNE result9
    LDA row : ASL A : ASL A : ASL A
    INY : CMP (ptr),Y : BNE result9
    INY : LDA (ptr),Y : CMP #TILE_W : BNE result9
    INY : LDA (ptr),Y : CMP #TILE_H : BNE result9
    INY : LDA (ptr),Y : CMP #1 : BNE result9
    \ Every count 1 to max; their sum.
    CLC : LDA ptr : ADC #HEADER+9 : STA smp : LDA ptr+1 : ADC #0 : STA smp+1
    LDX maxit : INX : STX maxp1
    LDA #0 : STA sum : STA sum+1 : STA sum+2
    LDY #0
.result2
    LDA (smp),Y : BEQ result9
    CMP maxp1 : BCS result9
    CLC : ADC sum : STA sum : BCC result3
    INC sum+1 : BNE result3 : INC sum+2
.result3
    INY : BPL result2
    JMP result4
.result9
    RTS
\ Done already. If it was this epoch, it was this worker's, and the ACK
\ that said so was lost: say it again. Otherwise someone else's.
.duplicate
    LDY #HEADER+3 : LDA (ptr),Y : BNE duplicate1
    DEY : LDA (ptr),Y : LDY #0 : CMP (tep),Y : BNE duplicate1
    LDA #0 : JMP sendack
.duplicate1
    LDA #1 : JMP sendack
.stale
    LDA #2 : JMP sendack
.result4
    JSR tilepointers
    LDY #0 : LDA (tsp),Y : CMP #2 : BEQ duplicate
    CMP #1 : BNE stale
    LDY #HEADER+3 : LDA (ptr),Y : BNE stale
    DEY : LDA (ptr),Y : LDY #0 : CMP (tep),Y : BNE stale
    LDX slot : LDA wstate,X : CMP #W_BUSY : BNE stale
    LDA wtilelo,X : CMP tid : BNE stale
    LDA wtilehi,X : CMP tid+1 : BNE stale
    \ Accepted.
    LDA #2 : LDY #0 : STA (tsp),Y
    LDA #W_REGISTERED : STA wstate,X
    INC wtileslo,X : BNE result5 : INC wtileshi,X
.result5
    CLC : LDA witer0,X : ADC sum : STA witer0,X
    LDA witer1,X : ADC sum+1 : STA witer1,X
    LDA witer2,X : ADC sum+2 : STA witer2,X
    LDA witer3,X : ADC #0 : STA witer3,X
    JSR draw
    INC done : BNE result6 : INC done+1
.result6
    LDA #0 : JSR sendack
    LDA done : CMP #LO(TILES) : BNE result7
    LDA done+1 : CMP #HI(TILES) : BNE result7
    JMP finish
.result7
    RTS
\ ACK tile2 epoch2 status, for the RESULT at ptr.
.sendack
    STA txm+HEADER+4
    LDY #HEADER : LDA (ptr),Y : STA txm+HEADER
    INY : LDA (ptr),Y : STA txm+HEADER+1
    INY : LDA (ptr),Y : STA txm+HEADER+2
    INY : LDA (ptr),Y : STA txm+HEADER+3
    JSR txptr
    LDA #5 : STA plen
    LDA #T_ACK : JSR hdr
    LDA rxstn : LDX #PORT_WORKER : JMP send

\ The image is done: tell every worker.
.finish
    LDA #P_DONE : STA phase
    LDA clk : STA rend : LDA clk+1 : STA rend+1
    LDX #NW-1
.finish1
    LDA wstate,X : BEQ finish2
    STX slot
    LDA wstn,X : STA rxstn
    JSR sendcomplete
    LDX slot
.finish2
    DEX : BPL finish1
    RTS

\ Tiles out too long go back in the queue, for the idle.
.timeouts
    LDA #0 : STA requeued
    LDX #NW-1
.timeouts1
    LDA wstate,X : CMP #W_BUSY : BNE timeouts2
    SEC : LDA clk : SBC wtimelo,X : STA el : LDA clk+1 : SBC wtimehi,X
    CMP #HI(TIMEOUT) : BCC timeouts2 : BNE timeouts1a
    LDA el : CMP #LO(TIMEOUT) : BCC timeouts2
.timeouts1a
    STX slot
    JSR tileof : LDA #0 : TAY : STA (tsp),Y
    LDX slot : LDA #W_UNRESPONSIVE : STA wstate,X
    INC requeued
.timeouts2
    DEX : BPL timeouts1
    LDA requeued : BEQ timeouts9
    LDX #NW-1
.timeouts3
    LDA wstate,X : CMP #W_IDLE : BNE timeouts4
    STX slot : JSR dispatch : LDX slot
.timeouts4
    DEX : BPL timeouts3
.timeouts9
    RTS

\ slot := the worker that sent the frame (rxstn), or &FF.
.find
    LDX #NW-1
.find1
    LDA wstate,X : BEQ find2
    LDA wstn,X : CMP rxstn : BEQ find3
.find2
    DEX : BPL find1
.find3
    STX slot
    RTS

\ tid := worker X's tile, and its pointers.
.tileof
    LDA wtilelo,X : STA tid : LDA wtilehi,X : STA tid+1
\ tsp, tep := tile tid's state and epoch.
.tilepointers
    CLC : LDA #LO(tstate) : ADC tid : STA tsp
    LDA #HI(tstate) : ADC tid+1 : STA tsp+1
    CLC : LDA #LO(tepoch) : ADC tid : STA tep
    LDA #HI(tepoch) : ADC tid+1 : STA tep+1
    RTS

\ row, column := tile tid's.
.place
    LDA tid : STA t16 : LDA tid+1 : STA t16+1
    LDA #0 : STA row
.place1
    LDA t16+1 : BNE place2
    LDA t16 : CMP #TILE_COLUMNS : BCC place3
.place2
    SEC : LDA t16 : SBC #TILE_COLUMNS : STA t16 : LDA t16+1 : SBC #0 : STA t16+1
    INC row : JMP place1
.place3
    STA column
    RTS

.txptr
    LDA #LO(txm) : STA ptr : LDA #HI(txm) : STA ptr+1
    RTS

IF SCREEN_MODE = 5
\ Draws tile tid's counts (at smp) in MODE 5: each byte is four pixels,
\ each pixel's colour in bits 7-p and 3-p.
.draw
    JSR screenaddress
    LDA #0 : STA dy
    LDY #0
.draw1
    LDA #0 : STA cell
.draw2
    LDA (smp),Y : TAX : LDA cmap,X : TAX : LDA pix0,X : STA byte : INY
    LDA (smp),Y : TAX : LDA cmap,X : TAX : LDA pix1,X : ORA byte : STA byte : INY
    LDA (smp),Y : TAX : LDA cmap,X : TAX : LDA pix2,X : ORA byte : STA byte : INY
    LDA (smp),Y : TAX : LDA cmap,X : TAX : LDA pix3,X : ORA byte
    STY sy
    PHA : LDA cell : ASL A : ASL A : ASL A : ORA dy : TAY : PLA
    STA (scr),Y
    LDY sy : INY
    INC cell : LDA cell : CMP #4 : BNE draw2
    INC dy : LDA dy : CMP #TILE_H : BNE draw1
    RTS

\ scr := the tile's place on the screen: SCREEN + row * 320 + column * 32.
.screenaddress
    JSR place
    LDA row : STA scr+1 : LDA #0 : STA scr
    LDA row : LSR A : LSR A : STA t16+1
    LDA row : ASL A : ASL A : ASL A : ASL A : ASL A : ASL A : STA t16
    CLC : LDA scr : ADC t16 : STA scr : LDA scr+1 : ADC t16+1 : STA scr+1
    LDA column : LSR A : LSR A : LSR A : STA t16+1
    LDA column : ASL A : ASL A : ASL A : ASL A : ASL A : STA t16
    CLC : LDA scr : ADC t16 : STA scr : LDA scr+1 : ADC t16+1 : ADC #HI(SCREEN) : STA scr+1
    RTS
ELSE
\ Draws tile tid's counts (at smp) in MODE 2: each byte is two pixels,
\ the left one's colour in bits 7, 5, 3 and 1, the right one's in 6, 4,
\ 2 and 0.
.draw
    JSR screenaddress
    LDA #0 : STA dy
    LDY #0
.draw1
    LDA #0 : STA cell
.draw2
    LDA (smp),Y : JSR colour : LDA left,X : STA byte : INY
    LDA (smp),Y : JSR colour : LDA left,X : LSR A : ORA byte
    STY sy
    PHA : LDA cell : ASL A : ASL A : ASL A : ORA dy : TAY : PLA
    STA (scr),Y
    LDY sy : INY
    INC cell : LDA cell : CMP #8 : BNE draw2
    INC dy : LDA dy : CMP #TILE_H : BNE draw1
    RTS

\ X := count A's colour: 0 for max, else 1 + (n - 1) MOD 15.
.colour
    CMP maxit : BEQ colour3
    SEC : SBC #1
.colour1
    CMP #15 : BCC colour2
    SBC #15 : BCS colour1
.colour2
    TAX : INX
    RTS
.colour3
    LDX #0
    RTS

\ scr := the tile's place on the screen: SCREEN + row * 640 + column * 64.
.screenaddress
    JSR place
    LDA row : AND #1 : LSR A : ROR A : STA scr          \ (row AND 1) * 128
    LDA row : LSR A : STA t16 : LDA row : ASL A : ADC t16 : STA scr+1
    LDA column : LSR A : LSR A : CLC : ADC scr+1 : ADC #HI(SCREEN) : STA scr+1
    LDA column : AND #3 : LSR A : ROR A : ROR A    \ (column AND 3) * 64
    CLC : ADC scr : STA scr : BCC screenaddress1
    INC scr+1
.screenaddress1
    RTS
ENDIF

IF SCREEN_MODE = 2
\ The picture's done: cycle its colours, the classic way. Every third
\ frame, at the vertical sync, each of colours 1 to 15 takes the next
\ one's shade, so the bands flow outwards from the set. Only VideoNuLA's
\ palette changes: the picture in memory stays as it was drawn.
.cycle
    LDA #19 : JSR OSBYTE            \ wait for the vertical sync
    INC frames : LDA frames : CMP #3 : BCC cycle9
    LDA #0 : STA frames
    INC shift : LDA shift : CMP #15 : BCC cycle1
    LDA #0 : STA shift
.cycle1
    LDX #1
.cycle2
    \ Colour X gets shade 1 + (X - 1 + shift) MOD 15.
    TXA : CLC : ADC shift : CMP #16 : BCC cycle3
    SBC #15
.cycle3
    ASL A : TAY
    TXA : ASL A : ASL A : ASL A : ASL A : STA byte
    LDA nula,Y : AND #15 : ORA byte : STA &FE23
    LDA nula+1,Y : STA &FE23
    INX : CPX #16 : BNE cycle2
.cycle9
    RTS
ENDIF

IF SCREEN_MODE = 5
\ cmap: a count's colour (0 for max, else 1 + (n - 1) MOD 3).
.colours
    LDX #1 : LDY #1
.colours1
    TYA : STA cmap,X
    INY : CPY #4 : BNE colours2 : LDY #1
.colours2
    INX : BNE colours1
    LDA #0 : STA cmap
    LDX maxit : STA cmap,X
    RTS
ENDIF

\ The summary, in MODE 7.
.summary
    LDX #BLOCKS-1
.summary1
    STX index : LDA blks,X : TAX : JSR delrx
    LDX index : DEX : BPL summary1
IF SCREEN_MODE = 2
    LDA #&40 : STA &FE22            \ VideoNuLA's standard colours again
ENDIF
    VDUS 12 : EQUB 22, 7, 23, 1, 0, 0, 0, 0, 0, 0, 0, 0
    LDY #0 : JSR stitle : LDY #1 : JSR stitle
    LDX #0 : LDY #3 : JSR tab
    LDA #131 : JSR OSWRCH
    LDA done : LDX done+1 : JSR pdec16
    JSR pstr : EQUS " of 320 tiles", 0
    LDA phase : CMP #P_DONE : BNE summary3
    JSR pstr : EQUS " in ", 0
    SEC : LDA rend : SBC rstart : STA t16 : LDA rend+1 : SBC rstart+1 : STA t16+1
    \ seconds = t16 DIV 100, then hundredths.
    LDA #0 : STA sum
.summary2
    LDA t16+1 : BNE summary2a
    LDA t16 : CMP #100 : BCC summary2b
.summary2a
    SEC : LDA t16 : SBC #100 : STA t16 : LDA t16+1 : SBC #0 : STA t16+1
    INC sum : JMP summary2
.summary2b
    LDA sum : JSR pdec8 : LDA #'.' : JSR OSWRCH
    LDA t16 : JSR pstn
    JSR pstr : EQUS "s", 0
.summary3
    JSR pstr : EQUS 13, 13, 134, "Station  Tiles  Iterations", 13, 0
    LDA #0 : STA sum : STA sum+1 : STA sum+2 : STA sum+3
    LDX #0
.summary4
    STX slot
    LDA wstate,X : BEQ summary5
    LDA #135 : JSR OSWRCH : LDA #' ' : JSR OSWRCH : JSR OSWRCH
    LDX slot : LDA wstn,X : JSR pstn
    LDA #5 : JSR spaces
    LDX slot : LDA wtileslo,X : PHA : LDA wtileshi,X : TAX : PLA : JSR pdec16
    LDA #5 : JSR spaces
    LDX slot
    LDA witer0,X : STA num : CLC : ADC sum : STA sum
    LDA witer1,X : STA num+1 : ADC sum+1 : STA sum+1
    LDA witer2,X : STA num+2 : ADC sum+2 : STA sum+2
    LDA witer3,X : STA num+3 : ADC sum+3 : STA sum+3
    JSR pdec32
    JSR pstr : EQUS 13, 0
.summary5
    LDX slot : INX : CPX #NW : BNE summary4
    JSR pstr : EQUS 13, 134, "Iterations in all ", 135, 0
    LDX #3
.summary6
    LDA sum,X : STA num,X
    DEX : BPL summary6
    JSR pdec32
    JSR pstr : EQUS 13, 13, 130, "Every one worked out by a BBC Micro", 13
    EQUS 130, "and sent over Econet.", 13, 13, 0
    RTS

.stitle
    LDX #0 : JSR tab
    JSR pstr : EQUS 132, 157, 131, 141, " DISTRIBUTED MANDELBROT", 0
    RTS

IF SCREEN_MODE = 5
\ A pixel's bits for each colour, by its place in the byte.
.pix0 EQUB &00, &08, &80, &88
.pix1 EQUB &00, &04, &40, &44
.pix2 EQUB &00, &02, &20, &22
.pix3 EQUB &00, &01, &10, &11
ELSE
\ A left-hand pixel's bits for each colour (a right-hand one's are these
\ shifted right).
.left
    FOR c, 0, 15 : EQUB (c AND 8) * 16 + (c AND 4) * 8 + (c AND 2) * 4 + (c AND 1) * 2 : NEXT
\ VideoNuLA's colours, as byte pairs for &FE23 (colour and red, green and
\ blue): black inside the set, then fifteen that go round, so the bands
\ run on smoothly: blues, cyan, white, yellow, orange, red, purple.
.nula
    EQUB &00, &00
    EQUB &10, &28, &20, &5C, &30, &9F, &42, &DF, &58, &FF, &6F, &FF, &7F, &F8
    EQUB &8F, &D2, &9F, &90, &AF, &50, &BC, &22, &C9, &06, &D6, &09, &E3, &0A, &F1, &19
ENDIF

.rxlo
    FOR i, 0, BLOCKS-1 : EQUB LO(rxbufs + i * FRAME) : NEXT
.rxhi
    FOR i, 0, BLOCKS-1 : EQUB HI(rxbufs + i * FRAME) : NEXT

.maxit  EQUB 0
.maxp1  EQUB 0
.phase  EQUB 0
.said   EQUB 0
.mtype  EQUB 0
.slot   EQUB 0
.index  EQUB 0
.requeued EQUB 0
.nworkers EQUB 0
.done   EQUW 0
.started EQUW 0
.lastreg EQUW 0
.rstart EQUW 0
.rend   EQUW 0
.t16    EQUW 0
.sum    SKIP 4
.row    EQUB 0
.column EQUB 0
.dy     EQUB 0
.cell   EQUB 0
.byte   EQUB 0
.sy     EQUB 0
.frames EQUB 0
.shift  EQUB 0
.blks   SKIP BLOCKS
.candidate EQUB 0
.probed EQUW 0
.wstn   SKIP NW
.wstate SKIP NW
.wtilelo SKIP NW
.wtilehi SKIP NW
.wtimelo SKIP NW
.wtimehi SKIP NW
.wtileslo SKIP NW
.wtileshi SKIP NW
.witer0 SKIP NW
.witer1 SKIP NW
.witer2 SKIP NW
.witer3 SKIP NW
.txm    SKIP 32
IF SCREEN_MODE = 5
.cmap   SKIP 256
ENDIF
.tstate SKIP TILES
.tepoch SKIP TILES
.rxbufs SKIP BLOCKS * FRAME

INCLUDE "lib.asm"
INCLUDE "remote.asm"
IF SCREEN_MODE = 5
    SAVE "MANDEL", MANDEL_ORG, P%, MANDEL_ORG
ELSE
    SAVE "MANDEL2", MANDEL2_ORG, P%, MANDEL2_ORG
ENDIF
