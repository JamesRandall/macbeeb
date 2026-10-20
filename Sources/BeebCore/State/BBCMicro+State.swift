import Foundation

extension BeebKey: Codable {}

extension BBCMicro {
    /// Everything about a running machine, for save states and rewind.
    /// Restoring it into a machine with the same ROMs continues exactly,
    /// cycle for cycle. (ROMs, the TV and audio outputs aren't included.)
    public struct Snapshot: Codable, Sendable {
        public static let currentVersion = 2
        public var version = Self.currentVersion

        public var cycles: UInt64
        var cpu: M6502.Snapshot
        var systemVIA: VIA6522
        var userVIA: VIA6522
        var crtc: CRTC6845
        var videoULA: VideoULA
        var saa5050: SAA5050
        var adc: UPD7002
        var soundChip: SN76489
        var model: Model
        /// Main, shadow, ANDY and HAZEL RAM.
        var ram: Data
        /// Sideways RAM banks' contents.
        var sidewaysRAM: [Int: Data]
        var romsel: UInt8
        var acccon: UInt8
        var pageTable: Int
        var lastVideoByte: UInt8
        var oldAddressableLatch: UInt8
        var rtc: MC146818
        var intel8271: Intel8271.State?
        var wd1770: WD1770.State?
        var stretch: Bool
        var addressableLatch: UInt8
        var oldSystemVIAPB: UInt8
        var systemVIAIRQ: UInt8
        var userVIAIRQ: UInt8
        var keyColumns: InlineArray<16, UInt8>
        var keyScanColumn: Int
        var notJoystickButtons: UInt8
        var resetting: Bool
        var keyEvents: [KeyEvent]
        var paste: Paste?
        var aciaControl: UInt8
        var serialULAControl: UInt8
        var crtcLastOutput: CRTC6845.Output
        var ic15Byte: UInt8
        var unit: VideoUnit
    }

    public func snapshot() -> Snapshot {
        Snapshot(cycles: cycles, cpu: cpu.snapshot, systemVIA: systemVIA, userVIA: userVIA, crtc: crtc,
                 videoULA: videoULA, saa5050: saa5050, adc: adc, soundChip: soundChip,
                 model: model, ram: Data(bytes: ram, count: Self.ramSize),
                 sidewaysRAM: Dictionary(uniqueKeysWithValues: sidewaysRAMBanks.map { ($0, Data(bytes: sidewaysBanks[$0]!, count: 0x4000)) }),
                 romsel: romsel, acccon: acccon, pageTable: pageTable, lastVideoByte: lastVideoByte,
                 oldAddressableLatch: oldAddressableLatch, rtc: rtc,
                 intel8271: intel8271?.state, wd1770: wd1770?.state, stretch: stretch,
                 addressableLatch: addressableLatch, oldSystemVIAPB: oldSystemVIAPB,
                 systemVIAIRQ: systemVIAIRQ, userVIAIRQ: userVIAIRQ,
                 keyColumns: keyColumns, keyScanColumn: keyScanColumn, notJoystickButtons: notJoystickButtons, resetting: resetting,
                 keyEvents: keyEvents, paste: paste, aciaControl: aciaControl,
                 serialULAControl: serialULAControl, crtcLastOutput: crtcLastOutput,
                 ic15Byte: ic15Byte, unit: unit)
    }

    public enum RestoreError: Error {
        case unsupportedVersion(Int)
        case wrongModel(Model)
    }

    public func restore(_ s: Snapshot) throws {
        guard s.version == Snapshot.currentVersion else { throw RestoreError.unsupportedVersion(s.version) }
        guard s.model == model else { throw RestoreError.wrongModel(s.model) }
        cycles = s.cycles
        cpu.restore(s.cpu)
        systemVIA = s.systemVIA
        userVIA = s.userVIA
        crtc = s.crtc
        videoULA = s.videoULA
        saa5050 = s.saa5050
        adc = s.adc
        soundChip = s.soundChip
        s.ram.withUnsafeBytes { ram.update(from: $0.bindMemory(to: UInt8.self).baseAddress!, count: Self.ramSize) }
        for (bank, data) in s.sidewaysRAM where sidewaysRAMBanks.contains(bank) && data.count == 0x4000 {
            data.withUnsafeBytes { sidewaysBanks[bank]!.update(from: $0.bindMemory(to: UInt8.self).baseAddress!, count: 0x4000) }
        }
        romsel = s.romsel
        acccon = s.acccon
        updatePaging()
        pageTable = s.pageTable
        lastVideoByte = s.lastVideoByte
        oldAddressableLatch = s.oldAddressableLatch
        rtc = s.rtc
        if let state = s.intel8271 { intel8271?.restore(state) }
        if let state = s.wd1770 { wd1770?.restore(state) }
        stretch = s.stretch
        addressableLatch = s.addressableLatch
        oldSystemVIAPB = s.oldSystemVIAPB
        systemVIAIRQ = s.systemVIAIRQ
        userVIAIRQ = s.userVIAIRQ
        keyColumns = s.keyColumns
        keyScanColumn = s.keyScanColumn
        notJoystickButtons = s.notJoystickButtons
        resetting = s.resetting
        keyEvents = s.keyEvents
        paste = s.paste
        aciaControl = s.aciaControl
        serialULAControl = s.serialULAControl
        crtcLastOutput = s.crtcLastOutput
        ic15Byte = s.ic15Byte
        unit = s.unit
        updateOpcodeHooks()
    }
}
