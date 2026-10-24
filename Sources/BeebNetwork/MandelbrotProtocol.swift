import BeebCore
import Foundation

// The Distributed Mandelbrot demo's own protocol (version 1, frozen in
// Examples/distributed-mandelbrot/protocol.md): what its guest programs
// put in their Econet frames on ports &B0-&B3. Read here only to show the
// traffic and follow a render; nothing here takes part in one.

/// The protocol's constants, and reading and writing its messages.
public enum MandelbrotProtocol {
    public static let magic: [UInt8] = [0x4D, 0x42]   // "MB"
    public static let version: UInt8 = 1
    public static let headerLength = 14

    /// The ports, by who listens on them.
    public enum Port: UInt8, Sendable, CaseIterable {
        /// MANDEL: HELLO, READY, RESULT.
        case coordinator = 0xB0
        /// WORKER: WELCOME, ASSIGN, ACK, COMPLETE.
        case worker = 0xB1
        /// CLUSTER and the other launchers: BOOT_HELLO, START_ACK, LAUNCH_ERROR, STATUS.
        case launcher = 0xB2
        /// A running worker's management: DISCOVER, START, STOP.
        case bootstrap = 0xB3

        public var name: String {
            switch self {
            case .coordinator: "Mandelbrot coordinator"
            case .worker: "Mandelbrot worker"
            case .launcher: "Mandelbrot launcher"
            case .bootstrap: "Mandelbrot management"
            }
        }
    }

    public static let ports: ClosedRange<UInt8> = 0xB0...0xB3

    /// What a port's for, if it's one of the demo's.
    public static func portName(_ port: UInt8) -> String? { Port(rawValue: port)?.name }

    // The image and its tiles.
    public static let imageWidth = 160
    public static let imageHeight = 256
    public static let tileWidth = 16
    public static let tileHeight = 8
    public static let tileColumns = imageWidth / tileWidth   // 10
    public static let tileRows = imageHeight / tileHeight    // 32
    public static let tileCount = tileColumns * tileRows     // 320
    public static let defaultMaxIterations = 64

    /// A tile's origin: tiles go along each row, top row first.
    public static func origin(ofTile id: Int) -> (x: Int, y: Int) {
        ((id % tileColumns) * tileWidth, (id / tileColumns) * tileHeight)
    }

    /// Why a frame isn't a message (a receiver would ignore it).
    public enum DecodeError: Error, Sendable, Equatable, CustomStringConvertible {
        case tooShort(Int)
        case badMagic
        case badVersion(UInt8)
        /// 14 + the header's payload length isn't the frame's length.
        case lengthMismatch(declared: Int, received: Int)
        case reservedType(UInt8)
        case unknownType(UInt8)
        /// The payload isn't the length its type needs.
        case wrongPayloadLength(type: String, expected: String, received: Int)

        public var description: String {
            switch self {
            case .tooShort(let count): "Too short: \(count) byte\(count == 1 ? "" : "s"), not the header's 14"
            case .badMagic: "Not \"MB\""
            case .badVersion(let version): "Version \(version), not 1"
            case .lengthMismatch(let declared, let received):
                "The header says \(declared) payload bytes, but \(received) came"
            case .reservedType(let type): "Type \(type) is reserved: version 1 doesn't send it"
            case .unknownType(let type): "Type \(type) isn't one of the protocol's"
            case .wrongPayloadLength(let type, let expected, let received):
                "\(type) needs \(expected) payload bytes, not \(received)"
            }
        }
    }

