// Acorn's Level 2 file server, on a Model B with a 6502 Second Processor
// at station 254: its disc made here, and everything else through Acorn's
// own software (the server, DSCMGR, DNFS on the Model B, ANFS on the
// Master).

import Foundation
import Testing
@testable import BeebCore
import BeebNetwork
import BeebROMs

extension EconetRig {
    /// Starts Acorn's Level 2 file server on machine `index`, as the Studio
    /// does: the machine's given a 6502 Second Processor, `disc` goes in
    /// drive 0 and the utilities disc in drive 1, and the start-up is typed
    /// all at once.
    func startLevel2FileServer(_ index: Int, disc: Level2FileServerDisc, stations: Int = 10) throws {
        let station = Int(machines[index].econet!.station)
        bus.detach(machines[index])
        let server = BBCMicro(configuration: BeebROMs.configuration(for: .modelB, secondProcessor: true, econetStation: station))
        server.run(cycles: 0)
        machines[index] = server
        bus.attach(server)
        server.insertDisc(try Disc.fromImage(disc.image, format: .dsd), drive: 0)
        let utilities = Level2FileServerDisc.utilities
        server.insertDisc(try Disc.fromImage(utilities.data, format: utilities.format), drive: Level2FileServerDisc.utilitiesDrive)
        run(seconds: 1.5)
        server.type(Level2FileServerDisc.startup(stations: stations, date: Self.level2Date))
        run(until: { screen(index).contains("Ready") }, seconds: 60)
    }

    static let level2Date = Level2FileServerDisc.Date(day: 23, month: 10, year: 1988)

    /// Types a line and waits for the prompt.
    func command(_ index: Int, _ line: String, seconds: Double = 30) {
        type(index, line + "\n")
        run(until: { lastLines(index, 1) == ">" }, seconds: seconds)
    }

    /// The server's disc, as it is now.
    func level2Disc(_ index: Int) throws -> Level2FileServerDisc {
        try Level2FileServerDisc(image: machines[index].drives[0].disc!.toSSDOrDSD())
    }

    /// Holds N through a Shift-Break, as a DNFS station is told to select
    /// the network filing system and boot.
    func shiftNBreak(_ index: Int) {
        machines[index].applyKey(.n, down: true)
        machines[index].shiftBreak()
        run(seconds: 1)
        machines[index].applyKey(.n, down: false)
    }
}

/// A short machine-code program that prints `text`, loaded at &3000 in
/// the I/O processor.
func printingProgram(_ text: String) -> [UInt8] {
    // LDX #0: LDA &300E,X: BEQ end: JSR OSASCI: INX: BNE loop: .end RTS
    [0xA2, 0x00, 0xBD, 0x0E, 0x30, 0xF0, 0x06, 0x20, 0xE3, 0xFF, 0xE8, 0xD0, 0xF5, 0x60] + Array(text.utf8) + [0x0D, 0x00]
}

