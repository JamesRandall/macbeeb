// The disc drives' noises: MAME's samples, and what plays when.

import Foundation
import Testing
@testable import BeebCore
import BeebROMs

struct DiscDriveNoiseTests {
    @Test func samplesLoad() throws {
        for model in [BBCMicro.Model.modelB, .masterCompact] {
            let sounds = try #require(BeebROMs.discDriveSounds(for: model))
            #expect(sounds.rate == 44_100)
            for sound in DiscDriveSounds.Sound.allCases {
                #expect(!sounds[sound].isEmpty, "\(sound)")
            }
            // Something to hear in the running motor.
            #expect(sounds[.spinLoaded].map(abs).max()! > 0.01)
        }
    }

    @Test func decodesWAV() throws {
        // A 16-bit mono WAV of three samples.
        var wav: [UInt8] = Array("RIFF".utf8) + [0, 0, 0, 0] + Array("WAVEfmt ".utf8) + [16, 0, 0, 0, 1, 0, 1, 0]
        wav += [0x22, 0x56, 0, 0, 0x44, 0xAC, 0, 0, 2, 0, 16, 0] + Array("data".utf8) + [6, 0, 0, 0]
        wav += [0, 0x40, 0, 0xC0, 0xFF, 0x7F]
        let decoded = try #require(DiscDriveSounds.decodeWAV(wav))
        #expect(decoded.rate == 22_050)
        #expect(decoded.samples.count == 3 && decoded.samples[0] == 0.5 && decoded.samples[1] == -0.5)
        #expect(DiscDriveSounds.decodeWAV(Array("not a wav".utf8)) == nil)
    }

    @Test func playsWhatTheDriveDoes() throws {
        let sounds = try #require(BeebROMs.discDriveSounds(for: .modelB))
        var noise = DiscDriveNoise()
        noise.event(.startSpinning, hasDisc: true, sounds: sounds)
        #expect(noise.spin?.sound == .spinStartLoaded)
        // Through the start into the loop.
        for _ in 0..<sounds[.spinStartLoaded].count + 10 { _ = noise.next(sounds, step: 1) }
        #expect(noise.spin?.sound == .spinLoaded)
        noise.event(.seekStart(steps: 1, stepMs: 6), hasDisc: true, sounds: sounds)
        #expect(noise.head?.sound == .step)
        // A seek takes the sample for its rate, for as long as it lasts.
        noise.event(.seekStart(steps: -10, stepMs: 6), hasDisc: true, sounds: sounds)
        #expect(noise.head?.sound == .seek6ms && noise.head!.end == min(Double(sounds[.seek6ms].count), 0.06 * 44_100))
        noise.event(.seekStart(steps: 3, stepMs: 24), hasDisc: true, sounds: sounds)
        #expect(noise.head?.sound == .seek20ms)
        // Stopped short: it ends there.
        for _ in 0..<100 { _ = noise.next(sounds, step: 1) }
        noise.event(.seekEnd(steps: 1), hasDisc: true, sounds: sounds)
        _ = noise.next(sounds, step: 1)
        #expect(noise.head == nil)
        noise.event(.stopSpinning, hasDisc: true, sounds: sounds)
        for _ in 0..<sounds[.spinEnd].count + 10 { _ = noise.next(sounds, step: 1) }
        #expect(noise.spin == nil)
    }

    /// Reading a disc makes a noise, with the sounds on, and doesn't change
    /// what the machine does.
    @Test func readingADiscIsHeard() throws {
        func catalogue(sounds: DiscDriveSounds?) throws -> (level: Float, machine: BBCMicro) {
            let m = try bootModelBWithDFS("bcdtest.ssd")
            let ring = SampleRing(capacity: 48_000 * 4)
            m.attachAudio(sampleRate: 48_000, ring: ring)
            m.discDriveSounds = sounds
            m.paste("*CAT\n")
            m.run(seconds: 2)
            var buffer = [Float](repeating: 0, count: ring.count)
            let n = buffer.withUnsafeMutableBufferPointer { ring.read(into: $0) }
            return (buffer.prefix(n).map(abs).max() ?? 0, m)
        }
        let heard = try catalogue(sounds: BeebROMs.discDriveSounds(for: .modelB))
        let silent = try catalogue(sounds: nil)
        #expect(heard.level > silent.level + 0.05, "\(heard.level) \(silent.level)")
        #expect(heard.machine.cycles == silent.machine.cycles && heard.machine.screenText() == silent.machine.screenText())
    }
}

extension DiscDriveNoise.Voice: Equatable {
    public static func == (a: Self, b: Self) -> Bool { a.sound == b.sound && a.position == b.position && a.end == b.end }
}
