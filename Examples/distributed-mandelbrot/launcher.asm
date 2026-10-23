\ The launcher: CLUSTER, WORKERS and STOPWK are this, assembled three ways
\ (TOOL, which cluster.asm, workers.asm and stopwk.asm set).
\ Each asks every candidate station (1-16, not this one or the servers)
\ what it is (DISCOVER), over Econet, then:
\   CLUSTER (TOOL 0): STARTs each waiting bootstrap, which loads WORKER
\     from the file server to work for this station, and waits to hear
\     it's running. A worker running already is adopted.
\   WORKERS (TOOL 1): lists what's there.
\   STOPWK (TOOL 2): STOPs each worker (back to its bootstrap).
\ Then returns to BASIC.

INCLUDE "common.asm"

ORG TOOL_ORG
GUARD &4000

FIRST = 1 : LAST = 16

.cluster
    JSR getstn
    JSR getservers
    LDA #&87 : JSR OSBYTE : STY mode
    \ A nonce for this session, from the clock.
    JSR now
    LDX #3
.cluster1
    LDA clk,X : STA nonce,X
    DEX : BPL cluster1
    LDA mystn : EOR nonce+3 : STA nonce+3
    JSR colour3
IF TOOL = 0
    JSR pstr : EQUS "MANDELBROT CLUSTER MANAGER", 13, 0
    JSR colour6
    JSR pstr : EQUS "Local coordinator: station ", 0
    LDA mystn : JSR pstn
    JSR newline
ELIF TOOL = 1
    JSR pstr : EQUS "MANDELBROT WORKERS", 13, 0
ELSE
    JSR pstr : EQUS "STOPPING MANDELBROT WORKERS", 13, 0
ENDIF
    JSR colour7
    JSR pstr : EQUS "Probing for bootstraps...", 13, 0
    LDA #LO(rx1) : STA ptr : LDA #HI(rx1) : STA ptr+1
    LDA #PORT_LAUNCHER : JSR openrx : STA blk1
    LDA #LO(rx2) : STA ptr : LDA #HI(rx2) : STA ptr+1
    LDA #PORT_LAUNCHER : JSR openrx : STA blk2
    LDA #0 : STA started : STA failures : STA already : STA unprepared
    LDA #FIRST : STA target

.probe
    LDA target
    CMP mystn : BEQ next
    CMP fsstn : BEQ next
    CMP psstn : BEQ next
    \ DISCOVER: are you a bootstrap or a worker?
    LDA #LO(txm) : STA ptr : LDA #HI(txm) : STA ptr+1
    JSR putnonce
    LDA target : STA txm+HEADER+4
    LDA mystn : STA txm+HEADER+5
    LDA #6 : STA plen
    LDA #T_DISCOVER : JSR mhdr
    LDA target : LDX #PORT_MGMT : JSR send
    BNE notprepared
    LDA #T_BOOT_HELLO : LDX #100 : JSR await
    BCS notprepared
    LDA reply+5 : STA tstate
    JSR colour3
    LDA target : JSR pstn
    LDA #' ' : JSR OSWRCH : JSR OSWRCH
IF TOOL = 0
    JSR launch
ELIF TOOL = 1
    JSR list
ELSE
    JSR stop
ENDIF
    JMP next
.notprepared
    LDX unprepared : LDA target : STA unpreparedlist,X : INC unprepared
.next
    INC target : LDA target : CMP #LAST+1 : BNE probe

    \ The summary.
    LDA unprepared : BEQ summary2
    JSR colour6
    JSR pstr : EQUS "Not prepared:", 0
    LDX #0
.summary1
    STX index
    LDA #' ' : JSR OSWRCH
    LDX index : LDA unpreparedlist,X : JSR pstn
    LDX index : INX : CPX unprepared : BNE summary1
    JSR newline
.summary2
    JSR colour7