struct EconetLevel2Tests {
    /// The disc made here is DSCMGR's, byte for byte: DSCMGR run on the
    /// server's machine formats a blank disc in drive 1 (80 tracks, both
    /// sides, through the 8271) and initialises it with the same answers.
    @Test func discIsTheDiscManagers() throws {
        let rig = EconetRig([(.modelB, 254)])
        rig.bus.detach(rig.machines[0])
        rig.machines[0] = BBCMicro(configuration: BeebROMs.configuration(for: .modelB, secondProcessor: true))
        let utilities = Level2FileServerDisc.utilities
        rig.machines[0].insertDisc(try Disc.fromImage(utilities.data, format: utilities.format), drive: 0)
        rig.machines[0].insertDisc(Disc(), drive: 1)
        rig.run(seconds: 1.5)
        rig.type(0, "CHAIN \"DSCMGR\"\n")
        #expect(rig.run(until: { rig.screen(0).contains("Your Choice") }), "\(rig.screen(0))")
        rig.type(0, "I")
        rig.run(until: { rig.screen(0).contains("Drive number") }, seconds: 5)
        rig.type(0, "1\n")
        rig.run(until: { rig.screen(0).contains("press RETURN") }, seconds: 5)
        rig.type(0, "\n")
        #expect(rig.run(until: { rig.screen(0).contains("Disc name") }, seconds: 300), "\(rig.screen(0))")
        rig.type(0, "SERVER\n")
        rig.run(until: { rig.screen(0).contains("Date") }, seconds: 5)
        rig.type(0, "23/10/88\n")
        rig.run(until: { rig.screen(0).contains("Password File") }, seconds: 60)
        rig.type(0, "Y\n")
        for user in ["BOOT", "ALICE", "BOB"] {
            rig.run(until: { rig.lastLines(0, 1).hasPrefix("User name") }, seconds: 10)
            rig.type(0, user + "\n")
        }
        rig.run(until: { rig.lastLines(0, 1).hasPrefix("User name") }, seconds: 10)
        rig.type(0, "\n")
        #expect(rig.run(until: { rig.screen(0).contains("Disc initialised") }, seconds: 120), "\(rig.screen(0))")

        let managers = try rig.machines[0].drives[1].disc!.toSSDOrDSD()
        let ours = try Level2FileServerDisc(name: "SERVER", users: ["BOOT", "ALICE", "BOB"], date: EconetRig.level2Date).image
        #expect(managers.count == ours.count)
        let differing = (0..<min(managers.count, ours.count) / 256).filter { managers[$0 * 256..<$0 * 256 + 256] != ours[$0 * 256..<$0 * 256 + 256] }
        #expect(differing.isEmpty, "image sectors differ: \(differing)")

        // And it reads back.
        let disc = try Level2FileServerDisc(image: managers)
        #expect(disc.name == "SERVER")
        #expect(disc.users.map(\.name) == ["SYST", "BOOT", "ALICE", "BOB"])
        #expect(disc.users.first?.isSystem == true)
        #expect(try disc.entries(in: "$").map(\.name) == ["ALICE", "BOB", "BOOT", "PASSWORDS"])
    }

