// Tube ULA register behaviour, following b2's tube.cpp.

import Foundation
import Testing
@testable import BeebCore

struct TubeTests {
    typealias S = Tube.Status
    static let available = Tube.Flag.available
    static let notFull = Tube.Flag.notFull

    func set(_ tube: inout Tube, _ flags: UInt8) { tube.hostWrite(0, S.s | flags) }
    func clear(_ tube: inout Tube, _ flags: UInt8) { tube.hostWrite(0, flags) }

    // MARK: Reset state

    @Test func powerOnState() {
        let tube = Tube()
        #expect(tube.hostPeek(0) == Self.notFull)
        #expect(tube.hostPeek(2) == Self.notFull)
        // One insignificant byte waits in FIFO 3 parasite to host.
        #expect(tube.hostPeek(4) == Self.available | Self.notFull)
        #expect(tube.hostPeek(6) == Self.notFull)
        #expect(tube.parasitePeek(0) == Self.notFull)
        #expect(tube.parasitePeek(2) == Self.notFull)
        #expect(tube.parasitePeek(4) == 0)
        #expect(tube.parasitePeek(6) == Self.notFull)
        #expect(!tube.hostIRQ && !tube.parasiteIRQ && !tube.parasiteNMI)
        #expect(!tube.parasiteResetRequested && !tube.tubeResetRequested)
    }

    @Test func registersMirrorEveryEightBytes() {
        var tube = Tube()
        tube.hostWrite(0xFEE9, 0x5A)
        #expect(tube.parasiteRead(0xFEF1) == 0x5A)
        tube.parasiteWrite(0xFEFF, 0xA5)
        #expect(tube.hostRead(0xFEFF) == 0xA5)
    }

    // MARK: Status register

    @Test func statusSetAndClear() {
        var tube = Tube()
        set(&tube, S.q | S.j | S.v)
        #expect(tube.status & 0x3F == S.q | S.j | S.v)
        set(&tube, S.m)
        #expect(tube.status & 0x3F == S.q | S.j | S.v | S.m)
        clear(&tube, S.j | S.m)
        #expect(tube.status & 0x3F == S.q | S.v)
        // Clearing flags that aren't set is harmless.
        clear(&tube, S.i)
        #expect(tube.status & 0x3F == S.q | S.v)
    }

    @Test func statusShowsInRegister0OnBothSides() {
        var tube = Tube()
        set(&tube, S.q | S.i | S.m)
        // S itself never shows.
        #expect(tube.hostRead(0) == Self.notFull | S.q | S.i | S.m)
        #expect(tube.parasiteRead(0) == Self.notFull | S.q | S.i | S.m)
        set(&tube, S.p | S.t)
        #expect(tube.hostPeek(0) == Self.notFull | S.q | S.i | S.m | S.p | S.t)
    }

    @Test func otherStatusRegistersDontShowControlFlags() {
        var tube = Tube()
        set(&tube, 0x3F)
        #expect(tube.hostPeek(2) == Self.notFull)
        #expect(tube.hostPeek(6) == Self.notFull)
        #expect(tube.parasitePeek(2) == Self.notFull)
        #expect(tube.parasitePeek(6) == Self.notFull)
    }

    @Test func parasiteCantWriteStatus() {
        var tube = Tube()
        tube.parasiteWrite(0, 0xFF)
        #expect(tube.status == 0)
    }

    // MARK: FIFO 1

    @Test func fifo1HostToParasite() {
        var tube = Tube()
        tube.hostWrite(1, 0x42)
        #expect(tube.hostPeek(0) & Self.notFull == 0)
        #expect(tube.parasitePeek(0) & Self.available != 0)
        #expect(tube.parasiteRead(1) == 0x42)
        #expect(tube.hostPeek(0) == Self.notFull)
        #expect(tube.parasitePeek(0) == Self.notFull)
        // Empty: the latch still holds the old byte.
        #expect(tube.parasiteRead(1) == 0x42)
        #expect(tube.parasitePeek(0) == Self.notFull)
    }

    @Test func fifo1HostToParasiteOverwrites() {
        var tube = Tube()
        tube.hostWrite(1, 0x11)
        tube.hostWrite(1, 0x22)
        #expect(tube.parasiteRead(1) == 0x22)
        #expect(tube.parasitePeek(0) & Self.available == 0)
    }

