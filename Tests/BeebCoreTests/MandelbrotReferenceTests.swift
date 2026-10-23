// The test oracle for the Distributed Mandelbrot demo (MandelbrotReference)
// checked against what protocol.md says of it.

import Testing

struct MandelbrotReferenceTests {
    @Test func tilesCoverThePictureOnce() {
        let tiles = MandelbrotReference.tiles
        #expect(tiles.count == 320)
        var hits = [Int](repeating: 0, count: 160 * 256)
        for tile in tiles {
            #expect(tile.x % 16 == 0 && tile.y % 8 == 0)
            for y in tile.y ..< tile.y + 8 {
                for x in tile.x ..< tile.x + 16 { hits[y * 160 + x] += 1 }
            }
        }
        #expect(hits.allSatisfy { $0 == 1 })
        #expect(MandelbrotReference.tile(0) == .init(id: 0, x: 0, y: 0))
        #expect(MandelbrotReference.tile(9) == .init(id: 9, x: 144, y: 0))
        #expect(MandelbrotReference.tile(10) == .init(id: 10, x: 0, y: 8))
        #expect(MandelbrotReference.tile(17) == .init(id: 17, x: 112, y: 8))
        #expect(MandelbrotReference.tile(319) == .init(id: 319, x: 144, y: 248))
    }

    @Test func cornersMapToThePlane() {
        // Top left -2.25 + 1.5i; one step 5/256 across, 3/256 down.
        #expect(MandelbrotReference.cReal(0) == -576 && MandelbrotReference.cImag(0) == 384)
        #expect(MandelbrotReference.cReal(159) == -576 + 795 && MandelbrotReference.cImag(255) == 384 - 765)
        #expect(MandelbrotReference.cReal(160) == 224)            // 0.875, just off the right
        #expect(MandelbrotReference.cImag(128) == 0)              // the real axis
        // The bottom row is the top's mirror, give or take a step.
        #expect(MandelbrotReference.cImag(256) == -384)
    }

    @Test func squaresAreTruncated() {
        #expect(MandelbrotReference.square(0) == 0)
        #expect(MandelbrotReference.square(255) == 254)   // 65025 / 256
        #expect(MandelbrotReference.square(256) == 256)
        #expect(MandelbrotReference.square(512) == 1024)
        #expect(MandelbrotReference.square(2047) == 16368)
    }

    @Test func knownPoints() {
        let count = MandelbrotReference.escapeCount
        // The origin never escapes.
        #expect(count(0, 0, 64) == 64)
        #expect(count(0, 0, 1) == 1)
        // -2.25 + 1.5i: out after the first step.
        #expect(count(-576, 384, 64) == 1)
        #expect(MandelbrotReference.count(x: 0, y: 0, maxIterations: 64) == 1)
        // -1 is in the set (period 2), and -2 is on its edge (z: 0, -2, 2, 2…).
        #expect(count(-256, 0, 64) == 64)
        #expect(count(-512, 0, 64) == 64)
        // Just beyond -2 is out at once: S(517) = 1044.
        #expect(count(-517, 0, 64) == 1)
        // 0.5: x goes 128, 192, 272, 417, 807, then |z|² > 4.
        #expect(count(128, 0, 64) == 5)
        // 0.25 is the cusp, in the set (in exact arithmetic it only
        // creeps up to 0.5); 0.26 is out after a while.
        #expect(count(64, 0, 64) == 64)
        let past = count(67, 0, 64)
        #expect(past > 5 && past < 64)
        // i is in (period 2: i, -1+i, -i, -1+i…), and 2i is out at once:
        // |z|² = 4 is not > 4 after the first step, so it's the second.
        #expect(count(0, 256, 64) == 64)
        #expect(count(0, 512, 64) == 2)
        // A bigger limit only changes what didn't escape.
        #expect(count(-576, 384, 255) == 1)
    }

    @Test func colourCycles() {
        let colour = MandelbrotReference.colour
        #expect(colour(64, 64) == 0)
        #expect((1 ... 7).map { colour($0, 64) } == [1, 2, 3, 1, 2, 3, 1])
        #expect(colour(63, 64) == 3)
        #expect(colour(32, 32) == 0)
    }

    @Test func tilesMakeThePicture() {
        let image = MandelbrotReference.image(maxIterations: 64)
        #expect(image.count == 160 * 256)
        #expect(image.allSatisfy { $0 >= 1 && $0 <= 64 })
        let tile = MandelbrotReference.tile(id: 17, maxIterations: 64)
        #expect(tile.count == 128)
        for dy in 0 ..< 8 {
            #expect(Array(image[(8 + dy) * 160 + 112 ..< (8 + dy) * 160 + 128]) == Array(tile[dy * 16 ..< dy * 16 + 16]))
        }
        // Repeated addition from the corner is the same as the mapping.
        for (i, n) in tile.enumerated() {
            #expect(n == MandelbrotReference.count(x: 112 + i % 16, y: 8 + i / 16, maxIterations: 64))
        }
        // The left edge is outside; the main cardioid (around -0.25) is in.
        #expect(image[0] == 1)
        #expect(image[128 * 160 + 102] == 64)   // x 102: -576 + 510 = -66, about -0.26
        let total = image.reduce(0) { $0 + Int($1) }
        let inside = image.filter { $0 == 64 }.count
        print("Mandelbrot reference, max 64: \(total) iterations in all, \(inside) of \(image.count) pixels at max")
        #expect(inside > 0 && inside < image.count / 2)
    }
}