    /// Users with passwords, their own directories, sub-directories, SAVE,
    /// LOAD and *SAVE/*LOAD, from a Model B (DNFS) and a Master (ANFS); then
    /// the server's own writes read back from its disc.
    @Test func usersAndFiles() throws {
        let rig = EconetRig([(.modelB, 254), (.modelB, 1), (.master128, 2)])
        var disc = try Level2FileServerDisc(name: "SCHOOL", users: ["ALICE", "BOB"], date: EconetRig.level2Date)
        try disc.setPassword("SECRET", for: "ALICE")
        try disc.createDirectory("$.LIBRARY", date: EconetRig.level2Date)
        try rig.startLevel2FileServer(0, disc: disc)
        defer { print("STATION 1:\n\(rig.screen(1))\nSTATION 2:\n\(rig.screen(2))\nSERVER:\n\(rig.screen(0))") }

        rig.command(1, "*NET")
        rig.command(1, "*I AM ALICE")
        #expect(rig.lastLines(1, 2) == "Wrong password\n>", "\(rig.screen(1))")
        rig.command(1, "*I AM ALICE SECRET")
        rig.command(1, "*CAT")
        #expect(rig.screen(1).contains("ALICE     (000)     Owner"), "\(rig.screen(1))")
        #expect(rig.screen(1).contains("SCHOOL") && rig.screen(1).contains("Dir. ALICE") && rig.screen(1).contains("Lib. LIBRARY"))

        // BASIC, in a sub-directory.
        rig.command(1, "*CDIR GAMES")
        rig.command(1, "10 PRINT \"HELLO FROM ALICE\"")
        rig.command(1, "SAVE \"GAMES.HELLO\"")
        rig.command(1, "*ACCESS GAMES.HELLO WR/R")
        rig.command(1, "*DIR GAMES")
        rig.command(1, "*CAT")
        #expect(rig.screen(1).contains("HELLO      WR/R"), "\(rig.screen(1))")

        // Binary: 1K of a pattern.
        rig.command(1, "FOR I%=0 TO 1023:I%?&3000=(I%*7+3) AND 255:NEXT")
        rig.command(1, "*SAVE DATA 3000+400")
        rig.command(1, "*ACCESS DATA WR/R")

        // Another user, on the Master: someone else's files by their full
        // path, and only those they may read.
        rig.command(2, "*NET")
        rig.command(2, "*I AM BOB")
        rig.command(2, "CHAIN \"$.ALICE.GAMES.HELLO\"")
        #expect(rig.screen(2).contains("HELLO FROM ALICE\n"), "\(rig.screen(2))")
        rig.command(2, "*LOAD $.ALICE.GAMES.DATA 4000")
        let pattern: [UInt8] = (0..<1024).map { UInt8(($0 * 7 + 3) & 255) }
        #expect((0..<1024).map { rig.machines[2].peek(UInt16(0x4000 + $0)) } == pattern)
        rig.command(1, "*ACCESS DATA WR/")
        rig.command(2, "*LOAD $.ALICE.GAMES.DATA 4000")
        #expect(rig.lastLines(2, 2) == "Insufficient access\n>", "\(rig.screen(2))")
        rig.command(2, "SAVE \"$.ALICE.MINE\"")
        #expect(rig.lastLines(2, 2) == "Insufficient access\n>", "\(rig.screen(2))")
        rig.command(2, "SAVE \"BOBS\"")
        rig.command(2, "*CAT $")
        #expect(rig.screen(2).contains("$         ") && rig.screen(2).contains("Public"), "\(rig.screen(2))")

        // What the server wrote, read back from its disc.
        let after = try rig.level2Disc(0)
        #expect(try after.entries(in: "$.ALICE").map(\.name) == ["GAMES"])
        #expect(try after.entries(in: "$.ALICE.GAMES").map(\.name) == ["DATA", "HELLO"])
        #expect(try after.contents(of: "$.ALICE.GAMES.DATA") == pattern)
        let hello = try after.entry(at: "$.ALICE.GAMES.HELLO")
        #expect(hello.access == .shared && hello.loadAddress == 0xFFFF_1B00 && hello.executionAddress == 0xFFFF_8023)
        #expect(try BBCBasic.list(after.contents(of: hello)).contains("PRINT \"HELLO FROM ALICE\""))
        #expect(try after.entries(in: "$.BOB").map(\.name) == ["BOBS"])
    }

    /// BOOT, with boot option 3: logging on EXECs its !BOOT. *I AM BOOT
    /// does, and so does Shift-Break when the network's the filing system
    /// it starts: on the Model B, with N held (DNFS starts DFS otherwise,
    /// even after *NET); on the Master, after *NET or with N held (its
    /// configured filing system, DFS, otherwise). A user's own *OPT 4,3
    /// makes their !BOOT run too.
    @Test func bootUserExecsItsBoot() throws {
        let rig = EconetRig([(.modelB, 254), (.modelB, 1), (.master128, 2)])
        var disc = try Level2FileServerDisc(users: ["BOOT", "ALICE"], date: EconetRig.level2Date)
        try disc.setBootOption(.exec, for: "BOOT")
        try disc.save("$.BOOT.!BOOT", contents: Array("PRINT \"BOOTED \";40+2\r".utf8), access: .shared)
        #expect(disc.users.first { $0.name == "BOOT" }?.bootOption == .exec)
        try rig.startLevel2FileServer(0, disc: disc)
        defer { print("STATION 1:\n\(rig.screen(1))\nSTATION 2:\n\(rig.screen(2))\nSERVER:\n\(rig.screen(0))") }

        rig.command(1, "*NET")
        rig.type(1, "*I AM BOOT\n")
        #expect(rig.run(until: { rig.screen(1).contains("BOOTED 42\n") }), "\(rig.screen(1))")

        // Shift-Break alone starts DFS on the Model B, even after *NET.
        rig.machines[1].shiftBreak()
        rig.run(seconds: 5)
        #expect(rig.screen(1).contains("Acorn DFS") && !rig.screen(1).contains("BOOTED"), "\(rig.screen(1))")
        rig.shiftNBreak(1)
        #expect(rig.run(until: { rig.screen(1).contains("BOOTED 42\n") }), "\(rig.screen(1))")
        #expect(rig.screen(1).contains("Econet Station 001"))

        // The Master keeps NFS through Shift-Break once it's selected.
        rig.command(2, "*NET")
        rig.machines[2].shiftBreak()
        #expect(rig.run(until: { rig.screen(2).contains("BOOTED 42\n") }), "\(rig.screen(2))")

        // ALICE sets her own.
        rig.command(1, "*I AM ALICE")
        rig.command(1, "$&3000=\"PRINT \"\"ALICE'S BOOT\"\"\"")
        rig.command(1, "*SAVE !BOOT 3000+16")
        rig.command(1, "*OPT 4,3")
        rig.command(1, "*CAT")
        #expect(rig.screen(1).contains("Option 03 (Exec)"), "\(rig.screen(1))")
        rig.command(1, "*BYE")
        rig.command(1, "CLS")
        rig.type(1, "*I AM ALICE\n")
        #expect(rig.run(until: { rig.screen(1).contains("ALICE'S BOOT\n") }), "\(rig.screen(1))")
        #expect(try rig.level2Disc(0).users.first { $0.name == "ALICE" }?.bootOption == .exec)
    }

