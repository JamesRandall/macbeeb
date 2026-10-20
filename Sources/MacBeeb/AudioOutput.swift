import AVFoundation
import BeebCore
import BeebHost

/// Plays the emulator's sound. The render callback just copies from the
/// sample ring; the emulation thread keeps the ring topped up, so the audio
/// device's clock paces the emulation.
final class AudioOutput {
    private let engine = AVAudioEngine()
    private let host: EmulatorHost

    init(host: EmulatorHost) {
        self.host = host
    }

    func start() {
        let ring = host.audioRing
        guard let format = AVAudioFormat(standardFormatWithSampleRate: Double(host.sampleRate), channels: 1) else { return }
        let source = AVAudioSourceNode(format: format) { _, _, frameCount, buffers -> OSStatus in
            let list = UnsafeMutableAudioBufferListPointer(buffers)
            guard let data = list[0].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            _ = ring.read(into: UnsafeMutableBufferPointer(start: data, count: Int(frameCount)))
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
            host.setAudioActive(true)
        } catch {
            NSLog("MacBeeb: no audio: \(error)")
            host.setAudioActive(false)
        }
    }

    func stop() {
        engine.stop()
        host.setAudioActive(false)
    }
}
