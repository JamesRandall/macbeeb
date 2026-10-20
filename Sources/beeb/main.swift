// beeb: run a headless BBC Micro from the command line.
//
//   beeb [--load DISC.ssd:FILE] [--seconds N] [--type TEXT] [--screenshot FILE.png] [--text]
//
// Boots a Model B (OS 1.2, BASIC 2), types TEXT (with \n for Return), runs
// for N seconds of emulated time after typing finishes (default 3), then
// writes a screenshot and/or prints the Mode 7 screen text.

import BeebCapture
import BeebCore
import BeebROMs
import Foundation

func usage() -> Never {
    FileHandle.standardError.write(Data("usage: beeb [--seconds N] [--type TEXT] [--screenshot FILE.png] [--text]\n".utf8))
    exit(2)
}

var seconds = 3.0
var typeText: String?
var screenshotPath: String?
var printText = false
var printPCs = false
var traceCount = 0
var loads: [(disc: String, file: String)] = []

var arguments = CommandLine.arguments.dropFirst()
while let argument = arguments.popFirst() {
    switch argument {
    case "--seconds":
        guard let value = arguments.popFirst().flatMap(Double.init) else { usage() }
        seconds = value
    case "--type":
        guard let value = arguments.popFirst() else { usage() }
        typeText = value.replacingOccurrences(of: "\\n", with: "\n")
    case "--screenshot":
        guard let value = arguments.popFirst() else { usage() }
        screenshotPath = value
    case "--load":
        // DISC.ssd:FILE - load a file from a disc image into memory.
        guard let value = arguments.popFirst(), let colon = value.lastIndex(of: ":") else { usage() }
        loads.append((String(value[..<colon]), String(value[value.index(after: colon)...])))
    case "--text":
        printText = true
    case "--pcs":
        printPCs = true
    case "--trace":
        guard let value = arguments.popFirst().flatMap(Int.init) else { usage() }
        traceCount = value
    default:
        usage()
    }
}

let machine = BBCMicro(os: BeebROMs.data(.os12), sidewaysROMs: [15: BeebROMs.data(.basic2)])
let tv = TVOutput()
machine.tv = tv

// Let it boot, load files, then type.
machine.runUntilIdle()
for (discPath, name) in loads {
    do {
        let disc = try DFSDisc(side: [UInt8](Data(contentsOf: URL(fileURLWithPath: discPath))))
        guard let file = disc.file(named: name) else {
            FileHandle.standardError.write(Data("beeb: no \(name) on \(discPath)\n".utf8))
            exit(1)
        }
        let contents = disc.contents(of: file)
        if contents.first == 0x0D {
            machine.loadBASIC(contents)
        } else {
            machine.load(contents, at: UInt16(truncatingIfNeeded: file.loadAddress))
        }
    } catch {
        FileHandle.standardError.write(Data("beeb: couldn't read \(discPath): \(error)\n".utf8))
        exit(1)
    }
}
if let typeText {
    machine.type(typeText)
    while machine.isTyping {
        machine.run(seconds: 0.1)
    }
}
machine.run(seconds: seconds)

if printPCs {
    // Where the CPU is spending its time.
    var counts: [UInt16: Int] = [:]
    for _ in 0..<200_000 {
        machine.step()
        if machine.cpu.isAboutToExecute {
            counts[machine.cpu.abus, default: 0] += 1
        }
    }
    let disassembler = M6502Disassembler(variant: .nmos)
    for (pc, count) in counts.sorted(by: { $0.value > $1.value }).prefix(16) {
        let text = disassembler.disassemble(at: pc, read: machine.peek).text
        print(String(format: "%04X %6d  %@", pc, count, text))
    }
}

if traceCount > 0 {
    let disassembler = M6502Disassembler(variant: .nmos)
    var printed = 0
    while printed < traceCount {
        machine.step()
        let cpu = machine.cpu
        if cpu.isAboutToExecute {
            let text = disassembler.disassemble(at: cpu.abus, read: machine.peek).text
            print(String(format: "%04X  %-16@ A=%02X X=%02X Y=%02X S=%02X P=%02X", cpu.abus, text, cpu.a, cpu.x, cpu.y, cpu.s, cpu.p))
            printed += 1
        }
    }
}

if let screenshotPath {
    do {
        try Screenshot.writePNG(tv, to: URL(fileURLWithPath: screenshotPath))
    } catch {
        FileHandle.standardError.write(Data("beeb: couldn't write \(screenshotPath): \(error)\n".utf8))
        exit(1)
    }
}

if printText {
    if let lines = machine.teletextScreenText() {
        print(lines.joined(separator: "\n"))
    } else {
        FileHandle.standardError.write(Data("beeb: not in Mode 7; can't read screen text\n".utf8))
    }
}
