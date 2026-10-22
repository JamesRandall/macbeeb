// Tokenising BBC BASIC text as BASIC 2 does, checked against BASIC itself:
// the same lines typed in on a Model B.

import Foundation
import Testing
@testable import BeebCore
import BeebROMs

struct BBCBasicTests {
    /// Lines that exercise the tokeniser's rules.
    static let program = """
        10 REM A test of the tokeniser: PRINT "not" here
        20 MODE 7:CLS:PRINT "PRINT in a string";TAB(3);CHR$(129)
        30 TIME=0:A=TIME:PAGE=&1900:HIMEM=HIMEM-&100
        40 IF A=0 THEN 60 ELSE GOTO 70
        50 ON X GOTO 100,200,300 ELSE PRINT
        60 PROCPRINT:DEF PROCPRINT:ENDPROC
        70 X=FNTOTAL(3):DEF FNTOTAL(N)=N*2
        80 TOP=1:PRINT TOP:ENDX=1:TRUEX=2:PRINTER=3
        90 FOR I%=1 TO 10 STEP 2:NEXT
        100 DATA 1,2,PRINT,"THREE"
        110 *FX 200,3
        120 VDU 23,1,0;0;0;0;:ENDPROC
        130 GOSUB 1000:RESTORE 100:RETURN
        140 a=1E5:b=.5:c=1.25E-3:lower=2:Mixed_Case=3
        150 X=INKEY$(10)+GET$:Y=INSTR(A$,"B"):Z$=LEFT$(A$,2)+MID$(A$,2)+RIGHT$(A$,1)
        160 REPEAT UNTIL TRUE:REPEAT:UNTIL FALSE
        170 LET TIME=5:PRINT ~PTR#F:PTR#F=0
        180 ON ERROR REPORT:PRINT " at line ";ERL:END
        190 IF X THEN TIME=1
        200 IF X THEN PRINT ELSE TIME=2
        210 OSCLI "CAT":SOUND 1,-15,53,20:ENVELOPE 1,1,0,0,0,0,0,0,126,0,0,-126,126,126
        220 COLOUR 1:GCOL 0,1:PLOT 85,0,0:DRAW 10,10:MOVE 0,0:POINT(1,2):CLG
        230 X=OPENIN "F":Y=OPENOUT "G":Z=OPENUP "H":CLOSE#X:BPUT#Y,1:Q=BGET#Z:E=EOF#Z
        240 X=ABS-1+ACS 1+ASN 1+ATN 1+COS 1+SIN 1+TAN 1+EXP 1+LN 1+LOG 1+SQR 1+DEG 1+RAD 1+SGN 1+INT 1
        250 X=RND(10)+RND+PI+POS+VPOS+COUNT+LEN"A"+ASC"A"+VAL"1"+EVAL"1"+USR&FFE0+ADVAL 1
        260 X=1 AND 2 OR 3 EOR 4 DIV 5 MOD 6:IF NOT X THEN STOP
        270 DIM A(10),B% 20:LOCAL X:CALL &FFEE:CHAIN "X":WIDTH 40:TRACE OFF:TRACE 100
        280 PRINT STR$(1)+STRING$(3,"A");SPC(2):INPUT LINE A$:READ A
        290 X=EXT#Y:CLEAR:CLOSE#0:LOMEM=LOMEM
        """

    /// The program as BASIC tokenises it, typed into a Model B.
    func tokenisedByBASIC(_ text: String) -> [UInt8] {
        let machine = BBCMicro(configuration: BeebROMs.configuration(for: .modelB))
        #expect(machine.runUntilIdle())
        machine.paste(text + "\n")
        #expect(machine.runUntilIdle(maxSeconds: 120))
        let page = UInt16(machine.peek(0x18)) << 8
        let top = UInt16(machine.peek(0x12)) | UInt16(machine.peek(0x13)) << 8
        return (page..<top).map { machine.peek($0) }
    }

    @Test func tokenisesAsBASICDoes() throws {
        let ours = try BBCBasic.tokenise(Self.program)
        let basics = tokenisedByBASIC(Self.program)
        // All 29 lines went in.
        #expect(lines(basics).count == 29 && basics.count > 900, "\(lines(basics).count) lines, \(basics.count) bytes")
        // Line by line, for a readable difference.
        let ourLines = lines(ours), theirLines = lines(basics)
        #expect(ourLines.count == theirLines.count)
        for (a, b) in zip(ourLines, theirLines) where a != b {
            Issue.record("line \(Int(b[1]) << 8 | Int(b[2])): ours \(hex(a)) BASIC's \(hex(b))")
        }
        #expect(ours == basics)
    }

    @Test func listsWhatItTokenises() throws {
        let program = try BBCBasic.tokenise(Self.program)
        #expect(BBCBasic.isProgram(program))
        #expect(BBCBasic.list(program) == Self.program + "\n")
        #expect(BBCBasic.list(program, padded: true).hasPrefix("   10 REM A test"))
    }

    @Test func lineNumbers() throws {
        for n in [0, 1, 63, 64, 255, 256, 1000, 16383, 16384, 32767] {
            let e = BBCBasic.encodeLineNumber(n)
            #expect(BBCBasic.decodeLineNumber(e[0], e[1], e[2]) == n)
        }
        // Unnumbered lines follow on in tens.
        let program = try BBCBasic.tokenise("PRINT 1\n\n  PRINT 2\n100 PRINT 3\nPRINT 4")
        #expect(BBCBasic.list(program) == "10PRINT 1\n20PRINT 2\n100 PRINT 3\n110PRINT 4\n")
        #expect(throws: BBCBasic.Error.badLineNumber(line: 1)) { try BBCBasic.tokenise("40000 PRINT") }
    }

    func lines(_ program: [UInt8]) -> [[UInt8]] {
        var result: [[UInt8]] = []
        var i = 0
        while i + 3 < program.count, program[i] == 0x0D, program[i + 1] != 0xFF {
            let length = Int(program[i + 3])
            guard length >= 4 else { break }
            result.append(Array(program[i..<min(i + length, program.count)]))
            i += length
        }
        return result
    }

    func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}
