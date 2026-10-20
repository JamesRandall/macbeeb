import Testing
@testable import BeebCore

struct ADFSImageTests {
    func pattern(tracks: Int, sides: Int) -> [UInt8] {
        (0..<tracks * sides * 16 * 256).map { UInt8(truncatingIfNeeded: $0 * 7 + $0 >> 8) }
    }

    @Test(arguments: [(Disc.ImageFormat.adf, 1, 80), (.adl, 2, 80), (.adf, 1, 40)])
    func roundTrips(_ format: Disc.ImageFormat, sides: Int, tracks: Int) throws {
        let image = pattern(tracks: tracks, sides: sides)
        let disc = try Disc.fromImage(image, format: format)
        #expect(try disc.toImage(format) == image)
    }

    @Test func shortImagesGrowToFortyTracks() throws {
        let image = pattern(tracks: 3, sides: 1)
        let back = try Disc.fromADF(image).toADFS(doubleSided: false)
        #expect(back.count == 40 * 16 * 256)
        #expect(Array(back.prefix(image.count)) == image)
    }

    @Test func formatsFromNames() {
        #expect(Disc.ImageFormat(path: "/a/b.ADL") == .adl)
        #expect(Disc.ImageFormat(path: "x.adm") == .adf)
        #expect(Disc.ImageFormat(path: "x.dsd") == .dsd)
        #expect(Disc.ImageFormat(path: "x.txt") == nil)
    }
}
