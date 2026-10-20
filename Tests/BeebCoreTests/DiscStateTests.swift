// Save states for the disc controllers, drives and discs: a snapshot taken
// mid-command restores exactly, cycle for cycle.

import Foundation
import Testing
@testable import BeebCore

/// A host and its controller, saved and restored together.
private protocol SnapshottingHost: AnyObject {
    associatedtype Snapshot
    func snapshot() -> Snapshot
    func restore(_ snapshot: Snapshot)
    func step()
    /// The registers, interrupt lines and drive 0's head, as one word.
    var observed: UInt64 { get }
    var discs: [Disc.State?] { get }
}

private struct WDHostSnapshot {
    var fdc: WD1770.State
    var received: [UInt8]
    var toSend: [UInt8]
    var ignoreData: Bool
    var readLimit: Int?
    var endWriteWhenSent: Bool
    var completionStatus: UInt8?
    var lastNMI: Bool
}

extension WDHost: SnapshottingHost {
    fileprivate func snapshot() -> WDHostSnapshot {
        WDHostSnapshot(fdc: fdc.state, received: received, toSend: toSend, ignoreData: ignoreData,
                       readLimit: readLimit, endWriteWhenSent: endWriteWhenSent,
                       completionStatus: completionStatus, lastNMI: lastNMI)
    }

    fileprivate func restore(_ s: WDHostSnapshot) {
        fdc.restore(s.fdc)
        received = s.received
        toSend = s.toSend
        ignoreData = s.ignoreData
        readLimit = s.readLimit
        endWriteWhenSent = s.endWriteWhenSent
        completionStatus = s.completionStatus
        lastNMI = s.lastNMI
    }

    var observed: UInt64 {
        let registers = (0..<4).reduce(UInt64(0)) { $0 | UInt64(fdc.peek($1)) << ($1 * 8) }
        let lines = UInt64(fdc.nmi ? 1 : 0) | UInt64(fdc.intrq ? 2 : 0) | UInt64(fdc.drq ? 4 : 0)
        let drive = fdc.drives[0]
        return registers | lines << 32 | UInt64(drive.track) << 36
            | UInt64(drive.headPosition) << 44 | UInt64(drive.spinning ? 1 : 0) << 60
    }

    var discs: [Disc.State?] { fdc.drives.map { $0.disc?.state } }
}

private struct DFSHostSnapshot {
    var fdc: Intel8271.State
    var received: [UInt8]
    var toSend: [UInt8]
    var ignoreData: Bool
    var completionResult: UInt8?
    var lastNMI: Bool
}

extension DFSHost: SnapshottingHost {
    fileprivate func snapshot() -> DFSHostSnapshot {
        DFSHostSnapshot(fdc: fdc.state, received: received, toSend: toSend, ignoreData: ignoreData,
                        completionResult: completionResult, lastNMI: lastNMI)
    }

    fileprivate func restore(_ s: DFSHostSnapshot) {
        fdc.restore(s.fdc)
        received = s.received
        toSend = s.toSend
        ignoreData = s.ignoreData
        completionResult = s.completionResult
        lastNMI = s.lastNMI
    }

    var observed: UInt64 {
        let registers = (0..<5).reduce(UInt64(0)) { $0 | UInt64(fdc.peek($1)) << ($1 * 8) }
        let drive = fdc.drives[0]
        return registers | UInt64(fdc.nmi ? 1 : 0) << 40 | UInt64(drive.track) << 41
            | UInt64(drive.headPosition) << 48 | UInt64(drive.spinning ? 1 : 0) << 62
    }

    var discs: [Disc.State?] { fdc.drives.map { $0.disc?.state } }
}

private func trace<Host: SnapshottingHost>(_ host: Host, us: Int) -> [UInt64] {
    var words = [UInt64]()
    words.reserveCapacity(us)
    for _ in 0..<us {
        host.step()
        words.append(host.observed)
    }
    return words
}

private func firstDifference(_ a: [UInt64], _ b: [UInt64]) -> String {
    guard let i = zip(a, b).enumerated().first(where: { $0.element.0 != $0.element.1 })?.offset else {
        return a.count == b.count ? "none" : "lengths \(a.count), \(b.count)"
    }
    return "at \(i)us: \(String(a[i], radix: 16)) vs \(String(b[i], radix: 16))"
}

