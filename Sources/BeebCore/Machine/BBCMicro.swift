import Foundation

// BBC Micro Model B and Master 128.
//
// The per-cycle update follows b2's BBCMicro_Update.inl (Copyright (C) Tom
// Seddon, GPLv3).
//
// `step()` runs one 2MHz cycle. Alternate cycles are 1MHz phi2 leading and
// trailing edges. Accesses to 1MHz devices are stretched so the access
// lines up with the 1MHz trailing edge: 1 or 2 extra cycles.
//
// Memory is mapped in 4K pages through two tables, as in b2: one for code
// running in &C000-&DFFF (the Master's VDU driver, which can see shadow RAM
// with ACCCON E) and one for everything else.

public final class BBCMicro {
    public enum Model: String, Codable, Sendable, CaseIterable {
        case modelB
        case master128

        public var displayName: String {
            switch self {
            case .modelB: "BBC Model B"
            case .master128: "BBC Master 128"
            }
        }
    }

    public enum IRQDevice {
        public static let systemVIA: UInt8 = 1 << 0
        public static let userVIA: UInt8 = 1 << 1
        /// The Master's ACCCON IRR bit.
        public static let acccon: UInt8 = 1 << 2
        public static let acia: UInt8 = 1 << 3
    }

    public enum NMIDevice {
        public static let fdc: UInt8 = 1 << 0
    }

    public let model: Model
    public let cpu: M6502
    public var systemVIA = VIA6522()
    public var userVIA = VIA6522()
    public var crtc = CRTC6845()
    public var videoULA = VideoULA()
    public var saa5050 = SAA5050()
    public var adc = UPD7002()
    public var soundChip = SN76489()
    /// The two disc drives.
    public let drives = [DiscDrive(id: 0), DiscDrive(id: 1)]
    /// The Model B's disc controller.
    public let intel8271: Intel8271?
    /// The Master's disc controller.
    public let wd1770: WD1770?
    /// The Master's real-time clock and CMOS RAM.
    public var rtc = MC146818()
    var mixer: SoundMixer?
    var sampleRing: SampleRing?
    /// A second copy of the audio, for recording.
    public var recordingAudio: SampleRing?

    /// The serial ULA (&FE10) and the 6850 ACIA (&FE08) it clocks: the
    /// cassette interface, and RS423 with nothing connected.
    public internal(set) var serial = SerialULA()
    /// The tape in the cassette recorder.
    public var tape: Tape?
    /// Called when the cassette motor relay switches (true: on).
    public var onCassetteMotor: ((Bool) -> Void)?

    /// Attach a TV to receive the video stream.
    public var tv: TVOutput?

    /// 2MHz cycles since power on.
    public internal(set) var cycles: UInt64 = 0

    // Memory.

    /// Main RAM (32K), then shadow RAM (32K, of which &3000-&7FFF is
    /// used), ANDY (4K) and HAZEL (8K).
    let ram: UnsafeMutablePointer<UInt8>
    static let ramSize = 0x13000
    static let shadowOffset = 0x8000
    static let andyOffset = 0x10000
    static let hazelOffset = 0x11000
    let osROM: UnsafeMutablePointer<UInt8>
    /// Sideways ROM and RAM banks; nil for an empty socket.
    let sidewaysBanks: [UnsafeMutablePointer<UInt8>?]
    let sidewaysRAMBanks: Set<Int>
    /// Writes to ROM land here.
    let discardPage: UnsafeMutablePointer<UInt8>
    /// 4K page -> memory, for reads (nil: nothing there) and writes. Pages
    /// 0-15 are for most code, 16-31 for code in &C000-&DFFF.
    let readPages: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>
    let writePages: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>>
    /// 0 or 16: the table for the current instruction.
    var pageTable = 0
    /// ROMSEL (&FE30): the paged ROM bank, and on the Master, bit 7 for
    /// ANDY.
    public internal(set) var romsel: UInt8 = 0
    /// The Master's ACCCON (&FE34).
    public internal(set) var acccon: UInt8 = 0
    /// Offset of the RAM the video hardware reads: shadow when ACCCON D is
    /// set.
    var videoRAMOffset = 0
    /// The Master's data bus isn't buffered: unmapped reads see the last
    /// byte the video fetched.
    var lastVideoByte: UInt8 = 0
    /// Base addresses for Mode 7, by MA11. The Master can show &3C00.
    let teletextBases: (UInt16, UInt16)

