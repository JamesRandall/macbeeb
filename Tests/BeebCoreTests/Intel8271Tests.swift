// The 8271 driven through its registers as the DFS does it, against discs
// built from .ssd images.

import Testing
@testable import BeebCore

/// An 8271 with DFS-style NMI service: each data request NMI moves a byte,
/// the completion NMI reads the result.
final class DFSHost {
    static let busy: UInt8 = 0x80
    static let resultReady: UInt8 = 0x10
    static let needData: UInt8 = 0x04
    static let loadHead: UInt8 = 0x08
    static let select: [UInt8] = [0x40, 0x80]

    let fdc = Intel8271()
    var received: [UInt8] = []
    var toSend: [UInt8] = []
    /// Ignore data requests, as a too-slow NMI handler would.
    var ignoreData = false
    var completionResult: UInt8?
    var lastNMI = false

    init(_ discs: Disc?...) {
        for (drive, disc) in discs.enumerated() { fdc.drives[drive].insert(disc) }
        // DFS 1.20's setup: no DMA; 24ms steps, 20ms settle, 64ms head
        // load, unload after 12 revolutions; no bad tracks.
        command(0x3A, 0x17, 0xC1)
        command(0x35, 0x0D, 12, 10, 0xC8)
        command(0x35, 0x10, 0xFF, 0xFF, 0)
        command(0x35, 0x18, 0xFF, 0xFF, 0)
    }

    func step() {
        fdc.tick()
        if fdc.nmi && !lastNMI {
            let status = fdc.read(0)
            if status & Self.needData != 0 {
                if !ignoreData {
                    if toSend.isEmpty {
                        received.append(fdc.read(4))
                    } else {
                        fdc.write(4, toSend.removeFirst())
                    }
                }
            } else if status & Self.resultReady != 0 {
                completionResult = fdc.read(1)
            }
        }
        lastNMI = fdc.nmi
    }

    func run(us: Int) {
        for _ in 0..<us { step() }
    }

    /// Sends a command and runs until it's done; returns the result, if any.
    @discardableResult
    func command(_ command: UInt8, _ params: UInt8..., timeoutUs: Int = 10_000_000) -> UInt8? {
        completionResult = nil
        fdc.write(0, command)
        for param in params { fdc.write(1, param) }
        var elapsed = 0
        while fdc.peek(0) & Self.busy != 0 && elapsed < timeoutUs {
            step()
            elapsed += 1
        }
        if let completionResult { return completionResult }
        return fdc.peek(0) & Self.resultReady != 0 ? fdc.read(1) : nil
    }

    /// Loads the head and waits for the drive to come up to speed, as the
    /// DFS does before its first command.
    func spinUp(drive: Int = 0) {
        command(0x3A, 0x23, Self.loadHead | Self.select[drive])
        run(us: 1_000_000)
        // The ready latch only updates when the drive status is read.
        readDriveStatus(drive: drive)
    }

    @discardableResult
    func readDriveStatus(drive: Int = 0) -> UInt8? {
        command(0x2C | Self.select[drive])
    }

    func seek(_ track: UInt8, drive: Int = 0) -> UInt8? {
        command(0x29 | Self.select[drive], track)
    }

    /// Reads `count` 256-byte sectors.
    func read(track: UInt8, sector: UInt8, count: UInt8, drive: Int = 0) -> (result: UInt8?, data: [UInt8]) {
        received = []
        let result = command(0x13 | Self.select[drive], track, sector, 0x20 | count)
        return (result, received)
    }

    func readIDs(track: UInt8, count: UInt8, drive: Int = 0) -> (result: UInt8?, ids: [UInt8]) {
        received = []
        let result = command(0x1B | Self.select[drive], track, 0, count)
        return (result, received)
    }

    func write(track: UInt8, sector: UInt8, _ data: [UInt8], drive: Int = 0) -> UInt8? {
        toSend = data
        defer { toSend = [] }
        return command(0x0B | Self.select[drive], track, sector, 0x20 | UInt8(data.count / 256))
    }
}

