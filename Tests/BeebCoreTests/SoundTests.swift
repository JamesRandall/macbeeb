import Testing
@testable import BeebCore

struct SoundTests {
    /// Runs a SOUND command and returns the samples for the middle of the
    /// note.
    func capture(_ command: String) -> [Float] {
        let machine = bootModelB()
        // Let the start-up beep finish.
        machine.run(seconds: 1)
        let ring = SampleRing(capacity: 48_000 * 4)
        machine.attachAudio(sampleRate: 48_000, ring: ring)
        machine.paste(command + "\n")
        machine.runUntilIdle()
        machine.run(seconds: 1)
        var samples = [Float](repeating: 0, count: ring.count)
        _ = samples.withUnsafeMutableBufferPointer { ring.read(into: $0) }
        return samples
    }

    /// Pitch from zero crossings of the signal, over its loud part.
    func frequency(_ samples: [Float]) -> Double {
        let mean = samples.reduce(0, +) / Float(samples.count)
        let centred = samples.map { $0 - mean }
        let peak = centred.map(abs).max() ?? 0
        let loud = centred.indices.filter { abs(centred[$0]) > peak * 0.5 }
        guard let first = loud.first, let last = loud.last, last > first else { return 0 }
        var crossings = 0
        for i in first..<last where centred[i] < 0 && centred[i + 1] >= 0 {
            crossings += 1
        }
        return Double(crossings) / (Double(last - first) / 48_000)
    }

    @Test func middleC() {
        // User Guide: pitch 53 is middle C. Duration 10 = 0.5s.
        let f = frequency(capture("SOUND 1,-15,53,10"))
        #expect(abs(f - 261.6) < 261.6 * 0.02, "\(f)Hz")
    }

    @Test func octaveUp() {
        // +48 is an octave.
        let f = frequency(capture("SOUND 1,-15,101,10"))
        #expect(abs(f - 523.3) < 523.3 * 0.02, "\(f)Hz")
    }

    @Test func silenceWhenQuiet() {
        let samples = capture("REM")
        let range = (samples.max() ?? 0) - (samples.min() ?? 0)
        #expect(range < 0.01)
    }
}
