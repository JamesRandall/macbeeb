// The WD1770 driven through its registers as DFS 2.26 and ADFS do it,
// against discs built from .ssd and ADFS images.

import Testing
@testable import BeebCore

/// A 1770 with a DFS/ADFS-style NMI service: each data request moves a
/// byte, the completion interrupt reads the status.
final class WDHost {
    static let busy: UInt8 = 0x01

    let fdc: WD1770
    let layout: WD1770.ControlLayout
    var received: [UInt8] = []
    var toSend: [UInt8] = []
    /// Ignore data requests, as a too-slow NMI handler would.
    var ignoreData = false
    /// End a multi-sector read with a force interrupt after this many
    /// bytes, as the filing systems do; a multi-sector write ends at the
    /// data request after `toSend` runs out.
    var readLimit: Int?
    var endWriteWhenSent = false
    var completionStatus: UInt8?
    var lastNMI = false

    init(variant: WD1770.Variant = .wd1770, layout: WD1770.ControlLayout = .acorn1770, _ discs: Disc?...) {
        fdc = WD1770(variant: variant)
        self.layout = layout
        for (drive, disc) in discs.enumerated() { fdc.drives[drive].insert(disc) }
        select()
    }

    /// The latch value for a drive, side and density in this host's layout.
    static func controlValue(_ layout: WD1770.ControlLayout, drive: Int, upper: Bool, doubleDensity: Bool) -> UInt8 {
        switch layout {
        case .acorn1770:
            return 0x20 | (drive == 0 ? 0x01 : 0x02) | (upper ? 0x04 : 0) | (doubleDensity ? 0 : 0x08)
        case .master128:
            return 0x04 | (drive == 0 ? 0x01 : 0x02) | (upper ? 0x10 : 0) | (doubleDensity ? 0 : 0x20)
        case .watfordDDB2:
            return (drive == 0 ? 0 : 0x04) | (upper ? 0x02 : 0) | (doubleDensity ? 0 : 0x01)
        case .watfordDDB3:
            return controlValue(.acorn1770, drive: drive, upper: upper, doubleDensity: doubleDensity)
        case .opus:
            return (drive == 0 ? 0 : 0x01) | (upper ? 0x02 : 0) | (doubleDensity ? 0x40 : 0)
        }
    }

    func select(drive: Int = 0, upper: Bool = false, doubleDensity: Bool = false) {
        fdc.writeControl(Self.controlValue(layout, drive: drive, upper: upper, doubleDensity: doubleDensity),
                         layout: layout)
    }

    func step() {
        fdc.tick()
        if fdc.nmi && !lastNMI { serviceNMI() }
        lastNMI = fdc.nmi
    }

    private func serviceNMI() {
        if fdc.drq {
            guard !ignoreData else { return }
            if toSend.isEmpty {
                if endWriteWhenSent {
                    fdc.write(0, 0xD0)
                    return
                }
                received.append(fdc.read(3))
                if let readLimit, received.count == readLimit { fdc.write(0, 0xD0) }
            } else {
                fdc.write(3, toSend.removeFirst())
            }
        } else if fdc.intrq {
            completionStatus = fdc.read(0)
        }
    }

    func run(us: Int) {
        for _ in 0..<us { step() }
    }

    /// Sends a command and runs until it's done; returns the final status.
    @discardableResult
    func command(_ command: UInt8, timeoutUs: Int = 10_000_000) -> UInt8 {
        completionStatus = nil
        fdc.write(0, command)
        var elapsed = 0
        while fdc.peek(0) & Self.busy != 0 && elapsed < timeoutUs {
            step()
            elapsed += 1
        }
        return completionStatus ?? fdc.peek(0)
    }

    @discardableResult
    func seek(_ track: UInt8, rate: UInt8 = 0) -> UInt8 {
        fdc.write(3, track)
        return command(0x10 | rate)
    }

    func read(track: UInt8, sector: UInt8) -> (status: UInt8, data: [UInt8]) {
        seek(track)
        received = []
        fdc.write(2, sector)
        let status = command(0x80)
        return (status, received)
    }