/// Runs `original` on from the snapshot, then a fresh host restored from it,
/// then the original restored after it's moved on; all must match.
private func checkRestoresExactly<Host: SnapshottingHost>(_ original: Host, fresh: Host, us: Int = 2_000_000,
                                                          _ comment: Comment) {
    let snapshot = original.snapshot()
    let expected = trace(original, us: us)
    let expectedDiscs = original.discs

    fresh.restore(snapshot)
    let restored = trace(fresh, us: us)
    // (Compared outside #expect, which would print every element on failure.)
    let freshMatches = restored == expected
    #expect(freshMatches, "fresh: \(firstDifference(restored, expected)) \(comment)")
    let freshDiscsMatch = fresh.discs == expectedDiscs
    #expect(freshDiscsMatch, "fresh discs \(comment)")

    original.restore(snapshot)
    let again = trace(original, us: us)
    let rewoundMatches = again == expected
    #expect(rewoundMatches, "rewound: \(firstDifference(again, expected)) \(comment)")
    let rewoundDiscsMatch = original.discs == expectedDiscs
    #expect(rewoundDiscsMatch, "rewound discs \(comment)")
}

struct DiscStateTests {
    func ssd(_ name: String = "TestTimings.ssd") throws -> Disc {
        try Disc.fromSSD(try testResource("discs/\(name)"))
    }

    // MARK: WD1770

    func runUntil(_ host: WDHost, limit: Int = 10_000_000, _ condition: () -> Bool) {
        var elapsed = 0
        while !condition() && elapsed < limit {
            host.step()
            elapsed += 1
        }
    }

    @Test func wd1770MidMultiSectorRead() throws {
        let host = WDHost(try ssd())
        host.seek(3)
        host.received = []
        host.readLimit = 10 * 256
        host.fdc.write(2, 0)
        host.fdc.write(0, 0x90)
        runUntil(host) { host.received.count == 700 }
        #expect(host.received.count == 700)
        checkRestoresExactly(host, fresh: WDHost(), "WD1770 FM read")
    }

    @Test func wd1770MidDoubleDensityRead() throws {
        let host = WDHost(try Disc.fromADL(adfsImage(doubleSided: true)))
        host.select(upper: true, doubleDensity: true)
        host.seek(9)
        host.received = []
        host.readLimit = 16 * 256
        host.fdc.write(2, 3)
        host.fdc.write(0, 0x90)
        // An odd byte, so the drive is mid-word.
        runUntil(host) { host.received.count == 1001 }
        #expect(host.received.count == 1001)
        checkRestoresExactly(host, fresh: WDHost(), "WD1770 MFM read")
    }

