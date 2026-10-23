// The Distributed Mandelbrot demo's picture, worked out as its protocol
// (Examples/distributed-mandelbrot/protocol.md) says a worker does, for
// tests to compare guests' results against byte for byte. Test-only: the
// app never works out a pixel itself.

enum MandelbrotReference {
    static let width = 160
    static let height = 256
    static let tileWidth = 16
    static let tileHeight = 8
    static let columns = width / tileWidth
    static let rows = height / tileHeight
    static let tileCount = columns * rows

    struct Tile: Equatable {
        var id: Int
        var x: Int
        var y: Int
    }

    /// Tile `id = row × 10 + column`, at `x = column × 16`, `y = row × 8`.
    static func tile(_ id: Int) -> Tile {
        Tile(id: id, x: id % columns * tileWidth, y: id / columns * tileHeight)
    }

    static var tiles: [Tile] { (0 ..< tileCount).map(tile) }

    /// Q8.8 corners: `cReal(x) = -576 + 5x`, `cImag(y) = 384 - 3y`.
    static func cReal(_ x: Int) -> Int { -576 + 5 * x }
    static func cImag(_ y: Int) -> Int { 384 - 3 * y }

    /// The truncated square, `floor(a² / 256)`, for 0 ≤ a < 2048 (a
    /// worker's table).
    static let squares: [Int] = (0 ..< 2048).map { $0 * $0 / 256 }

    static func square(_ a: Int) -> Int {
        precondition(a >= 0 && a < 2048)
        return squares[a]
    }

    /// The escape count of `(cr, ci)` with limit `max`: 1 … max.
    static func escapeCount(cr: Int, ci: Int, max: Int) -> Int {
        var x = 0, y = 0
        for n in 0 ..< max {
            if abs(x) >= 2048 || abs(y) >= 2048 { return n }
            let x2 = square(abs(x)), y2 = square(abs(y))
            if x2 + y2 > 1024 { return n }
            let s = abs(x + y)
            if s >= 2048 { return n }
            let xy = square(s) - x2 - y2
            y = xy + ci
            x = x2 - y2 + cr
            assert(Int(Int16.min) ... Int(Int16.max) ~= x && Int(Int16.min) ... Int(Int16.max) ~= y)
        }
        return max
    }

    /// The pixel's count, as a worker would work it out (by repeated
    /// addition from the tile's corner, which comes to the same).
    static func count(x: Int, y: Int, maxIterations: Int) -> UInt8 {
        UInt8(escapeCount(cr: cReal(x), ci: cImag(y), max: maxIterations))
    }

    /// A tile's 128 counts, row by row from the top, as its RESULT has them.
    static func tile(id: Int, maxIterations: Int = 64) -> [UInt8] {
        let t = tile(id)
        var counts: [UInt8] = []
        counts.reserveCapacity(tileWidth * tileHeight)
        var ci = cImag(t.y)
        for _ in 0 ..< tileHeight {
            var cr = cReal(t.x)
            for _ in 0 ..< tileWidth {
                counts.append(UInt8(escapeCount(cr: cr, ci: ci, max: maxIterations)))
                cr += 5
            }
            ci -= 3
        }
        return counts
    }

    /// The whole picture, 160 × 256 counts row by row.
    static func image(maxIterations: Int = 64) -> [UInt8] {
        var image = [UInt8](repeating: 0, count: width * height)
        for t in tiles {
            let counts = tile(id: t.id, maxIterations: maxIterations)
            for dy in 0 ..< tileHeight {
                for dx in 0 ..< tileWidth {
                    image[(t.y + dy) * width + t.x + dx] = counts[dy * tileWidth + dx]
                }
            }
        }
        return image
    }

    /// The MODE 5 colour: 0 if `n == max`, otherwise `1 + (n - 1) mod 3`.
    static func colour(_ n: Int, max: Int) -> Int {
        n == max ? 0 : 1 + (n - 1) % 3
    }
}
