// A local Econet: one shared, half-duplex line, its clock, and the stations
// plugged into it. Its stations run in lockstep (see NetworkHost): each runs
// a quantum of emulated time in turn, then the line delivers what they sent.
// What a station transmits reaches the others after `delay` cycles, never
// less than a quantum, so it never arrives in a station's past and the
// order the stations run in doesn't matter.

/// The line, as an observer sees it: every byte-time anyone transmitted.
public struct EconetLineEvent: Sendable, Equatable {
    /// When it started, in the network's 2MHz cycles.
    public var time: UInt64
    public var station: UInt8
    public var symbol: EconetSymbol
    /// Someone else was transmitting at the same time.
    public var collided: Bool
}

/// Something on the line that isn't a BBC Micro's Econet module (an
/// Internet gateway). It works in the network's time, and hears and
/// drives the line as a station does.
public protocol EconetLineDevice: AnyObject {
    /// Runs to `end` (network cycles): takes in what it's heard up to then,
    /// and returns what it puts on the line in [`start`, `end`), each symbol
    /// at its start time and as the station it's transmitting for.
    func run(from start: UInt64, to end: UInt64, clock: Bool, bitTime: Int) -> [(time: UInt64, station: UInt8, symbol: EconetSymbol)]
    /// Symbols from the others, at the network time each is in (all still to
    /// come, in time order).
    func hear(_ symbols: [(time: UInt64, symbol: EconetSymbol)])
}

public final class EconetBus {
    /// The clock's rate in bits a second, or nil if there's no clock.
    public var clockRate: Int?
    /// Cycles for a symbol to cross the line, and the longest quantum.
    public let delay: Int
    /// Sees every symbol, if set. Called on the network's thread.
    public var observer: ((EconetLineEvent) -> Void)?

    final class Port {
        let econet: Econet
        let now: () -> UInt64
        /// The network's time minus the machine's, this quantum.
        var offset: Int64 = 0
        var running = false
        /// When its last symbol ended (network time).
        var lastEnd: UInt64 = 0
        var collidedUntil: UInt64 = 0
        /// What it was last told of the line (clock, bit time, collision).
        var told: (Bool, Int, Bool)?

        init(econet: Econet, now: @escaping () -> UInt64) {
            self.econet = econet
            self.now = now
        }
    }

    private(set) var ports: [Port] = []
    /// Devices on the line that aren't BBCs, and when each last finished
    /// a symbol (and was collided with until).
    private var devices: [(device: EconetLineDevice, lastEnd: UInt64, collidedUntil: UInt64)] = []

    /// Plugs in a device (an Internet gateway).
    public func attach(device: EconetLineDevice) {
        guard !devices.contains(where: { $0.device === device }) else { return }
        devices.append((device, 0, 0))
    }

    public func detach(device: EconetLineDevice) {
        devices.removeAll { $0.device === device }
    }
    /// The network's time at the start of the quantum.
    public private(set) var time: UInt64 = 0

    public init(clockRate: Int? = 200_000, delay: Int = 32) {
        self.clockRate = clockRate
        self.delay = delay
    }

    var bitTime: Int {
        guard let clockRate, clockRate > 0 else { return 10 }
        return max(1, 2_000_000 / clockRate)
    }

    /// Plugs a machine's Econet module in. One station number each.
    public func attach(_ machine: BBCMicro) {
        guard let econet = machine.econet else { return }
        detach(machine)
        econet.bus = self
        ports.append(Port(econet: econet, now: { [unowned machine] in machine.cycles }))
        ports.sort { $0.econet.station < $1.econet.station }
    }

    public func detach(_ machine: BBCMicro) {
        guard let econet = machine.econet else { return }
        if let index = ports.firstIndex(where: { $0.econet === econet }) {
            ports.remove(at: index)
            econet.bus = nil
            econet.unplug(now: machine.cycles)
        }
    }

    public var stations: [UInt8] { ports.map(\.econet.station) }

    /// Which stations will run (the others aren't listening), until it's
    /// said again.
    public func setRunning(_ running: (Econet) -> Bool) {
        for port in ports {
            port.running = running(port.econet)
        }
    }

