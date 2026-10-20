// CSW tape images (Compressed Square Wave, versions 1 and 2, RLE or Z-RLE):
// recordings of the tape's square wave as pulse (half wave) lengths.
//
// Pulses are read back into slots by length: two short ones (about 1/4800s
// each) are a cycle of high tone, a long one (1/2400s) half a cycle of low
// tone, and anything much longer silence.

public enum CSW {
    public enum Error: Swift.Error, Equatable {
        case notCSW
        case unsupported
        case badData
    }

    static let signature = Array("Compressed Square Wave\u{1A}".utf8)

    public static func tape(_ file: [UInt8]) throws(Error) -> Tape {
        let (rate, pulses) = try self.pulses(file)
        return Tape(segments: segments(pulses, sampleRate: rate))
    }

    /// The sample rate and the pulse lengths (in samples).
    static func pulses(_ file: [UInt8]) throws(Error) -> (rate: Int, pulses: [Int]) {
        guard file.count >= 0x20, Array(file[0..<signature.count]) == signature else { throw .notCSW }
        func u16(_ i: Int) -> Int { Int(file[i]) | Int(file[i + 1]) << 8 }
        func u32(_ i: Int) -> Int { u16(i) | u16(i + 2) << 16 }
        let rate: Int
        let compression: UInt8
        let dataStart: Int
        switch file[0x17] {
        case 1:
            rate = u16(0x19)
            compression = file[0x1B]
            dataStart = 0x20
        case 2:
            guard file.count >= 0x34 else { throw .notCSW }
            rate = u32(0x19)
            compression = file[0x21]
            dataStart = 0x34 + Int(file[0x23])
        default:
            throw .unsupported
        }
        guard rate > 0, dataStart <= file.count else { throw .badData }
        let data: [UInt8]
        switch compression {
        case 1:
            data = Array(file[dataStart...])
        case 2:
            guard let inflated = Gzip.decompressZlib(file[dataStart...]) else { throw .badData }
            data = inflated
        default:
            throw .unsupported
        }
        var pulses: [Int] = []
        var i = 0
        while i < data.count {
            if data[i] != 0 {
                pulses.append(Int(data[i]))
                i += 1
            } else {
                guard i + 5 <= data.count else { throw .badData }
                pulses.append(Int(data[i + 1]) | Int(data[i + 2]) << 8 | Int(data[i + 3]) << 16 | Int(data[i + 4]) << 24)
                i += 5
            }
        }
        return (rate, pulses)
    }

    static func segments(_ pulses: [Int], sampleRate: Int) -> [Tape.Segment] {
        let slotRate = Tape.Segment.standardRate
        var signals: [Tape.Signal] = []
        var segments: [Tape.Segment] = []
        var pendingShort = false
        for pulse in pulses {
            // In slots (1/2400s): a high tone half wave is 0.5, a low 1.
            let slots = Double(pulse) * Double(slotRate) / Double(sampleRate)
            if slots < 0.75 {
                if pendingShort { signals.append(.high) }
                pendingShort.toggle()
            } else if slots < 4 {
                pendingShort = false
                signals.append(.low)
            } else {
                pendingShort = false
                if !signals.isEmpty {
                    segments.append(.pattern(signals))
                    signals = []
                }
                segments.append(.tone(.silence, slots: Int(slots.rounded())))
            }
        }
        if !signals.isEmpty { segments.append(.pattern(signals)) }
        return segments
    }
}

extension Tape {
    /// A tape from a UEF (plain or gzipped) or CSW image.
    public convenience init(image: [UInt8]) throws {
        if image.starts(with: CSW.signature) {
            let (rate, pulses) = try CSW.pulses(image)
            self.init(segments: CSW.segments(pulses, sampleRate: rate))
        } else {
            self.init(segments: UEF.segments(try UEF.chunks(image)))
        }
    }
}
