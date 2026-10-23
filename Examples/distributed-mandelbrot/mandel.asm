\ MANDEL: the coordinator. Run it on the BBC CLUSTER started the workers
\ from. It takes the workers that register (HELLO), hands each the next
\ tile of 320 as it asks (READY -> ASSIGN), takes the counts back
\ (RESULT -> ACK), and draws them on its own MODE 5 screen. A tile in
\ flight for 20 seconds goes back in the queue for someone else; a late
\ RESULT from an old assignment (epoch) isn't drawn. When the image is
\ complete it tells the workers, and keeps the picture until a key's
\ pressed: then a summary, and back to BASIC. While it draws, it looks
\ for bootstraps that have appeared since CLUSTER (a worker switched on
\ part way), one station a second, and STARTs them to join in.
\
\ &3000 up: code, tables and buffers, below MODE 5's screen at &5800.

INCLUDE "common.asm"

ORG MANDEL_ORG
GUARD &5800

NW = 16                     \ workers it can keep track of
BLOCKS = 6                  \ receive blocks on its port (NFS has room for eight in all)
TIMEOUT = 2000              \ centiseconds a tile may be out
SCREEN = &5800

\ Zero page.
tsp = &80 : tep = &82 : scr = &84 : smp = &86 : tid = &88

P_REGISTER = 0 : P_RENDER = 1 : P_DONE = 2
W_FREE = 0 : W_REGISTERED = 1 : W_IDLE = 2 : W_BUSY = 3 : W_UNRESPONSIVE = 4

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
    \ MODE 5: 0 black, 1 blue, 2 cyan, 3 yellow; no cursor.
    VDUS 30 : EQUB 22, 5, 23, 1, 0, 0, 0, 0, 0, 0, 0, 0
    EQUB 19, 1, 4, 0, 0, 0, 19, 2, 6, 0, 0, 0, 19, 3, 3, 0, 0, 0
    VDUS 2 : EQUB 17, 3
    JSR pstr : EQUS "MANDELBROT", 13, 0
    VDUS 2 : EQUB 17, 2
    JSR pstr : EQUS "Distributed over", 13, "Econet", 13, 13, 0
    VDUS 2 : EQUB 17, 1
    JSR pstr : EQUS "Coordinator: ", 0
    LDA mystn : JSR pstn
    JSR pstr : EQUS 13, "160 x 256, ", 0
    LDA maxit : JSR pdec8
    JSR pstr : EQUS " iter.", 13, 13, 0
    VDUS 2 : EQUB 17, 3
    JSR pstr : EQUS "Registering", 13, "workers...", 13, 0
    JSR colours
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
    JSR openlauncher
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
    VDUS 2 : EQUB 17, 1
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

\ Joining part way: every second, DISCOVER to the next candidate
\ station that isn't working for us (the run's ID is the nonce), and
\ START a bootstrap that answers.
.recruit
    LDX lblk : BNE recruit00
    JSR openlauncher : JMP recruit2
.recruit00
    JSR pollrx : BPL recruit2
    LDX lblk : JSR readrx
    LDA #LO(lbuf) : STA ptr : LDA #HI(lbuf) : STA ptr+1
    JSR check : BCS recruit1
    CMP #T_BOOT_HELLO : BNE recruit1
    LDA plen : CMP #8 : BNE recruit1
    LDA lbuf+HEADER+5 : CMP #1 : BNE recruit1
    LDX #3
.recruit0
    LDA lbuf+HEADER,X : CMP runid,X : BNE recruit1
    DEX : BPL recruit0
    \ START nonce target coordinator
    JSR txptr
    JSR runnonce
    LDA rxstn : STA txm+HEADER+4
    LDA mystn : STA txm+HEADER+5
    LDA #6 : STA plen
    LDA #T_START : JSR mhdr
    LDA rxstn : LDX #PORT_MGMT : JSR send
.recruit1
    JSR openlauncher
.recruit2
    JSR now
    LDA #LO(probed) : STA tm : LDA #HI(probed) : STA tm+1
    JSR elapsed
    LDA el+1 : BNE recruit3
    LDA el : CMP #100 : BCC recruit9
.recruit3
    LDA clk : STA probed : LDA clk+1 : STA probed+1
    \ The next candidate: not us, a server or a worker we have.
    LDY #16
.recruit4
    INC candidate : LDA candidate : CMP #17 : BCC recruit5
    LDA #1 : STA candidate
.recruit5
    DEY : BEQ recruit9
    LDA candidate
    CMP mystn : BEQ recruit4
    CMP fsstn : BEQ recruit4
    CMP psstn : BEQ recruit4
    STA rxstn : STY index
    JSR find : LDY index
    LDX slot : BMI recruit6
    LDA wstate,X : CMP #W_UNRESPONSIVE : BNE recruit4
.recruit6
    \ DISCOVER nonce target launcher
    JSR txptr
    JSR runnonce
    LDA candidate : STA txm+HEADER+4
    LDA mystn : STA txm+HEADER+5
    LDA #6 : STA plen
    LDA #T_DISCOVER : JSR mhdr
    LDA candidate : LDX #PORT_MGMT : JSR send
.recruit9
    RTS

.runnonce
    LDX #3
.runnonce1
    LDA runid,X : STA txm+HEADER,X
    DEX : BPL runnonce1
    RTS

.openlauncher
    LDA #LO(lbuf) : STA ptr : LDA #HI(lbuf) : STA ptr+1
    LDA #PORT_LAUNCHER : JSR openrx : STA lblk
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
.duplicate
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

\ Draws tile tid's counts (at smp) in MODE 5: each byte is four pixels,
\ each pixel's colour in bits 7-p and 3-p.
.draw
    JSR place
    \ scr = SCREEN + row * 320 + column * 32
    LDA row : STA scr+1 : LDA #0 : STA scr
    LDA row : LSR A : LSR A : STA t16+1
    LDA row : ASL A : ASL A : ASL A : ASL A : ASL A : ASL A : STA t16
    CLC : LDA scr : ADC t16 : STA scr : LDA scr+1 : ADC t16+1 : STA scr+1
    LDA column : LSR A : LSR A : LSR A : STA t16+1
    LDA column : ASL A : ASL A : ASL A : ASL A : ASL A : STA t16
    CLC : LDA scr : ADC t16 : STA scr : LDA scr+1 : ADC t16+1 : ADC #HI(SCREEN) : STA scr+1
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

\ The summary, in MODE 7.
.summary
    LDX #BLOCKS-1
.summary1
    STX index : LDA blks,X : TAX : JSR delrx
    LDX index : DEX : BPL summary1
    LDX lblk : JSR delrx
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

\ A pixel's bits for each colour, by its place in the byte.
.pix0 EQUB &00, &08, &80, &88
.pix1 EQUB &00, &04, &40, &44
.pix2 EQUB &00, &02, &20, &22
.pix3 EQUB &00, &01, &10, &11

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
.blks   SKIP BLOCKS
.lblk   EQUB 0
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
.cmap   SKIP 256
.tstate SKIP TILES
.tepoch SKIP TILES
.rxbufs SKIP BLOCKS * FRAME
.lbuf   SKIP FRAME

INCLUDE "lib.asm"
SAVE "MANDEL", MANDEL_ORG, P%, MANDEL_ORG
