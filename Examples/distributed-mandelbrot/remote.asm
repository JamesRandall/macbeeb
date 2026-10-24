\ Remote control: Econet's immediate operations, which NFS answers itself,
\ whatever the BBC at the other end is doing. CLUSTER and MANDEL use them
\ to start WORKER on a BBC that's only at BASIC:
\   POKE (&82): the hand-off (rhand) into its zero page at &70;
\   POKE: the stub below to STUB;
\   JSR (&83): the stub, which types *NET, *I AM GUEST and *WORKER into
\     its keyboard buffer, so BASIC runs them as if they'd been typed there.
\ (NFS makes a remote JSR from its interrupt handler, so the stub only
\ queues the keys: the commands run once it's returned.)
\ And machine type (&88), which only reads, to see whether a BBC's there.

STUB = &0A00                \ the remote's RS423 input buffer, unused

\ Is there a BBC at station A? Z set if so.
.present
    JSR imstation
    LDA #LO(imtype) : LDX #HI(imtype) : LDY #4 : JSR imrange
    LDA #0 : TAX : JSR imaddr
    LDA #&88 : JMP imgo

\ Starts WORKER on the BBC at station A, which must be at BASIC: rhand
\ says who for. Z set if the stub went and was called.
.remote
    JSR imstation
    LDA #LO(rhand) : LDX #HI(rhand) : LDY #7 : JSR imrange
    LDA #HANDOFF_COORD : LDX #0 : JSR imaddr
    LDA #&82 : JSR imgo : BNE remote9
    LDA #LO(stub) : LDX #HI(stub) : LDY #stubend-stub : JSR imrange
    LDA #LO(STUB) : LDX #HI(STUB) : JSR imaddr
    LDA #&82 : JSR imgo : BNE remote9
    \ (DNFS wants a byte of arguments with a JSR.)
    LDA #LO(stub) : LDX #HI(stub) : LDY #1 : JSR imrange
    LDA #LO(STUB) : LDX #HI(STUB) : JSR imaddr
    LDA #&83 : JSR imgo
.remote9
    RTS

.imstation
    STA imcb+2
    LDA #0 : STA imcb+1 : STA imcb+3    \ port 0, this network
    RTS

\ The local buffer: Y bytes from XA.
.imrange
    STA imcb+4 : STX imcb+5
    TYA : CLC : ADC imcb+4 : STA imcb+8
    LDA imcb+5 : ADC #0 : STA imcb+9
    LDA #&FF : STA imcb+6 : STA imcb+7 : STA imcb+10 : STA imcb+11
    RTS

\ The remote address: XA.
.imaddr
    STA imcb+12 : STX imcb+13
    LDA #0 : STA imcb+14 : STA imcb+15
    RTS

\ Does immediate operation A; A (and Z) is the result, 0 if it went.
.imgo
    STA imop
    LDA #20 : STA tries
.imgo1
    LDA imop : STA imcb
    LDX #LO(imcb) : LDY #HI(imcb) : LDA #&10 : JSR OSWORD
    LDA imcb : BNE imgo2
    \ Another transmission's under way: try again.
    DEC tries : BNE imgo1
    LDA #&FF : RTS
.imgo2
    LDA #&32 : JSR OSBYTE
    TXA : BMI imgo2
    RTS

\ What's poked to STUB and called there: it can't use absolute addresses
\ of its own but by STUB's.
.stub
    LDA #0 : STA STUB+stubi-stub
.stub1
    LDX STUB+stubi-stub
    LDY STUB+stubtext-stub,X : BEQ stub2
    LDA #&8A : LDX #0 : JSR OSBYTE
    INC STUB+stubi-stub : BNE stub1
.stub2
    RTS
.stubi EQUB 0
.stubtext EQUS "*NET", 13, "*I AM GUEST", 13, "*WORKER", 13, 0
.stubend

\ The hand-off: coordinator, nonce (4), launcher, 'W' (as at &70-&76).
.rhand  SKIP 7
.imop   EQUB 0
.imcb   SKIP 16
.imtype SKIP 4