struct Intel8271Tests {
    static let sectorSize = 256
    static let trackSize = 2560

    func image(_ name: String) throws -> [UInt8] {
        try testResource("discs/\(name)")
    }

    /// Bytes of an .ssd, as zero-padded to a whole number of tracks.
    func sectors(_ image: [UInt8], track: Int, sector: Int, count: Int) -> [UInt8] {
        let start = track * Self.trackSize + sector * Self.sectorSize
        return (start..<start + count * Self.sectorSize).map { $0 < image.count ? image[$0] : 0 }
    }

    @Test func readsEveryTrackOfAnImage() throws {
        let bytes = try image("dp111-6502timing.ssd")
        let host = DFSHost(try Disc.fromSSD(bytes))
        host.spinUp()
        let tracks = (bytes.count + Self.trackSize - 1) / Self.trackSize
        for track in 0..<tracks {
            let (result, data) = host.read(track: UInt8(track), sector: 0, count: 10)
            #expect(result == Intel8271.Result.ok, "track \(track)")
            #expect(data == sectors(bytes, track: track, sector: 0, count: 10), "track \(track)")
        }
        // And back down, from the middle of a track.
        let (result, data) = host.read(track: 1, sector: 7, count: 3)
        #expect(result == Intel8271.Result.ok)
        #expect(data == sectors(bytes, track: 1, sector: 7, count: 3))
    }

    @Test func seeksAndReadsSectorIDsInPhysicalOrder() throws {
        let host = DFSHost(try Disc.fromSSD(try image("TestTimings.ssd")))
        host.spinUp()
        #expect(host.seek(2) == Intel8271.Result.ok)
        #expect(host.fdc.drives[0].track == 2)
        let (result, ids) = host.readIDs(track: 2, count: 10)
        #expect(result == Intel8271.Result.ok)
        // From the index, with *FORM's skew of 3 sectors a track.
        let order = (0..<10).map { (4 + $0) % 10 }
        #expect(ids == order.flatMap { [2, 0, UInt8($0), 1] })
    }

    @Test func readsAFortyTrackDiscFromTheOtherDrive() throws {
        let bytes = try image("bcdtest.ssd")
        // Its catalogue says 80 tracks; lay it out for a 40-track drive anyway.
        #expect(try !Disc.fromSSD(bytes).is40Track)
        let disc = try Disc.fromSSD(bytes, layout: .expanded40)
        #expect(disc.is40Track)
        let host = DFSHost(try Disc.fromSSD(try image("RmwX.ssd")), disc)
        host.spinUp(drive: 1)
        let (result, data) = host.read(track: 0, sector: 0, count: 6, drive: 1)
        #expect(result == Intel8271.Result.ok)
        #expect(data == sectors(bytes, track: 0, sector: 0, count: 6))
        let catalogue = try DFSDisc(side: data)
        #expect(catalogue.files.count > 0)

        // Logical track 3 is two steps a track out.
        #expect(host.seek(3, drive: 1) == Intel8271.Result.ok)
        #expect(host.fdc.drives[1].track == 6)
        #expect(host.fdc.drives[1].logicalTrack == 3)
        #expect(host.fdc.drives[0].track == 0)
    }

    @Test func sniffsFortyTrackCatalogues() throws {
        var bytes = try image("bcdtest.ssd")
        // 400 sectors.
        bytes[0x106] = bytes[0x106] & ~3 | 1
        bytes[0x107] = 0x90
        #expect(Disc.isFortyTrackDFS(bytes, doubleSided: false))
        #expect(try Disc.fromSSD(bytes).is40Track)
        #expect(try Disc.fromSSD(bytes).toSSDOrDSD().starts(with: bytes))
        // Data past track 42 says otherwise.
        bytes += [UInt8](repeating: 0, count: 50 * Self.trackSize) + [1]
        #expect(!Disc.isFortyTrackDFS(bytes, doubleSided: false))
    }