    /// True for each address in &FC00-&FEFF that's a 1MHz device.
    let stretchTable: [Bool]
    var stretch = false

    // System VIA port B drives the addressable latch (IC32).
    public internal(set) var addressableLatch: UInt8 = 0xFF
    var oldAddressableLatch: UInt8 = 0xFF
    var oldSystemVIAPB: UInt8 = 0xFF
    var systemVIAIRQ: UInt8 = 0
    var userVIAIRQ: UInt8 = 0

    // Keyboard: one byte per column, bit per row.
    var keyColumns = InlineArray<16, UInt8>(repeating: 0)
    var keyScanColumn = 0
    /// Joystick fire buttons on system VIA PB4/PB5, active low.
    var notJoystickButtons: UInt8 = 0x30
    public internal(set) var resetting = false
    /// Scheduled presses and releases from `type(_:)`, in time order.
    var keyEvents: [KeyEvent] = []

    /// Set when anything needs to see each opcode fetch (pasting, idle
    /// detection), so the common case costs one test per cycle.
    var opcodeHooks = false
    var paste: Paste?
    var watchForIdle = false
    /// Stop address for `runUntil(address:)`.
    var watchAddress: UInt16?
    public internal(set) var reachedWatchAddress = false
    /// Set when the CPU fetches from the OS's wait-for-key loop.
    public internal(set) var reachedIdle = false
    /// Characters written through WRCHV while `captureOutput` is set.
    public var capturedOutput: [UInt8] = []
    public var captureOutput = false {
        didSet { updateOpcodeHooks() }
    }

    /// Called for writes to I/O addresses with no device (e.g. test
    /// programs reporting results to &FCD0).
    public var unmappedIOWriteObserver: ((UInt16, UInt8) -> Void)?

    // Video.
    var crtcLastOutput = CRTC6845.Output()
    /// The byte latched for the SAA5050 (IC15).
    var ic15Byte: UInt8 = 0
    var unit = VideoUnit()

    static let screenWrapAdjustments: InlineArray<4, UInt16> = [0x4000 >> 3, 0x2000 >> 3, 0x5000 >> 3, 0x2800 >> 3]

    /// The model and ROMs the machine was built with.
    public struct Configuration: Codable, Sendable, Equatable {
        public var model: Model
        public var os: [UInt8]
        /// Sideways ROMs by bank, 0-15.
        public var sidewaysROMs: [Int: [UInt8]]
        /// Banks that are RAM. (On the Master, 4-7.)
        public var sidewaysRAMBanks: Set<Int>

        public init(model: Model = .modelB, os: [UInt8], sidewaysROMs: [Int: [UInt8]],
                    sidewaysRAMBanks: Set<Int>? = nil) {
            self.model = model
            self.os = os
            self.sidewaysROMs = sidewaysROMs
            self.sidewaysRAMBanks = sidewaysRAMBanks ?? (model == .master128 ? [4, 5, 6, 7] : [])
        }

        enum CodingKeys: CodingKey {
            case model, os, sidewaysROMs, sidewaysRAMBanks
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            model = try c.decodeIfPresent(Model.self, forKey: .model) ?? .modelB
            os = try c.decode([UInt8].self, forKey: .os)
            sidewaysROMs = try c.decode([Int: [UInt8]].self, forKey: .sidewaysROMs)
            sidewaysRAMBanks = try c.decodeIfPresent(Set<Int>.self, forKey: .sidewaysRAMBanks) ?? []
        }
    }