    /// Before the stations run: which of them will (the others aren't
    /// listening), and the line's state for each.
    public func beginQuantum(running: (Econet) -> Bool) {
        setRunning(running)
        beginQuantum()
    }

    /// Before the stations run: the line's state for each that will.
    public func beginQuantum() {
        for port in ports {
            guard port.running else { continue }
            let local = port.now()
            port.offset = Int64(bitPattern: time) - Int64(bitPattern: local)
            let line = (clockRate != nil, bitTime, time < port.collidedUntil)
            if port.told.map({ $0 != line }) ?? true {
                port.told = line
                port.econet.setLine(clock: line.0, bitTime: line.1, collision: line.2, now: local)
            }
        }
    }

    /// After the stations have each run `cycles`: what they sent goes onto
    /// the line, collisions spoil it, and it's delivered to the others.
    public func endQuantum(cycles: Int) {
        struct Sent {
            var port: Int
            var time: UInt64
            var symbol: EconetSymbol
            var collided = false
        }
        var sent: [Sent] = []
        for (index, port) in ports.enumerated() where port.running {
            for (time, symbol) in port.econet.outbox {
                sent.append(Sent(port: index, time: UInt64(Int64(bitPattern: time) + port.offset), symbol: symbol))
            }
            port.econet.outbox.removeAll(keepingCapacity: true)
        }
        // Devices are ports after the BBCs', transmitting as the stations
        // they speak for.
        var deviceStation: [Int: [UInt64: UInt8]] = [:]
        for (index, entry) in devices.enumerated() {
            let port = ports.count + index
            for (time, station, symbol) in entry.device.run(from: self.time, to: self.time + UInt64(cycles),
                                                              clock: clockRate != nil, bitTime: bitTime) {
                sent.append(Sent(port: port, time: time, symbol: symbol))
                deviceStation[port, default: [:]][time] = station
            }
        }
        func lastEnd(_ port: Int) -> UInt64 { port < ports.count ? ports[port].lastEnd : devices[port - ports.count].lastEnd }
        let byteTime = UInt64(bitTime * 8)
        if !sent.isEmpty {
            // Two stations driving the line at once.
            for i in sent.indices {
                let start = sent[i].time, end = start + byteTime
                for j in sent.indices where sent[j].port != sent[i].port {
                    if sent[j].time < end && sent[j].time + byteTime > start {
                        sent[i].collided = true
                    }
                }
                for index in 0..<(ports.count + devices.count) where index != sent[i].port && lastEnd(index) > start
                    && !sent.contains(where: { $0.port == index }) {
                    sent[i].collided = true
                }
            }
            for item in sent where item.collided {
                if item.port < ports.count {
                    ports[item.port].collidedUntil = item.time + byteTime * 2
                } else {
                    devices[item.port - ports.count].collidedUntil = item.time + byteTime * 2
                }
            }
            sent.sort { ($0.time, $0.port) < ($1.time, $1.port) }
            for item in sent {
                let station: UInt8
                if item.port < ports.count {
                    ports[item.port].lastEnd = max(ports[item.port].lastEnd, item.time + byteTime)
                    station = ports[item.port].econet.station
                } else {
                    let d = item.port - ports.count
                    devices[d].lastEnd = max(devices[d].lastEnd, item.time + byteTime)
                    station = deviceStation[item.port]?[item.time] ?? 0
                }
                observer?(EconetLineEvent(time: item.time, station: station, symbol: item.symbol, collided: item.collided))
            }
            for (index, port) in ports.enumerated() where port.running {
                let arriving = sent.filter { $0.port != index }.map { item in
                    // A byte's received when its last bit is in.
                    (time: UInt64(Int64(bitPattern: item.time + byteTime + UInt64(delay)) - port.offset),
                     symbol: item.collided ? EconetSymbol.garbage : item.symbol)
                }
                if !arriving.isEmpty {
                    port.econet.deliver(arriving)
                }
            }
            for (index, entry) in devices.enumerated() {
                let port = ports.count + index
                let arriving = sent.filter { $0.port != port }.map { item in
                    (time: item.time + byteTime + UInt64(delay), symbol: item.collided ? EconetSymbol.garbage : item.symbol)
                }
                if !arriving.isEmpty {
                    entry.device.hear(arriving)
                }
            }
        }
        time += UInt64(cycles)
    }
}
