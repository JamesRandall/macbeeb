// Turns the sound chip's 250kHz output into samples at the host rate.
//
// Follows b2's BeebThread audio path (Copyright (C) Tom Seddon, GPLv3):
// a logarithmic volume table (2dB steps), a 3rd-order RC low-pass filter at
// 8kHz run at the chip rate, then averaging down to the output rate.

public struct SoundMixer {
    public static let chipRate = 250_000

    static let volumes: InlineArray<16, Float> = [
        0.00000, 0.03981, 0.05012, 0.06310, 0.07943, 0.10000, 0.12589, 0.15849,
        0.19953, 0.25119, 0.31623, 0.39811, 0.50119, 0.63096, 0.79433, 1.00000,
    ]

    public let outputRate: Int
    public var volume: Float = 1
    let alpha: Float

    // Filter state.
    var f0: Float = 0, f1: Float = 0, f2: Float = 0
    // Rate conversion: emit a sample each time `error` passes chipRate.
    var error = 0
    var accumulated: Float = 0
    var accumulatedCount = 0

    public init(outputRate: Int, cutoffHz: Double = 8000) {
        self.outputRate = outputRate
        let dt = 1.0 / Double(Self.chipRate)
        let rc = 1.0 / (2 * Double.pi * cutoffHz)
        alpha = Float(dt / (rc + dt))
    }

    /// Feeds one chip tick. Returns a sample when one is due.
    @inline(__always)
    public mutating func mix(_ output: SN76489.Output) -> Float? {
        let level = (Self.volumes[Int(output[0])] + Self.volumes[Int(output[1])]
            + Self.volumes[Int(output[2])] + Self.volumes[Int(output[3])]) * 0.25
        f0 += alpha * (level - f0)
        f1 += alpha * (f0 - f1)
        f2 += alpha * (f1 - f2)
        accumulated += f2
        accumulatedCount += 1

        error += outputRate
        guard error >= Self.chipRate else { return nil }
        error -= Self.chipRate
        let sample = accumulated / Float(accumulatedCount) * volume
        accumulated = 0
        accumulatedCount = 0
        return sample
    }
}