    public let configuration: Configuration

    /// Creates a Model B with the given OS and sideways ROMs, keyed by bank
    /// 0-15.
    public convenience init(os: [UInt8], sidewaysROMs roms: [Int: [UInt8]] = [:]) {
        self.init(configuration: Configuration(os: os, sidewaysROMs: roms))
    }

    /// Creates a machine with the given ROMs. Sideways RAM banks start
    /// empty, unless `sidewaysROMs` has an image for them.
    public init(configuration: Configuration) {
        precondition(configuration.os.count == 16384, "OS ROM must be 16K")
        self.configuration = configuration
        model = configuration.model
        let master = model == .master128
        cpu = M6502(variant: master ? .cmos : .nmos)

        ram = .allocate(capacity: Self.ramSize)
        ram.initialize(repeating: 0, count: Self.ramSize)
        osROM = .allocate(capacity: 0x4000)
        osROM.initialize(from: configuration.os, count: 0x4000)
        sidewaysRAMBanks = configuration.sidewaysRAMBanks
        sidewaysBanks = (0..<16).map { bank in
            let data = configuration.sidewaysROMs[bank]
            let isRAM = configuration.sidewaysRAMBanks.contains(bank)
            guard data != nil || isRAM else { return nil }
            precondition(data?.count ?? 0 <= 16384, "sideways ROM too big")
            let p = UnsafeMutablePointer<UInt8>.allocate(capacity: 0x4000)
            p.initialize(repeating: isRAM ? 0 : 0xFF, count: 0x4000)
            if let data {
                p.update(from: data, count: data.count)
            }
            return p
        }
        discardPage = .allocate(capacity: 0x1000)
        discardPage.initialize(repeating: 0, count: 0x1000)
        readPages = .allocate(capacity: 32)
        readPages.initialize(repeating: nil, count: 32)
        writePages = .allocate(capacity: 32)
        writePages.initialize(repeating: discardPage, count: 32)

        // FRED and JIM are 1MHz; so are parts of SHEILA.
        var stretchTable = [Bool](repeating: false, count: 0x300)
        for i in 0..<0x200 { stretchTable[i] = true }
        let sheila = master ? [0x00...0x1F, 0x28...0x2B, 0x40...0x9F] : [0x00...0x1F, 0x40...0x7F, 0xC0...0xDF]
        for range in sheila {
            for i in range { stretchTable[0x200 + i] = true }
        }
        self.stretchTable = stretchTable

        if master {
            intel8271 = nil
            wd1770 = WD1770(drives: drives)
            teletextBases = (0x3C00, 0x7C00)
            rtc.setTime(Date())
        } else {
            intel8271 = Intel8271(drives: drives)
            wd1770 = nil
            teletextBases = (0x7C00, 0x7C00)
        }

        updatePaging()
        oldSystemVIAPB = systemVIA.b.p
        cpu.reset()
    }

    deinit {
        ram.deallocate()
        osROM.deallocate()
        for bank in sidewaysBanks { bank?.deallocate() }
        discardPage.deallocate()
        readPages.deallocate()
        writePages.deallocate()
    }

    // MARK: Memory

