// The Distributed Mandelbrot demo's protocol as the Swift side reads it,
// and the observer that follows a render from the frames on the line.
// The frames are made here with the encoder, as the four-way handshake
// would put them on the line.

import Testing
@testable import BeebCore
import BeebNetwork

/// Frames as a trace would have them: each message a scout, its
/// acknowledgement, the data and the last acknowledgement.
struct SyntheticLine {
    var frames: [EconetFrame] = []
    var time: UInt64 = 0
    private var transaction = 0

    mutating func send(_ body: MandelbrotMessage.Body, from: UInt8, to: UInt8, port: UInt8, run: UInt32 = 0x1234_5678,
                       acknowledged: Bool = true) {
        let message = MandelbrotMessage(header: .init(runId: run, messageId: UInt16(frames.count & 0xFFFF), sender: from), body: body)
        sendData(message.encoded(), from: from, to: to, port: port, acknowledged: acknowledged)
    }

    mutating func sendData(_ data: [UInt8], from: UInt8, to: UInt8, port: UInt8, acknowledged: Bool = true) {
        transaction += 1
        add(from, [to, 0, from, 0, 0x80, port], .scout)
        guard acknowledged else { return }
        add(to, [from, 0, to, 0], .acknowledgement)
        add(from, [to, 0, from, 0] + data, .data)
        add(to, [from, 0, to, 0], .acknowledgement)
    }

    /// Time passing, in seconds.
    mutating func wait(_ seconds: Double) { time += UInt64(seconds * 2_000_000) }

    private mutating func add(_ transmitter: UInt8, _ bytes: [UInt8], _ kind: EconetFrame.Kind) {
        let end = time + UInt64(bytes.count * 40)
        frames.append(EconetFrame(id: frames.count, start: time, end: end, transmitter: transmitter, bytes: bytes,
                                  status: .valid, kind: kind, transaction: transaction))
        time = end + 100
    }
}

struct MandelbrotProtocolTests {
    static let samples: [MandelbrotMessage.Body] = [
        .hello(.init(machine: 1)),
        .welcome(.init(maxIterations: 64)),
        .ready(station: 2),
        .assign(.standard(tile: 17, epoch: 1)),
        .result(.init(tileId: 17, epoch: 1, x: 112, y: 8, width: 16, height: 8, counts: (0 ..< 128).map { UInt8($0 % 64 + 1) })),
        .ack(.init(tileId: 17, epoch: 1, status: 0)),
        .complete(tiles: 320),
        .discover(nonce: 0xDEAD_BEEF, target: 3, launcher: 1),
        .bootHello(nonce: 0xDEAD_BEEF, station: 3, state: 1, bootstrapVersion: 1, workerVersion: 0),
        .start(nonce: 7, target: 3, coordinator: 1),
        .startAck(nonce: 7, status: 0),
        .launchError(nonce: 7, error: 214, message: "File not found"),
        .stop(nonce: 9),
        .status(nonce: 9, state: 2, workerVersion: 1, coordinator: 1),
    ]

    @Test(arguments: samples)
    func messagesRoundTrip(body: MandelbrotMessage.Body) throws {
        let message = MandelbrotMessage(header: .init(runId: 0xCAFE_F00D, messageId: 513, sender: 4), body: body)
        let bytes = message.encoded()
        #expect(Array(bytes[0 ..< 4]) == [0x4D, 0x42, 1, body.type])
        #expect(bytes.count == 14 + Int(bytes[12]) + Int(bytes[13]) * 256)
        #expect(try MandelbrotProtocol.decode(bytes).get() == message)
        #expect(!message.summary().isEmpty)
        #expect(message.fields.first?.value.hasPrefix(body.name) == true)
    }

    @Test func headerIsLittleEndian() {
        let bytes = MandelbrotMessage(header: .init(runId: 0x0403_0201, messageId: 0x0605, sender: 7), body: .ready(station: 7)).encoded()
        #expect(bytes == [0x4D, 0x42, 1, 3, 1, 2, 3, 4, 5, 6, 7, 0, 1, 0, 7])
    }

