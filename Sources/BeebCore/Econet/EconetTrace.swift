// What's been on a network's line, as frames: each station's symbols
// between flags, put back together, then read as Econet reads them (the
// four-way handshake's scout, acknowledgement and data). A bounded ring:
// old frames go as new ones arrive.

/// One frame seen on the line.
public struct EconetFrame: Sendable, Equatable, Codable, Identifiable {
    public enum Status: String, Sendable, Codable {
        /// Closed with its check bytes: as good as a receiver would take.
        case valid
        /// Spoiled by another station transmitting at the same time.
        case collided
        /// The transmitter gave up part way (an abort, or it ran dry).
        case aborted
    }

    /// What the frame is in Econet's four-way handshake.
    public enum Kind: String, Sendable, Codable {
        /// The first frame of a transaction: who it's for, the control
        /// byte and the port.
        case scout
        /// Four bytes: received, carry on.
        case acknowledgement
        /// The transaction's data, after the scout's acknowledgement.
        case data
        /// To station 255: everyone.
        case broadcast
        case unknown
    }

    /// Counts frames since the trace began.
    public var id: Int
    /// When its first byte went out, and when its closing flag did, in the
    /// network's 2MHz cycles.
    public var start: UInt64
    public var end: UInt64
    /// The station that transmitted it.
    public var transmitter: UInt8
    public var bytes: [UInt8]
    public var status: Status
    public var kind: Kind = .unknown
    /// Which transaction it's part of (scout, acknowledgement, data,
    /// acknowledgement), when that's known.
    public var transaction: Int?

    public var destinationStation: UInt8? { bytes.count > 0 ? bytes[0] : nil }
    public var destinationNetwork: UInt8? { bytes.count > 1 ? bytes[1] : nil }
    public var sourceStation: UInt8? { bytes.count > 2 ? bytes[2] : nil }
    public var sourceNetwork: UInt8? { bytes.count > 3 ? bytes[3] : nil }
    /// A scout's control byte and port.
    public var control: UInt8? { (kind == .scout || kind == .broadcast) && bytes.count > 4 ? bytes[4] : nil }
    public var port: UInt8? { (kind == .scout || kind == .broadcast) && bytes.count > 5 ? bytes[5] : nil }
    /// A data frame's payload (after its four address bytes).
    public var payload: ArraySlice<UInt8> { bytes.count > 4 ? bytes[4...] : [] }

    /// What a port's for, where it's a well-known one.
    public static func portName(_ port: UInt8) -> String? {
        switch port {
        case 0x00: "immediate operation"
        case 0x90: "file server reply"
        case 0x91...0x98: "file server data"
        case 0x99: "file server command"
        case 0x9C: "bridge"
        case 0x9E: "printer server reply"
        case 0x9F: "printer server enquiry"
        case 0xB0: "find server"
        case 0xD1: "printer data"
        case 0xD2: "TCP/IP"
        default: nil
        }
    }

    /// A one-line description, as the inspector lists it.
    public var summary: String {
        switch kind {
        case .scout, .broadcast:
            let portText = port.map { p in Self.portName(p).map { "port &\(hex(p)) (\($0))" } ?? "port &\(hex(p))" } ?? ""
            return (kind == .broadcast ? "Broadcast" : "Scout") + " · control &\(control.map(hex) ?? "?") · " + portText
        case .acknowledgement:
            return "Acknowledgement"
        case .data:
            return "Data · \(payload.count) byte\(payload.count == 1 ? "" : "s")"
        case .unknown:
            return "\(bytes.count) bytes"
        }
    }

    private func hex(_ value: UInt8) -> String { String(value, radix: 16, uppercase: true).leftPadded(2) }
}

extension String {
    func leftPadded(_ width: Int) -> String {
        count >= width ? self : String(repeating: "0", count: width - count) + self
    }
}

/// Builds frames from the line's symbols (see EconetBus.observer).
public final class EconetTrace {
    /// The most frames kept.
    public let capacity: Int
    public private(set) var frames: [EconetFrame] = []
    /// Every frame ever assembled (the next one's id).
    public private(set) var count = 0
    /// Collecting, or not (frames in progress still finish).
    public var recording = true

    private struct Building {
        var start: UInt64
        var bytes: [UInt8] = []
        var checks = 0
        var collided = false
    }
    private var building: [UInt8: Building] = [:]
    /// Scouts whose data frame hasn't been seen yet, by (from, to).
    private var awaitingData: [UInt16: Int] = [:]
    /// The latest transaction between two stations (either way round).
    private var latest: [UInt16: Int] = [:]
    private var transactions = 0

    public init(capacity: Int = 4096) {
        self.capacity = capacity
    }

    public func clear() {
        frames.removeAll()
        building.removeAll()
        awaitingData.removeAll()
        latest.removeAll()
    }

    public func observe(_ event: EconetLineEvent) {
        let station = event.station
        if event.collided {
            building[station]?.collided = true
        }
        switch event.symbol {
        case .flag:
            if let frame = building.removeValue(forKey: station), !frame.bytes.isEmpty {
                finish(frame, station: station, end: event.time,
                       status: frame.collided ? .collided : frame.checks >= 2 ? .valid : .aborted)
            }
        case .byte(let byte):
            if building[station] == nil { building[station] = Building(start: event.time) }
            building[station]?.bytes.append(byte)
        case .check:
            building[station]?.checks += 1
        case .abort, .garbage:
            if let frame = building.removeValue(forKey: station), !frame.bytes.isEmpty {
                finish(frame, station: station, end: event.time, status: event.symbol == .garbage ? .collided : .aborted)
            }
        }
    }

    private func finish(_ built: Building, station: UInt8, end: UInt64, status: EconetFrame.Status) {
        guard recording else { return }
        var frame = EconetFrame(id: count, start: built.start, end: end, transmitter: station, bytes: built.bytes, status: status)
        count += 1
        classify(&frame)
        frames.append(frame)
        if frames.count > capacity {
            frames.removeFirst(frames.count - capacity)
        }
    }

    /// Reads it as the four-way handshake: an acknowledgement is four
    /// bytes; a frame from a station whose scout to the same place was
    /// acknowledged is its data; otherwise it's a scout.
    private func classify(_ frame: inout EconetFrame) {
        guard frame.status == .valid, frame.bytes.count >= 4, let to = frame.destinationStation,
              let from = frame.sourceStation else { return }
        let pair = UInt16(from) << 8 | UInt16(to)
        let either = UInt16(min(from, to)) << 8 | UInt16(max(from, to))
        if to == 0xFF {
            frame.kind = .broadcast
            transactions += 1
            frame.transaction = transactions
        } else if frame.bytes.count == 4 {
            frame.kind = .acknowledgement
            frame.transaction = latest[either]
        } else if let transaction = awaitingData[pair], let last = frames.last(where: { $0.transaction == transaction }),
                  last.kind == .acknowledgement {
            frame.kind = .data
            frame.transaction = transaction
            awaitingData[pair] = nil
        } else {
            frame.kind = .scout
            transactions += 1
            frame.transaction = transactions
            awaitingData[pair] = transactions
            latest[either] = transactions
            // Immediate operations' scouts carry their data.
            if frame.bytes.count > 5 && frame.bytes[5] == 0 { awaitingData[pair] = nil }
        }
    }

    /// Frames after `id` (all, if nil), newest last, at most `limit`.
    public func frames(after id: Int?, limit: Int = .max) -> [EconetFrame] {
        let newer = id.map { last in frames.filter { $0.id > last } } ?? frames
        return Array(newer.suffix(limit))
    }
}
