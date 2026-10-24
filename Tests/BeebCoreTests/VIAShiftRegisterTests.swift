// The 6522's shift register, in the modes clocked by phi2.

import Testing
@testable import BeebCore

struct VIAShiftRegisterTests {
    private func tick(_ via: inout VIA6522, _ cycles: Int) {
        for _ in 0..<cycles {
            _ = via.updatePhi2TrailingEdge()
            _ = via.updatePhi2LeadingEdge()
        }
    }

    /// Mode 2 (in under phi2): a read starts eight shifts, then the SR
    /// interrupt; reading again clears it. NFS relies on this to run a
    /// remote JSR.
    @Test func shiftInUnderPhi2Interrupts() {
        var via = VIA6522()
        via.write(0xE, 0x84)
        via.write(0xB, 0x08)
        _ = via.read(0xA)
        tick(&via, 7)
        #expect(via.read(0xD) & 0x04 == 0)
        tick(&via, 1)
        #expect(via.read(0xD) == 0x84)
        _ = via.read(0xA)
        #expect(via.read(0xD) & 0x04 == 0)
    }

    /// Mode 6 (out under phi2): a write starts it, and eight shifts bring
    /// the byte round again.
    @Test func shiftOutUnderPhi2() {
        var via = VIA6522()
        via.write(0xB, 0x18)
        via.write(0xA, 0xA5)
        tick(&via, 8)
        #expect(via.read(0xD) & 0x04 != 0)
        #expect(via.peek(0xA) == 0xA5)
    }

    /// Disabled (mode 0), it's a plain register and never interrupts.
    @Test func disabledIsALatch() {
        var via = VIA6522()
        via.write(0xA, 0x5A)
        tick(&via, 20)
        #expect(via.read(0xA) == 0x5A)
        #expect(via.read(0xD) & 0x04 == 0)
    }
}