    @Test func writesThenReadsBack() throws {
        let bytes = try image("TestTimings.ssd")
        let disc = try Disc.fromSSD(bytes)
        let host = DFSHost(disc)
        host.spinUp()
        let pattern = (0..<2 * Self.sectorSize).map { UInt8(truncatingIfNeeded: $0 * 7 + 3) }
        #expect(host.write(track: 1, sector: 8, pattern) == Intel8271.Result.ok)
        #expect(host.write(track: 30, sector: 0, Array(pattern[0..<256])) == Intel8271.Result.ok)

        let (result, data) = host.read(track: 1, sector: 7, count: 3)
        #expect(result == Intel8271.Result.ok)
        #expect(data == sectors(bytes, track: 1, sector: 7, count: 1) + pattern[0..<512])
        #expect(host.read(track: 1, sector: 9, count: 1).data == Array(pattern[256..<512]))
        #expect(host.read(track: 30, sector: 0, count: 1).data == Array(pattern[0..<256]))

        // The image shows the writes and nothing else.
        var expected = bytes + [UInt8](repeating: 0, count: 80 * Self.trackSize - bytes.count)
        expected.replaceSubrange(1 * Self.trackSize + 8 * 256..<1 * Self.trackSize + 10 * 256, with: pattern[0..<512])
        expected.replaceSubrange(30 * Self.trackSize..<30 * Self.trackSize + 256, with: pattern[0..<256])
        #expect(disc.isModified)
        #expect(try disc.toSSDOrDSD() == expected)
    }