    @Test func assignIsTheProtocolsMapping() throws {
        let bytes = MandelbrotMessage(body: .assign(.standard(tile: 17, epoch: 1))).encoded()
        guard case .assign(let assign) = try MandelbrotProtocol.decode(bytes).get().body else { Issue.record(); return }
        #expect((assign.x, assign.y, assign.width, assign.height) == (112, 8, 16, 8))
        #expect(assign.startReal == -576 + 5 * 112 && assign.startImag == 384 - 3 * 8)
        #expect((assign.stepReal, assign.stepImag) == (5, -3))
        #expect(MandelbrotMessage(body: .assign(assign)).summary(to: 2) == "ASSIGN tile 17 (x 112, y 8) epoch 1 → station 2")
    }

    @Test func malformedFramesAreRefused() {
        let good = MandelbrotMessage(body: .ack(.init(tileId: 1, epoch: 1, status: 0))).encoded()
        func refused(_ bytes: [UInt8]) -> MandelbrotProtocol.DecodeError? {
            if case .failure(let error) = MandelbrotProtocol.decode(bytes) { error } else { nil }
        }
        #expect(refused(Array(good.prefix(13))) == .tooShort(13))
        var bad = good; bad[0] = 0x4E
        #expect(refused(bad) == .badMagic)
        bad = good; bad[2] = 2
        #expect(refused(bad) == .badVersion(2))
        #expect(refused(good + [0]) == .lengthMismatch(declared: 5, received: 6))
        #expect(refused(Array(good.dropLast())) == .lengthMismatch(declared: 5, received: 4))
        // The header and the frame agree, but an ACK is 5 bytes.
        bad = good + [0]; bad[12] = 6
        #expect(refused(bad) == .wrongPayloadLength(type: "ACK", expected: "5", received: 6))
        bad = good; bad[3] = 7
        #expect(refused(bad) == .reservedType(7))
        bad = good; bad[3] = 99
        #expect(refused(bad) == .unknownType(99))
        // RESULT: 9 + width × height.
        var result = MandelbrotMessage(body: .result(.init(tileId: 0, epoch: 1, x: 0, y: 0, width: 16, height: 8,
                                                           counts: .init(repeating: 1, count: 128)))).encoded()
        result[14 + 7] = 4   // height 4: 64 counts, but 128 came
        #expect(refused(result) == .wrongPayloadLength(type: "RESULT", expected: "9 + 16 × 4 = 73", received: 137))
        // LAUNCH_ERROR's message is at most 40 bytes.
        let long = MandelbrotMessage(body: .launchError(nonce: 1, error: 1, message: String(repeating: "x", count: 41))).encoded()
        #expect(refused(long) == .wrongPayloadLength(type: "LAUNCH_ERROR", expected: "5 to 45", received: 46))
        let longest = MandelbrotMessage(body: .launchError(nonce: 1, error: 1, message: String(repeating: "x", count: 40))).encoded()
        #expect((try? MandelbrotProtocol.decode(longest).get()) != nil)
    }

    @Test func portsAreNamed() {
        #expect(MandelbrotProtocol.portName(0xB0) == "Mandelbrot coordinator")
        #expect(MandelbrotProtocol.portName(0xB3) == "Mandelbrot management")
        #expect(MandelbrotProtocol.portName(0x99) == nil)
    }

    @Test func dataIsPairedWithItsScout() {
        var line = SyntheticLine()
        line.send(.ready(station: 2), from: 2, to: 1, port: 0xB0)
        // Not the demo's port: its data isn't read.
        line.send(.ready(station: 2), from: 2, to: 1, port: 0x99)
        line.sendData([1, 2, 3], from: 2, to: 1, port: 0xB0)
        var traffic = MandelbrotTraffic()
        let readings = line.frames.compactMap { traffic.read($0) }
        #expect(readings.count == 2)
        #expect(readings[0].frame == 2 && readings[0].port == 0xB0 && readings[0].from == 2 && readings[0].to == 1)
        #expect(readings[0].summary == "READY station 2 → station 1")
        #expect(readings[1].message == .failure(.tooShort(3)))
    }
}

