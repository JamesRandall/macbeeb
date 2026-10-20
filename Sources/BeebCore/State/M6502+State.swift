extension M6502.State: Codable {}
extension M6502.Op: Codable {}
extension M6502.BusAccess: Codable {}

extension M6502 {
    /// Everything that changes as the CPU runs, for save states.
    public struct Snapshot: Codable, Sendable {
        var abus: UInt16, dbus: UInt8, access: BusAccess
        var a: UInt8, x: UInt8, y: UInt8, s: UInt8, pc: UInt16
        var flags: UInt8
        var ad: UInt16, ia: UInt16, data: UInt8, opcode: UInt8, op: Op
        var acarry: Bool, d1x1: Bool, state: State
        var nmiVector: Bool, nmiRecheck: Bool
        var irqFlags: UInt8, nmiFlags: UInt8, deviceIRQFlags: UInt8, deviceNMIFlags: UInt8
        var opcodePC: UInt16
    }

    public var snapshot: Snapshot {
        Snapshot(abus: abus, dbus: dbus, access: access, a: a, x: x, y: y, s: s, pc: pc,
                 flags: (c ? 1 : 0) | (z ? 2 : 0) | (i ? 4 : 0) | (d ? 8 : 0) | (v ? 0x40 : 0) | (n ? 0x80 : 0),
                 ad: ad, ia: ia, data: data, opcode: opcode, op: op,
                 acarry: acarry, d1x1: d1x1, state: state, nmiVector: nmiVector, nmiRecheck: nmiRecheck,
                 irqFlags: irqFlags, nmiFlags: nmiFlags, deviceIRQFlags: deviceIRQFlags, deviceNMIFlags: deviceNMIFlags,
                 opcodePC: opcodePC)
    }

    public func restore(_ s: Snapshot) {
        abus = s.abus; dbus = s.dbus; access = s.access
        a = s.a; x = s.x; y = s.y; self.s = s.s; pc = s.pc
        c = s.flags & 1 != 0; z = s.flags & 2 != 0; i = s.flags & 4 != 0
        d = s.flags & 8 != 0; v = s.flags & 0x40 != 0; n = s.flags & 0x80 != 0
        ad = s.ad; ia = s.ia; data = s.data; opcode = s.opcode; op = s.op
        acarry = s.acarry; d1x1 = s.d1x1; state = s.state
        nmiVector = s.nmiVector; nmiRecheck = s.nmiRecheck
        irqFlags = s.irqFlags; nmiFlags = s.nmiFlags
        deviceIRQFlags = s.deviceIRQFlags; deviceNMIFlags = s.deviceNMIFlags
        opcodePC = s.opcodePC
    }
}
