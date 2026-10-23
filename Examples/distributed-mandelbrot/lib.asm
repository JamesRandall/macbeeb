\ Distributed Mandelbrot: Econet and printing routines, included in each
\ program's own scope. Econet is the network filing system's own calls:
\ OSWORD &10 (transmit), &11 (receive blocks), &13 (station numbers) and
\ OSBYTE &32-&34 (poll and delete).

\ mystn := this station.
.getstn
    LDA #8 : JSR ow13
    LDA ow13b+1 : STA mystn
    RTS

\ fsstn, psstn := the file server's and printer server's stations.
.getservers
    LDA #0 : JSR ow13
    LDA ow13b+1 : STA fsstn
    LDA #2 : JSR ow13
    LDA ow13b+1 : STA psstn
    RTS

.ow13
    STA ow13b
    LDX #LO(ow13b) : LDY #HI(ow13b) : LDA #&13 : JMP OSWORD

\ clk := the MOS clock, in centiseconds (5 bytes).
.now
    LDX #LO(clk) : LDY #HI(clk) : LDA #1 : JMP OSWORD

\ el := clk - (tm), 16 bits (call now first).
.elapsed
    SEC
    LDY #0 : LDA clk : SBC (tm),Y : STA el
    INY : LDA clk+1 : SBC (tm),Y : STA el+1
    RTS

\ Sends the frame at ptr (header and payload) to station A, port X.
\ Returns its result in A, zero (and Z set) if it was taken.
.send
    STA txcb+2 : STX txcb+1
    LDA #0 : STA txcb+3
    LDA ptr : STA txcb+4 : LDA ptr+1 : STA txcb+5
    LDA #&FF : STA txcb+6 : STA txcb+7 : STA txcb+10 : STA txcb+11
    LDY #12 : LDA (ptr),Y : CLC : ADC #HEADER
    ADC ptr : STA txcb+8 : LDA ptr+1 : ADC #0 : STA txcb+9
    LDA #20 : STA tries
.sendgo
    LDA #&80 : STA txcb
    LDX #LO(txcb) : LDY #HI(txcb) : LDA #&10 : JSR OSWORD
    LDA txcb : BNE sendpoll
    \ Another transmission's under way: try again.
    DEC tries : BNE sendgo
    LDA #&FF : RTS
.sendpoll
    LDA #&32 : JSR OSBYTE
    TXA : BMI sendpoll
    RTS

\ Writes a header at ptr: type A, payload length plen, the run runid.
.hdr
    LDY #3 : STA (ptr),Y
    LDY #0 : LDA #'M' : STA (ptr),Y
    INY : LDA #'B' : STA (ptr),Y
    INY : LDA #1 : STA (ptr),Y
    LDY #4 : LDX #0
.hdr1
    LDA runid,X : STA (ptr),Y
    INY : INX : CPX #4 : BNE hdr1
    INC msgid : BNE hdr2 : INC msgid+1
.hdr2
    LDA msgid : STA (ptr),Y
    INY : LDA msgid+1 : STA (ptr),Y
    INY : LDA mystn : STA (ptr),Y
    INY : LDA #0 : STA (ptr),Y
    INY : LDA plen : STA (ptr),Y
    INY : LDA #0 : STA (ptr),Y
    RTS

\ The same for the management ports, whose run is 0.
.mhdr
    JSR hdr
    LDA #0 : LDY #4 : STA (ptr),Y : INY : STA (ptr),Y : INY : STA (ptr),Y : INY : STA (ptr),Y
    RTS

\ Opens a receive block on port A, from any station, into the FRAME
\ bytes at ptr. Returns its number in A (0: none could be opened).
.openrx
    STA rxcb+2
    LDA #0 : STA rxcb : STA rxcb+3 : STA rxcb+4
    LDA #&7F : STA rxcb+1
    LDA ptr : STA rxcb+5 : CLC : ADC #FRAME : STA rxcb+9
    LDA ptr+1 : STA rxcb+6 : ADC #0 : STA rxcb+10
    LDA #&FF : STA rxcb+7 : STA rxcb+8 : STA rxcb+11 : STA rxcb+12
    LDX #LO(rxcb) : LDY #HI(rxcb) : LDA #&11 : JSR OSWORD
    LDA rxcb
    RTS

\ N set if receive block X has had a frame.
.pollrx
    LDA #&33 : JSR OSBYTE
    TXA
    RTS

\ Reads receive block X (which frees it): rxstn, rxlen.
.readrx
    STX rxcb
    LDX #LO(rxcb) : LDY #HI(rxcb) : LDA #&11 : JSR OSWORD
    LDA rxcb+3 : STA rxstn
    SEC : LDA rxcb+9 : SBC rxcb+5 : STA rxlen
    RTS

