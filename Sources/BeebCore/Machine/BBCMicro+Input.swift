// Typing, and reading text back off the screen.

extension BBCMicro {
    struct KeyEvent: Codable {
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
        rewinder?.keyframe()
    }

    /// Shift-Break: resets with Shift held, which boots the disc in drive 0.
    public func shiftBreak() {
        applyKey(.shift, down: true)
        applyKey(.breakKey, down: true)
        schedule(KeyEvent(cycle: cycles + 200_000, key: .breakKey, down: false))
        schedule(KeyEvent(cycle: cycles + 2_000_000, key: .shift, down: false))
        rewinder?.keyframe()
    }

    /// Presses and releases Break.
    public func pressBreak() {
        applyKey(.breakKey, down: true)
        schedule(KeyEvent(cycle: cycles + 200_000, key: .breakKey, down: false))
        rewinder?.keyframe()
    }

    private func schedule(_ event: KeyEvent) {
        let index = keyEvents.firstIndex { $0.cycle > event.cycle } ?? keyEvents.endIndex
        keyEvents.insert(event, at: index)
    }

    /// True while typed text is still being entered.
    public var isTyping: Bool { !keyEvents.isEmpty }

    /// Applies key events that are due.
    func processKeyEvents() {
        while let event = keyEvents.first, event.cycle <= cycles {
            keyEvents.removeFirst()
            applyKey(event.key, down: event.down)
        }
    }

    // MARK: Paste

    /// OS entry point.
    static let osrdch: UInt16 = 0xFFE0
    /// In OSRDCH's loop waiting for a key (OS 1.20, B+ MOS 2.00, MOS 3.20).
    var osIdleAddress: UInt16 {
        switch model {
        case .modelA, .modelB: 0xE581
        case .bPlus: 0xDF70
        case .master128: 0xE7D7
        case .masterCompact: 0xE907
        }
    }

    struct Paste: Codable {
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
        applyKey(.space, down: true)
        updateOpcodeHooks()
        rewinder?.keyframe()
    }

    public var isPasting: Bool { paste != nil }

    func updateOpcodeHooks() {
        opcodeHooks = paste != nil || watchForIdle || captureOutput || watchAddress != nil
    }

