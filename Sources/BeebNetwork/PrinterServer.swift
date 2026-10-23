import BeebCore
import Foundation

/// MacBeeb's Econet printer server: a BBC BASIC program for a station
/// (235, usually) with a printer on its printer port. Acorn's own printer
/// server isn't bundled, so this one speaks the protocol Acorn's network
/// filing systems use to print (as PiEconetBridge's printer server, GPLv3,
/// documents it): a status query on port &9F answered on &9E, and the job
/// in packets on port &D1, each answered with one byte on &D1 with the same
/// control byte. The control byte's bit 0 alternates, so a packet sent
/// twice is printed once; &82/&83 starts a job (its one byte isn't printed)
/// and &86/&87 ends it (its last byte isn't printed either: it's the VDU 3). It runs on the station's own BBC, through its own
/// network filing system, so everything on the line is genuine.
public enum PrinterServer {
    public static let program = """
    10 REM MacBeeb Econet printer server
    20 REM Prints what stations send it on its printer port
    30 REM (The printer is the parallel one, as at power on.)
    40 *FX6,0
    50 MODE 7
    60 DIM B% 300,C% 20,Q% 20,R% 12,T% 20,E%(255)
    70 PRINT "MacBeeb printer server"
    80 PRINT "Printing to the printer port"
    90 J%=-1:PROCdata:PROCquery
    100 PRINT "Ready"
    110 REPEAT
    120 A%=&33:X%=N%:U%=USR(&FFF4):IF U% AND &8000 PROCpacket
    130 A%=&33:X%=M%:U%=USR(&FFF4):IF U% AND &8000 PROCstatus
    140 UNTIL FALSE
    150 DEF PROCdata
    160 C%?0=0:C%?1=&7F:C%?2=&D1:C%?3=0:C%?4=0:C%!5=B%:C%!9=B%+256
    170 X%=C%:Y%=C% DIV 256:A%=&11:CALL &FFF1:N%=C%?0
    180 ENDPROC
    190 DEF PROCquery
    200 Q%?0=0:Q%?1=&7F:Q%?2=&9F:Q%?3=0:Q%?4=0:Q%!5=R%:Q%!9=R%+12
    210 X%=Q%:Y%=Q% DIV 256:A%=&11:CALL &FFF1:M%=Q%?0
    220 ENDPROC
    230 DEF PROCsend(K%,P%,S%,W%,A,L%)
    240 T%?0=K%:T%?1=P%:T%?2=S%:T%?3=W%:T%!4=A:T%!8=A+L%
    250 X%=T%:Y%=T% DIV 256:A%=&10:CALL &FFF1
    260 REPEAT:A%=&32:U%=USR(&FFF4):UNTIL (U% AND &8000)=0
    270 ENDPROC
    280 DEF PROCpacket
    290 C%?0=N%:X%=C%:Y%=C% DIV 256:A%=&11:CALL &FFF1
    300 K%=C%?1 OR &80:S%=C%?3:W%=C%?4:L%=C%!9-B%
    310 IF J%<>-1 AND J%<>S% PROCdata:ENDPROC
    320 IF (K% AND &FE)=&82 E%(S%)=K% AND 1:J%=S%:PRINT "Job from station ";S%
    330 IF J%=-1 J%=S%:E%(S%)=K% AND 1:PRINT "Job from station ";S%
    340 PROCsend(K%,&D1,S%,W%,B%,1)
    350 IF (K% AND 1)<>E%(S%) PROCdata:ENDPROC
    360 E%(S%)=E%(S%) EOR 1
    370 IF (K% AND &FE)=&86 L%=L%-1
    375 IF (K% AND &FE)=&82 L%=0
    380 IF L%>0 FOR I%=0 TO L%-1:VDU 2,1,B%?I%,3:NEXT
    390 IF (K% AND &FE)=&86 PRINT "Printed":J%=-1
    400 PROCdata
    410 ENDPROC
    420 DEF PROCstatus
    430 Q%?0=M%:X%=Q%:Y%=Q% DIV 256:A%=&11:CALL &FFF1
    440 S%=Q%?3:W%=Q%?4
    450 R%?0=-(J%<>-1 AND J%<>S%):R%?1=0:R%?2=0
    460 PROCsend(&80,&9E,S%,W%,R%,3)
    470 PROCquery
    480 ENDPROC
    """

    /// A DFS disc with the server on it, booting it (Shift-Break).
    public static func disc() throws -> [UInt8] {
        var volume = try DiscVolume(disc: Disc.fromImage(BlankDisc.dfs40.image(title: "PRINTSERVER"), format: .ssd))
        let basic = try BBCBasic.tokenise(program)
        try volume.save(at: .init(), name: "PSERV", loadAddress: 0xFF1900, executionAddress: 0xFF8023, contents: basic)
        try volume.save(at: .init(), name: "!BOOT", loadAddress: 0, executionAddress: 0,
                        contents: Array("CHAIN \"PSERV\"\r".utf8))
        volume.setBootOption(3)
        return volume.image
    }
}
