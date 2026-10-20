// SN76489 sound generator, clocked at 250kHz.
//
// A port of b2's SN76489.cpp (Copyright (C) Tom Seddon, GPLv3).

public struct SN76489: Codable, Sendable {
    struct Channel: Codable {
        /// Period, as set by the %1xx0xxxx and %0xxxxxxx commands.
        var frequency: UInt16 = 1023
        /// 15 = loudest.
        var volume: UInt8 = 15
        /// Counts down to 0, then the output toggles.
        var counter: UInt16 = 0
        var mask: UInt8 = 0xFF
    }

    /// The four channels' current output levels, 0-15.
    public typealias Output = SIMD4<UInt8>

    var channels = InlineArray<4, Channel>(repeating: Channel())
    var register: UInt8 = 0
    var noiseSeed: UInt16 = 1 << 14
    var noiseToggle = true

    /// `tone`: the power-on beep (all channels at full volume until the OS
    /// silences them).
    public init(tone: Bool = true) {
        if !tone {
            for i in 0..<4 {
                channels[i].volume = 0
            }
        }
    }

    /// Advances one 250kHz tick. `write` is the write strobe (IC32 bit 0 low),
    /// with `value` on the data bus.
    @inline(__always)
    public mutating func update(write: Bool, value: UInt8) -> Output {
        var output = Output.zero

        // Tone channels.
        for i in 0..<3 {
            var channel = channels[i]
            output[i] = channel.volume & channel.mask
            if channel.counter > 0 {
                channel.counter -= 1
            }
            if channel.counter == 0 {
                channel.mask = ~channel.mask
                channel.counter = channel.frequency == 0 ? 1024 : channel.frequency
            }
            channels[i] = channel
        }

        // Noise channel.
        var noise = channels[3]
        if noise.counter > 0 {
            noise.counter -= 1
        }
        if noise.counter == 0 {
            noiseToggle.toggle()
            if noiseToggle {
                let bit = noise.frequency & 4 != 0 ? nextWhiteNoiseBit() : nextPeriodicNoiseBit()
                noise.mask = bit ? 0xFF : 0x00
            }
            switch noise.frequency & 3 {
            case 3:
                // Clocked by tone channel 2.
                let f = channels[2].frequency
                noise.counter = f == 0 ? 1024 : f
            case 2: noise.counter = 0x40
            case 1: noise.counter = 0x20
            default: noise.counter = 0x10
            }
        }
        output[3] = noise.volume & noise.mask
        channels[3] = noise

        if write {
            self.write(value)
        }
        return output
    }

    private mutating func write(_ value: UInt8) {
        if value & 0x80 != 0 {
            // Latch/data byte.
            register = value >> 4 & 7
            let v = UInt16(value & 0x0F)
            let index = Int(register >> 1)
            if register & 1 != 0 {
                channels[index].volume = UInt8(v) ^ 0x0F
            } else {
                channels[index].frequency = (channels[index].frequency & ~0x0F) | v
                if register == 6 {
                    noiseSeed = 1 << 14
                }
            }
        } else {
            // Data byte.
            let index = Int(register >> 1)
            let v = UInt16(value & 0x3F)
            if register & 1 != 0 {
                channels[index].volume = UInt8(v & 0x0F) ^ 0x0F
            } else if register == 6 {
                channels[index].frequency = v
                noiseSeed = 1 << 14
            } else {
                channels[index].frequency = (channels[index].frequency & 0x0F) | v << 4
            }
        }
    }

    // http://www.zeridajh.org/articles/various/sn76489/index.htm
    private mutating func nextWhiteNoiseBit() -> Bool {
        let feed = (noiseSeed >> 1 ^ noiseSeed) & 1
        noiseSeed = (noiseSeed & 0x7FFF) >> 1 | feed << 14
        return noiseSeed & 1 != 0
    }

    private mutating func nextPeriodicNoiseBit() -> Bool {
        let result = noiseSeed & 1 != 0
        noiseSeed = (noiseSeed >> 1 | noiseSeed << 14) & 0x7FFF
        return result
    }
}
