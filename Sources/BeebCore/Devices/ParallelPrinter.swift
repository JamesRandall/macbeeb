// A printer on the BBC's parallel (Centronics) port: the user VIA's port A
// carries the data, CA2 is /STROBE and CA1 /ACK. The printer takes a byte
// on each strobe and acknowledges it a little later, so the OS's printer
// driver (*FX5,1) sends the next.

/// A printer plugged into the printer port.
public final class ParallelPrinter {
    /// Cycles from a strobe to the printer's acknowledgement: a printer with
    /// a buffer takes bytes as fast as the OS sends them.
    public var acknowledgeDelay = 100
    /// Gets each byte, with the machine's cycle count when it was strobed.
    public var onByte: (UInt8, UInt64) -> Void

    /// (Low to start with: CA2 is until the OS sets the VIA up, which
    /// isn't a strobe.)
    var lastStrobe: UInt8 = 0
    /// Counts down to /ACK.
    var acknowledgeIn = 0
    /// How long /ACK is held low (1MHz ticks).
    var acknowledgeLow = 0

    public init(onByte: @escaping (UInt8, UInt64) -> Void) {
        self.onByte = onByte
    }

    /// At each 1MHz tick, before the VIA's: watches /STROBE and drives /ACK.
    @inline(__always)
    func tick(_ via: inout VIA6522, cycles: UInt64) {
        let strobe = via.a.c2
        if lastStrobe != 0 && strobe == 0 {
            onByte(via.a.p, cycles)
            acknowledgeIn = max(1, acknowledgeDelay / 2)
        }
        lastStrobe = strobe
        if acknowledgeIn > 0 {
            acknowledgeIn -= 1
            if acknowledgeIn == 0 { acknowledgeLow = 2 }
        }
        if acknowledgeLow > 0 {
            acknowledgeLow -= 1
            via.a.c1 = 0
        }
    }
}
