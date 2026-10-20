// BBC Micro Model B.
//
// The per-cycle update follows b2's BBCMicro_Update.inl (Copyright (C) Tom
// Seddon, GPLv3).
//
// `step()` runs one 2MHz cycle. Alternate cycles are 1MHz phi2 leading and
// trailing edges. Accesses to 1MHz devices are stretched so the access
// lines up with the 1MHz trailing edge: 1 or 2 extra cycles.

public final class BBCMicro {
    public enum IRQDevice {
        public static let systemVIA: UInt8 = 1 << 0
        public static let userVIA: UInt8 = 1 << 1
    }

    public enum NMIDevice {
        public static let fdc: UInt8 = 1 << 0
    }

    public let cpu = M6502(variant: .nmos)
    public var systemVIA = VIA6522()
    public var userVIA = VIA6522()
    public var crtc = CRTC6845()
    public var videoULA = VideoULA()
    public var saa5050 = SAA5050()
    public var adc = UPD7002()
    public var soundChip = SN76489()
    /// The 8271 disc controller and its two drives.
    public let fdc = Intel8271()
    var mixer: SoundMixer?
    var sampleRing: SampleRing?
    /// A second copy of the audio, for recording.
    public var recordingAudio: SampleRing?

    /// 6850 ACIA control register. Until serial and tape are emulated, the
    /// ACIA is idle: nothing received, nothing connected.
    var aciaControl: UInt8 = 0
    /// Serial ULA control register (&FE10). Bit 6 selects RS423 (1) or the
    /// cassette (0).
    var serialULAControl: UInt8 = 0

    /// Attach a TV to receive the video stream.
    public var tv: TVOutput?

    /// 2MHz cycles since power on.
    public private(set) var cycles: UInt64 = 0

    // Memory.
    let ram: UnsafeMutablePointer<UInt8>
    let osROM: UnsafeMutablePointer<UInt8>
    let sidewaysROMs: [UnsafeMutablePointer<UInt8>?]
    /// ROMSEL (&FE30): the paged ROM bank.
    public private(set) var romsel: UInt8 = 0
    /// Current sideways bank, or nil for an empty socket.
    var pagedROM: UnsafeMutablePointer<UInt8>?

    /// True for each address in &FC00-&FEFF that's a 1MHz device.
    let stretchTable: [Bool]
    var stretch = false

    // System VIA port B drives the addressable latch (IC32).
    public private(set) var addressableLatch: UInt8 = 0xFF
    var oldSystemVIAPB: UInt8 = 0xFF
    var systemVIAIRQ: UInt8 = 0
    var userVIAIRQ: UInt8 = 0

    // Keyboard: one byte per column, bit per row.
    var keyColumns = InlineArray<16, UInt8>(repeating: 0)
    var keyScanColumn = 0
    public private(set) var resetting = false
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

    /// Creates a Model B with OS 1.2 (or `os`) and the given sideways ROMs,
    /// keyed by bank 0-15.
    public init(os: [UInt8], sidewaysROMs roms: [Int: [UInt8]] = [:]) {
        precondition(os.count == 16384, "OS ROM must be 16K")
        ram = .allocate(capacity: 0x8000)
        ram.initialize(repeating: 0, count: 0x8000)
        osROM = .allocate(capacity: 0x4000)
        osROM.initialize(from: os, count: 0x4000)
        sidewaysROMs = (0..<16).map { bank in
            guard let data = roms[bank] else { return nil }
            precondition(data.count <= 16384, "sideways ROM too big")
            let p = UnsafeMutablePointer<UInt8>.allocate(capacity: 0x4000)
            p.initialize(repeating: 0xFF, count: 0x4000)
            p.update(from: data, count: data.count)
            return p
        }

        // FRED and JIM are 1MHz; so are parts of SHEILA.
        var stretchTable = [Bool](repeating: false, count: 0x300)
        for i in 0..<0x200 { stretchTable[i] = true }
        for range in [0x00...0x1F, 0x40...0x7F, 0xC0...0xDF] {
            for i in range { stretchTable[0x200 + i] = true }
        }
        self.stretchTable = stretchTable

        pagedROM = sidewaysROMs[0]
        oldSystemVIAPB = systemVIA.b.p
        cpu.reset()
    }

    deinit {
        ram.deallocate()
        osROM.deallocate()
        for rom in sidewaysROMs { rom?.deallocate() }
    }

