// An AMX mouse on the user port.
//
// Each axis is a pair of quadrature signals: a clock to a VIA control line
// (X to CB1, Y to CB2), whose edges interrupt, and a direction to a port B
// bit, read at the edge to tell which way it went. The buttons pull port B
// bits low. Wired as BeebEm has it: X on PB0, Y on PB2 and the buttons
// (left, middle, right) on PB5-PB7; or, with the Master 512, whose mouse
// is wired differently, X on PB3, Y on PB4 and the buttons on PB0-PB2.
//
// BeebEm sets the interrupt flags directly; here the lines go through the
// quadrature cycle, so the VIA sees real edges on whichever one its PCR
// asks for. With X moving right (and Y moving up) the clock leads: the
// clock falls with the direction high and rises with it low. At rest both
// signals are high, as if nothing were connected.
//
// Like BeebEm, it waits for the software to take each interrupt before the
// next clock edge, so counts aren't lost; here for a while after (the
// Master 512's handler interrupts on both edges, flipping the PCR's edge
// bit after it has cleared the flag).

public struct AMXMouse: Codable, Sendable, Equatable {
    public struct Buttons: OptionSet, Codable, Sendable, Hashable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let left = Buttons(rawValue: 1)
        public static let middle = Buttons(rawValue: 2)
        public static let right = Buttons(rawValue: 4)
    }

    struct Axis: Codable, Sendable, Equatable {
        /// Counts still to send, forward positive.
        var pending = 0
        /// The place in the quadrature cycle, 0-3 (0: both signals high).
        var phase = 0
        /// The way the count under way is going: 1 or -1.
        var direction = 1
        /// 1MHz ticks the axis's interrupt flag has been clear.
        var clearTicks = 0

        /// The signals: forward goes 11, 01, 00, 10 (clock, direction).
        var clock: Bool { phase == 0 || phase == 3 }
        var directionSignal: Bool { phase == 0 || phase == 1 }

        /// One phase step, unless it would move the clock before the last
        /// edge's interrupt has been dealt with.
        mutating func step() {
            if phase == 0 {
                guard pending != 0 else { return }
                direction = pending > 0 ? 1 : -1
            }
            let next = (phase + direction) & 3
            let clockMoves = (next == 0 || next == 3) != clock
            guard !clockMoves || clearTicks >= AMXMouse.settleTicks else { return }
            if phase == 0 {
                pending -= direction
            }
            phase = next
        }
    }

    var x = Axis()
    var y = Axis()
    public internal(set) var buttons: Buttons = []
    /// 1MHz ticks until the next phase step.
    var countdown = 0

    /// 1MHz ticks between phase steps: four to a count, so about 4,000
    /// counts a second.
    static let ticksPerPhase = 60
    /// Counts kept while the software isn't taking them.
    static let maxPending = 1024
    /// 1MHz ticks an interrupt flag must have been clear before the next
    /// clock edge.
    static let settleTicks = 100

    /// Moves it: right and down are positive.
    mutating func move(dx: Int, dy: Int) {
        x.pending = max(-Self.maxPending, min(Self.maxPending, x.pending + dx))
        // Up is Y's forward.
        y.pending = max(-Self.maxPending, min(Self.maxPending, y.pending - dy))
    }

    /// At each 1MHz tick, after the user VIA's: drives its lines.
    @inline(__always)
    mutating func tick(_ via: inout VIA6522, master512: Bool) {
        // At rest it drives nothing.
        guard countdown > 0 || x.pending != 0 || y.pending != 0 || x.phase != 0 || y.phase != 0 || !buttons.isEmpty else {
            return
        }
        x.clearTicks = via.ifr & VIA6522.IRQ.cb1 != 0 ? 0 : x.clearTicks + 1
        y.clearTicks = via.ifr & VIA6522.IRQ.cb2 != 0 ? 0 : y.clearTicks + 1
        if countdown > 0 {
            countdown -= 1
        } else if x.pending != 0 || y.pending != 0 || x.phase != 0 || y.phase != 0 {
            countdown = Self.ticksPerPhase
            x.step()
            y.step()
        }
        let xBit: UInt8 = master512 ? 0x08 : 0x01
        let yBit: UInt8 = master512 ? 0x10 : 0x04
        var low: UInt8 = (x.directionSignal ? 0 : xBit) | (y.directionSignal ? 0 : yBit)
        low |= master512 ? buttons.rawValue : buttons.rawValue << 5
        via.b.p &= ~low
        via.b.c1 = x.clock ? 1 : 0
        if !y.clock {
            via.b.c2 = 0
        }
    }
}