    /// Rebuilds the page tables from ROMSEL and ACCCON.
    func updatePaging() {
        let master = model == .master128
        let bank = Int(romsel & 0x0F)
        let andy = master && romsel & 0x80 != 0
        let shadowAll = master && acccon & 0x04 != 0  // X
        let shadowVDU = master && acccon & 0x02 != 0  // E
        let hazel = master && acccon & 0x08 != 0      // Y
        // Code in &C000-&DFFF only sees shadow RAM through E when it's the
        // MOS there, not HAZEL.
        let shadowMOS = hazel ? shadowAll : shadowVDU

        for table in [0, 16] {
            let shadow = table == 0 ? shadowAll : shadowMOS
            for page in 0..<16 {
                var read: UnsafeMutablePointer<UInt8>?
                var write: UnsafeMutablePointer<UInt8>?
                switch page {
                case 0..<3:
                    read = ram + page << 12
                    write = read
                case 3..<8:
                    read = ram + (shadow ? Self.shadowOffset : 0) + page << 12
                    write = read
                case 8 where andy:
                    read = ram + Self.andyOffset
                    write = read
                case 8..<12:
                    read = sidewaysBanks[bank].map { $0 + (page - 8) << 12 }
                    if sidewaysRAMBanks.contains(bank) {
                        write = read
                    }
                case 12..<14 where hazel:
                    read = ram + Self.hazelOffset + (page - 12) << 12
                    write = read
                default:
                    read = osROM + (page - 12) << 12
                }
                readPages[table + page] = read
                writePages[table + page] = write ?? discardPage
            }
        }
        videoRAMOffset = master && acccon & 0x01 != 0 ? Self.shadowOffset : 0
    }

    /// Reads memory as the CPU would, without side effects. I/O reads return
    /// what the device would return.
    public func peek(_ address: UInt16) -> UInt8 {
        if address >= 0xFC00 && address < 0xFF00 {
            return peekIO(address)
        }
        return readPages[Int(address >> 12)]?[Int(address & 0xFFF)] ?? 0xFF
    }

    /// Writes memory as the CPU would (for loading programs), except that
    /// I/O is ignored.
    public func poke(_ address: UInt16, _ value: UInt8) {
        if address < 0xFC00 || address >= 0xFF00 {
            writePages[Int(address >> 12)][Int(address & 0xFFF)] = value
        }
    }

    /// Reads the RAM the video hardware sees (shadow RAM on the Master
    /// with ACCCON D set).
    public func peekScreen(_ address: UInt16) -> UInt8 {
        ram[Int(address & 0x7FFF) + videoRAMOffset]
    }

    /// Reads main RAM, regardless of paging.
    func peekMainRAM(_ address: UInt16) -> UInt8 {
        ram[Int(address & 0x7FFF)]
    }

    /// The OS font's 8 bytes for characters 32-126: in the OS ROM at &C000
    /// (OS 1.20), or in bank 15 at &B900 (MOS 3.20, whose bank 15 is part
    /// of the OS).
    func fontGlyph(_ character: Int) -> [UInt8] {
        let offset = (character - 32) * 8
        if model == .master128, let bank = sidewaysBanks[15] {
            return (0..<8).map { bank[0x3900 + offset + $0] }
        }
        return (0..<8).map { osROM[offset + $0] }
    }

    private func peekIO(_ address: UInt16) -> UInt8 {
        if model == .master128 {
            switch address & 0xFFE0 {
            case 0xFE00:
                if address & 0x18 == 0x18 { return adc.peek(Int(address)) }
                if address & 0x18 == 0x08 { return serial.peekACIA(Int(address)) }
                if address & 0x19 == 1 { return crtc.readData() }
            case 0xFE20:
                switch address & 0x1C {
                case 0x08: return wd1770!.peek(Int(address))
                case 0x10: return romsel
                case 0x14: return acccon
                default: break
                }
            case 0xFE40: return systemVIA.peek(Int(address))
            case 0xFE60: return userVIA.peek(Int(address))
            default: break
            }
            return 0xFF
        }
        switch address & 0xFFE0 {
        case 0xFE40: return systemVIA.peek(Int(address))
        case 0xFE60: return userVIA.peek(Int(address))
        case 0xFE80: return intel8271!.peek(Int(address))
        case 0xFEC0: return adc.peek(Int(address))
        case 0xFE00 where address & 0x19 == 1: return crtc.readData()
        case 0xFE00 where address & 0x18 == 0x08: return serial.peekACIA(Int(address))
        default: return 0xFF
        }
    }

