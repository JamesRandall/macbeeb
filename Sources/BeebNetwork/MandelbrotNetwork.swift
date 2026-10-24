import BeebCore
import Foundation

/// The Distributed Mandelbrot network: eight workers, BBCs at BASIC, that
/// *CLUSTER takes over by remote control, a Guide machine whose screen says
/// what to do, and a Level 2 file server. The programs (MandelbrotGuest)
/// are in the server's library, so any station that's logged on can
/// *CLUSTER and *MANDEL.
public enum MandelbrotNetwork {
    /// The stations the workers have.
    public static let workers = 2...9

    /// The coordinator a Guide's instructions are for: MANDEL (MODE 5), or
    /// MANDEL2 (MODE 2 in VideoNuLA's colours, which cycle when it's done).
    public enum Coordinator: String, Sendable {
        case mode5 = "MANDEL", mode2 = "MANDEL2"
    }

    /// MODE 7 instructions: on the Guide machine's own disc (it boots it),
    /// and on the file server (GUEST's GUIDE and GUIDE2). They select the
    /// network and log on as GUEST, trying again until the server's up.
    public static func guide(for coordinator: Coordinator = .mode5) -> String {
        coordinator == .mode5 ? guide : guide
            .replacingOccurrences(of: #"130 PRINT G$;"*MANDEL";W$;"  hand out tiles and draw""#,
                                  with: #"130 PRINT G$;"*MANDEL2";W$;" hand out tiles and draw""#)
            .replacingOccurrences(of: #"150 PRINT C$;"Each worker works out 16 x 8 tiles in""#,
                                  with: #"150 PRINT C$;"Workers work out 16 x 8 tiles; this""#)
            .replacingOccurrences(of: #"160 PRINT C$;"its own 6502 and sends them back.""#,
                                  with: #"160 PRINT C$;"BBC's VideoNuLA gives them 16 colours.""#)
            .replacingOccurrences(of: #"210 PRINT C$;"A key ends MANDEL's picture. On other""#,
                                  with: #"210 PRINT C$;"Then the colours cycle; a key ends it.""#)
            .replacingOccurrences(of: #"220 PRINT C$;"BBCs, first *NET and *I AM GUEST.""#,
                                  with: #"220 PRINT C$;"Elsewhere: *NET, then *I AM GUEST.""#)
            .replacingOccurrences(of: "  DISTRIBUTED MANDELBROT", with: " MANDELBROT IN COLOUR")
    }

    static let guide = """
    10 REM Distributed Mandelbrot: what to do
    20 MODE 7:VDU 23,1,0;0;0;0;
    30 Y$=CHR$131:C$=CHR$134:G$=CHR$130:W$=CHR$135
    40 FOR I%=1 TO 2:PRINT CHR$132;CHR$157;CHR$141;Y$;"  DISTRIBUTED MANDELBROT":NEXT
    50 PRINT
    60 PRINT C$;"Eight BBC Micros on this network sit"
    70 PRINT C$;"at BASIC. *CLUSTER takes each over by"
    80 PRINT C$;"remote control: POKEs code in over"
    90 PRINT C$;"Econet and JSRs it, to type *WORKER."
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
    210 PRINT C$;"A key ends MANDEL's picture. On other"
    220 PRINT C$;"BBCs, first *NET and *I AM GUEST."
    230 PRINT
    240 PRINT CHR$132;CHR$157;W$;"This is station 1. Workers: 2 to 9  ";CHR$156
    250 *NET
    260 ON ERROR IF ERR=17 VDU 23,1,1;0;0;0;:END ELSE T%=TIME+100:REPEAT UNTIL TIME>T%:GOTO 270
    270 *I AM GUEST
    280 ON ERROR OFF
    290 VDU 23,1,1;0;0;0;
    """

    /// The file server's disc, Level 2's:
    /// - GUEST, for the Guide, the workers and anyone else, with the guide programs;
    /// - the programs in $.LIBRARY, the library everyone's given, with the
    ///   coordinator's own CLUSTER (Mandelbrot in Colour's ends by pointing
    ///   at *MANDEL2).
    public static func fileServerDisc(for coordinator: Coordinator = .mode5,
                                      date: Level2FileServerDisc.Date = .today) throws -> Level2FileServerDisc {
        var disc = try Level2FileServerDisc(name: "MANDELBROT", users: ["GUEST"], date: date)
        try disc.createDirectory("$.LIBRARY", date: date)
        for var file in MandelbrotGuest.files {
            switch (file.name, coordinator) {
            case ("CLUSTER", .mode2), ("CLUSTC", .mode5): continue
            case ("CLUSTC", .mode2): file.name = "CLUSTER"
            default: break
            }
            try disc.save("$.LIBRARY.\(file.name)", loadAddress: 0xFFFF_0000 | file.loadAddress,
                          executionAddress: 0xFFFF_0000 | file.executionAddress, contents: file.contents, access: .shared, date: date)
        }
        try disc.save("$.GUEST.GUIDE", loadAddress: 0xFFFF_1900, executionAddress: 0xFFFF_8023,
                      contents: BBCBasic.tokenise(guide(for: .mode5)), access: .shared, date: date)
        try disc.save("$.GUEST.GUIDE2", loadAddress: 0xFFFF_1900, executionAddress: 0xFFFF_8023,
                      contents: BBCBasic.tokenise(guide(for: .mode2)), access: .shared, date: date)
        return disc
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