    /// Called at each opcode fetch while `opcodeHooks` is set, with the
    /// opcode on the data bus.
    func opcodeFetched() {
        let address = cpu.abus
        if address == watchAddress {
            reachedWatchAddress = true
            stopRequested = true
        }
        if watchForIdle {
            if address == osIdleAddress && paste == nil && keyEvents.isEmpty {
                reachedIdle = true
                stopRequested = true
            }
            // Looking in the keyboard buffer (REMV and CNPV, buffer 0).
            if cpu.x == 0 && (address == vector(0x22C) || address == vector(0x22E)) {
                keyboardPolled()
            }
        }
        // Capture at WRCHV's target: OSASCI and OSNEWL jump there directly.
        if captureOutput && address == UInt16(ram[0x20F]) << 8 | UInt16(ram[0x20E]) {
            capturedOutput.append(cpu.a)
        }
        if address == Self.osrdch, var paste {
            if paste.waiting {
                applyKey(.space, down: false)
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

    /// How long the machine must be waiting for input, as seen by
    /// `checkWaiting`, to count as idle: half a second.
    static let waitingCycles: UInt64 = 1_000_000
    /// The longest gap between keyboard polls that's still polling.
    static let keyboardPollGap: UInt64 = 200_000

    /// Watches for the machine waiting for input, with nothing left to
    /// type or paste: when it happens `reachedIdle` is set and `run` stops.
    ///
    /// That's seen exactly when the host OS is in OSRDCH's loop waiting for
    /// a key, which is where BASIC, the 6502, Z80 and ARM second processors
    /// and CP/M all wait. Software that reads the keyboard itself (DOS Plus
    /// on the Master 512, games) is seen by what it does: polling the
    /// keyboard continually, with nothing else happening (the picture
    /// unchanged, no drive or cassette motor running), for `waitingCycles`.
    /// A program working silently doesn't poll the keyboard, so it isn't
    /// mistaken for one waiting.
    public func watchForIdle(_ enabled: Bool) {
        watchForIdle = enabled
        reachedIdle = false
        lastActivity = cycles
        pollingSince = cycles
        lastKeyboardPoll = cycles &- Self.keyboardPollGap &- 1
        screenHash = 0
        lastScreenHash = 0
        updateOpcodeHooks()
    }

    /// The vector at `address` (in page 2).
    func vector(_ address: Int) -> UInt16 {
        UInt16(ram[address + 1]) << 8 | UInt16(ram[address])
    }

    /// While watching for idle, a read of the system VIA: with the
    /// keyboard's autoscan off (IC32 bit 3 low), port A reads a key.
    func systemVIARead(_ address: UInt16) {
        if addressableLatch & 0x08 == 0 && (address & 0x0F == 0x01 || address & 0x0F == 0x0F) {
            keyboardPolled()
        }
    }

    func keyboardPolled() {
        if cycles &- lastKeyboardPoll > Self.keyboardPollGap {
            pollingSince = cycles
        }
        lastKeyboardPoll = cycles
    }

    /// At each vsync while watching for idle: is the machine still waiting?
    func checkWaiting() {
        let busy = screenHash != lastScreenHash || paste != nil || !keyEvents.isEmpty
            || serial.motorOn || drives.contains(where: \.spinning)
        lastScreenHash = screenHash
        screenHash = 0
        if busy {
            lastActivity = cycles
        }
        let polling = cycles &- lastKeyboardPoll <= Self.keyboardPollGap
        if polling && cycles &- lastActivity >= Self.waitingCycles && cycles &- pollingSince >= Self.waitingCycles {
            reachedIdle = true
            stopRequested = true
        }
    }

    /// Watches for the CPU reaching `address` (nil stops watching): when it
    /// does, `reachedWatchAddress` is set and `run` stops, with the
    /// instruction there about to execute.
    public func watch(address: UInt16?) {
        watchAddress = address
        reachedWatchAddress = false
        updateOpcodeHooks()
    }

    /// Runs until the OS is waiting for a key, with nothing left to type or
    /// paste, then a little longer. Returns false if that didn't happen
    /// within `maxSeconds`.
    @discardableResult
    public func runUntilIdle(maxSeconds: Double = 60) -> Bool {
        watchForIdle(true)
        defer { watchForIdle(false) }
        let deadline = cycles + UInt64(maxSeconds * 2_000_000)
        while !reachedIdle && cycles < deadline && !isStoppedByDebugger {
            run(cycles: Int(min(deadline - cycles, 200_000)))
        }
        guard reachedIdle else { return false }
        watchForIdle(false)
        run(seconds: 0.01)
        return true
    }

    /// Runs until the CPU is about to execute the instruction at `address`.
    /// Returns false if that didn't happen within `maxSeconds`.
    @discardableResult
    public func runUntil(address: UInt16, maxSeconds: Double) -> Bool {
        watch(address: address)
        defer { watch(address: nil) }
        let deadline = cycles + UInt64(maxSeconds * 2_000_000)
        while !reachedWatchAddress && cycles < deadline && !isStoppedByDebugger {
            run(cycles: Int(min(deadline - cycles, 200_000)))
        }
        return reachedWatchAddress
    }

    /// Releases every key (e.g. when the window loses focus, so keys
    /// aren't left held down).
    public func releaseAllKeys() {
        rewinder?.record(.releaseAllKeys)
        applyReleaseAllKeys()
    }

    func applyReleaseAllKeys() {
        for column in 0..<16 {
            keyColumns[column] = 0
        }
        if resetting {
            applyKey(.breakKey, down: false)
        }
    }

    // MARK: Loading programs

    public enum LoadError: Error {
        case badDisc(Error)
        case noSuchFile(String)
    }

    /// Loads a file from a DFS disc image straight into memory: BASIC at
    /// PAGE, anything else at its load address. Returns the file.
    @discardableResult
    public func loadProgram(disc: [UInt8], file name: String) -> Result<DFSDisc.File, LoadError> {
        let image: DFSDisc
        do {
            image = try DFSDisc(side: disc)
        } catch {
            return .failure(.badDisc(error))
        }
        guard let file = image.file(named: name) else {
            return .failure(.noSuchFile(name))
        }
        let contents = image.contents(of: file)
        if contents.first == 0x0D {
            loadBASIC(contents)
        } else {
            load(contents, at: UInt16(truncatingIfNeeded: file.loadAddress))
        }
        return .success(file)
    }

    /// Copies `bytes` into RAM at `address`.
    public func load(_ bytes: [UInt8], at address: UInt16) {
        for (offset, byte) in bytes.enumerated() {
            poke(address &+ UInt16(offset), byte)
        }
        rewinder?.keyframe()
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
                let ma = start &+ UInt16(row * columns + column)
                let address = ma & 0x3FF | (ma & 0x800 == 0 ? teletextBases.0 : teletextBases.1)
                line.append(Self.teletextCharacter(peekScreen(address)))
            }
            while line.last == " " { line.removeLast() }
            lines.append(line)
        }
        return lines
    }
}