    @Test func wd1770MidWrite() throws {
        let host = WDHost(try ssd())
        host.seek(5)
        host.toSend = (0..<3 * 256).map { UInt8(truncatingIfNeeded: $0 * 5 + 1) }
        host.endWriteWhenSent = true
        host.fdc.write(2, 2)
        host.fdc.write(0, 0xB0)
        runUntil(host) { host.toSend.count == 400 }
        #expect(host.toSend.count == 400)
        let before = host.fdc.drives[0].disc!.state
        checkRestoresExactly(host, fresh: WDHost(), "WD1770 write")
        let after = try #require(host.fdc.drives[0].disc)
        #expect(after.state != before)
        #expect(after.tracks[5].findSectors().first { $0.sectorNumber == 4 }?.data
            == (512..<768).map { UInt8(truncatingIfNeeded: $0 * 5 + 1) })
    }

    @Test func wd1770MidSeekAndSpinUp() throws {
        let host = WDHost(variant: .wd1772, try ssd())
        // Motor off: spin-up first.
        host.fdc.write(3, 40)
        host.fdc.write(0, 0x17)
        host.run(us: 300_017)
        #expect(host.fdc.peek(0) & WDHost.busy != 0)
        #expect(host.fdc.drives[0].track == 0)
        checkRestoresExactly(host, fresh: WDHost(variant: .wd1772), "WD1772 spin up")

        runUntil(host) { host.fdc.drives[0].track == 17 }
        host.run(us: 1_234)
        checkRestoresExactly(host, fresh: WDHost(variant: .wd1772), "WD1772 seek")
    }

    @Test func wd1770StateRoundTrips() throws {
        let host = WDHost(try ssd())
        host.seek(5)
        host.toSend = [UInt8](repeating: 0x42, count: 256)
        host.fdc.write(2, 1)
        host.fdc.write(0, 0xA0)
        runUntil(host) { host.toSend.count == 100 }
        let snapshot = host.snapshot()

        let json = try JSONEncoder().encode(snapshot.fdc)
        let plistEncoder = PropertyListEncoder()
        plistEncoder.outputFormat = .binary
        let plist = try plistEncoder.encode(snapshot.fdc)
        let fromJSON = try JSONDecoder().decode(WD1770.State.self, from: json)
        let fromPlist = try PropertyListDecoder().decode(WD1770.State.self, from: plist)
        #expect(fromJSON == snapshot.fdc)
        #expect(fromPlist == snapshot.fdc)
        // An 80-track single-sided disc and its controller.
        #expect(plist.count > 900_000 && plist.count < 1_100_000, "\(plist.count) bytes")

        let expected = trace(host, us: 1_000_000)
        // The snapshot doesn't see the writes made since.
        #expect(try plistEncoder.encode(snapshot.fdc) == plist)
        for decoded in [fromJSON, fromPlist] {
            let fresh = WDHost()
            var copy = snapshot
            copy.fdc = decoded
            fresh.restore(copy)
            let matches = trace(fresh, us: 1_000_000) == expected
            #expect(matches)
        }
    }

    // MARK: Intel 8271

    func runUntil(_ host: DFSHost, limit: Int = 10_000_000, _ condition: () -> Bool) {
        var elapsed = 0
        while !condition() && elapsed < limit {
            host.step()
            elapsed += 1
        }
    }

    @Test func intel8271MidMultiSectorRead() throws {
        let host = DFSHost(try ssd())
        host.spinUp()
        host.received = []
        host.fdc.write(0, 0x13 | 0x40)
        for param: UInt8 in [4, 0, 0x2A] { host.fdc.write(1, param) }
        runUntil(host) { host.received.count == 700 }
        #expect(host.received.count == 700)
        checkRestoresExactly(host, fresh: DFSHost(), "8271 read")
    }

    @Test func intel8271MidWrite() throws {
        let host = DFSHost(try ssd())
        host.spinUp()
        host.toSend = (0..<3 * 256).map { UInt8(truncatingIfNeeded: $0 * 3 + 7) }
        host.fdc.write(0, 0x0B | 0x40)
        for param: UInt8 in [6, 1, 0x23] { host.fdc.write(1, param) }
        runUntil(host) { host.toSend.count == 300 }
        #expect(host.toSend.count == 300)
        checkRestoresExactly(host, fresh: DFSHost(), "8271 write")
        let disc = try #require(host.fdc.drives[0].disc)
        #expect(disc.tracks[6].findSectors().first { $0.sectorNumber == 3 }?.data
            == (512..<768).map { UInt8(truncatingIfNeeded: $0 * 3 + 7) })
    }

    @Test func intel8271MidSeek() throws {
        let host = DFSHost(try ssd())
        host.spinUp()
        host.fdc.write(0, 0x29 | 0x40)
        host.fdc.write(1, 30)
        host.run(us: 200_003)
        #expect(host.fdc.drives[0].track > 0 && host.fdc.drives[0].track < 30)
        checkRestoresExactly(host, fresh: DFSHost(), "8271 seek")
    }

    @Test func intel8271StateRoundTrips() throws {
        let host = DFSHost(try ssd())
        host.spinUp()
        host.received = []
        host.fdc.write(0, 0x13 | 0x40)
        for param: UInt8 in [2, 0, 0x25] { host.fdc.write(1, param) }
        runUntil(host) { host.received.count == 300 }
        let snapshot = host.snapshot()
        let json = try JSONEncoder().encode(snapshot.fdc)
        let decoded = try JSONDecoder().decode(Intel8271.State.self, from: json)
        #expect(decoded == snapshot.fdc)

        let expected = trace(host, us: 1_000_000)
        let fresh = DFSHost()
        var copy = snapshot
        copy.fdc = decoded
        fresh.restore(copy)
        let matches = trace(fresh, us: 1_000_000) == expected
        #expect(matches)
    }

    // MARK: Discs

    @Test func discStateRoundTripsAndIsCompact() throws {
        let disc = try Disc.fromADL(adfsImage(doubleSided: true))
        disc.writeProtected = true
        let state = disc.state
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(state)
        let decoded = try PropertyListDecoder().decode(Disc.State.self, from: data)
        #expect(decoded == state)
        let copy = Disc(state: decoded)
        #expect(copy.writeProtected && copy.isDoubleSided)
        #expect(copy.state == disc.state)

        // Unformatted tracks cost next to nothing.
        let blank = try encoder.encode(Disc().state)
        #expect(blank.count < 10_000, "\(blank.count) bytes")
        // 160 formatted tracks of 12.5KB.
        #expect(data.count < 160 * 12_600, "\(data.count) bytes")

        // A corrupt state is an error, not a crash.
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as! [String: Any]
        json["tracks"] = []
        let bad = try JSONSerialization.data(withJSONObject: json)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(Disc.State.self, from: bad) }
    }

    @Test func driveRestoresIntoItsDiscOrEjects() throws {
        let drive = DiscDrive(id: 0)
        let disc = try ssd()
        var written: [Int] = []
        disc.onTrackWritten = { written.append($1) }
        drive.insert(disc)
        let state = drive.state
        drive.insert(nil)
        drive.restore(state)
        // Back into the Disc in the drive, if any; here a new one.
        #expect(drive.disc !== disc)
        #expect(drive.disc?.state == disc.state)

        drive.insert(disc)
        disc.writeProtected = true
        drive.restore(state)
        #expect(drive.disc === disc)
        #expect(!disc.writeProtected)
        #expect(disc.onTrackWritten != nil)

        drive.restore(DiscDrive(id: 0).state)
        #expect(drive.disc == nil)
    }
}