    /// $.LIBRARY is every user's library: *name runs a program from it.
    /// *LIB picks another.
    @Test func library() throws {
        let rig = EconetRig([(.modelB, 254), (.modelB, 1)])
        var disc = try Level2FileServerDisc(users: ["ALICE"], date: EconetRig.level2Date)
        try disc.createDirectory("$.LIBRARY")
        try disc.save("$.LIBRARY.HELLO", loadAddress: 0xFFFF_3000, executionAddress: 0xFFFF_3000,
                      contents: printingProgram("FROM THE LIBRARY"), access: .shared)
        try disc.createDirectory("$.ALICE.TOOLS")
        try disc.save("$.ALICE.TOOLS.TOOL", loadAddress: 0xFFFF_3000, executionAddress: 0xFFFF_3000,
                      contents: printingProgram("ALICE'S TOOL"))
        try rig.startLevel2FileServer(0, disc: disc)
        defer { print("STATION 1:\n\(rig.screen(1))\nSERVER:\n\(rig.screen(0))") }

        rig.command(1, "*NET")
        rig.command(1, "*I AM ALICE")
        rig.command(1, "*HELLO")
        #expect(rig.screen(1).contains("FROM THE LIBRARY\n"), "\(rig.screen(1))")
        rig.command(1, "*LIB TOOLS")
        rig.command(1, "*CAT")
        #expect(rig.screen(1).contains("Lib. TOOLS"), "\(rig.screen(1))")
        rig.command(1, "*TOOL")
        #expect(rig.screen(1).contains("ALICE'S TOOL\n"), "\(rig.screen(1))")
        rig.command(1, "*HELLO")
        #expect(rig.lastLines(1, 2) == "Bad Command\n>", "\(rig.screen(1))")
    }

    /// Files from the Mac go in $.LIBRARY, for everyone; a folder becomes a
    /// directory.
    @Test func filesFromTheMac() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("l2-\(UUID().uuidString)")
        let games = folder.appendingPathComponent("GAMES")
        try FileManager.default.createDirectory(at: games, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try "10 PRINT \"HELLO FROM THE MAC\"\n".write(to: folder.appendingPathComponent("FROMMAC.bas"), atomically: true, encoding: .utf8)
        try "10 PRINT \"A GAME\"\n".write(to: games.appendingPathComponent("SNAKE.bas"), atomically: true, encoding: .utf8)

        var disc = try Level2FileServerDisc.standard(date: EconetRig.level2Date)
        #expect(try disc.add([folder.appendingPathComponent("FROMMAC.bas"), games]) == ["$.LIBRARY.FROMMAC", "$.LIBRARY.GAMES.SNAKE"])

        let rig = EconetRig([(.modelB, 254), (.master128, 1)])
        try rig.startLevel2FileServer(0, disc: disc)
        rig.command(1, "*NET")
        rig.command(1, "*I AM GUEST")
        rig.command(1, "CHAIN \"$.LIBRARY.FROMMAC\"")
        #expect(rig.screen(1).contains("HELLO FROM THE MAC\n"), "\(rig.screen(1))")
        rig.command(1, "CHAIN \"$.LIBRARY.GAMES.SNAKE\"")
        #expect(rig.screen(1).contains("A GAME\n"), "\(rig.screen(1))")
    }