    @inline(__always)
    private func readIO(_ address: UInt16) -> UInt8 {
        switch address & 0xFFE0 {
        case 0xFE00:
            switch address & 0x18 {
            case 0x00:
                // CRTC (&FE00-&FE07): address/data on A0.
                return address & 1 == 0 ? crtc.readAddress() : crtc.readData()
            case 0x08:
                // ACIA (&FE08-&FE0F): status/data on A0.
                return serial.readACIA(Int(address))
            default:
                // Serial ULA: there's no read/write line, so a read writes
                // the stale bus. Reads give 0 on the B (as b2).
                writeSerialULA(cpu.dbus)
                return 0
            }
        case 0xFE40:
            return systemVIA.read(Int(address))
        case 0xFE60:
            return userVIA.read(Int(address))
        case 0xFE80:
            return intel8271!.read(Int(address))
        case 0xFEC0:
            return adc.read(Int(address))
        default:
            break
        }
        // Unmapped: the data bus keeps its previous value.
        return cpu.dbus
    }

    @inline(__always)
    private func writeIO(_ address: UInt16, _ value: UInt8) {
        switch address & 0xFFE0 {
        case 0xFE00:
            switch address & 0x18 {
            case 0x00:
                if address & 1 == 0 {
                    crtc.writeAddress(value)
                } else {
                    crtc.writeData(value)
                }
            case 0x08:
                serial.writeACIA(Int(address), value)
            default:
                writeSerialULA(value)
            }
        case 0xFE20:
            if address & 0x10 == 0 {
                // Video ULA (&FE20-&FE2F).
                if address & 1 == 0 {
                    videoULA.writeControl(value)
                } else {
                    videoULA.writePalette(value)
                }
            } else {
                // ROMSEL (&FE30-&FE3F).
                romsel = value & 0x0F
                updatePaging()
            }
        case 0xFE40:
            systemVIA.write(Int(address), value)
        case 0xFE60:
            userVIA.write(Int(address), value)
        case 0xFE80:
            intel8271!.write(Int(address), value)
        case 0xFEC0:
            adc.write(Int(address), value)
        default:
            if address < 0xFE00 {
                // FRED and JIM: nothing fitted.
                unmappedIOWriteObserver?(address, value)
            }
        }
    }

    // MARK: Master I/O

    @inline(__always)
    private func readIOMaster(_ address: UInt16) -> UInt8 {
        // TST: the OS ROM appears in place of I/O.
        if acccon & 0x40 != 0 {
            return osROM[Int(address - 0xC000)]
        }
        switch address & 0xFFE0 {
        case 0xFE00:
            switch address & 0x18 {
            case 0x00:
                return address & 1 == 0 ? crtc.readAddress() : crtc.readData()
            case 0x08:
                return serial.readACIA(Int(address))
            case 0x10:
                // Serial ULA: every access is a write (of the stale bus).
                writeSerialULA(lastVideoByte)
                return lastVideoByte
            default:
                return adc.read(Int(address))
            }
        case 0xFE20:
            switch address & 0x1C {
            case 0x08: return wd1770!.read(Int(address))
            case 0x10: return romsel
            case 0x14: return acccon
            default: break
            }
        case 0xFE40:
            return systemVIA.read(Int(address))
        case 0xFE60:
            return userVIA.read(Int(address))
        default:
            break
        }
        return lastVideoByte
    }

    @inline(__always)
    private func writeIOMaster(_ address: UInt16, _ value: UInt8) {
        switch address & 0xFFE0 {
        case 0xFE00:
            switch address & 0x18 {
            case 0x00:
                if address & 1 == 0 {
                    crtc.writeAddress(value)
                } else {
                    crtc.writeData(value)
                }
            case 0x08:
                serial.writeACIA(Int(address), value)
            case 0x10:
                writeSerialULA(value)
            default:
                adc.write(Int(address), value)
            }
        case 0xFE20:
            switch address & 0x1C {
            case 0x00:
                if address & 1 == 0 {
                    videoULA.writeControl(value)
                } else {
                    videoULA.writePalette(value)
                }
            case 0x04:
                wd1770!.writeControl(value, layout: .master128)
            case 0x08:
                wd1770!.write(Int(address), value)
            case 0x10:
                romsel = value & 0x8F
                updatePaging()
            case 0x14:
                acccon = value
                updatePaging()
                cpu.setIRQ(IRQDevice.acccon, value & 0x80 != 0)
            default:
                break
            }
        case 0xFE40:
            systemVIA.write(Int(address), value)
        case 0xFE60:
            userVIA.write(Int(address), value)
        default:
            if address < 0xFE00 {
                unmappedIOWriteObserver?(address, value)
            }
        }
    }

