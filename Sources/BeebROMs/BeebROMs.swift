import Foundation

/// The bundled ROM images.
public enum BeebROMs {
    public enum Image: String, CaseIterable, Sendable {
        case os12 = "os12"
        case basic2 = "basic2"
        case dfs12 = "dfs12"
        case dfs226 = "dfs226"
        case bPlusMOS = "bplus-mos"
        case tube110 = "tube110"
        case z80121 = "z80-121"
        case master512BIOS = "master512-bios"
        case armEval100 = "armeval-100"
        case masterTurboParasite = "master-turbo-parasite"
        case watfordDDFS153 = "watford-ddfs153"
        case watfordDDFS154T = "watford-ddfs154t"
        case opusDDOS345 = "opus-ddos345"
        case mos510 = "mos510-mos"
        case mos510Utils = "mos510-utils"
        case mos510BASIC4 = "mos510-basic4"
        case mos510ADFS = "mos510-adfs"
        case mos320 = "mos320-mos"
        case mos320Terminal = "mos320-terminal"
        case mos320View = "mos320-view"
        case mos320ADFS = "mos320-adfs"
        case mos320BASIC4 = "mos320-basic4"
        case mos320Edit = "mos320-edit"
        case mos320ViewSheet = "mos320-viewsht"
        case mos320DFS = "mos320-dfs"
        /// Expansion boards' controller ROMs (see Firmware).
        case watford32KRAM240 = "watford-32kram-240"
        case ariesB32100 = "aries-b32-100"
    }

    /// The resource bundle. In an app it's in Contents/Resources (SwiftPM's
    /// Bundle.module only looks next to the executable, which codesign
    /// won't accept); elsewhere, Bundle.module finds it.
    static let bundle: Bundle = {
        let name = "macbeeb_BeebROMs.bundle"
        if let url = Bundle.main.resourceURL?.appendingPathComponent(name),
           let bundle = Bundle(url: url) {
            return bundle
        }
        return Bundle.module
    }()

    /// The bundled discs: the co-processors' system discs, and the rest of
    /// the Master 512's.
    public enum BundledDisc: String, CaseIterable, Sendable {
        /// Acorn CP/M 2.2 (BIOS 1.20) and its utilities, for the Z80.
        case cpm = "cpm-utilities.dsd"
        /// DOS Plus 1.2's boot disc, for the Master 512.
        case dosPlus = "dosplus-boot.adl"
        /// The Master 512's GEM discs (GEM itself, its applications and
        /// data) and its miscellaneous one, in its 800K DOS format.
        case gemApplications = "gem-applications.img"
        case gemData = "gem-data.img"
        case master512Miscellaneous = "master512-miscellaneous.img"

        /// The disc the co-processor boots from, if it needs one.
        public static func system(for coprocessor: BBCMicro.Coprocessor) -> BundledDisc? {
            switch coprocessor {
            case .z80: .cpm
            case .master512: .dosPlus
            case .mos6502, .arm, .masterTurbo: nil
            }
        }

        public var displayName: String {
            switch self {
            case .cpm: "CP/M 2.2 System and Utilities (Z80)"
            case .dosPlus: "DOS Plus 1.2 Boot (Master 512, disc 1)"
            case .gemApplications: "GEM Applications (Master 512, disc 2)"
            case .gemData: "GEM Data (Master 512, disc 3)"
            case .master512Miscellaneous: "Miscellaneous (Master 512, disc 4)"
            }
        }

        /// Its name for an agent: the file name without the extension.
        public var shortName: String { (rawValue as NSString).deletingPathExtension }

        public var format: Disc.ImageFormat { Disc.ImageFormat(path: rawValue)! }

        public var data: [UInt8] {
            guard let url = bundle.url(forResource: rawValue, withExtension: nil, subdirectory: "Discs"),
                  let data = try? Data(contentsOf: url) else {
                preconditionFailure("missing bundled disc \(rawValue)")
            }
            return [UInt8](data)
        }
    }

    /// The disc drives' noises for `model`: 3.5" drives on the Compact,
    /// 5.25" on the others. Nil if the samples can't be read.
    public static func discDriveSounds(for model: BBCMicro.Model) -> DiscDriveSounds? {
        let drive = model == .masterCompact ? "35" : "525"
        let names: [DiscDriveSounds.Sound: String] = [
            .spinStartLoaded: "spin_start_loaded", .spinStartEmpty: "spin_start_empty",
            .spinLoaded: "spin_loaded", .spinEmpty: "spin_empty", .spinEnd: "spin_end",
            .step: "step_1_1", .seek2ms: "seek_2ms", .seek6ms: "seek_6ms", .seek12ms: "seek_12ms", .seek20ms: "seek_20ms",
        ]
        var rate = 0.0
        var samples: [[Float]] = []
        for sound in DiscDriveSounds.Sound.allCases {
            guard let url = bundle.url(forResource: "\(drive)_\(names[sound]!)", withExtension: "wav", subdirectory: "Sounds"),
                  let data = try? Data(contentsOf: url),
                  let wav = DiscDriveSounds.decodeWAV([UInt8](data)),
                  rate == 0 || wav.rate == rate else { return nil }
            rate = wav.rate
            samples.append(wav.samples)
        }
        return DiscDriveSounds(rate: rate, samples: samples)
    }

