/// Disassembles 6502 instructions using a variant's instruction table.
public struct M6502Disassembler: Sendable {
    public let instructions: [M6502InstructionInfo]

    public init(variant: M6502.Variant) {
        switch variant {
        case .nmos: instructions = M6502InstructionInfo.nmos
        case .cmos: instructions = M6502InstructionInfo.cmos
        case .rockwell: instructions = M6502InstructionInfo.rockwell
        }
    }

    /// Disassembles the instruction at `address`, reading memory with `read`
    /// (which should have no side effects). Returns the text, e.g.
    /// "LDA $1234,X", and the instruction's length in bytes.
    public func disassemble(at address: UInt16, read: (UInt16) -> UInt8) -> (text: String, length: Int) {
        let info = instructions[Int(read(address))]
        let b1 = read(address &+ 1)
        let b2 = read(address &+ 2)
        let word = UInt16(b2) << 8 | UInt16(b1)
        let mnemonic = info.mnemonic.uppercased()

        func hex2(_ v: UInt8) -> String { "$" + hexDigits(UInt16(v), 2) }
        func hex4(_ v: UInt16) -> String { "$" + hexDigits(v, 4) }
        func relative(_ offset: UInt8, from end: UInt16) -> UInt16 {
            end &+ UInt16(bitPattern: Int16(Int8(bitPattern: offset)))
        }

        let operand: String
        switch info.mode {
        case .imp: operand = ""
        case .acc: operand = "A"
        case .imm: operand = "#" + hex2(b1)
        case .zpg: operand = hex2(b1)
        case .zpx: operand = hex2(b1) + ",X"
        case .zpy: operand = hex2(b1) + ",Y"
        case .inx: operand = "(" + hex2(b1) + ",X)"
        case .iny: operand = "(" + hex2(b1) + "),Y"
        case .inz: operand = "(" + hex2(b1) + ")"
        case .abs: operand = hex4(word)
        case .abx: operand = hex4(word) + ",X"
        case .aby: operand = hex4(word) + ",Y"
        case .ind: operand = "(" + hex4(word) + ")"
        case .indx: operand = "(" + hex4(word) + ",X)"
        case .rel: operand = hex4(relative(b1, from: address &+ 2))
        case .zpgRelRockwell: operand = hex2(b1) + "," + hex4(relative(b2, from: address &+ 3))
        }
        return (operand.isEmpty ? mnemonic : mnemonic + " " + operand, info.length)
    }
}

func hexDigits(_ value: UInt16, _ width: Int) -> String {
    let digits = String(value, radix: 16, uppercase: true)
    return String(repeating: "0", count: max(0, width - digits.count)) + digits
}