    /// Reads a frame's data (after Econet's four address bytes) as a message,
    /// checking it as a receiver does.
    public static func decode<Bytes: Collection<UInt8>>(_ bytes: Bytes) -> Result<MandelbrotMessage, DecodeError> {
        let b = Array(bytes)
        guard b.count >= headerLength else { return .failure(.tooShort(b.count)) }
        guard b[0] == magic[0] && b[1] == magic[1] else { return .failure(.badMagic) }
        guard b[2] == version else { return .failure(.badVersion(b[2])) }
        var reader = Reader(bytes: b, at: 3)
        let type = reader.u8()
        let header = MandelbrotMessage.Header(runId: reader.u32(), messageId: reader.u16(), sender: reader.u8(), flags: reader.u8())
        let declared = Int(reader.u16())
        let received = b.count - headerLength
        guard declared == received else { return .failure(.lengthMismatch(declared: declared, received: received)) }
        let payload = Array(b[headerLength...])
        switch MandelbrotMessage.Body.decode(type: type, payload: payload) {
        case .success(let body): return .success(MandelbrotMessage(header: header, body: body))
        case .failure(let error): return .failure(error)
        }
    }
}

/// One of the protocol's messages: its header and what it says.
public struct MandelbrotMessage: Sendable, Equatable {
    public struct Header: Sendable, Equatable {
        /// The render it's part of (0 on the management ports).
        public var runId: UInt32
        /// The sender's own counter.
        public var messageId: UInt16
        /// The sender's station, as it says (diagnostic only).
        public var sender: UInt8
        public var flags: UInt8

        public init(runId: UInt32 = 0, messageId: UInt16 = 0, sender: UInt8 = 0, flags: UInt8 = 0) {
            self.runId = runId
            self.messageId = messageId
            self.sender = sender
            self.flags = flags
        }
    }

    public struct Hello: Sendable, Equatable {
        /// 1 = worker.
        public var role: UInt8 = 1
        /// OSBYTE 0's X: which machine it is.
        public var machine: UInt8
        /// Bit 0: Q8.8.
        public var numericFormats: UInt8 = 1
        public var workerVersion: UInt8 = 1
        public init(role: UInt8 = 1, machine: UInt8, numericFormats: UInt8 = 1, workerVersion: UInt8 = 1) {
            self.role = role; self.machine = machine; self.numericFormats = numericFormats; self.workerVersion = workerVersion
        }
    }

    public struct Welcome: Sendable, Equatable {
        public var width: UInt16 = 160
        public var height: UInt16 = 256
        public var maxIterations: UInt8
        public var tileWidth: UInt8 = 16
        public var tileHeight: UInt8 = 8
        public var numericFormat: UInt8 = 1
        public init(width: UInt16 = 160, height: UInt16 = 256, maxIterations: UInt8, tileWidth: UInt8 = 16,
                    tileHeight: UInt8 = 8, numericFormat: UInt8 = 1) {
            self.width = width; self.height = height; self.maxIterations = maxIterations
            self.tileWidth = tileWidth; self.tileHeight = tileHeight; self.numericFormat = numericFormat
        }
    }

    public struct Assign: Sendable, Equatable {
        public var tileId: UInt16
        public var epoch: UInt16
        public var x: UInt8, y: UInt8, width: UInt8, height: UInt8
        /// Q8.8.
        public var startReal: Int16, startImag: Int16, stepReal: Int16, stepImag: Int16
        public var maxIterations: UInt8
        public var numericFormat: UInt8 = 1
        public init(tileId: UInt16, epoch: UInt16, x: UInt8, y: UInt8, width: UInt8, height: UInt8,
                    startReal: Int16, startImag: Int16, stepReal: Int16, stepImag: Int16,
                    maxIterations: UInt8, numericFormat: UInt8 = 1) {
            self.tileId = tileId; self.epoch = epoch; self.x = x; self.y = y; self.width = width; self.height = height
            self.startReal = startReal; self.startImag = startImag; self.stepReal = stepReal; self.stepImag = stepImag
            self.maxIterations = maxIterations; self.numericFormat = numericFormat
        }

        /// The tile as the coordinator assigns it, from the protocol's mapping.
        public static func standard(tile: Int, epoch: UInt16, maxIterations: UInt8 = 64) -> Assign {
            let (x, y) = MandelbrotProtocol.origin(ofTile: tile)
            return Assign(tileId: UInt16(tile), epoch: epoch, x: UInt8(x), y: UInt8(y),
                          width: UInt8(MandelbrotProtocol.tileWidth), height: UInt8(MandelbrotProtocol.tileHeight),
                          startReal: Int16(-576 + 5 * x), startImag: Int16(384 - 3 * y), stepReal: 5, stepImag: -3,
                          maxIterations: maxIterations)
        }
    }