struct MandelbrotObserverTests {
    static let coordinator: UInt8 = 1
    static let run: UInt32 = 0x1234_5678

    /// A tile's counts, made up (the observer never works them out).
    static func counts(_ tile: Int) -> [UInt8] { (0 ..< 128).map { UInt8(($0 + tile) % 64 + 1) } }

    static func result(_ tile: Int, epoch: Int) -> MandelbrotMessage.Body {
        let (x, y) = MandelbrotProtocol.origin(ofTile: tile)
        return .result(.init(tileId: UInt16(tile), epoch: UInt16(epoch), x: UInt8(x), y: UInt8(y), width: 16, height: 8,
                             counts: counts(tile)))
    }

    static func join(_ line: inout SyntheticLine, _ worker: UInt8) {
        line.send(.hello(.init(machine: 1)), from: worker, to: coordinator, port: 0xB0, run: 0)
        line.send(.welcome(.init(maxIterations: 64)), from: coordinator, to: worker, port: 0xB1)
        line.send(.ready(station: worker), from: worker, to: coordinator, port: 0xB0)
    }

    static func assign(_ line: inout SyntheticLine, _ tile: Int, epoch: Int, to worker: UInt8) {
        line.send(.assign(.standard(tile: tile, epoch: UInt16(epoch))), from: coordinator, to: worker, port: 0xB1)
    }

    static func ack(_ line: inout SyntheticLine, _ tile: Int, epoch: Int, to worker: UInt8, status: UInt8 = 0) {
        line.send(.ack(.init(tileId: UInt16(tile), epoch: UInt16(epoch), status: status)), from: coordinator, to: worker, port: 0xB1)
    }

    @Test func emptyUntilTheDemosTraffic() {
        var observer = MandelbrotObserver()
        var line = SyntheticLine()
        line.sendData([1, 2, 3, 4, 5], from: 2, to: 254, port: 0x99)
        observer.observe(line.frames)
        #expect(observer.isEmpty)
        #expect(observer.workers.isEmpty)
    }

    @Test func followsATileThroughItsStates() {
        var line = SyntheticLine()
        var observer = MandelbrotObserver()
        Self.join(&line, 2)
        observer.observe(line.frames)
        #expect(observer.coordinator == 1)
        #expect(observer.runId == Self.run)
        #expect(observer.workers[2]?.state == .idle)
        #expect(observer.workers[2]?.machine == 1)

        var seen = line.frames.count
        Self.assign(&line, 17, epoch: 1, to: 2)
        observer.observe(line.frames[seen...]); seen = line.frames.count
        #expect(observer.workers[2]?.state == .computing)
        #expect(observer.inFlight.map(\.tile) == [17])
        #expect(observer.assignments[17]?.station == 2)

        line.send(Self.result(17, epoch: 1), from: 2, to: 1, port: 0xB0)
        observer.observe(line.frames[seen...]); seen = line.frames.count
        #expect(observer.workers[2]?.state == .sending)
        // Received, but not accepted: not in the picture yet.
        #expect(observer.received[.init(tile: 17, epoch: 1)] != nil)
        #expect(observer.accepted.isEmpty)
        #expect(observer.count(x: 112, y: 8) == nil)

        Self.ack(&line, 17, epoch: 1, to: 2)
        observer.observe(line.frames[seen...])
        let worker = observer.workers[2]!
        #expect(worker.state == .idle)
        #expect(observer.tilesCompleted == 1)
        #expect(observer.accepted[17]?.drawn == true)
        #expect(observer.inFlight.isEmpty)
        #expect((worker.tiles, worker.pixels, worker.iterations) == (1, 128, Self.counts(17).reduce(0) { $0 + Int($1) }))
        #expect(worker.bytes > 137)
        #expect(observer.count(x: 112, y: 8) == Self.counts(17)[0])
        #expect(observer.count(x: 127, y: 15) == Self.counts(17)[127])
        #expect(observer.count(x: 111, y: 8) == nil)
    }

