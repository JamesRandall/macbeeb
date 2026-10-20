import Testing
import BeebCore

struct DisassemblerTests {
    func disassemble(_ bytes: [UInt8], _ variant: M6502.Variant = .nmos, at address: UInt16 = 0x1000) -> String {
        let disassembler = M6502Disassembler(variant: variant)
        let result = disassembler.disassemble(at: address) { a in
            let offset = Int(a &- address)
            return offset < bytes.count ? bytes[offset] : 0
        }
        #expect(result.length == bytes.count)
        return result.text
    }

    @Test func addressingModes() {
        #expect(disassemble([0xEA]) == "NOP")
        #expect(disassemble([0x0A]) == "ASL A")
        #expect(disassemble([0xA9, 0x7F]) == "LDA #$7F")
        #expect(disassemble([0xA5, 0x12]) == "LDA $12")
        #expect(disassemble([0xB5, 0x12]) == "LDA $12,X")
        #expect(disassemble([0xB6, 0x12]) == "LDX $12,Y")
        #expect(disassemble([0xA1, 0x12]) == "LDA ($12,X)")
        #expect(disassemble([0xB1, 0x12]) == "LDA ($12),Y")
        #expect(disassemble([0xAD, 0x34, 0x12]) == "LDA $1234")
        #expect(disassemble([0xBD, 0x34, 0x12]) == "LDA $1234,X")
        #expect(disassemble([0xB9, 0x34, 0x12]) == "LDA $1234,Y")
        #expect(disassemble([0x6C, 0xFC, 0xFF]) == "JMP ($FFFC)")
        #expect(disassemble([0xD0, 0xFE]) == "BNE $1000")
        #expect(disassemble([0x10, 0x10]) == "BPL $1012")
    }

    @Test func variants() {
        #expect(disassemble([0xB2, 0x80], .cmos) == "LDA ($80)")
        #expect(disassemble([0x7C, 0x00, 0x30], .cmos) == "JMP ($3000,X)")
        #expect(disassemble([0x89, 0x01], .cmos) == "BIT #$01")
        #expect(disassemble([0x1A], .cmos) == "INC A")
        #expect(disassemble([0x0F, 0x70, 0xFD], .rockwell) == "BBR0 $70,$1000")
        #expect(disassemble([0x87, 0x10], .rockwell) == "SMB0 $10")
        #expect(disassemble([0xA7, 0x10]) == "LAX $10")
        #expect(disassemble([0x02]) == "HLT")
    }
}