    public struct TileResult: Sendable, Equatable {
        public var tileId: UInt16
        public var epoch: UInt16
        public var x: UInt8, y: UInt8, width: UInt8, height: UInt8
        /// 1 = raw 8-bit counts.
        public var format: UInt8 = 1
        /// Escape counts, row by row from the top.
        public var counts: [UInt8]
        public init(tileId: UInt16, epoch: UInt16, x: UInt8, y: UInt8, width: UInt8, height: UInt8, format: UInt8 = 1,
                    counts: [UInt8]) {
            self.tileId = tileId; self.epoch = epoch; self.x = x; self.y = y; self.width = width; self.height = height
            self.format = format; self.counts = counts
        }
    }

    public struct Ack: Sendable, Equatable {
        public var tileId: UInt16
        public var epoch: UInt16
        /// 0 = accepted, 1 = duplicate (already done), 2 = stale epoch or
        /// not assigned to the worker.
        public var status: UInt8
        public init(tileId: UInt16, epoch: UInt16, status: UInt8) {
            self.tileId = tileId; self.epoch = epoch; self.status = status
        }

        public var statusText: String {
            switch status {
            case 0: "accepted"
            case 1: "duplicate"
            case 2: "stale"
            default: "status \(status)"
            }
        }
    }

    public enum Body: Sendable, Equatable {
        case hello(Hello)
        case welcome(Welcome)
        /// The worker's station.
        case ready(station: UInt8)
        case assign(Assign)
        case result(TileResult)
        case ack(Ack)
        case complete(tiles: UInt16)
        case discover(nonce: UInt32, target: UInt8, launcher: UInt8)
        /// state 1 = bootstrap waiting, 2 = worker running.
        case bootHello(nonce: UInt32, station: UInt8, state: UInt8, bootstrapVersion: UInt8, workerVersion: UInt8)
        case start(nonce: UInt32, target: UInt8, coordinator: UInt8)
        /// status 0 = loading WORKER, 1 = already running (adopted the new coordinator).
        case startAck(nonce: UInt32, status: UInt8)
        case launchError(nonce: UInt32, error: UInt8, message: String)
        case stop(nonce: UInt32)
        /// state 2 = running, 3 = stopping.
        case status(nonce: UInt32, state: UInt8, workerVersion: UInt8, coordinator: UInt8)

        public var type: UInt8 {
            switch self {
            case .hello: 1
            case .welcome: 2
            case .ready: 3
            case .assign: 4
            case .result: 5
            case .ack: 6
            case .complete: 8
            case .discover: 11
            case .bootHello: 12
            case .start: 13
            case .startAck: 14
            case .launchError: 15
            case .stop: 16
            case .status: 17
            }
        }

        public var name: String { Self.name(of: type) ?? "type \(type)" }

        public static func name(of type: UInt8) -> String? {
            switch type {
            case 1: "HELLO"
            case 2: "WELCOME"
            case 3: "READY"
            case 4: "ASSIGN"
            case 5: "RESULT"
            case 6: "ACK"
            case 7: "PROGRESS"
            case 8: "COMPLETE"
            case 9: "ERROR"
            case 10: "CANCEL"
            case 11: "DISCOVER"
            case 12: "BOOT_HELLO"
            case 13: "START"
            case 14: "START_ACK"
            case 15: "LAUNCH_ERROR"
            case 16: "STOP"
            case 17: "STATUS"
            default: nil
            }
        }

        /// The payload's length for each type (RESULT's and LAUNCH_ERROR's
        /// depend on what's in them).
        static func fixedLength(of type: UInt8) -> Int? {
            switch type {
            case 1: 4
            case 2: 8
            case 3: 1
            case 4: 18
            case 6: 5
            case 8: 2
            case 11: 6
            case 12: 8
            case 13: 6
            case 14: 5
            case 16: 4
            case 17: 7
            default: nil
            }
        }