    private func writeSerialULA(_ value: UInt8) {
        if serial.writeControl(value) {
            onCassetteMotor?(serial.motorOn)
        }
    }

    /// Sends audio, at `sampleRate`, to `ring`.
    public func attachAudio(sampleRate: Int, ring: SampleRing) {
        mixer = SoundMixer(outputRate: sampleRate)
        sampleRing = ring
    }

    public func detachAudio() {
        mixer = nil
        sampleRing = nil
    }

    /// Puts a disc in drive 0 or 1 (nil ejects).
    public func insertDisc(_ disc: Disc?, drive: Int = 0) {
        drives[drive].insert(disc)
    }

    // MARK: Joysticks

    /// Sets analogue joystick 0 or 1: `x` and `y` from -1 (left/down) to 1
    /// (right/up), and its fire button.
    public func setJoystick(_ index: Int, x: Double, y: Double, fire: Bool) {
        precondition(index == 0 || index == 1)
        // The BBC reads high values for left and up.
        func channel(_ value: Double, inverted: Bool) -> UInt16 {
            let v = max(-1, min(1, value))
            return UInt16(((inverted ? -v : v) + 1) / 2 * 1023)
        }
        adc.channels[index * 2] = channel(x, inverted: true)
        adc.channels[index * 2 + 1] = channel(y, inverted: false)
        let bit: UInt8 = index == 0 ? 0x10 : 0x20
        if fire {
            notJoystickButtons &= ~bit
        } else {
            notJoystickButtons |= bit
        }
    }

    // MARK: Keyboard

    public func isKeyDown(_ key: BeebKey) -> Bool {
        keyColumns[key.column] & UInt8(1 << key.row) != 0
    }

    /// Presses or releases a key. Break halts the CPU while held and resets
    /// it on release.
    public func setKey(_ key: BeebKey, down: Bool) {
        var key = key
        if key.isKeypad && model == .modelB {
            guard let equivalent = key.mainKeyboardEquivalent else { return }
            key = equivalent
        }
        if key == .breakKey {
            guard down != resetting else { return }
            resetting = down
            if down {
                cpu.halt()
            } else {
                cpu.reset()
            }
            return
        }
        if down {
            keyColumns[key.column] |= UInt8(1 << key.row)
        } else {
            keyColumns[key.column] &= ~UInt8(1 << key.row)
        }
    }

    // MARK: Running

    /// Set by watches (idle, address) to end `run` early.
    var stopRequested = false

    /// Runs up to `count` 2MHz cycles, stopping early (on the exact cycle)
    /// if a watch fires: see `watchForIdle(_:)` and `watch(address:)`.
    /// Returns the cycles run.
    @discardableResult
    public func run(cycles count: Int) -> Int {
        stopRequested = false
        var done = 0
        while done < count && !stopRequested {
            // Key events are applied at 0.5ms granularity.
            let chunk = min(count - done, 1000)
            processKeyEvents()
            var i = 0
            while i < chunk {
                step()
                i += 1
                if stopRequested { break }
            }
            done += i
        }
        return done
    }

    /// Runs for `seconds` of emulated time.
    public func run(seconds: Double) {
        run(cycles: Int(seconds * 2_000_000))
    }