    @Test func formatsATrack() throws {
        let disc = Disc()
        let host = DFSHost(disc)
        host.spinUp()
        // As *FORM: 10 sectors of 256 bytes, GAP3 21, GAP1 16; the IDs
        // supplied a byte per data request.
        let order: [UInt8] = [3, 4, 5, 6, 7, 8, 9, 0, 1, 2]
        host.toSend = order.flatMap { [5, 0, $0, 1] }
        #expect(host.command(0x63, 5, 21, 0x2A, 0, 16) == Intel8271.Result.ok)
        #expect(host.toSend.isEmpty)
        #expect(host.readIDs(track: 5, count: 10).ids == order.flatMap { [5, 0, $0, 1] })
        let (result, data) = host.read(track: 5, sector: 0, count: 10)
        #expect(result == Intel8271.Result.ok)
        #expect(data == [UInt8](repeating: 0xE5, count: Self.trackSize))
        #expect(try disc.toSSDOrDSD() == [UInt8](repeating: 0, count: 5 * Self.trackSize)
            + [UInt8](repeating: 0xE5, count: Self.trackSize))
    }

    @Test func writingOffTheEndOfATrackIsSectorNotFound() throws {
        let host = DFSHost(try Disc.fromSSD(try image("TestTimings.ssd")))
        host.spinUp()
        let pattern = [UInt8](repeating: 0x5A, count: 2 * Self.sectorSize)
        #expect(host.write(track: 0, sector: 9, pattern) == Intel8271.Result.sectorNotFound)
    }

    @Test func writeProtectedDiscRefusesWrites() throws {
        let bytes = try image("TestTimings.ssd")
        let disc = try Disc.fromSSD(bytes)
        disc.writeProtected = true
        let host = DFSHost(disc)
        host.spinUp()
        #expect(host.readDriveStatus()! & 0x08 != 0)
        let pattern = [UInt8](repeating: 0xA5, count: Self.sectorSize)
        #expect(host.write(track: 0, sector: 0, pattern) == Intel8271.Result.writeProtected)
        #expect(host.read(track: 0, sector: 0, count: 1).data == sectors(bytes, track: 0, sector: 0, count: 1))
        #expect(!disc.isModified)

        disc.writeProtected = false
        host.fdc.drives[0].writeProtectSwitch = true
        #expect(host.write(track: 0, sector: 0, pattern) == Intel8271.Result.writeProtected)
    }

    @Test func missingSectorIsSectorNotFound() throws {
        let host = DFSHost(try Disc.fromSSD(try image("TestTimings.ssd")))
        host.spinUp()
        let start = host.fdc.time
        let (result, data) = host.read(track: 0, sector: 12, count: 1)
        #expect(result == Intel8271.Result.sectorNotFound)
        #expect(data.isEmpty)
        // Given up on the third index pulse: two to three revolutions.
        let elapsed = host.fdc.time - start
        #expect(elapsed > 400_000 && elapsed <= 600_000, "\(elapsed)us")
    }

    @Test func unformattedTrackIsSectorNotFound() throws {
        let host = DFSHost(try Disc.fromSSD(try image("TestTimings.ssd")))
        host.spinUp()
        #expect(host.read(track: 81, sector: 0, count: 1).result == Intel8271.Result.sectorNotFound)
    }

    @Test func emptyDriveIsNotReady() {
        let host = DFSHost()
        // The index is held on with no disc, so no pulses come.
        host.spinUp()
        #expect(host.read(track: 0, sector: 0, count: 1).result == Intel8271.Result.driveNotReady)
    }

    @Test func unservicedDataRequestIsLateDMA() throws {
        let host = DFSHost(try Disc.fromSSD(try image("TestTimings.ssd")))
        host.spinUp()
        host.ignoreData = true
        #expect(host.read(track: 0, sector: 0, count: 1).result == Intel8271.Result.lateDMA)
    }

    @Test func headUnloadsAfterTwelveRevolutions() throws {
        let host = DFSHost(try Disc.fromSSD(try image("TestTimings.ssd")))
        host.spinUp()
        _ = host.read(track: 0, sector: 0, count: 1)
        #expect(host.fdc.driveLight(0))
        host.run(us: 11 * 200_000)
        #expect(host.fdc.drives[0].spinning)
        host.run(us: 2 * 200_000)
        #expect(!host.fdc.drives[0].spinning)
        #expect(!host.fdc.driveLight(0))
    }

    @Test func stepsAtTheSpecifiedRate() throws {
        let host = DFSHost(try Disc.fromSSD(try image("TestTimings.ssd")))
        host.spinUp()
        var events: [DiscDrive.Event] = []
        host.fdc.drives[0].onEvent = { events.append($0) }
        let start = host.fdc.time
        #expect(host.seek(10) == Intel8271.Result.ok)
        // 10 steps of 24ms, then 20ms to settle.
        #expect(host.fdc.time - start == 10 * 24_000 + 20_000)
        #expect(events == [.seekStart(steps: 10, stepMs: 24), .seekEnd(steps: 10)])
    }

    @Test func ssdAndDSDRoundTrip() throws {
        let bytes = try image("dp111-6502timing.ssd")
        let ssd = try Disc.fromSSD(bytes).toSSDOrDSD()
        #expect(ssd == bytes + [UInt8](repeating: 0, count: 80 * Self.trackSize - bytes.count))

        let dsdBytes = (0..<2 * 80 * Self.trackSize).map { UInt8(truncatingIfNeeded: $0 / 256 &* 13 &+ $0) }
        let dsd = try Disc.fromDSD(dsdBytes)
        #expect(dsd.isDoubleSided)
        #expect(try dsd.toSSDOrDSD() == dsdBytes)
    }

    @Test func readsTheUpperSideOfADSD() throws {
        let dsdBytes = (0..<2 * 80 * Self.trackSize).map { UInt8(truncatingIfNeeded: $0 / 256 &* 13 &+ $0) }
        let host = DFSHost(try Disc.fromDSD(dsdBytes))
        // Side select is a drive output bit, set as the DFS does through the
        // MMIO register.
        host.command(0x3A, 0x23, DFSHost.loadHead | DFSHost.select[0] | 0x20)
        host.run(us: 1_000_000)
        host.readDriveStatus()
        let (result, data) = host.read(track: 4, sector: 0, count: 10)
        #expect(result == Intel8271.Result.ok)
        let start = (4 * 2 + 1) * Self.trackSize
        #expect(data == Array(dsdBytes[start..<start + Self.trackSize]))
    }
}