        static let launchErrorText = 40

        static func decode(type: UInt8, payload p: [UInt8]) -> Swift.Result<Body, MandelbrotProtocol.DecodeError> {
            guard let name = name(of: type) else { return .failure(.unknownType(type)) }
            if type == 7 || type == 9 || type == 10 { return .failure(.reservedType(type)) }
            if let length = fixedLength(of: type), p.count != length {
                return .failure(.wrongPayloadLength(type: name, expected: "\(length)", received: p.count))
            }
            var r = Reader(bytes: p, at: 0)
            switch type {
            case 1: return .success(.hello(Hello(role: r.u8(), machine: r.u8(), numericFormats: r.u8(), workerVersion: r.u8())))
            case 2:
                return .success(.welcome(Welcome(width: r.u16(), height: r.u16(), maxIterations: r.u8(), tileWidth: r.u8(),
                                                 tileHeight: r.u8(), numericFormat: r.u8())))
            case 3: return .success(.ready(station: r.u8()))
            case 4:
                return .success(.assign(Assign(tileId: r.u16(), epoch: r.u16(), x: r.u8(), y: r.u8(), width: r.u8(), height: r.u8(),
                                               startReal: r.i16(), startImag: r.i16(), stepReal: r.i16(), stepImag: r.i16(),
                                               maxIterations: r.u8(), numericFormat: r.u8())))
            case 5:
                // 9 bytes, then width x height counts.
                guard p.count >= 9 else {
                    return .failure(.wrongPayloadLength(type: name, expected: "9 + width × height", received: p.count))
                }
                let tile = r.u16(), epoch = r.u16(), x = r.u8(), y = r.u8(), width = r.u8(), height = r.u8(), format = r.u8()
                let cells = Int(width) * Int(height)
                guard p.count == 9 + cells else {
                    return .failure(.wrongPayloadLength(type: name, expected: "9 + \(width) × \(height) = \(9 + cells)", received: p.count))
                }
                return .success(.result(TileResult(tileId: tile, epoch: epoch, x: x, y: y, width: width, height: height, format: format,
                                               counts: Array(p[9...]))))
            case 6: return .success(.ack(Ack(tileId: r.u16(), epoch: r.u16(), status: r.u8())))
            case 8: return .success(.complete(tiles: r.u16()))
            case 11: return .success(.discover(nonce: r.u32(), target: r.u8(), launcher: r.u8()))
            case 12:
                return .success(.bootHello(nonce: r.u32(), station: r.u8(), state: r.u8(), bootstrapVersion: r.u8(), workerVersion: r.u8()))
            case 13: return .success(.start(nonce: r.u32(), target: r.u8(), coordinator: r.u8()))
            case 14: return .success(.startAck(nonce: r.u32(), status: r.u8()))
            case 15:
                guard p.count >= 5 && p.count <= 5 + launchErrorText else {
                    return .failure(.wrongPayloadLength(type: name, expected: "5 to \(5 + launchErrorText)", received: p.count))
                }
                let nonce = r.u32(), error = r.u8()
                let text = String(decoding: p[5...].map { $0 >= 32 && $0 < 127 ? $0 : 46 }, as: UTF8.self)
                return .success(.launchError(nonce: nonce, error: error, message: text))
            case 16: return .success(.stop(nonce: r.u32()))
            default:
                return .success(.status(nonce: r.u32(), state: r.u8(), workerVersion: r.u8(), coordinator: r.u8()))
            }
        }