    @Test func onlyAcceptedTilesAreDrawn() {
        var line = SyntheticLine()
        Self.join(&line, 2)
        Self.assign(&line, 0, epoch: 1, to: 2)
        line.send(Self.result(0, epoch: 1), from: 2, to: 1, port: 0xB0)
        // Stale: not drawn.
        Self.ack(&line, 0, epoch: 1, to: 2, status: 2)
        // Accepted, but its RESULT never seen: counted, not drawn.
        Self.assign(&line, 1, epoch: 1, to: 2)
        Self.ack(&line, 1, epoch: 1, to: 2)
        var observer = MandelbrotObserver()
        observer.observe(line.frames)
        #expect(observer.accepted[0] == nil)
        #expect(observer.workers[2]?.stale == 1)
        #expect(observer.accepted[1]?.drawn == false)
        #expect(observer.covered.allSatisfy { !$0 })
        #expect(observer.workers[2]?.tiles == 1)
    }

    /// The coordinator's ACK didn't get through, so the worker sent its
    /// RESULT again and heard "duplicate": the tile was accepted the first
    /// time, and it's drawn once.
    @Test func aDuplicateIsAnAcceptanceMissed() {
        var line = SyntheticLine()
        Self.join(&line, 2)
        Self.assign(&line, 3, epoch: 1, to: 2)
        line.send(Self.result(3, epoch: 1), from: 2, to: 1, port: 0xB0)
        line.send(Self.result(3, epoch: 1), from: 2, to: 1, port: 0xB0)
        Self.ack(&line, 3, epoch: 1, to: 2, status: 1)
        var observer = MandelbrotObserver()
        observer.observe(line.frames)
        #expect(observer.accepted[3]?.drawn == true)
        #expect(observer.workers[2]?.tiles == 1 && observer.workers[2]?.duplicates == 1)
        #expect(observer.tilesCompleted == 1)
    }

    @Test func aSlowWorkerIsUnresponsiveAndItsTileGoesElsewhere() {
        var line = SyntheticLine()
        Self.join(&line, 2)
        Self.join(&line, 3)
        Self.assign(&line, 5, epoch: 1, to: 2)
        var observer = MandelbrotObserver()
        observer.observe(line.frames)
        var seen = line.frames.count
        #expect(observer.workers[2]?.state == .computing)
        observer.advance(to: line.time + MandelbrotObserver.timeout + 1)
        #expect(observer.workers[2]?.state == .unresponsive)

        line.time = observer.now
        Self.assign(&line, 5, epoch: 2, to: 3)
        line.send(Self.result(5, epoch: 2), from: 3, to: 1, port: 0xB0)
        Self.ack(&line, 5, epoch: 2, to: 3)
        // The slow one's late result is stale.
        line.send(Self.result(5, epoch: 1), from: 2, to: 1, port: 0xB0)
        observer.observe(line.frames[seen...]); seen = line.frames.count
        #expect(observer.workers[2]?.state == .unresponsive)
        Self.ack(&line, 5, epoch: 1, to: 2, status: 2)
        observer.observe(line.frames[seen...])
        #expect(observer.workers[2]?.state == .idle)
        #expect(observer.accepted[5]?.epoch == 2 && observer.accepted[5]?.station == 3 && observer.accepted[5]?.drawn == true)
        #expect(observer.workers[3]?.tiles == 1 && observer.workers[2]?.tiles == 0)
    }