    /// A multi-sector read of `count` sectors, ended by force interrupt.
    func read(track: UInt8, sector: UInt8, count: Int, sectorSize: Int = 256) -> (status: UInt8, data: [UInt8]) {
        seek(track)
        received = []
        readLimit = count * sectorSize
        defer { readLimit = nil }
        fdc.write(2, sector)
        let status = command(0x90)
        return (status, received)
    }

    func write(track: UInt8, sector: UInt8, _ data: [UInt8], deleted: Bool = false) -> UInt8 {
        seek(track)
        toSend = data
        defer { toSend = [] }
        fdc.write(2, sector)
        return command(deleted ? 0xA1 : 0xA0)
    }

    /// A multi-sector write, ended by force interrupt.
    func writeMulti(track: UInt8, sector: UInt8, _ data: [UInt8]) -> UInt8 {
        seek(track)
        toSend = data
        endWriteWhenSent = true
        defer {
            toSend = []
            endWriteWhenSent = false
        }
        fdc.write(2, sector)
        return command(0xB0)
    }

    func readAddress() -> (status: UInt8, id: [UInt8]) {
        received = []
        let status = command(0xC0)
        return (status, received)
    }
}

enum WDStatus {
    static let motorOn: UInt8 = 0x80
    static let writeProtected: UInt8 = 0x40
    static let deletedMark: UInt8 = 0x20
    static let recordNotFound: UInt8 = 0x10
    static let crcError: UInt8 = 0x08
    static let track0: UInt8 = 0x04
    static let lostByte: UInt8 = 0x04
    /// Everything a good type II command leaves bar the motor.
    static let errors: UInt8 = 0x7D
}

/// An ADFS image with a recognisable byte everywhere.
func adfsImage(doubleSided: Bool) -> [UInt8] {
    (0..<(doubleSided ? 2 : 1) * 80 * 16 * 256).map { UInt8(truncatingIfNeeded: $0 / 256 &* 13 &+ $0) }
}

struct WD1770Tests {
    static let sectorSize = 256
    static let trackSize = 2560

    func image(_ name: String) throws -> [UInt8] {
        try testResource("discs/\(name)")
    }

    func sectors(_ image: [UInt8], track: Int, sector: Int, count: Int) -> [UInt8] {
        let start = track * Self.trackSize + sector * Self.sectorSize
        return (start..<start + count * Self.sectorSize).map { $0 < image.count ? image[$0] : 0 }
    }

    /// ADFS sectors, by track, side and sector.
    func adfsSectors(_ image: [UInt8], sides: Int, track: Int, side: Int, sector: Int, count: Int) -> [UInt8] {
        let start = ((track * sides + side) * 16 + sector) * 256
        return Array(image[start..<start + count * 256])
    }

    @Test func restoreFindsTrackZero() throws {
        let host = WDHost(try Disc.fromSSD(try image("TestTimings.ssd")))
        // The first command spins the motor up: 6 index pulses.
        let start = host.fdc.time
        host.seek(5)
        #expect(host.fdc.time - start > 1_000_000)
        #expect(host.fdc.drives[0].track == 5)
        #expect(host.fdc.peek(1) == 5)

        let status = host.command(0x00)
        #expect(host.fdc.drives[0].track == 0)
        #expect(host.fdc.peek(1) == 0)
        #expect(status & WDStatus.track0 != 0)
        #expect(status & WDStatus.motorOn != 0)
        #expect(!host.fdc.intrq, "status read clears INTRQ")

        // And with verify, which reads an ID from track 0.
        host.seek(5)
        let verified = host.command(0x04)
        #expect(verified & WDStatus.recordNotFound == 0)
        #expect(host.fdc.drives[0].track == 0)
    }