    @Test func fifo1ParasiteToHostHolds24Bytes() {
        var tube = Tube()
        for i in 0..<23 {
            tube.parasiteWrite(1, UInt8(i))
            #expect(tube.parasitePeek(0) & Self.notFull != 0)
            #expect(tube.hostPeek(0) & Self.available != 0)
        }
        tube.parasiteWrite(1, 23)
        #expect(tube.parasitePeek(0) & Self.notFull == 0)
        // Overrun: dropped.
        tube.parasiteWrite(1, 0xEE)
        for i in 0..<24 {
            #expect(tube.hostRead(1) == UInt8(i))
            #expect(tube.parasitePeek(0) & Self.notFull != 0)
            #expect((tube.hostPeek(0) & Self.available != 0) == (i < 23))
        }
        // Empty: the last byte the parasite wrote, even the dropped one.
        #expect(tube.hostRead(1) == 0xEE)
        #expect(tube.hostPeek(0) == Self.notFull)
    }

    @Test func fifo1ParasiteToHostWraps() {
        var tube = Tube()
        var next: UInt8 = 0
        var expected: UInt8 = 0
        for _ in 0..<5 {
            for _ in 0..<10 { tube.parasiteWrite(1, next); next &+= 1 }
            for _ in 0..<10 { #expect(tube.hostRead(1) == expected); expected &+= 1 }
        }
        #expect(tube.hostPeek(0) & Self.available == 0)
    }

    @Test func fifo1EmptyHostReadIsLastParasiteWriteOnAnyRegister() {
        var tube = Tube()
        tube.parasiteWrite(7, 0x99)
        #expect(tube.hostRead(1) == 0x99)
    }

    // MARK: FIFO 2

    @Test func fifo2HostToParasite() {
        var tube = Tube()
        tube.hostWrite(3, 0x12)
        #expect(tube.hostPeek(2) == 0)
        #expect(tube.parasitePeek(2) == Self.available | Self.notFull)
        tube.hostWrite(3, 0x34)
        #expect(tube.parasiteRead(3) == 0x34)
        #expect(tube.hostPeek(2) == Self.notFull)
        #expect(tube.parasitePeek(2) == Self.notFull)
        #expect(tube.parasiteRead(3) == 0x34)
        #expect(tube.hostPeek(2) == Self.notFull)
    }

    @Test func fifo2ParasiteToHost() {
        var tube = Tube()
        tube.parasiteWrite(3, 0x56)
        #expect(tube.parasitePeek(2) == 0)
        #expect(tube.hostPeek(2) == Self.available | Self.notFull)
        tube.parasiteWrite(3, 0x78)
        #expect(tube.hostRead(3) == 0x78)
        #expect(tube.hostPeek(2) == Self.notFull)
        #expect(tube.parasitePeek(2) == Self.notFull)
        #expect(tube.hostRead(3) == 0x78)
    }

    @Test func fifosAreIndependent() {
        var tube = Tube()
        tube.hostWrite(1, 1)
        tube.hostWrite(3, 2)
        tube.hostWrite(7, 4)
        #expect(tube.parasiteRead(7) == 4)
        #expect(tube.parasiteRead(3) == 2)
        #expect(tube.parasiteRead(1) == 1)
    }

    // MARK: FIFO 4

    @Test func fifo4HostToParasite() {
        var tube = Tube()
        tube.hostWrite(7, 0x9A)
        #expect(tube.hostPeek(6) == 0)
        #expect(tube.parasitePeek(6) == Self.available | Self.notFull)
        #expect(tube.parasiteRead(7) == 0x9A)
        #expect(tube.hostPeek(6) == Self.notFull)
        #expect(tube.parasitePeek(6) == Self.notFull)
    }

    @Test func fifo4ParasiteToHost() {
        var tube = Tube()
        tube.parasiteWrite(7, 0xBC)
        #expect(tube.parasitePeek(6) == 0)
        #expect(tube.hostPeek(6) == Self.available | Self.notFull)
        tube.parasiteWrite(7, 0xDE)
        #expect(tube.hostRead(7) == 0xDE)
        #expect(tube.hostPeek(6) == Self.notFull)
        #expect(tube.parasitePeek(6) == Self.notFull)
    }

    // MARK: FIFO 3

    @Test func fifo3ResetByteAsksForNMIOnceRead() {
        var tube = Tube()
        set(&tube, S.m)
        #expect(!tube.parasiteNMI)
        #expect(tube.hostRead(5) == 0)
        #expect(tube.hostPeek(4) == Self.notFull)
        #expect(tube.parasitePeek(4) == Self.available | Self.notFull)
        #expect(tube.parasiteNMI)
        // Empty: the last byte the parasite wrote.
        tube.parasiteWrite(1, 0x77)
        #expect(tube.hostRead(5) == 0x77)
    }

    @Test func fifo3OneByteHostToParasite() {
        var tube = Tube()
        set(&tube, S.m)
        tube.hostWrite(5, 0x31)
        #expect(tube.hostPeek(4) & Self.notFull == 0)
        #expect(tube.parasitePeek(4) & Self.available != 0)
        #expect(tube.parasiteNMI)
        #expect(tube.parasiteRead(5) == 0x31)
        #expect(!tube.parasiteNMI)
        #expect(tube.hostPeek(4) & Self.notFull != 0)
        #expect(tube.parasitePeek(4) & Self.available == 0)
        // Empty: the last byte the host wrote.
        tube.hostWrite(7, 0x66)
        #expect(tube.parasiteRead(5) == 0x66)
    }

    @Test func fifo3OneByteModeStillQueuesTwo() {
        var tube = Tube()
        set(&tube, S.m)
        tube.hostWrite(5, 0x01)
        tube.hostWrite(5, 0x02)
        tube.hostWrite(5, 0x03)
        #expect(tube.parasiteRead(5) == 0x01)
        #expect(tube.parasiteNMI)
        #expect(tube.parasitePeek(4) & Self.available != 0)
        #expect(tube.parasiteRead(5) == 0x02)
        #expect(!tube.parasiteNMI)
        #expect(tube.parasitePeek(4) & Self.available == 0)
    }

    @Test func fifo3TwoByteHostToParasite() {
        var tube = Tube()
        set(&tube, S.m | S.v)
        tube.hostWrite(5, 0x11)
        #expect(tube.hostPeek(4) & Self.notFull != 0)
        #expect(tube.parasitePeek(4) & Self.available == 0)
        #expect(!tube.parasiteNMI)
        tube.hostWrite(5, 0x22)
        #expect(tube.hostPeek(4) & Self.notFull == 0)
        #expect(tube.parasitePeek(4) & Self.available != 0)
        #expect(tube.parasiteNMI)
        // Overrun: dropped.
        tube.hostWrite(5, 0x33)
        #expect(tube.parasiteRead(5) == 0x11)
        #expect(tube.parasiteNMI)
        #expect(tube.hostPeek(4) & Self.notFull == 0)
        #expect(tube.parasiteRead(5) == 0x22)
        #expect(!tube.parasiteNMI)
        #expect(tube.hostPeek(4) & Self.notFull != 0)
        #expect(tube.parasiteRead(5) == 0x33)
    }

    @Test func fifo3OneByteParasiteToHost() {
        var tube = Tube()
        set(&tube, S.m)
        _ = tube.hostRead(5)
        #expect(tube.parasiteNMI)
        tube.parasiteWrite(5, 0x44)
        #expect(!tube.parasiteNMI)
        #expect(tube.parasitePeek(4) & Self.notFull == 0)
        #expect(tube.hostPeek(4) & Self.available != 0)
        #expect(tube.hostRead(5) == 0x44)
        #expect(tube.parasiteNMI)
        #expect(tube.parasitePeek(4) & Self.notFull != 0)
    }

    @Test func fifo3TwoByteParasiteToHost() {
        var tube = Tube()
        set(&tube, S.m | S.v)
        _ = tube.hostRead(5)
        #expect(tube.parasiteNMI)
        tube.parasiteWrite(5, 0x55)
        #expect(tube.parasiteNMI)
        #expect(tube.hostPeek(4) & Self.available == 0)
        #expect(tube.parasitePeek(4) & Self.notFull != 0)
        tube.parasiteWrite(5, 0x66)
        #expect(!tube.parasiteNMI)
        #expect(tube.hostPeek(4) & Self.available != 0)
        #expect(tube.parasitePeek(4) & Self.notFull == 0)
        tube.parasiteWrite(5, 0x77)
        #expect(tube.hostRead(5) == 0x55)
        #expect(!tube.parasiteNMI)
        #expect(tube.hostPeek(4) & Self.available != 0)
        #expect(tube.hostRead(5) == 0x66)
        #expect(tube.parasiteNMI)
        #expect(tube.hostPeek(4) & Self.available == 0)
        #expect(tube.parasitePeek(4) & Self.notFull != 0)
        #expect(tube.hostRead(5) == 0x77)
    }

    @Test func fifo3TwoByteModeKeepsResetByte() {
        var tube = Tube()
        set(&tube, S.m | S.v)
        // The reset byte counts, so one more parasite write fills it.
        tube.parasiteWrite(5, 0xAB)
        #expect(tube.hostRead(5) == 0)
        #expect(tube.hostRead(5) == 0xAB)
    }

    @Test func nmiNeedsM() {
        var tube = Tube()
        _ = tube.hostRead(5)
        #expect(!tube.parasiteNMI)
        // The request is latched, so M lets it through later.
        set(&tube, S.m)
        #expect(tube.parasiteNMI)
        clear(&tube, S.m)
        #expect(!tube.parasiteNMI)
        // The parasite status register shows the request regardless of M.
        #expect(tube.parasitePeek(4) & Self.available != 0)
    }

    @Test func nmiRequestedAgainWhileStanding() {
        var tube = Tube()
        set(&tube, S.m)
        _ = tube.hostRead(5)
        tube.hostWrite(5, 0x42)
        #expect(tube.parasiteNMI)
        #expect(tube.parasiteRead(5) == 0x42)
        #expect(!tube.parasiteNMI)
    }

    @Test func switchingToTwoByteDoesntRaiseNMIBySelf() {
        var tube = Tube()
        set(&tube, S.m)
        tube.hostWrite(5, 0x01)
        _ = tube.parasiteRead(5)
        set(&tube, S.v)
        #expect(!tube.parasiteNMI)
    }

    // MARK: Interrupts

    @Test func hostIRQFromFIFO4WithQ() {
        var tube = Tube()
        tube.parasiteWrite(7, 1)
        #expect(!tube.hostIRQ)
        set(&tube, S.q)
        #expect(tube.hostIRQ)
        _ = tube.hostRead(7)
        #expect(!tube.hostIRQ)
        tube.parasiteWrite(7, 2)
        #expect(tube.hostIRQ)
        clear(&tube, S.q)
        #expect(!tube.hostIRQ)
    }

    @Test func hostIRQIgnoresOtherFIFOs() {
        var tube = Tube()
        set(&tube, S.q)
        tube.parasiteWrite(1, 1)
        tube.parasiteWrite(3, 1)
        tube.parasiteWrite(5, 1)
        tube.hostWrite(7, 1)
        #expect(!tube.hostIRQ)
    }

    @Test func parasiteIRQFromFIFO1WithI() {
        var tube = Tube()
        tube.hostWrite(1, 1)
        #expect(!tube.parasiteIRQ)
        set(&tube, S.i)
        #expect(tube.parasiteIRQ)
        _ = tube.parasiteRead(1)
        #expect(!tube.parasiteIRQ)
        tube.hostWrite(1, 2)
        set(&tube, S.j)
        clear(&tube, S.i)
        #expect(!tube.parasiteIRQ)
    }

    @Test func parasiteIRQFromFIFO4WithJ() {
        var tube = Tube()
        tube.hostWrite(7, 1)
        #expect(!tube.parasiteIRQ)
        set(&tube, S.i)
        #expect(!tube.parasiteIRQ)
        set(&tube, S.j)
        #expect(tube.parasiteIRQ)
        _ = tube.parasiteRead(7)
        #expect(!tube.parasiteIRQ)
    }

    @Test func parasiteIRQFromBothSources() {
        var tube = Tube()
        set(&tube, S.i | S.j)
        tube.hostWrite(1, 1)
        tube.hostWrite(7, 1)
        _ = tube.parasiteRead(1)
        #expect(tube.parasiteIRQ)
        _ = tube.parasiteRead(7)
        #expect(!tube.parasiteIRQ)
    }

    @Test func parasiteIRQIgnoresOtherFIFOs() {
        var tube = Tube()
        set(&tube, S.i | S.j)
        tube.hostWrite(3, 1)
        tube.hostWrite(5, 1)
        tube.parasiteWrite(1, 1)
        tube.parasiteWrite(7, 1)
        #expect(!tube.parasiteIRQ)
    }

    // MARK: Reset bits

    @Test func resetRequestBits() {
        var tube = Tube()
        set(&tube, S.p)
        #expect(tube.parasiteResetRequested && !tube.tubeResetRequested)
        set(&tube, S.t)
        #expect(tube.parasiteResetRequested && tube.tubeResetRequested)
        clear(&tube, S.p | S.t)
        #expect(!tube.parasiteResetRequested && !tube.tubeResetRequested)
    }

    @Test func resetEmptiesFIFOsButKeepsStatus() {
        var tube = Tube()
        set(&tube, S.q | S.i | S.j | S.m | S.t)
        tube.hostWrite(1, 1)
        tube.hostWrite(3, 1)
        tube.hostWrite(5, 1)
        tube.hostWrite(7, 1)
        for _ in 0..<5 { tube.parasiteWrite(1, 1) }
        tube.parasiteWrite(3, 1)
        tube.parasiteWrite(7, 1)
        #expect(tube.hostIRQ && tube.parasiteIRQ && tube.parasiteNMI)
        tube.reset()
        #expect(!tube.hostIRQ && !tube.parasiteIRQ && !tube.parasiteNMI)
        #expect(tube.tubeResetRequested)
        #expect(tube.hostPeek(0) == Self.notFull | S.q | S.i | S.j | S.m | S.t)
        #expect(tube.hostPeek(2) == Self.notFull)
        #expect(tube.hostPeek(4) == Self.available | Self.notFull)
        #expect(tube.hostPeek(6) == Self.notFull)
        #expect(tube.parasitePeek(2) == Self.notFull)
        #expect(tube.parasitePeek(4) == 0)
        #expect(tube.parasitePeek(6) == Self.notFull)
    }

    @Test func resetRefillsEmptyFIFO3WithLastParasiteByte() {
        var tube = Tube()
        _ = tube.hostRead(5)
        tube.parasiteWrite(3, 0x5C)
        tube.reset()
        #expect(tube.hostRead(5) == 0x5C)

        // A byte still waiting is kept.
        tube = Tube()
        _ = tube.hostRead(5)
        tube.parasiteWrite(5, 0x6D)
        tube.parasiteWrite(3, 0x7E)
        tube.reset()
        #expect(tube.hostRead(5) == 0x6D)
    }

    // MARK: Peek and Codable

    @Test func peeksHaveNoSideEffects() {
        var tube = Tube()
        set(&tube, S.q | S.i | S.j | S.m | S.v)
        tube.hostWrite(1, 1)
        tube.hostWrite(3, 2)
        tube.hostWrite(5, 3)
        tube.hostWrite(7, 4)
        tube.parasiteWrite(1, 5)
        tube.parasiteWrite(1, 6)
        tube.parasiteWrite(3, 7)
        tube.parasiteWrite(5, 8)
        tube.parasiteWrite(7, 9)
        let before = tube
        let host = (0..<8).map { tube.hostPeek($0) }
        let parasite = (0..<8).map { tube.parasitePeek($0) }
        #expect(tube == before)
        #expect(host == [Self.available | S.q | S.i | S.j | S.m | S.v,
                         5, Self.available, 7, Self.available | Self.notFull, 0, Self.available, 9])
        #expect(parasite == [Self.available | Self.notFull | S.q | S.i | S.j | S.m | S.v,
                             1, Self.available, 2, 0, 3, Self.available, 4])
        // Reads return what the peeks said.
        #expect((0..<8).map { tube.hostRead($0) } == host)
        tube = before
        #expect((0..<8).map { tube.parasiteRead($0) } == parasite)
    }

    @Test func codableRoundTrip() throws {
        var tube = Tube()
        set(&tube, S.q | S.m | S.v)
        for i in 0..<30 { tube.parasiteWrite(1, UInt8(i)) }
        for _ in 0..<7 { _ = tube.hostRead(1) }
        tube.hostWrite(5, 0x12)
        tube.parasiteWrite(7, 0x34)
        let data = try JSONEncoder().encode(tube)
        var decoded = try JSONDecoder().decode(Tube.self, from: data)
        #expect(decoded == tube)
        #expect(decoded.hostIRQ && !decoded.parasiteNMI)
        #expect(decoded.hostRead(1) == 7)
    }
}