    @Test func aWholeRunIsComplete() {
        var line = SyntheticLine()
        let workers: [UInt8] = [2, 3, 4]
        for worker in workers { Self.join(&line, worker) }
        for tile in 0 ..< MandelbrotProtocol.tileCount {
            let worker = workers[tile % workers.count]
            Self.assign(&line, tile, epoch: 1, to: worker)
            line.send(Self.result(tile, epoch: 1), from: worker, to: 1, port: 0xB0)
            // A resend: received once.
            line.send(Self.result(tile, epoch: 1), from: worker, to: 1, port: 0xB0)
            Self.ack(&line, tile, epoch: 1, to: worker)
            line.send(.ready(station: worker), from: worker, to: 1, port: 0xB0)
        }
        for worker in workers { line.send(.complete(tiles: 320), from: 1, to: worker, port: 0xB1) }
        let end = line.time
        line.wait(5)
        line.send(.hello(.init(machine: 1)), from: 2, to: 1, port: 0xB0)

        var observer = MandelbrotObserver()
        observer.observe(line.frames)
        #expect(observer.tilesCompleted == 320)
        #expect(observer.completeSeen)
        #expect(observer.covered.allSatisfy { $0 })
        #expect(observer.missedFrames == 0 && observer.malformed == 0)
        // Elapsed stops at COMPLETE.
        #expect(observer.elapsedCycles! < end - observer.runStart! && observer.elapsedCycles! > 0)
        #expect(observer.workers.values.map(\.tiles).reduce(0, +) == 320)
        #expect(observer.workers.values.map(\.pixels).reduce(0, +) == 160 * 256)
        #expect(observer.workers[2]?.resultsSent == 2 * 107)
        #expect(observer.sortedWorkers.allSatisfy { $0.state == .idle })
        for tile in [0, 9, 10, 319] {
            let (x, y) = MandelbrotProtocol.origin(ofTile: tile)
            #expect(observer.count(x: x + 3, y: y + 2) == Self.counts(tile)[2 * 16 + 3])
        }
    }

    /// The picture is the workers' counts, placed: with the reference's
    /// counts sent, it's the reference's picture.
    @Test func theCompositeIsWhatWasSent() {
        var line = SyntheticLine()
        Self.join(&line, 2)
        for tile in 0 ..< MandelbrotProtocol.tileCount {
            let (x, y) = MandelbrotProtocol.origin(ofTile: tile)
            Self.assign(&line, tile, epoch: 1, to: 2)
            line.send(.result(.init(tileId: UInt16(tile), epoch: 1, x: UInt8(x), y: UInt8(y), width: 16, height: 8,
                                    counts: MandelbrotReference.tile(id: tile, maxIterations: 64))), from: 2, to: 1, port: 0xB0)
            Self.ack(&line, tile, epoch: 1, to: 2)
        }
        var observer = MandelbrotObserver()
        observer.observe(line.frames)
        #expect(observer.image == MandelbrotReference.image(maxIterations: 64))
        #expect(observer.workers[2]?.iterations == MandelbrotReference.image(maxIterations: 64).reduce(0) { $0 + Int($1) })
    }

    @Test func aNewRunStartsAgain() {
        var line = SyntheticLine()
        Self.join(&line, 2)
        Self.assign(&line, 0, epoch: 1, to: 2)
        line.send(Self.result(0, epoch: 1), from: 2, to: 1, port: 0xB0)
        Self.ack(&line, 0, epoch: 1, to: 2)
        line.send(.welcome(.init(maxIterations: 32)), from: 1, to: 2, port: 0xB1, run: 99)
        var observer = MandelbrotObserver()
        observer.observe(line.frames)
        #expect(observer.runId == 99)
        #expect(observer.maxIterations == 32)
        #expect(observer.accepted.isEmpty && observer.received.isEmpty)
        #expect(observer.covered.allSatisfy { !$0 })
        #expect(observer.workers[2]?.tiles == 0)
    }

    @Test func malformedAndMissedFramesAreCounted() {
        var line = SyntheticLine()
        line.sendData([0x4D, 0x42, 1, 3], from: 2, to: 1, port: 0xB0)
        Self.join(&line, 2)
        var observer = MandelbrotObserver()
        observer.observe(line.frames.prefix(3))
        observer.observe(line.frames.dropFirst(6))
        #expect(observer.malformed == 1)
        #expect(observer.missedFrames == 3)
    }
}
