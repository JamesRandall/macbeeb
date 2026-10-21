// The disc drives' mechanical noises: the motor spinning up, running and
// down, the head stepping and seeking.
//
// As b2 does it (BBCMicro.cpp's StepSound and UpdateDiscDriveSound,
// Copyright (C) Tom Seddon, GPLv3), with MAME's recorded samples (CC0), and
// mixed in at the sound chip's 250kHz. b2 sees each step; the drives here
// announce a seek with its steps and step rate (as jsbeeb's ddnoise has
// them), so a seek of more than one step plays MAME's seek sample for that
// rate (b2's choice of it) for as long as the seek lasts.

/// One drive type's samples, mono, at their own rate.
public struct DiscDriveSounds: Sendable {
    public enum Sound: Int, CaseIterable, Sendable {
        case spinStartLoaded, spinStartEmpty, spinLoaded, spinEmpty, spinEnd
        case step, seek2ms, seek6ms, seek12ms, seek20ms
    }

    public let rate: Double
    let samples: [[Float]]

    /// `samples` has one array for each of `Sound`'s cases, in order.
    public init(rate: Double, samples: [[Float]]) {
        precondition(samples.count == Sound.allCases.count, "one sample for each sound")
        self.rate = rate
        self.samples = samples
    }

    subscript(sound: Sound) -> [Float] { samples[sound.rawValue] }

    /// A 16-bit PCM WAV file's first channel and rate.
    public static func decodeWAV(_ bytes: [UInt8]) -> (rate: Double, samples: [Float])? {
        func u32(_ i: Int) -> Int { Int(bytes[i]) | Int(bytes[i + 1]) << 8 | Int(bytes[i + 2]) << 16 | Int(bytes[i + 3]) << 24 }
        func u16(_ i: Int) -> Int { Int(bytes[i]) | Int(bytes[i + 1]) << 8 }
        guard bytes.count >= 12, bytes[0..<4].elementsEqual("RIFF".utf8), bytes[8..<12].elementsEqual("WAVE".utf8) else {
            return nil
        }
        var rate = 0, channels = 0, bits = 0
        var at = 12
        while at + 8 <= bytes.count {
            let size = u32(at + 4)
            let body = at + 8
            guard body + size <= bytes.count else { return nil }
            if bytes[at..<at + 4].elementsEqual("fmt ".utf8), size >= 16 {
                guard u16(body) == 1 else { return nil }  // PCM
                channels = u16(body + 2)
                rate = u32(body + 4)
                bits = u16(body + 14)
            } else if bytes[at..<at + 4].elementsEqual("data".utf8) {
                guard bits == 16, channels > 0, rate > 0 else { return nil }
                let frame = 2 * channels
                let samples = stride(from: body, to: body + size - frame + 1, by: frame).map {
                    Float(Int16(bitPattern: UInt16(u16($0)))) / 32768
                }
                return (Double(rate), samples)
            }
            at = body + size + (size & 1)
        }
        return nil
    }
}

/// One drive's noises.
struct DiscDriveNoise {
    /// A sample playing from `position` (in the sample's frames), until
    /// `end`.
    struct Voice {
        var sound: DiscDriveSounds.Sound
        var position: Double = 0
        var end: Double = .infinity
    }

    var spin: Voice?
    /// A step or a seek.
    var head: Voice?

    mutating func event(_ event: DiscDrive.Event, hasDisc: Bool, sounds: DiscDriveSounds) {
        switch event {
        case .startSpinning:
            spin = Voice(sound: hasDisc ? .spinStartLoaded : .spinStartEmpty)
        case .stopSpinning:
            spin = Voice(sound: .spinEnd)
        case .seekStart(let steps, let stepMs):
            let steps = abs(steps)
            guard steps > 0 else { return }
            if steps == 1 {
                head = Voice(sound: .step)
                return
            }
            // b2's choice of sample for the step rate.
            let sound: DiscDriveSounds.Sound = stepMs >= 17 ? .seek20ms : stepMs >= 10 ? .seek12ms : stepMs >= 4 ? .seek6ms : .seek2ms
            let length = Double(sounds[sound].count)
            head = Voice(sound: sound, end: min(length, Double(steps * stepMs) / 1000 * sounds.rate))
        case .seekEnd:
            // The head's stopped, perhaps short of where it was going.
            if var seek = head, seek.sound != .step {
                seek.end = min(seek.end, seek.position)
                head = seek
            }
        }
    }

    /// The next sample at the chip rate: `step` frames of the samples' own
    /// rate a tick.
    mutating func next(_ sounds: DiscDriveSounds, step: Double) -> Float {
        var level: Float = 0
        if var voice = spin {
            let samples = sounds[voice.sound]
            level += samples[min(Int(voice.position), samples.count - 1)]
            voice.position += step
            if voice.position >= Double(samples.count) {
                switch voice.sound {
                case .spinStartLoaded, .spinLoaded: voice = Voice(sound: .spinLoaded, position: voice.position - Double(samples.count))
                case .spinStartEmpty, .spinEmpty: voice = Voice(sound: .spinEmpty, position: voice.position - Double(samples.count))
                default: spin = nil
                }
            }
            if spin != nil { spin = voice }
        }
        if var voice = head {
            let samples = sounds[voice.sound]
            level += samples[min(Int(voice.position), samples.count - 1)]
            voice.position += step
            head = voice.position >= min(voice.end, Double(samples.count)) ? nil : voice
        }
        return level
    }
}