        var payload: [UInt8] {
            var w = Writer()
            switch self {
            case .hello(let m): w.u8(m.role); w.u8(m.machine); w.u8(m.numericFormats); w.u8(m.workerVersion)
            case .welcome(let m):
                w.u16(m.width); w.u16(m.height); w.u8(m.maxIterations); w.u8(m.tileWidth); w.u8(m.tileHeight); w.u8(m.numericFormat)
            case .ready(let station): w.u8(station)
            case .assign(let m):
                w.u16(m.tileId); w.u16(m.epoch); w.u8(m.x); w.u8(m.y); w.u8(m.width); w.u8(m.height)
                w.i16(m.startReal); w.i16(m.startImag); w.i16(m.stepReal); w.i16(m.stepImag); w.u8(m.maxIterations); w.u8(m.numericFormat)
            case .result(let m):
                w.u16(m.tileId); w.u16(m.epoch); w.u8(m.x); w.u8(m.y); w.u8(m.width); w.u8(m.height); w.u8(m.format)
                w.bytes += m.counts
            case .ack(let m): w.u16(m.tileId); w.u16(m.epoch); w.u8(m.status)
            case .complete(let tiles): w.u16(tiles)
            case .discover(let nonce, let target, let launcher): w.u32(nonce); w.u8(target); w.u8(launcher)
            case .bootHello(let nonce, let station, let state, let bootstrap, let worker):
                w.u32(nonce); w.u8(station); w.u8(state); w.u8(bootstrap); w.u8(worker)
            case .start(let nonce, let target, let coordinator): w.u32(nonce); w.u8(target); w.u8(coordinator)
            case .startAck(let nonce, let status): w.u32(nonce); w.u8(status)
            case .launchError(let nonce, let error, let message): w.u32(nonce); w.u8(error); w.bytes += Array(message.utf8)
            case .stop(let nonce): w.u32(nonce)
            case .status(let nonce, let state, let worker, let coordinator): w.u32(nonce); w.u8(state); w.u8(worker); w.u8(coordinator)
            }
            return w.bytes
        }
    }

    public var header: Header
    public var body: Body

    public init(header: Header = Header(), body: Body) {
        self.header = header
        self.body = body
    }

    public var type: UInt8 { body.type }

    /// The message as a frame's data: the header, then the payload. (For
    /// tests: the guests write their own.)
    public func encoded() -> [UInt8] {
        let payload = body.payload
        var w = Writer()
        w.bytes = MandelbrotProtocol.magic
        w.u8(MandelbrotProtocol.version); w.u8(body.type); w.u32(header.runId); w.u16(header.messageId)
        w.u8(header.sender); w.u8(header.flags); w.u16(UInt16(clamping: payload.count))
        return w.bytes + payload
    }

    /// One line, as the traffic lists it: "ASSIGN tile 17 (x 112, y 8)
    /// epoch 1 → station 2". `to` is the frame's destination.
    public func summary(to destination: UInt8? = nil) -> String {
        let to = destination.map { " → station \($0)" } ?? ""
        switch body {
        case .hello(let m): return "HELLO from a \(m.role == 1 ? "worker" : "role \(m.role)"), \(Self.machineName(m.machine))" + to
        case .welcome(let m): return "WELCOME run \(hex32(header.runId)), max \(m.maxIterations) iterations" + to
        case .ready(let station): return "READY station \(station)" + to
        case .assign(let m): return "ASSIGN tile \(m.tileId) (x \(m.x), y \(m.y)) epoch \(m.epoch)" + to
        case .result(let m): return "RESULT tile \(m.tileId) (x \(m.x), y \(m.y)) epoch \(m.epoch), \(m.counts.count) counts" + to
        case .ack(let m): return "ACK tile \(m.tileId) epoch \(m.epoch): \(m.statusText)" + to
        case .complete(let tiles): return "COMPLETE \(tiles) tiles" + to
        case .discover(_, let target, _): return "DISCOVER station \(target)" + to
        case .bootHello(_, let station, let state, _, _):
            return "BOOT_HELLO station \(station), \(state == 1 ? "bootstrap waiting" : state == 2 ? "worker running" : "state \(state)")" + to
        case .start(_, let target, let coordinator): return "START station \(target) for coordinator \(coordinator)" + to
        case .startAck(_, let status):
            return "START_ACK: \(status == 0 ? "loading WORKER" : status == 1 ? "already running" : "status \(status)")" + to
        case .launchError(_, let error, let message): return "LAUNCH_ERROR \(error): \(message)" + to
        case .stop: return "STOP" + to
        case .status(_, let state, _, let coordinator):
            return "STATUS \(state == 2 ? "running" : state == 3 ? "stopping" : "state \(state)"), coordinator \(coordinator)" + to
        }
    }