    @Test func seeksAtTheCommandsStepRate() throws {
        for (variant, rate, stepMs) in [(WD1770.Variant.wd1770, UInt8(0), 6), (.wd1770, 1, 12), (.wd1770, 3, 30),
                                        (.wd1772, 2, 2), (.wd1772, 3, 3)] {
            let host = WDHost(variant: variant, try Disc.fromSSD(try image("TestTimings.ssd")))
            host.command(0x00)
            var events: [DiscDrive.Event] = []
            host.fdc.drives[0].onEvent = { events.append($0) }
            let start = host.fdc.time
            host.seek(10, rate: rate)
            // Steps, then 32us to completion.
            #expect(host.fdc.time - start == 10 * stepMs * 1000 + 32, "\(variant) rate \(rate)")
            #expect(host.fdc.drives[0].track == 10)
            #expect(events == [.seekStart(steps: 10, stepMs: stepMs), .seekEnd(steps: 10)])
        }
    }

    @Test func seekWithVerifyChecksTheTrack() throws {
        let host = WDHost(try Disc.fromSSD(try image("TestTimings.ssd")))
        host.command(0x00)
        host.fdc.write(3, 7)
        #expect(host.command(0x14) & WDStatus.recordNotFound == 0)
        // Told it's elsewhere, the controller lands on the wrong track.
        host.fdc.write(1, 2)
        host.fdc.write(3, 4)
        let start = host.fdc.time
        #expect(host.command(0x14) & WDStatus.recordNotFound != 0)
        #expect(host.fdc.drives[0].track == 9)
        // 30ms to settle, then 5 or 6 revolutions.
        #expect(host.fdc.time - start > 1_000_000)
    }

    @Test func stepsInAndOut() throws {
        let host = WDHost(try Disc.fromSSD(try image("TestTimings.ssd")))
        host.command(0x00)
        host.command(0x50)
        host.command(0x50)
        #expect(host.fdc.drives[0].track == 2)
        #expect(host.fdc.peek(1) == 2)
        // Without update the track register stays.
        host.command(0x60)
        #expect(host.fdc.drives[0].track == 1)
        #expect(host.fdc.peek(1) == 2)
        // STEP goes the last way.
        host.command(0x30)
        #expect(host.fdc.drives[0].track == 0)
        #expect(host.fdc.peek(1) == 1)
        // Not past track 0.
        host.command(0x20)
        #expect(host.fdc.drives[0].track == 0)
    }

    @Test func readsSingleDensitySectors() throws {
        let bytes = try image("dp111-6502timing.ssd")
        let host = WDHost(try Disc.fromSSD(bytes))
        for track in [0, 1, 7] {
            for sector in 0..<10 {
                let (status, data) = host.read(track: UInt8(track), sector: UInt8(sector))
                #expect(status & WDStatus.errors == 0, "track \(track) sector \(sector)")
                #expect(data == sectors(bytes, track: track, sector: sector, count: 1), "track \(track) sector \(sector)")
            }
        }
    }

    @Test func readsMultipleSectors() throws {
        let bytes = try image("dp111-6502timing.ssd")
        let host = WDHost(try Disc.fromSSD(bytes))
        let (status, data) = host.read(track: 1, sector: 2, count: 5)
        #expect(status & WDStatus.errors == 0)
        #expect(data == sectors(bytes, track: 1, sector: 2, count: 5))
        #expect(host.fdc.peek(2) == 6)

        // Left to run, it reads to the end of the track and fails to find sector 10.
        host.seek(2)
        host.received = []
        host.fdc.write(2, 0)
        let endStatus = host.command(0x90)
        #expect(endStatus & WDStatus.recordNotFound != 0)
        #expect(host.received == sectors(bytes, track: 2, sector: 0, count: 10))
        #expect(host.fdc.peek(2) == 10)
    }

    @Test func readsAddresses() throws {
        let host = WDHost(try Disc.fromSSD(try image("TestTimings.ssd")))
        host.seek(2)
        var sectorsSeen: Set<UInt8> = []
        for _ in 0..<10 {
            let (status, id) = host.readAddress()
            #expect(status & WDStatus.errors == 0)
            #expect(id.count == 6)
            #expect(id[0] == 2 && id[1] == 0 && id[3] == 1)
            let crc = IBMDiscFormat.crcAdd(IBMDiscFormat.crcAdd(0xFFFF, 0xFE), id[0..<4])
            #expect(UInt16(id[4]) << 8 | UInt16(id[5]) == crc)
            // The track goes in the sector register.
            #expect(host.fdc.peek(2) == 2)
            sectorsSeen.insert(id[2])
        }
        // Each one the next to come round, so each from a different sector.
        #expect(sectorsSeen.count >= 9)
    }

