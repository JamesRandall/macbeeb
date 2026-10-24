// What each immediate operation puts on the line between two DNFS
// stations: who sends each frame (ECONET_DEBUG=1 prints it).

import Foundation
import Testing
@testable import BeebCore

struct EconetImmediateTrace {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ECONET_DEBUG"] != nil),
          arguments: [0x81, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88])
    func immediate(control: Int) {
        let rig = EconetRig([(.modelB, 1), (.modelB, 2)])
        let trace = EconetTrace()
        rig.bus.observer = { trace.observe($0) }
        rig.run(seconds: 1.5)
        rig.machines[1].poke(0x0D63, 0)
        rig.runProgram(0, """
        10 C%=&3100:?C%=\(control):C%?1=0:C%?2=2:C%?3=0:C%!4=&FFFF3000:C%!8=&FFFF3010:C%!12=&FFFF0A00
        20 X%=C%:Y%=C% DIV 256:A%=&10:CALL &FFF1
        30 REPEAT A%=&32:U%=USR&FFF4:UNTIL (U%AND&8000)=0
        40 PRINT "RESULT ";(U% DIV 256) AND 255
        """)
        rig.run(until: { rig.screen(0).contains("RESULT") }, seconds: 5)
        let lines = trace.frames.map { f in
            "\(f.transmitter) -> \(f.destinationStation ?? 0): \(f.bytes.count) bytes \(f.bytes.prefix(16).map { String(format: "%02X", $0) }.joined(separator: " "))"
        }
        print("OP \(String(format: "%02X", control)):\n" + lines.joined(separator: "\n") + "\n" + (rig.screen(0).split(separator: "\n").last.map(String.init) ?? ""))
    }
}