    /// Every field, labelled, as the traffic's detail shows them.
    public var fields: [(label: String, value: String)] {
        var list: [(String, String)] = [
            ("Type", "\(body.name) (\(body.type))"),
            ("Run", hex32(header.runId)),
            ("Message", "\(header.messageId)"),
            ("Sender", "station \(header.sender)"),
        ]
        if header.flags != 0 { list.append(("Flags", "&" + hex(header.flags))) }
        switch body {
        case .hello(let m):
            list += [("Role", m.role == 1 ? "worker" : "\(m.role)"), ("Machine", "\(Self.machineName(m.machine)) (\(m.machine))"),
                     ("Formats", m.numericFormats & 1 != 0 ? "Q8.8" : "&" + hex(m.numericFormats)),
                     ("Worker version", "\(m.workerVersion)")]
        case .welcome(let m):
            list += [("Image", "\(m.width) × \(m.height)"), ("Max iterations", "\(m.maxIterations)"),
                     ("Tiles", "\(m.tileWidth) × \(m.tileHeight)"), ("Format", m.numericFormat == 1 ? "Q8.8" : "\(m.numericFormat)")]
        case .ready(let station):
            list.append(("Station", "\(station)"))
        case .assign(let m):
            list += [("Tile", "\(m.tileId)"), ("Epoch", "\(m.epoch)"), ("Origin", "x \(m.x), y \(m.y)"),
                     ("Size", "\(m.width) × \(m.height)"),
                     ("Start", "\(q88(m.startReal)) + \(q88(m.startImag))i (\(m.startReal), \(m.startImag))"),
                     ("Step", "\(m.stepReal), \(m.stepImag)"), ("Max iterations", "\(m.maxIterations)"),
                     ("Format", m.numericFormat == 1 ? "Q8.8" : "\(m.numericFormat)")]
        case .result(let m):
            let total = m.counts.reduce(0) { $0 + Int($1) }
            list += [("Tile", "\(m.tileId)"), ("Epoch", "\(m.epoch)"), ("Origin", "x \(m.x), y \(m.y)"),
                     ("Size", "\(m.width) × \(m.height)"), ("Format", m.format == 1 ? "raw 8-bit counts" : "\(m.format)"),
                     ("Iterations", "\(total) in all, \(m.counts.min() ?? 0) to \(m.counts.max() ?? 0)")]
        case .ack(let m):
            list += [("Tile", "\(m.tileId)"), ("Epoch", "\(m.epoch)"), ("Status", "\(m.status): \(m.statusText)")]
        case .complete(let tiles):
            list.append(("Tiles", "\(tiles)"))
        case .discover(let nonce, let target, let launcher):
            list += [("Nonce", hex32(nonce)), ("Target", "station \(target)"), ("Launcher", "station \(launcher)")]
        case .bootHello(let nonce, let station, let state, let bootstrap, let worker):
            list += [("Nonce", hex32(nonce)), ("Station", "\(station)"),
                     ("State", state == 1 ? "bootstrap waiting" : state == 2 ? "worker running" : "\(state)"),
                     ("Bootstrap version", "\(bootstrap)"), ("Worker version", "\(worker)")]
        case .start(let nonce, let target, let coordinator):
            list += [("Nonce", hex32(nonce)), ("Target", "station \(target)"), ("Coordinator", "station \(coordinator)")]
        case .startAck(let nonce, let status):
            list += [("Nonce", hex32(nonce)), ("Status", status == 0 ? "loading WORKER" : status == 1 ? "already running" : "\(status)")]
        case .launchError(let nonce, let error, let message):
            list += [("Nonce", hex32(nonce)), ("Error", "\(error)"), ("Message", message)]
        case .stop(let nonce):
            list.append(("Nonce", hex32(nonce)))
        case .status(let nonce, let state, let worker, let coordinator):
            list += [("Nonce", hex32(nonce)), ("State", state == 2 ? "running" : state == 3 ? "stopping" : "\(state)"),
                     ("Worker version", "\(worker)"), ("Coordinator", "station \(coordinator)")]
        }
        return list
    }