    /// Runs one 2MHz cycle.
    @inline(__always)
    public func step() {
        let trailingEdge = cycles & 1 != 0

        // CPU.
        if stretch {
            if trailingEdge {
                stretch = false
            }
        } else {
            cpu.tick()
            let address = cpu.abus
            if address >= 0xFC00 && address < 0xFF00 {
                stretch = stretchTable[Int(address - 0xFC00)]
            }
        }

        if !stretch {
            let address = cpu.abus
            let io = address >= 0xFC00 && address < 0xFF00
            if cpu.access == .write {
                if io {
                    if model == .master128 {
                        writeIOMaster(address, cpu.dbus)
                    } else {
                        writeIO(address, cpu.dbus)
                    }
                } else {
                    writePages[pageTable + Int(address >> 12)][Int(address & 0xFFF)] = cpu.dbus
                }
            } else {
                if cpu.access == .opcode && model == .master128 {
                    pageTable = address & 0xE000 == 0xC000 ? 16 : 0
                }
                if io {
                    cpu.dbus = model == .master128 ? readIOMaster(address) : readIO(address)
                } else if let page = readPages[pageTable + Int(address >> 12)] {
                    cpu.dbus = page[Int(address & 0xFFF)]
                } else if model == .master128 {
                    cpu.dbus = lastVideoByte
                }
                // (An empty socket on the B leaves the data bus alone.)
                if opcodeHooks && cpu.access == .opcode {
                    opcodeFetched()
                }
            }
        }

        // Video.
        if videoULA.fast6845 || trailingEdge {
            updateVideo(trailingEdge: trailingEdge)
        }
        emitVideo()

        // Sound: 250kHz. The chip takes port A while IC32 bit 0 is low.
        if cycles & 7 == 0 {
            let output = soundChip.update(write: addressableLatch & 1 == 0, value: systemVIA.a.p)
            if mixer != nil, let sample = mixer!.mix(output) {
                sampleRing?.write(sample)
                recordingAudio?.write(sample)
            }
        }

        // VIAs.
        if trailingEdge {
            updateTrailingEdge()
        } else {
            systemVIAIRQ = systemVIA.updatePhi2LeadingEdge()
            userVIAIRQ = userVIA.updatePhi2LeadingEdge()
        }

        cycles &+= 1
    }

    @inline(__always)
    private func updateVideo(trailingEdge: Bool) {
        let output = crtc.update(lightpen: systemVIA.b.c2 != 0)

        var address = output.address
        if address & 0x2000 != 0 {
            // Mode 7: 1K at &7C00 (or &3C00 on the Master).
            address = (address & 0x3FF) | (address & 0x800 == 0 ? teletextBases.0 : teletextBases.1)
        } else {
            if address & 0x1000 != 0 {
                address &-= Self.screenWrapAdjustments[Int(addressableLatch >> 4 & 3)]
                address &= ~0x1000
            }
            // When raster >= 8 this address is bogus; it isn't displayed.
            address = (address << 3 | UInt16(output.raster & 7)) & 0x7FFF
        }

        if trailingEdge {
            if output.vsync && !crtcLastOutput.vsync {
                saa5050.vsync()
            }
            if videoULA.teletext {
                // Line boundaries come from DISPEN on the SAA5050's LOSE pin.
                if output.display {
                    if !crtcLastOutput.display {
                        saa5050.startOfLine()
                    }
                } else {
                    ic15Byte |= 0x40
                    if crtcLastOutput.display {
                        saa5050.endOfLine()
                    }
                }
            }
        }
        let value = ram[Int(address) + videoRAMOffset]
        lastVideoByte = value
        if trailingEdge {
            saa5050.byte(ic15Byte, dispen: output.display)
            ic15Byte = output.address & 0x2000 != 0 ? value : 0
        }

        // Done even in teletext mode: the cursor flag sets up the cursor.
        videoULA.byte(value, cudisp: output.cudisp)
        crtcLastOutput = output
    }

