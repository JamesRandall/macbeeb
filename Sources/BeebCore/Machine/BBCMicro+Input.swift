// Typing, and reading text back off the screen.

extension BBCMicro {
    struct KeyEvent {
        var cycle: UInt64
        var key: BeebKey
        var down: Bool
    }

    /// How long typed keys are held, and the gap after release. The OS
    /// scans the keyboard every 10ms, so this is comfortably long.
    static let typingKeyDownCycles: UInt64 = 2_000_000 * 40 / 1000
    static let typingKeyUpCycles: UInt64 = 2_000_000 * 40 / 1000

    /// Types `text` through the keyboard matrix, one key at a time, starting
    /// after anything already being typed. Characters that can't be typed
    /// are skipped. "\n" and "\r" press Return.
    public func type(_ text: String) {
        var time = max(cycles, keyEvents.last.map { $0.cycle + Self.typingKeyUpCycles } ?? cycles)
        for character in text {
            guard let (key, shift) = BeebKey.forCharacter(character) else { continue }
            if shift {
                keyEvents.append(KeyEvent(cycle: time, key: .shift, down: true))
            }
            keyEvents.append(KeyEvent(cycle: time, key: key, down: true))
            time += Self.typingKeyDownCycles
            keyEvents.append(KeyEvent(cycle: time, key: key, down: false))
            if shift {
                keyEvents.append(KeyEvent(cycle: time, key: .shift, down: false))
            }
            time += Self.typingKeyUpCycles
        }
    }

    /// True while typed text is still being entered.
    public var isTyping: Bool { !keyEvents.isEmpty }

    /// Applies key events that are due.
    func processKeyEvents() {
        while let event = keyEvents.first, event.cycle <= cycles {
            keyEvents.removeFirst()
            setKey(event.key, down: event.down)
        }
    }

    // MARK: Paste

    /// OS 1.2 entry points.
    static let osrdch: UInt16 = 0xFFE0
    /// In OSRDCH's loop waiting for a key.
    static let osIdleAddress: UInt16 = 0xE581

    struct Paste {
        var text: [UInt8]
        var index = 0
        /// Waiting for OSRDCH to be called: a key is held to wake it.
        var waiting = true
    }

    /// Enters text as if typed, but fast: each call to OSRDCH returns the
    /// next character. (b2's method: a key is pressed to wake the OS, then
    /// erased with Delete.) "\n" is Return.
    public func paste(_ text: String) {
        let bytes = text.unicodeScalars.compactMap { scalar -> UInt8? in
            scalar == "\n" ? 13 : scalar.isASCII ? UInt8(scalar.value) : nil
        }
        guard !bytes.isEmpty else { return }
        paste = Paste(text: bytes)
        setKey(.space, down: true)
        updateOpcodeHooks()
    }

    public var isPasting: Bool { paste != nil }

    func updateOpcodeHooks() {
        opcodeHooks = paste != nil || watchForIdle || captureOutput
    }

    /// Called at each opcode fetch while `opcodeHooks` is set, with the
    /// opcode on the data bus.
    func opcodeFetched() {
        let address = cpu.abus
        if watchForIdle && address == Self.osIdleAddress && paste == nil && keyEvents.isEmpty {
            reachedIdle = true
        }
        // Capture at WRCHV's target: OSASCI and OSNEWL jump there directly.
        if captureOutput && address == UInt16(ram[0x20F]) << 8 | UInt16(ram[0x20E]) {
            capturedOutput.append(cpu.a)
        }
        if address == Self.osrdch, var paste {
            if paste.waiting {
                setKey(.space, down: false)
                paste.waiting = false
                cpu.a = 127
            } else {
                cpu.a = paste.text[paste.index]
                paste.index += 1
            }
            self.paste = paste.index == paste.text.count ? nil : paste
            // No Escape, and pretend the instruction was RTS.
            cpu.c = false
            cpu.dbus = 0x60
            updateOpcodeHooks()
        }
    }

    /// Runs until the OS is waiting for a key, with nothing left to type or
    /// paste, then a little longer. Returns false if that didn't happen
    /// within `maxSeconds`.
    @discardableResult
    public func runUntilIdle(maxSeconds: Double = 60) -> Bool {
        watchForIdle = true
        reachedIdle = false
        updateOpcodeHooks()
        defer {
            watchForIdle = false
            updateOpcodeHooks()
        }
        let deadline = cycles + UInt64(maxSeconds * 2_000_000)
        while !reachedIdle && cycles < deadline {
            run(cycles: 10_000)
        }
        guard reachedIdle else { return false }
        run(seconds: 0.01)
        return true
    }

    // MARK: Loading programs

    /// Copies `bytes` into RAM at `address`.
    public func load(_ bytes: [UInt8], at address: UInt16) {
        for (offset, byte) in bytes.enumerated() {
            poke(address &+ UInt16(offset), byte)
        }
    }

    /// Installs a tokenised BASIC program at PAGE, as LOAD would. BASIC
    /// programs are relocatable, so it doesn't matter where it was saved.
    public func loadBASIC(_ program: [UInt8]) {
        let page = UInt16(peek(0x18)) << 8
        load(program, at: page)
        let top = page &+ UInt16(program.count)
        // TOP and the start of variables (LOMEM/VARTOP).
        for address: UInt16 in [0x02, 0x12] {
            poke(address, UInt8(truncatingIfNeeded: top))
            poke(address + 1, UInt8(truncatingIfNeeded: top >> 8))
        }
    }

    // MARK: Screen text

    /// The character a Mode 7 screen byte shows. The OS stores "#" as &5F,
    /// "_" as &60 and "£" as &23, to match the SAA5050's glyphs.
    static func teletextCharacter(_ byte: UInt8) -> Character {
        switch byte & 0x7F {
        case 0x23: return "£"
        case 0x5F: return "#"
        case 0x60: return "_"
        case let b where b >= 0x20 && b < 0x7F: return Character(UnicodeScalar(b))
        default: return " "
        }
    }

    /// The text on a Mode 7 screen, one string per row, read from screen
    /// memory using the CRTC's start address and size. Returns nil if the
    /// display isn't in teletext mode.
    public func teletextScreenText() -> [String]? {
        guard videoULA.teletext else { return nil }
        let start = UInt16(crtc.registers[12]) << 8 | UInt16(crtc.registers[13])
        let columns = Int(crtc.registers[1])
        let rows = Int(crtc.registers[6])
        var lines: [String] = []
        for row in 0..<rows {
            var line = ""
            for column in 0..<columns {
                let address = (start &+ UInt16(row * columns + column)) & 0x3FF | 0x7C00
                line.append(Self.teletextCharacter(ram[Int(address)]))
            }
            while line.last == " " { line.removeLast() }
            lines.append(line)
        }
        return lines
    }
}