IF TOOL = 0
    LDA started : JSR pdec8
    JSR pstr : EQUS " workers started. ", 0
    LDA failures : JSR pdec8
    JSR pstr : EQUS " failed.", 13, 0
    LDA already : BEQ summary3
    JSR pdec8
    JSR pstr : EQUS " already running.", 13, 0
.summary3
    JSR colour2
    JSR pstr : EQUS "Now *MANDEL to draw.", 13, 0
ELIF TOOL = 1
    LDA started : JSR pdec8
    JSR pstr : EQUS " running, ", 0
    LDA already : JSR pdec8
    JSR pstr : EQUS " waiting.", 13, 0
ELSE
    LDA started : JSR pdec8
    JSR pstr : EQUS " stopped.", 13, 0
ENDIF
    LDX blk1 : JSR delrx
    LDX blk2 : JSR delrx
    RTS

IF TOOL = 0
\ Starts the bootstrap at target (or adopts its worker).
.launch
    LDA tstate : CMP #2 : BNE launch1
    JSR colour2
    JSR pstr : EQUS "WORKER ALREADY RUNNING", 13, 0
    INC already
    JMP sendstart
.launch1
    JSR colour6
    JSR pstr : EQUS "BOOTSTRAP READY -> START", 0
    JSR sendstart
    BCS launch9
    LDA reply+4 : BNE launch8     \ (adopted after all)
    \ WORKER's loading from the file server: wait for it to say so.
    LDA #T_STATUS : LDX #0 : JSR await
    BCS launch7
    LDA type : CMP #T_LAUNCH_ERROR : BNE launch6
    JSR sendstart9
    INC failures
    RTS
.launch6
    LDA reply+4 : CMP #2 : BNE launch7
.launch8
    JSR colour2
    JSR pstr : EQUS " -> RUNNING", 13, 0
    INC started
    RTS
.launch7
    JSR colour1
    JSR pstr : EQUS " -> NO ANSWER", 13, 0
    INC failures
    RTS
.launch9
    INC failures
    RTS