    /// OSBYTE 0's X.
    static func machineName(_ x: UInt8) -> String {
        switch x {
        case 0: "Electron"
        case 1: "BBC Micro (OS 1.20)"
        case 2: "BBC B+"
        case 3: "Master 128"
        case 4: "Master ET"
        case 5: "Master Compact"
        default: "machine \(x)"
        }
    }
}

private func hex(_ value: UInt8) -> String { String(value, radix: 16, uppercase: true).leftPadded(2) }
private func hex32(_ value: UInt32) -> String { "&" + String(value, radix: 16, uppercase: true).leftPadded(8) }
private func q88(_ value: Int16) -> String { String(format: "%.4f", Double(value) / 256) }

private extension String {
    func leftPadded(_ width: Int) -> String {
        count >= width ? self : String(repeating: "0", count: width - count) + self
    }
}

/// Little-endian fields, read in order. The callers check the length first.
private struct Reader {
    let bytes: [UInt8]
    var at: Int
    mutating func u8() -> UInt8 { defer { at += 1 }; return bytes[at] }
    mutating func u16() -> UInt16 { UInt16(u8()) | UInt16(u8()) << 8 }
    mutating func i16() -> Int16 { Int16(bitPattern: u16()) }
    mutating func u32() -> UInt32 { UInt32(u16()) | UInt32(u16()) << 16 }
}

private struct Writer {
    var bytes: [UInt8] = []
    mutating func u8(_ value: UInt8) { bytes.append(value) }
    mutating func u16(_ value: UInt16) { bytes += [UInt8(value & 0xFF), UInt8(value >> 8)] }
    mutating func i16(_ value: Int16) { u16(UInt16(bitPattern: value)) }
    mutating func u32(_ value: UInt32) { u16(UInt16(value & 0xFFFF)); u16(UInt16(value >> 16)) }
}

// MARK: Frames

/// A data frame on one of the demo's ports, read as a message (or why it
/// can't be).
public struct MandelbrotReading: Sendable, Equatable {
    public var frame: Int
    public var port: UInt8
    /// Who sent it and who it was for.
    public var from: UInt8
    public var to: UInt8?
    public var message: Result<MandelbrotMessage, MandelbrotProtocol.DecodeError>

    public var summary: String {
        switch message {
        case .success(let message): message.summary(to: to)
        case .failure(let error): "Not a Mandelbrot message: \(error)"
        }
    }
}

/// Reads frames in the order they crossed the line, pairing each data
/// frame with its transaction's scout (which has the port: the data
/// doesn't), and reads those on &B0-&B3 as the demo's messages.
public struct MandelbrotTraffic: Sendable {
    /// Scouts on the demo's ports whose data hasn't come yet, by transaction.
    private var scouts: [Int: UInt8] = [:]

    public init() {}

    public mutating func read(_ frame: EconetFrame) -> MandelbrotReading? {
        guard let transaction = frame.transaction else { return nil }
        switch frame.kind {
        case .scout:
            if let port = frame.port, MandelbrotProtocol.ports.contains(port) {
                scouts[transaction] = port
                // Scouts that were never answered shouldn't pile up.
                if scouts.count > 256, let oldest = scouts.keys.min() { scouts[oldest] = nil }
            }
            return nil
        case .data:
            guard let port = scouts.removeValue(forKey: transaction) else { return nil }
            return MandelbrotReading(frame: frame.id, port: port, from: frame.transmitter, to: frame.destinationStation,
                                     message: MandelbrotProtocol.decode(frame.payload))
        case .acknowledgement, .broadcast, .unknown:
            return nil
        }
    }
}
