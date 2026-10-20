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

    /// The bundled system discs for the co-processors that need one.
    public enum SystemDisc: String, CaseIterable, Sendable {
        /// Acorn CP/M 2.2 (BIOS 1.20) and its utilities, for the Z80.
        case cpm = "cpm-utilities.dsd"
        /// DOS Plus 1.2's boot disc, for the Master 512.
        case dosPlus = "dosplus-boot.adl"

        public init?(for coprocessor: BBCMicro.Coprocessor) {
            switch coprocessor {
            case .z80: self = .cpm
            case .master512: self = .dosPlus
            case .mos6502, .arm: return nil
            }
        }

        public var format: Disc.ImageFormat { Disc.ImageFormat(path: rawValue)! }

        public var data: [UInt8] {
            guard let url = bundle.url(forResource: rawValue, withExtension: nil, subdirectory: "Discs"),
                  let data = try? Data(contentsOf: url) else {
                preconditionFailure("missing bundled disc \(rawValue)")
            }
            return [UInt8](data)
        }
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
    /// given: the Z80 (client ROM 1.21) or the ARM Evaluation System
    /// (supervisor ROM 1.00).
    ///
    /// The Z80 and the Master 512 start with their system disc in drive 0
    /// (CP/M, DOS Plus), so they boot, unless `systemDisc` is false.
    ///
    /// On the Model B, `discInterface` picks the disc controller and its
    /// filing system (in bank 14).
    public static func configuration(for model: BBCMicro.Model, secondProcessor: Bool = false,
                                     coprocessor: BBCMicro.Coprocessor = .mos6502,
                                     discInterface: BBCMicro.DiscInterface = .intel8271,
                                     systemDisc: Bool = true) -> BBCMicro.Configuration {
        var configuration = standardConfiguration(for: model)
        configuration.coprocessor = coprocessor
        if model == .modelB {
            configuration.discInterface = discInterface
            configuration.sidewaysROMs[14] = switch discInterface {
            case .intel8271: data(.dfs12)
            case .acorn1770: data(.dfs226)
            case .watfordDDB2: data(.watfordDDFS153)
            case .watfordDDB3: data(.watfordDDFS154T)
            case .opus: data(.opusDDOS345)
            }
        }
        if secondProcessor && model.hasTube {
            let rom: Image = switch coprocessor {
            case .mos6502: .tube110
            case .z80: .z80121
            case .master512: .master512BIOS
            case .arm: .armEval100
            }
            configuration.secondProcessorROM = data(rom)
            if systemDisc, let disc = SystemDisc(for: coprocessor) {
                configuration.startupDisc = .init(name: disc.rawValue, image: disc.data, format: disc.format)
            }
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