    @inline(__always)
    private func emitVideo() {
        if videoULA.teletext {
            saa5050.emitPixels(&unit)
            if videoULA.cursorPattern & 1 != 0 {
                unit.pixels[0] ^= cursorXOR
                unit.pixels[1] ^= cursorXOR
            }
            videoULA.cursorPattern >>= 1
        } else if crtcLastOutput.display && crtcLastOutput.raster < 8 {
            videoULA.emitPixels(&unit)
        } else {
            videoULA.emitBlank(&unit)
        }

        var flags: UInt16 = 0
        if crtcLastOutput.hsync { flags |= VideoUnit.hsyncFlag }
        if crtcLastOutput.vsync { flags |= VideoUnit.vsyncFlag }
        unit.pixels[1] = (unit.pixels[1] & 0x0FFF) | flags << 12

        tv?.update(unit)
    }

    @inline(__always)
    private func updateTrailingEdge() {
        // CA1 is vsync.
        if !crtcLastOutput.vsync {
            systemVIA.a.c1 = 0
        }

        systemVIAIRQ |= systemVIA.updatePhi2TrailingEdge()
        userVIAIRQ |= userVIA.updatePhi2TrailingEdge()
        cpu.setIRQ(IRQDevice.systemVIA, systemVIAIRQ != 0)
        cpu.setIRQ(IRQDevice.userVIA, userVIAIRQ != 0)

        // Cassette and serial, at 1MHz.
        serial.update(tape: tape)
        cpu.setIRQ(IRQDevice.acia, serial.irq)

        // Keyboard. With IC32 bit 3 high the keyboard scans itself and
        // raises CA2 when a key (other than row 0) is down in the current
        // column; otherwise port A selects a key to test.
        if addressableLatch & 0x08 != 0 {
            if keyColumns[keyScanColumn] & 0xFE == 0 {
                systemVIA.a.c2 = 0
            }
            keyScanColumn = (keyScanColumn + 1) & 0x0F
        } else {
            let key = systemVIA.a.p & 0x7F
            let column = keyColumns[Int(key & 0x0F)]
            // Row 0 doesn't cause an interrupt.
            if column & 0xFE == 0 {
                systemVIA.a.c2 = 0
            }
            if column & UInt8(1 << (key >> 4)) == 0 {
                systemVIA.a.p &= 0x7F
            }
        }

        // Joystick fire buttons.
        systemVIA.b.p = (systemVIA.b.p & ~0x30) | notJoystickButtons

        // The disc controller's INT is NMI.
        if let fdc = intel8271 {
            fdc.tick()
            cpu.setNMI(NMIDevice.fdc, fdc.nmi)
        } else if let fdc = wd1770 {
            fdc.tick()
            cpu.setNMI(NMIDevice.fdc, fdc.nmi)
        }

        // ADC end of conversion is CB1.
        systemVIA.b.c1 = adc.update() ? 1 : 0

        // Addressable latch: PB0-2 select a bit, PB3 is its value.
        let pb = systemVIA.b.p
        if pb != oldSystemVIAPB {
            let mask = UInt8(1 << (pb & 7))
            addressableLatch &= ~mask
            if pb & 0x08 != 0 {
                addressableLatch |= mask
            }
            // Master RTC: PB6 is chip select, PB7 address strobe; the
            // address is latched on AS 1->0.
            if model == .master128 && pb & 0x40 != 0 && oldSystemVIAPB & 0x80 != 0 && pb & 0x80 == 0 {
                rtc.setAddress(systemVIA.a.p)
            }
            oldSystemVIAPB = pb
        }

        if model == .master128 {
            // With AS low, latch bit 1 selects read; in write mode, data
            // is written on DS (latch bit 2) 1->0.
            if pb & 0x40 != 0 && pb & 0x80 == 0 {
                if addressableLatch & 0x02 != 0 {
                    systemVIA.a.p &= rtc.read()
                } else if oldAddressableLatch & 0x04 != 0 && addressableLatch & 0x04 == 0 {
                    rtc.setData(systemVIA.a.p)
                }
            }
            rtc.update()
        }
        oldAddressableLatch = addressableLatch
    }
}