    /// The Studio's disc: BOOT's !BOOT (a *CAT) runs at log-on.
    @Test func standardDisc() throws {
        let disc = try Level2FileServerDisc.standard(date: EconetRig.level2Date)
        #expect(disc.users.map(\.name) == ["SYST", "BOOT", "GUEST"])
        #expect(try disc.entries(in: "$").map(\.name) == ["BOOT", "GUEST", "LIBRARY", "PASSWORDS"])
        let rig = EconetRig([(.modelB, 254), (.modelB, 1)])
        try rig.startLevel2FileServer(0, disc: disc)
        rig.shiftNBreak(1)
        #expect(rig.run(until: { rig.screen(1).contains("Option 03 (Exec)") && rig.screen(1).contains("!BOOT") }),
                "\(rig.screen(1))")
    }

    /// More users than one sector of the password file holds (15): it
    /// grows, as Acorn's EXTENDPWF would make it, and the server finds them.
    @Test func manyUsers() throws {
        var disc = try Level2FileServerDisc(users: [], date: EconetRig.level2Date)
        for number in 1...20 {
            try disc.addUser(.init("U\(number)", password: "P\(number)"), directory: number <= 17)
        }
        #expect(disc.users.count == 21)
        #expect(try disc.entries(in: "$").count == 18)
        let rig = EconetRig([(.modelB, 254), (.modelB, 1)])
        try rig.startLevel2FileServer(0, disc: disc)
        rig.command(1, "*NET")
        for (user, directory) in [("U17", "U17"), ("U20", "$")] {
            rig.command(1, "*I AM \(user) P\(user.dropFirst())")
            rig.command(1, "CLS")
            rig.command(1, "*CAT")
            #expect(rig.screen(1).contains("Dir. \(directory) "), "\(rig.screen(1))")
        }
        rig.command(1, "*I AM U20 WRONG")
        #expect(rig.lastLines(1, 2) == "Wrong password\n>", "\(rig.screen(1))")
    }

    /// A disc written while edited here keeps working with the server, and
    /// the server's later writes don't lose what was added.
    @Test func editsAfterTheServerHasWritten() throws {
        let rig = EconetRig([(.modelB, 254), (.modelB, 1)])
        try rig.startLevel2FileServer(0, disc: Level2FileServerDisc(users: ["ALICE"], date: EconetRig.level2Date))
        rig.command(1, "*NET")
        rig.command(1, "*I AM ALICE")
        rig.command(1, "10 PRINT \"ONE\"")
        rig.command(1, "SAVE \"ONE\"")

        // The server off; a file added from the Mac; the server back.
        var disc = try rig.level2Disc(0)
        try disc.save("$.ALICE.TWO", loadAddress: 0xFFFF_1900, executionAddress: 0xFFFF_8023,
                      contents: BBCBasic.tokenise("10 PRINT \"TWO\"\n"))
        try rig.startLevel2FileServer(0, disc: disc)
        rig.command(1, "*I AM ALICE")
        rig.command(1, "10 PRINT \"THREE\"")
        rig.command(1, "SAVE \"THREE\"")
        for name in ["ONE", "TWO", "THREE"] {
            rig.command(1, "CHAIN \"\(name)\"")
            #expect(rig.screen(1).contains("\n\(name)\n"), "\(rig.screen(1))")
        }
        #expect(try rig.level2Disc(0).entries(in: "$.ALICE").map(\.name) == ["ONE", "THREE", "TWO"])
    }
}
