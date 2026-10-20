// Measures raw 6502 core speed: the CPU against flat RAM, no devices.
//
// Usage: swift run -c release beeb-bench [seconds]

import BeebCore
import BeebROMs
import Foundation

let seconds = CommandLine.arguments.count > 1 ? Double(CommandLine.arguments[1]) ?? 3 : 3

// A loop with a mix of indexed loads/stores, ALU, RMW and branches.
let program: [UInt8] = [
    0xA2, 0x00,       // $0200 LDX #0
    0xBD, 0x00, 0x10, // $0202 LDA $1000,X
    0x9D, 0x00, 0x20, // $0205 STA $2000,X
    0x69, 0x03,       // $0208 ADC #3
    0x26, 0x30,       // $020A ROL $30
    0xE6, 0x31,       // $020C INC $31
    0xCA,             // $020E DEX
    0xD0, 0xF1,       // $020F BNE $0202
    0xC8,             // $0211 INY
    0x4C, 0x00, 0x02, // $0212 JMP $0200
]

for variant in M6502.Variant.allCases {
    let memory = UnsafeMutablePointer<UInt8>.allocate(capacity: 0x10000)
    memory.initialize(repeating: 0, count: 0x10000)
    for (offset, byte) in program.enumerated() {
        memory[0x200 + offset] = byte
    }
    memory[0xFFFC] = 0x00
    memory[0xFFFD] = 0x02

    let cpu = M6502(variant: variant)
    var cycles = 0
    let clock = ContinuousClock()
    let start = clock.now
    let deadline = start + .seconds(seconds)
    while clock.now < deadline {
        for _ in 0..<1_000_000 {
            cpu.tick()
            if cpu.access == .write {
                memory[Int(cpu.abus)] = cpu.dbus
            } else {
                cpu.dbus = memory[Int(cpu.abus)]
            }
        }
        cycles += 1_000_000
    }
    let elapsed = clock.now - start
    let elapsedSeconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    let mhz = Double(cycles) / elapsedSeconds / 1e6
    print(String(format: "%-9@ %8.1f MHz  (%.0fx a 2MHz BBC)", variant.rawValue, mhz, mhz / 2))
    memory.deallocate()
}

// The whole Model B: CPU, VIAs, CRTC, ULA, teletext, with and without the TV.
for withTV in [false, true] {
    let machine = BBCMicro(os: BeebROMs.data(.os12), sidewaysROMs: [15: BeebROMs.data(.basic2)])
    if withTV {
        machine.tv = TVOutput()
    }
    machine.run(seconds: 1)
    // A busy BASIC loop drawing in Mode 2.
    machine.type("MODE 2\nREPEAT:GCOL0,RND(7):DRAW RND(1280),RND(1024):UNTIL FALSE\n")
    while machine.isTyping {
        machine.run(seconds: 0.1)
    }
    let emulatedSeconds = 20.0
    let clock = ContinuousClock()
    let start = clock.now
    machine.run(seconds: emulatedSeconds)
    let elapsed = clock.now - start
    let elapsedSeconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    print(String(format: "Model B %@ %.0fx real time", withTV ? "with TV   " : "headless  ", emulatedSeconds / elapsedSeconds))
}