\ START, and its acknowledgement. C set if it failed (and why's shown).
.sendstart
    LDA #LO(txm) : STA ptr : LDA #HI(txm) : STA ptr+1
    JSR putnonce
    LDA target : STA txm+HEADER+4
    LDA mystn : STA txm+HEADER+5
    LDA #6 : STA plen
    LDA #T_START : JSR mhdr
    LDA target : LDX #PORT_MGMT : JSR send
    BNE sendstart8
    LDA #T_START_ACK : LDX #200 : JSR await
    BCS sendstart8
    LDA type : CMP #T_LAUNCH_ERROR : BEQ sendstart9
    CLC
    RTS
.sendstart8
    JSR colour1
    JSR pstr : EQUS " -> NO ANSWER", 13, 0
    SEC
    RTS
.sendstart9
    JSR colour1
    JSR pstr : EQUS " -> FAILED", 13, "    ", 0
    LDX #5
.sendstart10
    CPX plen : BEQ sendstart11
    LDA reply,X : JSR OSWRCH
    INX : BNE sendstart10
.sendstart11
    JSR newline
    SEC
    RTS
ENDIF

IF TOOL = 1
.list
    LDA tstate : CMP #2 : BNE list1
    JSR colour2
    JSR pstr : EQUS "WORKER RUNNING", 13, 0
    INC started
    RTS
.list1
    JSR colour6
    JSR pstr : EQUS "BOOTSTRAP WAITING", 13, 0
    INC already
    RTS
ENDIF

IF TOOL = 2
.stop
    LDA tstate : CMP #2 : BEQ stop1
    JSR colour6
    JSR pstr : EQUS "BOOTSTRAP WAITING", 13, 0
    RTS
.stop1
    LDA #LO(txm) : STA ptr : LDA #HI(txm) : STA ptr+1
    JSR putnonce
    LDA #4 : STA plen
    LDA #T_STOP : JSR mhdr
    LDA target : LDX #PORT_MGMT : JSR send
    BNE stop9
    LDA #T_STATUS : LDX #200 : JSR await
    BCS stop9
    JSR colour2
    JSR pstr : EQUS "STOPPED: BACK TO WBOOT", 13, 0
    INC started
    RTS
.stop9
    JSR colour1
    JSR pstr : EQUS "NO ANSWER", 13, 0
    RTS
ENDIF

\ Waits up to X centiseconds (0: 30 seconds) for a message of type A
\ (or LAUNCH_ERROR) from target, in this session, on either receive
\ block. C clear if one came: its payload's at reply, its type in type.
.await
    STA wanted
    STX limit : LDA #0 : STA limit+1
    CPX #0 : BNE await1
    LDA #LO(3000) : STA limit : LDA #HI(3000) : STA limit+1
.await1
    JSR now
    LDA clk : STA since : LDA clk+1 : STA since+1
    LDA #LO(since) : STA tm : LDA #HI(since) : STA tm+1
.await2
    LDX blk1 : JSR pollrx : BPL await3
    LDX blk1 : LDA #LO(rx1) : LDY #HI(rx1) : JSR take
    LDA #PORT_LAUNCHER : JSR openrx : STA blk1
    LDA got : BNE await5
.await3
    LDX blk2 : JSR pollrx : BPL await4
    LDX blk2 : LDA #LO(rx2) : LDY #HI(rx2) : JSR take
    LDA #PORT_LAUNCHER : JSR openrx : STA blk2
    LDA got : BNE await5
.await4
    JSR now : JSR elapsed
    LDA el : CMP limit : LDA el+1 : SBC limit+1 : BCC await2
    SEC
    RTS
.await5
    CLC
    RTS

\ Reads receive block X into the buffer at YA (and leaves ptr there for
\ reopening it): got is 1 if it's what await wants.
.take
    STA ptr : STY ptr+1
    LDA #0 : STA got
    JSR readrx
    LDA rxstn : CMP target : BNE take9
    JSR check : BCS take9
    STA type
    CMP wanted : BEQ take1
    CMP #T_LAUNCH_ERROR : BNE take9
.take1
    LDY #HEADER
.take2
    LDA (ptr),Y : STA reply-HEADER,Y
    INY : CPY #HEADER+48 : BNE take2
    LDX #3
.take3
    LDA reply,X : CMP nonce,X : BNE take9
    DEX : BPL take3
    LDA #1 : STA got
.take9
    RTS

.putnonce
    LDX #3
.putnonce1
    LDA nonce,X : STA txm+HEADER,X
    DEX : BPL putnonce1
    RTS

.newline
    LDA #13 : JMP OSASCI

\ Teletext colours, in MODE 7 only.
.colour1 LDA #129 : BNE colour
.colour2 LDA #130 : BNE colour
.colour3 LDA #131 : BNE colour
.colour6 LDA #134 : BNE colour
.colour7 LDA #135
.colour
    LDX mode : CPX #7 : BNE colour9
    JMP OSWRCH
.colour9
    RTS

.mode   EQUB 0
.nonce  EQUD 0
.target EQUB 0
.tstate EQUB 0
.blk1   EQUB 0
.blk2   EQUB 0
.wanted EQUB 0
.type   EQUB 0
.got    EQUB 0
.limit  EQUW 0
.since  EQUW 0
.index  EQUB 0
.started EQUB 0
.failures EQUB 0
.already EQUB 0
.unprepared EQUB 0
.unpreparedlist SKIP 16
.reply  SKIP 48
.rx1    SKIP FRAME
.rx2    SKIP FRAME
.txm    SKIP 32

INCLUDE "lib.asm"
IF TOOL = 0
    SAVE "CLUSTER", TOOL_ORG, P%, TOOL_ORG
ELIF TOOL = 1
    SAVE "WORKERS", TOOL_ORG, P%, TOOL_ORG
ELSE
    SAVE "STOPWK", TOOL_ORG, P%, TOOL_ORG
ENDIF
