import BeebCore
import Foundation

/// Records a running machine: call `capture()` after each slice of
/// emulation, on the thread that runs the machine.
public final class MachineRecorder {
    public let recorder: VideoRecorder
    private let machine: BBCMicro
    private let tv: TVOutput
    private let audio: SampleRing
    private var lastFrame: Int
    private var buffer: [Float]

    public init(machine: BBCMicro, tv: TVOutput, url: URL, codec: VideoRecorder.Codec, sampleRate: Int = 48_000) throws {
        recorder = try VideoRecorder(url: url, codec: codec, sampleRate: sampleRate)
        self.machine = machine
        self.tv = tv
        // 1s of headroom between captures.
        audio = SampleRing(capacity: sampleRate)
        buffer = [Float](repeating: 0, count: sampleRate)
        lastFrame = tv.frameCount
        machine.recordingAudio = audio
    }

    /// Writes any frame and audio produced since the last call.
    public func capture() throws {
        let count = audio.count
        if count > 0 {
            let n = buffer.withUnsafeMutableBufferPointer { pointer in
                audio.read(into: UnsafeMutableBufferPointer(rebasing: pointer[0..<count]))
            }
            try recorder.append(audio: Array(buffer[0..<n]))
        }
        if tv.frameCount != lastFrame {
            lastFrame = tv.frameCount
            try recorder.append(frame: tv.lastFrame, cycles: machine.cycles)
        }
    }

    public func finish() throws {
        try capture()
        machine.recordingAudio = nil
        try recorder.finish()
    }
}
