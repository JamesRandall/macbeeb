import BeebCore
import Foundation

/// The Distributed Mandelbrot network: eight workers that boot from the
/// file server into WBOOT, and a Guide machine whose screen says what to
/// do. The programs (MandelbrotGuest) are in the server's library, so
/// any station can *CLUSTER and *MANDEL.
public enum MandelbrotNetwork {
    /// The stations the workers have.
    public static let workers = 2...9

    /// The coordinator a Guide's instructions are for: MANDEL (MODE 5), or
    /// MANDEL2 (MODE 2 in VideoNuLA's colours, which cycle when it's done).
    public enum Coordinator: String, Sendable {
        case mode5 = "MANDEL", mode2 = "MANDEL2"
    }

    /// MODE 7 instructions: on the Guide machine's own disc (it boots it),
    /// and on the file server (GUIDE and GUIDE2).
    public static func guide(for coordinator: Coordinator = .mode5) -> String {
        coordinator == .mode5 ? guide : guide
            .replacingOccurrences(of: #"130 PRINT G$;"*MANDEL";W$;"  hand out tiles and draw""#,
                                  with: #"130 PRINT G$;"*MANDEL2";W$;" hand out tiles and draw""#)
            .replacingOccurrences(of: #"150 PRINT C$;"Each worker works out 16 x 8 tiles in""#,
                                  with: #"150 PRINT C$;"Workers work out 16 x 8 tiles; this""#)
            .replacingOccurrences(of: #"160 PRINT C$;"its own 6502 and sends them back.""#,
                                  with: #"160 PRINT C$;"BBC's VideoNuLA gives them 16 colours.""#)
            .replacingOccurrences(of: #"210 PRINT C$;"A key ends MANDEL's picture. On another""#,
                                  with: #"210 PRINT C$;"Then the colours cycle; a key ends it.""#)
            .replacingOccurrences(of: #"220 PRINT C$;"BBC, press Break and type *NET first.""#,
                                  with: #"220 PRINT C$;"Elsewhere: press Break, then *NET.""#)
            .replacingOccurrences(of: "  DISTRIBUTED MANDELBROT", with: " MANDELBROT IN COLOUR")
    }

    static let guide = """
    10 REM Distributed Mandelbrot: what to do
    20 MODE 7:VDU 23,1,0;0;0;0;
    30 Y$=CHR$131:C$=CHR$134:G$=CHR$130:W$=CHR$135
    40 FOR I%=1 TO 2:PRINT CHR$132;CHR$157;CHR$141;Y$;"  DISTRIBUTED MANDELBROT":NEXT
    50 PRINT
    60 PRINT C$;"Eight BBC Micros on this network are"
    70 PRINT C$;"waiting to draw the Mandelbrot set:"
    80 PRINT C$;"each has loaded WBOOT from the file"
    90 PRINT C$;"server, and listens on Econet."
    100 PRINT
    110 PRINT Y$;"Here (or on any BBC), type:"
    120 PRINT G$;"*CLUSTER";W$;" start the workers"
    130 PRINT G$;"*MANDEL";W$;"  hand out tiles and draw"
    140 PRINT
    150 PRINT C$;"Each worker works out 16 x 8 tiles in"
    160 PRINT C$;"its own 6502 and sends them back."
    170 PRINT Y$;"Try:";W$;"switching a worker off part"
    180 PRINT W$;"     way: its tile goes to another."
    190 PRINT G$;"*WORKERS";W$;" list them  ";G$;"*STOPWK";W$;" stop"
    200 PRINT Y$;"On the Mac:";W$;"Mandelbrot view, Traffic."
    210 PRINT C$;"A key ends MANDEL's picture. On another"
    220 PRINT C$;"BBC, press Break and type *NET first."
    230 PRINT
    240 PRINT CHR$132;CHR$157;W$;"This is station 1. Workers: 2 to 9  ";CHR$156
    250 *NET
    260 VDU 23,1,1;0;0;0;
    """

    /// What a worker's boot file says: load the bootstrap.
    public static let bootFile = "*WBOOT\r"

    /// The file server's disc: Level 1, the programs in the library (&),
    /// the workers' !BOOT and the guide in directory A.
    public static func fileServerDisc() throws -> [UInt8] {
        var volume = try DiscVolume(disc: Disc.fromImage(FileServerDisc.image(), format: .ssd))
        for file in MandelbrotGuest.files {
            try volume.save(at: .init(), name: "&.\(file.name)", loadAddress: 0xFFFF_0000 | file.loadAddress,
                            executionAddress: 0xFFFF_0000 | file.executionAddress, contents: file.contents)
        }
        let shared = FileServerDisc.sharedDirectory
        try volume.save(at: .init(), name: "\(shared).!BOOT", loadAddress: 0, executionAddress: 0, contents: Array(bootFile.utf8))
        try volume.save(at: .init(), name: "\(shared).GUIDE", loadAddress: 0xFFFF_1900, executionAddress: 0xFFFF_8023,
                        contents: BBCBasic.tokenise(guide(for: .mode5)))
        try volume.save(at: .init(), name: "\(shared).GUIDE2", loadAddress: 0xFFFF_1900, executionAddress: 0xFFFF_8023,
                        contents: BBCBasic.tokenise(guide(for: .mode2)))
        return volume.image
    }

    /// The Guide machine's disc: it boots into the instructions.
    public static func guideDisc(for coordinator: Coordinator = .mode5) throws -> [UInt8] {
        var volume = try DiscVolume(disc: Disc.fromImage(BlankDisc.dfs40.image(title: "MANDELBROT"), format: .ssd))
        try volume.save(at: .init(), name: "GUIDE", loadAddress: 0xFFFF_1900, executionAddress: 0xFFFF_8023,
                        contents: BBCBasic.tokenise(guide(for: coordinator)))
        try volume.save(at: .init(), name: "!BOOT", loadAddress: 0, executionAddress: 0, contents: Array("CHAIN \"GUIDE\"\r".utf8))
        volume.setBootOption(3)
        return volume.image
    }
}