\ Deletes receive block X.
.delrx
    LDA #&34 : JMP OSBYTE

\ Checks the frame at ptr, rxlen long: C clear and its type in A (and
\ its payload length in plen) if it's well formed.
.check
    LDA rxlen : CMP #HEADER : BCC checkbad
    LDY #0 : LDA (ptr),Y : CMP #'M' : BNE checkbad
    INY : LDA (ptr),Y : CMP #'B' : BNE checkbad
    INY : LDA (ptr),Y : CMP #1 : BNE checkbad
    LDY #13 : LDA (ptr),Y : BNE checkbad
    DEY : LDA (ptr),Y : STA plen
    CLC : ADC #HEADER : BCS checkbad
    CMP rxlen : BNE checkbad
    LDY #3 : LDA (ptr),Y
    CLC
    RTS
.checkbad
    SEC
    RTS

\ Z set if the frame at ptr is in run runid.
.samerun
    LDY #4 : LDX #0
.samerun1
    LDA (ptr),Y : CMP runid,X : BNE samerun2
    INY : INX : CPX #4 : BNE samerun1
.samerun2
    RTS

\ Prints the zero-terminated string after the JSR (13 is a new line).
.pstr
    PLA : STA sptr : PLA : STA sptr+1
.pstr1
    INC sptr : BNE pstr2 : INC sptr+1
.pstr2
    LDY #0 : LDA (sptr),Y : BEQ pstr3
    JSR OSASCI
    JMP pstr1
.pstr3
    LDA sptr+1 : PHA : LDA sptr : PHA
    RTS

\ Sends the VDU codes after the JSR: a count, then the codes.
.vdus
    PLA : STA sptr : PLA : STA sptr+1
    LDY #1 : LDA (sptr),Y : STA vdun
.vdus1
    INY : LDA (sptr),Y : JSR OSWRCH
    DEC vdun : BNE vdus1
    TYA : CLC : ADC sptr : STA sptr : BCC vdus2 : INC sptr+1
.vdus2
    LDA sptr+1 : PHA : LDA sptr : PHA
    RTS

\ Moves the text cursor to X, Y.
.tab
    LDA #31 : JSR OSWRCH
    TXA : JSR OSWRCH
    TYA : JMP OSWRCH

\ Prints A as two hex digits.
.phex
    PHA
    LSR A : LSR A : LSR A : LSR A : JSR phex1
    PLA : AND #15
.phex1
    CMP #10 : BCC phex2 : ADC #6
.phex2
    ADC #'0' : JMP OSWRCH

\ Prints a station: at least two digits.
.pstn
    CMP #10 : BCS pdec8
    PHA : LDA #'0' : JSR OSWRCH : PLA
\ Prints A in decimal.
.pdec8
    LDX #0
\ Prints X:A in decimal.
.pdec16
    STA num : STX num+1
    LDA #0 : STA num+2 : STA num+3
\ Prints the 32 bits at num in decimal (num is used up).
.pdec32
    LDA #0 : STA nz
    LDX #0
.pdec1
    LDA #0 : STA dig
.pdec2
    SEC
    LDA num : SBC pow10,X : STA t4
    LDA num+1 : SBC pow10+1,X : STA t4+1
    LDA num+2 : SBC pow10+2,X : STA t4+2
    LDA num+3 : SBC pow10+3,X : BCC pdec3
    STA num+3 : LDA t4+2 : STA num+2 : LDA t4+1 : STA num+1 : LDA t4 : STA num
    INC dig : JMP pdec2
.pdec3
    LDA dig : ORA nz : BEQ pdec4
    LDA dig : ORA #'0' : JSR OSWRCH
    LDA #1 : STA nz
.pdec4
    INX : INX : INX : INX : CPX #36 : BNE pdec1
    LDA num : ORA #'0' : JMP OSWRCH
.pow10
    EQUD 1000000000, 100000000, 10000000, 1000000, 100000, 10000, 1000, 100, 10

\ Prints A spaces.
.spaces
    TAX
.spaces1
    LDA #' ' : JSR OSWRCH
    DEX : BNE spaces1
    RTS

\ The library's workspace.
.mystn  EQUB 0
.fsstn  EQUB 0
.psstn  EQUB 0
.runid  EQUD 0
.msgid  EQUW 0
.plen   EQUB 0
.rxstn  EQUB 0
.rxlen  EQUB 0
.tries  EQUB 0
.vdun   EQUB 0
.clk    SKIP 5
.el     EQUW 0
.num    SKIP 4
.t4     SKIP 3
.dig    EQUB 0
.nz     EQUB 0
.ow13b  SKIP 16
.txcb   SKIP 12
.rxcb   SKIP 13
