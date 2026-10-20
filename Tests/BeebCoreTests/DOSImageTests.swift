// The Master 512's 800K DOS discs (.img) and 720K PC ones (.dos): MFM
// sectors of 1024 and 512 bytes, numbered from 1.

import Testing
@testable import BeebCore
import BeebROMs

struct DOSImageTests {
    func image(_ size: Int) -> [UInt8] {
        (0..<size).map { UInt8(truncatingIfNeeded: $0 * 7 + $0 >> 9) }
    }

    @Test(arguments: [(Disc.ImageFormat.img, 819_200, 1024, 5), (.dos, 737_280, 512, 9)])
    func roundTrips(_ format: Disc.ImageFormat, size: Int, sectorSize: Int, sectors: Int) throws {
        let bytes = image(size)
        let disc = try Disc.fromImage(bytes, format: format)
        #expect(try disc.toImage(format) == bytes)
        // Track 1 of the second side: sectors 1 up, the side in the ID.
        let found = disc.tracks[Disc.trackIndex(true, 1)].findSectors()
        #expect(found.map(\.sectorNumber) == Array(1...sectors))
        #expect(found.allSatisfy { $0.header[1] == 1 && $0.data?.count == sectorSize && !$0.hasDataCRCError })
        // Its first sector is the image's fourth track's (track 1, side 1).
        let offset = 3 * sectors * sectorSize
        #expect(found[0].data == Array(bytes[offset..<offset + sectorSize]))
    }

    @Test func formatsFromNames() {
        #expect(Disc.ImageFormat(path: "GEM.IMG") == .img && Disc.ImageFormat(path: "a.dos") == .dos)
        #expect(Disc.ImageFormat.extensions.contains("img"))
    }

    /// DOS Plus reading the bundled GEM disc in drive B.
    @Test func dosPlusReadsTheGEMDisc() throws {
        let m = BBCMicro(configuration: BeebROMs.configuration(for: .master128, secondProcessor: true, coprocessor: .master512))
        let gem = BeebROMs.BundledDisc.gemApplications
        m.insertDisc(try Disc.fromImage(gem.data, format: gem.format), drive: 1)
        #expect(m.runUntilIdle(maxSeconds: 60))
        m.type("DIR B:\r")
        #expect(m.runUntilIdle(maxSeconds: 30))
        let text = m.screenText()
        #expect(text.contains { $0.hasPrefix(" Volume in drive B is DISK    #2") }, "\(text)")
        #expect(text.contains { $0.hasPrefix("GEMSYS       <DIR>") }, "\(text)")
    }
}