    // MARK: Memory

    /// Reads memory as the CPU would, without side effects. I/O reads return
    /// what the device would return.
    public func peek(_ address: UInt16) -> UInt8 {
        switch address {
        case 0..<0x8000: return ram[Int(address)]
        case 0x8000..<0xC000: return pagedROM?[Int(address - 0x8000)] ?? 0xFF
        case 0xFC00..<0xFF00: return peekIO(address)
        default: return osROM[Int(address - 0xC000)]
        }
    }

    /// Writes RAM directly (for loading programs). ROM and I/O are ignored.
    public func poke(_ address: UInt16, _ value: UInt8) {
        if address < 0x8000 {
            ram[Int(address)] = value
        }
    }

    private func peekIO(_ address: UInt16) -> UInt8 {
        switch address & 0xFFE0 {
        case 0xFE40: return systemVIA.peek(Int(address))
        case 0xFE60: return userVIA.peek(Int(address))
        case 0xFE80: return fdc.peek(Int(address))
        case 0xFEC0: return adc.peek(Int(address))
        case 0xFE00 where address & 0x19 == 1: return crtc.readData()
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
                return address & 1 == 0 ? aciaStatus : 0
            default:
                // Serial ULA: write only. (b2 has reads returning 0 on the B.)
                return 0
            }
        case 0xFE40:
            return systemVIA.read(Int(address))
        case 0xFE60:
            return userVIA.read(Int(address))
        case 0xFE80:
            return fdc.read(Int(address))
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
                if address & 1 == 0 {
                    aciaControl = value
                }
            default:
                serialULAControl = value
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
                pagedROM = sidewaysROMs[Int(romsel)]
            }
        case 0xFE40:
            systemVIA.write(Int(address), value)
        case 0xFE60:
            userVIA.write(Int(address), value)
        case 0xFE80:
            fdc.write(Int(address), value)
        case 0xFEC0:
            adc.write(Int(address), value)
        default:
            if address < 0xFE00 {
                // FRED and JIM: nothing fitted.
                unmappedIOWriteObserver?(address, value)
            }
        }
    }

    private var aciaStatus: UInt8 {
        // With RS423 selected and nothing connected, CTS is high, which
        // inhibits TDRE; the cassette side always has CTS low. (As jsbeeb.)
        let rs423 = serialULAControl & 0x40 != 0
        let notCTS: UInt8 = rs423 ? 0x08 : 0
        // Master reset (counter divide select 3) clears the status.
        if aciaControl & 3 == 3 {
            return notCTS
        }
        return notCTS | (rs423 ? 0 : 0x02)
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
        fdc.drives[drive].insert(disc)
    }

    // MARK: Keyboard

    public func isKeyDown(_ key: BeebKey) -> Bool {
        keyColumns[key.column] & UInt8(1 << key.row) != 0
    }

    /// Presses or releases a key. Break halts the CPU while held and resets
    /// it on release.
    public func setKey(_ key: BeebKey, down: Bool) {
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
            if cpu.access == .write {
                if address < 0x8000 {
                    ram[Int(address)] = cpu.dbus
                } else if address >= 0xFC00 && address < 0xFF00 {
                    writeIO(address, cpu.dbus)
                }
            } else {
                switch address >> 14 {
                case 0, 1:
                    cpu.dbus = ram[Int(address)]
                case 2:
                    // An empty socket leaves the data bus alone.
                    if let rom = pagedROM {
                        cpu.dbus = rom[Int(address - 0x8000)]
                    }
                default:
                    if address >= 0xFC00 && address < 0xFF00 {
                        cpu.dbus = readIO(address)
                    } else {
                        cpu.dbus = osROM[Int(address - 0xC000)]
                    }
                }
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
            // Mode 7: 1K at &7C00.
            address = (address & 0x3FF) | 0x7C00
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
            saa5050.byte(ic15Byte, dispen: output.display)
            ic15Byte = output.address & 0x2000 != 0 ? ram[Int(address)] : 0
        }

        // Done even in teletext mode: the cursor flag sets up the cursor.
        videoULA.byte(ram[Int(address)], cudisp: output.cudisp)
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

        // The 8271's INT is NMI.
        fdc.tick()
        cpu.setNMI(NMIDevice.fdc, fdc.nmi)

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
            oldSystemVIAPB = pb
        }
    }
}