    @Test func writesThenReadsBack() throws {
        let bytes = try image("TestTimings.ssd")
        let disc = try Disc.fromSSD(bytes)
        let host = WDHost(disc)
        let pattern = (0..<2 * Self.sectorSize).map { UInt8(truncatingIfNeeded: $0 * 7 + 3) }
        #expect(host.write(track: 1, sector: 8, Array(pattern[0..<256])) & WDStatus.errors == 0)
        #expect(host.writeMulti(track: 30, sector: 3, pattern) & WDStatus.errors == 0)
        #expect(host.toSend.isEmpty)

        #expect(host.read(track: 1, sector: 8).data == Array(pattern[0..<256]))
        #expect(host.read(track: 1, sector: 9).data == sectors(bytes, track: 1, sector: 9, count: 1))
        let (status, data) = host.read(track: 30, sector: 2, count: 4)
        #expect(status & WDStatus.errors == 0)
        #expect(data == sectors(bytes, track: 30, sector: 2, count: 1) + pattern
            + sectors(bytes, track: 30, sector: 5, count: 1))

        var expected = bytes + [UInt8](repeating: 0, count: 80 * Self.trackSize - bytes.count)
        expected.replaceSubrange(1 * Self.trackSize + 8 * 256..<1 * Self.trackSize + 9 * 256, with: pattern[0..<256])
        expected.replaceSubrange(30 * Self.trackSize + 3 * 256..<30 * Self.trackSize + 5 * 256, with: pattern)
        #expect(disc.isModified)
        #expect(try disc.toSSDOrDSD() == expected)
    }

    @Test func deletedDataShowsInTheStatus() throws {
        let host = WDHost(try Disc.fromSSD(try image("TestTimings.ssd")))
        let pattern = [UInt8](repeating: 0x6D, count: 256)
        #expect(host.write(track: 3, sector: 4, pattern, deleted: true) & WDStatus.errors == 0)
        let (status, data) = host.read(track: 3, sector: 4)
        #expect(status & WDStatus.deletedMark != 0)
        #expect(data == pattern)
        #expect(host.read(track: 3, sector: 5).status & WDStatus.deletedMark == 0)
    }

    @Test func writeProtectedDiscRefusesWrites() throws {
        let bytes = try image("TestTimings.ssd")
        let disc = try Disc.fromSSD(bytes)
        disc.writeProtected = true
        let host = WDHost(disc)
        // Type I commands report it.
        #expect(host.command(0x00) & WDStatus.writeProtected != 0)
        let pattern = [UInt8](repeating: 0xA5, count: 256)
        let status = host.write(track: 0, sector: 0, pattern)
        #expect(status & WDStatus.writeProtected != 0)
        #expect(host.read(track: 0, sector: 0).data == sectors(bytes, track: 0, sector: 0, count: 1))
        #expect(!disc.isModified)

        disc.writeProtected = false
        host.fdc.drives[0].writeProtectSwitch = true
        #expect(host.write(track: 0, sector: 0, pattern) & WDStatus.writeProtected != 0)
        host.fdc.drives[0].writeProtectSwitch = false
        #expect(host.write(track: 0, sector: 0, pattern) & WDStatus.errors == 0)
    }

    @Test func missingSectorIsRecordNotFound() throws {
        let host = WDHost(try Disc.fromSSD(try image("TestTimings.ssd")))
        host.seek(0)
        let start = host.fdc.time
        let (status, data) = host.read(track: 0, sector: 12)
        #expect(status & WDStatus.recordNotFound != 0)
        #expect(data.isEmpty)
        // Given up on the sixth index pulse: five to six revolutions.
        let elapsed = host.fdc.time - start
        #expect(elapsed > 1_000_000 && elapsed <= 1_200_100, "\(elapsed)us")
        // A track that doesn't match the register, likewise.
        host.fdc.write(1, 9)
        host.fdc.write(2, 0)
        #expect(host.command(0x80) & WDStatus.recordNotFound != 0)
    }

    @Test func unservicedDataRequestsAreLostBytes() throws {
        let host = WDHost(try Disc.fromSSD(try image("TestTimings.ssd")))
        host.ignoreData = true
        let status = host.read(track: 0, sector: 0).status
        #expect(status & WDStatus.lostByte != 0)
        #expect(status & WDStatus.recordNotFound == 0)
    }

    @Test func readsADFSLDoubleDensity() throws {
        let bytes = adfsImage(doubleSided: true)
        let host = WDHost(try Disc.fromADL(bytes))
        host.select(doubleDensity: true)
        for (track, side) in [(0, 0), (3, 1), (40, 0), (79, 1)] {
            host.select(upper: side == 1, doubleDensity: true)
            let (status, data) = host.read(track: UInt8(track), sector: 0, count: 16)
            #expect(status & WDStatus.errors == 0, "track \(track) side \(side)")
            #expect(data == adfsSectors(bytes, sides: 2, track: track, side: side, sector: 0, count: 16),
                    "track \(track) side \(side)")
        }
        let (status, id) = host.readAddress()
        #expect(status & WDStatus.errors == 0)
        #expect(id[0] == 79 && id[3] == 1)
        let crc = IBMDiscFormat.crcAdd(IBMDiscFormat.crcAdd(0xFFFF, [0xA1, 0xA1, 0xA1, 0xFE]), id[0..<4])
        #expect(UInt16(id[4]) << 8 | UInt16(id[5]) == crc)
    }

    @Test func readsAndWritesADFSSDoubleDensity() throws {
        let bytes = adfsImage(doubleSided: false)
        let disc = try Disc.fromADF(bytes)
        let host = WDHost(disc)
        host.select(doubleDensity: true)
        let (status, data) = host.read(track: 12, sector: 5)
        #expect(status & WDStatus.errors == 0)
        #expect(data == adfsSectors(bytes, sides: 1, track: 12, side: 0, sector: 5, count: 1))

        let pattern = (0..<512).map { UInt8(truncatingIfNeeded: $0 * 11 + 1) }
        // (Ended at the next sector's data request, so not the last on the track.)
        #expect(host.writeMulti(track: 20, sector: 13, pattern) & WDStatus.errors == 0)
        let (readStatus, readBack) = host.read(track: 20, sector: 12, count: 4)
        #expect(readStatus & WDStatus.errors == 0)
        #expect(readBack == adfsSectors(bytes, sides: 1, track: 20, side: 0, sector: 12, count: 1) + pattern
            + adfsSectors(bytes, sides: 1, track: 20, side: 0, sector: 15, count: 1))
        #expect(disc.isModified)
        // The neighbours survive, by the disc's own reading of the track.
        let found = disc.tracks[20].findSectors()
        #expect(found.count == 16)
        #expect(found.allSatisfy { !$0.hasDataCRCError && !$0.hasHeaderCRCError })
        #expect(found[0].data == adfsSectors(bytes, sides: 1, track: 20, side: 0, sector: 0, count: 1))
    }

    @Test func densityMustMatchTheDisc() throws {
        let fm = WDHost(try Disc.fromSSD(try image("TestTimings.ssd")))
        fm.select(doubleDensity: true)
        #expect(fm.read(track: 0, sector: 0).status & WDStatus.recordNotFound != 0)

        let mfm = WDHost(try Disc.fromADF(adfsImage(doubleSided: false)))
        #expect(mfm.read(track: 0, sector: 0).status & WDStatus.recordNotFound != 0)
    }

    @Test func masterLayoutReadsTheUpperSide() throws {
        let bytes = adfsImage(doubleSided: true)
        let host = WDHost(layout: .master128, nil, try Disc.fromADL(bytes))
        host.select(drive: 1, upper: true, doubleDensity: true)
        #expect(host.fdc.selectedDrive == 1)
        let (status, data) = host.read(track: 6, sector: 9)
        #expect(status & WDStatus.errors == 0)
        #expect(data == adfsSectors(bytes, sides: 2, track: 6, side: 1, sector: 9, count: 1))
        #expect(host.fdc.drives[1].track == 6)
        #expect(host.fdc.drives[0].track == 0)
        #expect(host.fdc.driveLight(1) && !host.fdc.driveLight(0))
    }

    @Test func controlLayouts() {
        let fdc = WD1770()
        // Acorn: drive 0, upper, single density, out of reset.
        fdc.writeControl(0x2D, layout: .acorn1770)
        #expect(fdc.selectedDrive == 0 && fdc.isSideUpper && !fdc.isDoubleDensity && !fdc.isReset)
        fdc.writeControl(0x02, layout: .acorn1770)
        #expect(fdc.selectedDrive == 1 && !fdc.isSideUpper && fdc.isDoubleDensity && fdc.isReset)
        // Master: drive 1, upper, double density, out of reset.
        fdc.writeControl(0x16, layout: .master128)
        #expect(fdc.selectedDrive == 1 && fdc.isSideUpper && fdc.isDoubleDensity && !fdc.isReset)
        fdc.writeControl(0x21, layout: .master128)
        #expect(fdc.selectedDrive == 0 && !fdc.isSideUpper && !fdc.isDoubleDensity && fdc.isReset)
        fdc.writeControl(0x24, layout: .master128)
        #expect(fdc.selectedDrive == nil)
    }

    @Test func resetHoldsTheController() throws {
        let host = WDHost(try Disc.fromSSD(try image("TestTimings.ssd")))
        host.fdc.write(2, 7)
        host.fdc.writeControl(0x01, layout: .acorn1770)
        #expect(host.fdc.peek(2) == 1)
        host.fdc.write(2, 5)
        host.fdc.write(1, 9)
        #expect(host.fdc.peek(2) == 1)
        #expect(host.fdc.peek(1) == 9)
        host.fdc.write(0, 0x00)
        #expect(host.fdc.peek(0) == 0)
        #expect(!host.fdc.drives[0].spinning)
        host.select()
        #expect(host.command(0x00) & WDStatus.track0 != 0)
    }

    @Test func forceInterrupt() throws {
        let host = WDHost(try Disc.fromSSD(try image("TestTimings.ssd")))
        // Immediate: INTRQ at once, and so NMI, until the status is read.
        host.fdc.write(0, 0xD8)
        #expect(host.fdc.intrq && host.fdc.nmi)
        #expect(host.fdc.peek(0) & WDStatus.motorOn != 0)
        _ = host.fdc.read(0)
        #expect(!host.fdc.nmi)

        // &D0 aborts a command with no interrupt.
        host.seek(0)
        host.fdc.write(2, 12)
        host.fdc.write(0, 0x80)
        host.run(us: 100_000)
        #expect(host.fdc.peek(0) & WDHost.busy != 0)
        host.fdc.write(0, 0xD0)
        host.run(us: 31)
        #expect(host.fdc.peek(0) & WDHost.busy != 0)
        host.run(us: 1)
        #expect(host.fdc.peek(0) & WDHost.busy == 0)
        #expect(!host.fdc.nmi)
    }

    @Test func motorStopsAfterNineIdleRevolutions() throws {
        let host = WDHost(try Disc.fromSSD(try image("TestTimings.ssd")))
        host.command(0x00)
        #expect(host.fdc.peek(0) & WDStatus.motorOn != 0)
        host.run(us: 8 * 200_000)
        #expect(host.fdc.drives[0].spinning)
        host.run(us: 2 * 200_000)
        #expect(!host.fdc.drives[0].spinning)
        #expect(host.fdc.peek(0) & WDStatus.motorOn == 0)
    }
}