    public static func data(_ image: Image) -> [UInt8] {
        guard let url = bundle.url(forResource: image.rawValue, withExtension: "rom", subdirectory: "ROMs"),
              let data = try? Data(contentsOf: url) else {
            preconditionFailure("missing bundled ROM \(image.rawValue)")
        }
        return [UInt8](data)
    }
}

import BeebCore

extension BeebROMs {
    /// A standard machine with the bundled ROMs:
    ///
    /// - Model B: OS 1.20, BASIC 2 (bank 15), DFS 1.20 (bank 14).
    /// - B+ 128K: the B+ MOS, BASIC 2 (bank 15), DFS 2.26 (bank 14), as b2;
    ///   sideways RAM in 0, 1, 12 and 13.
    /// - Master 128: MOS 3.20 and its ROMs in banks 9-15, as b2; sideways
    ///   RAM in 4-7.
    ///
    /// - Master Compact: MOS 5.10, Utils (bank 15), BASIC 4 (14), ADFS (13),
    ///   as b2; sideways RAM in 4-7. It boots ADFS (no DFS).
    ///
    /// With `secondProcessor`, a 6502 Second Processor (Tube OS 1.10) is
    /// fitted (not on the Compact, which has no Tube), or the `coprocessor`
    /// given: the Z80 (client ROM 1.21), the Master Turbo's 65C102 (its
    /// Tube OS 1.20; on the Master 128) or the ARM Evaluation System
    /// (supervisor ROM 1.00).
    ///
    /// The Z80 and the Master 512 start with their system disc in drive 0
    /// (CP/M, DOS Plus), so they boot, unless `systemDisc` is false.
    ///
    /// On the Model B, `discInterface` picks the disc controller and its
    /// filing system (in bank 14), and `expansions` the memory board.
    /// `sidewaysImages` are put in sideways RAM banks at power on.
    public static func configuration(for model: BBCMicro.Model, secondProcessor: Bool = false,
                                     coprocessor: BBCMicro.Coprocessor = .mos6502,
                                     discInterface: BBCMicro.DiscInterface = .intel8271,
                                     systemDisc: Bool = true,
                                     expansions: BBCMicro.Expansions = .none,
                                     sidewaysImages: [Int: [UInt8]] = [:],
                                     controllerROM: [UInt8]? = nil) -> BBCMicro.Configuration {
        var configuration = standardConfiguration(for: model)
        configuration.coprocessor = coprocessor
        if model == .modelB {
            configuration.expansions = expansions
            configuration.discInterface = discInterface
            configuration.sidewaysROMs[14] = switch discInterface {
            case .intel8271: data(.dfs12)
            case .acorn1770: data(.dfs226)
            case .watfordDDB2: data(.watfordDDFS153)
            case .watfordDDB3: data(.watfordDDFS154T)
            case .opus: data(.opusDDOS345)
            }
        }
        if secondProcessor && coprocessor.fits(model) {
            let rom: Image = switch coprocessor {
            case .mos6502: .tube110
            case .z80: .z80121
            case .master512: .master512BIOS
            case .arm: .armEval100
            case .masterTurbo: .masterTurboParasite
            }
            configuration.secondProcessorROM = data(rom)
            if systemDisc, let disc = BundledDisc.system(for: coprocessor) {
                configuration.startupDisc = .init(name: disc.rawValue, image: disc.data, format: disc.format)
            }
        }
        // A board's controller ROM: the bundled one, or the user's own.
        if let bank = configuration.fittedExpansions.board.controllerROMBank,
           let firmware = Firmware.standard(for: configuration.fittedExpansions.board) {
            configuration.sidewaysROMs[bank] = controllerROM ?? firmware.bundledData
        }
        // Only into RAM, and never over a ROM.
        let ramBanks = configuration.sidewaysRAMBanks.union(configuration.fittedExpansions.sidewaysRAMBanks)
        for (bank, image) in sidewaysImages where ramBanks.contains(bank) && image.count <= 0x4000 {
            configuration.sidewaysROMs[bank] = image
        }
        return configuration
    }

    private static func standardConfiguration(for model: BBCMicro.Model) -> BBCMicro.Configuration {
        switch model {
        case .modelA:
            return BBCMicro.Configuration(model: .modelA, os: data(.os12), sidewaysROMs: [15: data(.basic2)])
        case .modelB:
            return BBCMicro.Configuration(os: data(.os12), sidewaysROMs: [15: data(.basic2), 14: data(.dfs12)])
        case .bPlus:
            return BBCMicro.Configuration(model: .bPlus, os: data(.bPlusMOS),
                                          sidewaysROMs: [15: data(.basic2), 14: data(.dfs226)])
        case .masterCompact:
            return BBCMicro.Configuration(model: .masterCompact, os: data(.mos510), sidewaysROMs: [
                15: data(.mos510Utils),
                14: data(.mos510BASIC4),
                13: data(.mos510ADFS),
            ])
        case .master128:
            return BBCMicro.Configuration(model: .master128, os: data(.mos320), sidewaysROMs: [
                15: data(.mos320Terminal),
                14: data(.mos320View),
                13: data(.mos320ADFS),
                12: data(.mos320BASIC4),
                11: data(.mos320Edit),
                10: data(.mos320ViewSheet),
                9: data(.mos320DFS),
            ])
        }
    }
}
