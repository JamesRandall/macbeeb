// The user's ROMs in the machines' real sockets: the ROM library, each
// model's sockets, the Master's cartridges and links, and a network's own
// copies.

import Foundation
import Testing
@testable import BeebCore
@testable import BeebNetwork
import BeebROMs

/// A ROM image with a header: `title`, a language if `language`.
func syntheticROM(_ title: String, size: Int = 0x4000, language: Bool = false, fill: UInt8 = 0) -> [UInt8] {
    var image = [UInt8](repeating: fill, count: size)
    // Language and service entries that return straight away.
    image[0] = 0x60
    image[3] = 0x60
    image[6] = language ? 0xC2 : 0x82
    let text = Array(title.utf8)
    image.replaceSubrange(9..<(9 + text.count), with: text)
    let copyright = 9 + text.count
    image[7] = UInt8(copyright)
    image.replaceSubrange(copyright..<(copyright + 4), with: [0, 0x28, 0x43, 0x29])
    return image
}

/// A ROM library in a new folder, with these images added.
private func library(_ images: [String: [UInt8]]) throws -> (ROMLibrary, [String: UserROM]) {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("roms-\(UUID().uuidString)")
    let files = folder.appendingPathComponent("files")
    try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
    let library = ROMLibrary(folder: folder.appendingPathComponent("library"))
    var added: [String: UserROM] = [:]
    for (name, image) in images {
        let url = files.appendingPathComponent(name + ".rom")
        try Data(image).write(to: url)
        added[name] = try library.add(fileAt: url)
    }
    return (library, added)
}

struct ROMSocketTests {
    @Test func theLibraryKeepsCopiesByContent() throws {
        let (lib, roms) = try library(["Lisp": syntheticROM("LISP", language: true), "Small": Array(syntheticROM("SMALL").prefix(0x2000))])
        let lisp = try #require(roms["Lisp"])
        #expect(lisp.title == "LISP" && lisp.isLanguage && lisp.layout == .single && lisp.size == 0x4000)
        #expect(lib.data(for: lisp.id) == syntheticROM("LISP", language: true))
        // Adding the same image again finds it.
        let again = FileManager.default.temporaryDirectory.appendingPathComponent("again-\(UUID().uuidString).rom")
        try Data(syntheticROM("LISP", language: true)).write(to: again)
        #expect(try lib.add(fileAt: again).id == lisp.id && lib.roms.count == 2)
        // And it's still there next time.
        #expect(ROMLibrary(folder: lib.folder).roms.map(\.name) == ["Lisp", "Small"])
        try lib.remove(lisp.id)
        #expect(lib.data(for: lisp.id) == nil && lib.roms.count == 1)
    }

    @Test func layoutsComeFromTheSize() {
        #expect(ROMLayout.candidates(for: syntheticROM("A")) == [.single])
        // Two different ROMs in 32K: a pair first; the same one twice:
        // switched, as Inter-Word is.
        #expect(ROMLayout.candidates(for: syntheticROM("A") + syntheticROM("B")).first == .pair)
        #expect(ROMLayout.candidates(for: syntheticROM("A") + syntheticROM("A")).first == .mapped(.interWord))
        #expect(ROMLayout.candidates(for: [UInt8](repeating: 0, count: 0x10000)).first == .mapped(.interBase))
        #expect(ROMLayout.candidates(for: [UInt8](repeating: 0, count: 0x5000)).isEmpty)
    }

    @Test func theModelBHasFourSocketsAndHardwareTakesSome() {
        var setup = MachineSetup(model: .modelB)
        let stock = setup.socketGroups().flatMap(\.sockets)
        #expect(stock.map(\.bank) == [12, 13, 14, 15])
        #expect(stock.map(\.standard) == [nil, nil, "DFS 1.20", "BASIC 2"] && stock.allSatisfy { $0.takenBy == nil })
        setup.expansions = BBCMicro.Expansions(board: .watford32K, sidewaysRAM: .ram16, sidewaysRAMSocket: 13)
        let watford = setup.socketGroups().flatMap(\.sockets)
        #expect(watford[0].takenBy == "The Watford board's ROM" && watford[1].takenBy == "16K sideways RAM module")
        // A station: DNFS has the DFS's socket.
        #expect(MachineSetup(model: .modelB).socketGroups(econet: true).flatMap(\.sockets)[2].takenBy?.hasPrefix("DNFS") == true)
        // The Aries B32 renumbers them; the B12 has its own.
        setup.expansions = BBCMicro.Expansions(board: .ariesB32)
        #expect(setup.socketGroups().flatMap(\.sockets).map(\.answersAs) == [12, 9, 10, 11])
        setup.expansions = BBCMicro.Expansions(board: .ariesB32B12)
        let b12 = setup.socketGroups().flatMap(\.sockets)
        #expect(b12.map(\.answersAs) == Array(1...12))
    }

    @Test func romsGoInTheModelBsSockets() throws {
        let interWord = syntheticROM("INTER-WORD", language: true) + syntheticROM("INTER-WORD", language: true, fill: 1)
        let (lib, roms) = try library(["Lisp": syntheticROM("LISP", language: true), "IW": interWord])
        var setup = MachineSetup(model: .modelB)
        setup.sockets.roms = [12: .rom(roms["IW"]!.plugged), 13: .rom(roms["Lisp"]!.plugged), 14: .empty]
        let configuration = setup.configuration(roms: lib.source)
        #expect(configuration.sidewaysROMs[12] == interWord && configuration.romMappers[12] == .interWord)
        #expect(configuration.sidewaysROMs[13] == syntheticROM("LISP", language: true) && configuration.romMappers[13] == nil)
        // DFS taken out; BASIC still there.
        #expect(configuration.sidewaysROMs[14] == nil && configuration.sidewaysROMs[15] != nil)
        let m = BBCMicro(configuration: configuration)
        #expect(m.sidewaysSlots[12].header?.title == "INTER-WORD" && m.romMappers[12] == .interWord)

        // With the Aries B32, socket 13's ROM is bank 9.
        setup.expansions = BBCMicro.Expansions(board: .ariesB32)
        setup.sockets.roms[14] = nil
        let aries = setup.configuration(roms: lib.source)
        #expect(aries.sidewaysROMs[9] == syntheticROM("LISP", language: true) && aries.romMappers[12] == .interWord)
        // On a station, DNFS wins socket 14.
        setup.expansions = .none
        setup.sockets.roms[14] = .rom(roms["Lisp"]!.plugged)
        #expect(BBCMicro.ROMHeader(Array(setup.configuration(econetStation: 1, roms: lib.source).sidewaysROMs[14]!.prefix(256)))?.title == "DFS,NET")
    }

    @Test func aSmallROMRepeatsAndAMissingOneLeavesItsSocketEmpty() throws {
        let small = Array(syntheticROM("SMALL").prefix(0x2000))
        let (lib, roms) = try library(["Small": small])
        var setup = MachineSetup(model: .modelB)
        setup.sockets.roms = [12: .rom(roms["Small"]!.plugged), 13: .rom(PluggedROM(id: "gone", name: "Gone", layout: .single))]
        let configuration = setup.configuration(roms: lib.source)
        #expect(configuration.sidewaysROMs[12] == small + small)
        #expect(configuration.sidewaysROMs[13] == nil)
        #expect(setup.socketProblems(source: lib.source) == [13: "Gone isn't in the ROM library"])
    }

    @Test func theMastersCartridgesAndLinks() throws {
        let pair = syntheticROM("LOW") + syntheticROM("HIGH")
        let (lib, roms) = try library(["Pair": pair, "One": syntheticROM("ONE")])
        var setup = MachineSetup(model: .master128)
        #expect(setup.socketGroups().map(\.name) == ["Front Cartridge", "Rear Cartridge", "IC37", "IC41"])
        #expect(setup.socketGroups().allSatisfy { $0.sockets.isEmpty })

        setup.sockets.cartridges = [0: .roms, 1: .ram32]
        setup.sockets.romLinks = [4]
        setup.sockets.roms = [0: .rom(roms["Pair"]!.plugged), 5: .rom(roms["One"]!.plugged)]
        let configuration = setup.configuration(roms: lib.source)
        #expect(configuration.sidewaysROMs[0] == syntheticROM("LOW") && configuration.sidewaysROMs[1] == syntheticROM("HIGH"))
        #expect(configuration.sidewaysRAMBanks == [2, 3, 6, 7])
        #expect(configuration.sidewaysROMs[5] == syntheticROM("ONE") && configuration.sidewaysROMs[4] == nil)
        let m = BBCMicro(configuration: configuration)
        let slots = m.sidewaysSlots
        #expect(slots[0].owner == "Front cartridge" && slots[2].owner == "Rear cartridge (sideways RAM)")
        #expect(slots[2].kind == .ram && slots[5].owner == "IC37 (LK19 East)" && slots[6].kind == .ram)
        // The MOS finds them.
        m.runUntilIdle()
        m.type("*ROMS\n")
        m.runUntilIdle()
        let screen = m.screenText().joined(separator: "\n")
        #expect(screen.contains("LOW") && screen.contains("HIGH") && screen.contains("ONE"), "\(screen)")
    }

    @Test func aPairNeedsATwoBankSocket() throws {
        let (lib, roms) = try library(["Pair": syntheticROM("LOW") + syntheticROM("HIGH")])
        var setup = MachineSetup(model: .modelB)
        setup.sockets.roms = [12: .rom(roms["Pair"]!.plugged)]
        #expect(setup.socketProblems(source: lib.source)[12]?.contains("two banks") == true)
        setup.model = .bPlus
        setup.sockets.roms = [2: .rom(roms["Pair"]!.plugged)]
        #expect(setup.socketProblems(source: lib.source).isEmpty)
        #expect(setup.configuration(roms: lib.source).sidewaysROMs[3] == syntheticROM("HIGH"))
    }

    @Test func olderSetupsHaveStandardSockets() throws {
        let old = #"{"model":"master128","secondProcessor":false,"coprocessor":"mos6502","discInterface":"intel8271","expansions":{},"powerOnImagePaths":{},"controllerROMPaths":[],"videoNuLA":false}"#
        let setup = try JSONDecoder().decode(MachineSetup.self, from: Data(old.utf8))
        #expect(setup.sockets == .standard && setup.model == .master128)
        var changed = setup
        changed.sockets.cartridges[1] = .ram16
        #expect(try JSONDecoder().decode(MachineSetup.self, from: JSONEncoder().encode(changed)) == changed)
    }

    @Test func aNetworkKeepsCopiesOfItsROMs() throws {
        let (lib, roms) = try library(["Lisp": syntheticROM("LISP", language: true), "Other": syntheticROM("OTHER")])
        let package = FileManager.default.temporaryDirectory.appendingPathComponent("net-\(UUID().uuidString).macbeebnet")
        var setup = MachineSetup(model: .modelB)
        setup.sockets.roms = [12: .rom(roms["Lisp"]!.plugged)]
        var project = NetworkProject(name: "Net", nodes: [NetworkNode(kind: .station, name: "BBC", stationNumber: 1, setup: setup)])
        try NetworkPackage.save(project, to: package)
        try NetworkPackage.syncROMs(of: project, into: package, library: lib.source)
        // Gone from the library, the network still has it.
        try lib.remove(roms["Lisp"]!.id)
        let source = ROMSource(folders: [NetworkPackage.romsURL(in: package), lib.folder])
        #expect(setup.configuration(econetStation: 1, roms: source).sidewaysROMs[12] == syntheticROM("LISP", language: true))
        // Out of the sockets, the copy goes.
        project.nodes[0].setup?.sockets.roms = [:]
        try NetworkPackage.syncROMs(of: project, into: package, library: lib.source)
        #expect(!source.has(roms["Lisp"]!.id))
    }
}

struct MachineConfigurationsTests {
    @Test func savedMachinesKeepTheirSetUp() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("machines-\(UUID().uuidString).json")
        let store = MachineConfigurations(url: url)
        var master = MachineSetup(model: .master128, secondProcessor: true)
        master.sockets = SocketSetup(roms: [0: .rom(PluggedROM(id: "abc", name: "InterWord", layout: .mapped(.interWord)))],
                                     cartridges: [0: .roms, 1: .ram32], romLinks: [6])
        let saved = try store.save(master, as: "Word Processor")
        try store.save(MachineSetup(model: .modelB, videoNuLA: true), as: "Colour B")
        #expect(store.machines.map(\.name) == ["Colour B", "Word Processor"])
        #expect(store.matching(master)?.id == saved.id)
        #expect(master.fittedSummary == "6502 Second Processor · 32K Sideways RAM Cartridge · InterWord")
        // Saving under a name that's there replaces it.
        master.videoNuLA = true
        try store.save(master, as: "word processor")
        #expect(store.machines.count == 2 && store[saved.id]?.setup.videoNuLA == true)
        try store.rename(saved.id, to: "Inter Suite")
        #expect(store.freeName("Inter Suite") == "Inter Suite 2")
        // Next time.
        let reloaded = MachineConfigurations(url: url)
        #expect(reloaded.machines.map(\.name) == ["Colour B", "Inter Suite"] && reloaded[saved.id]?.setup == master)
        try reloaded.remove(saved.id)
        #expect(MachineConfigurations(url: url).machines.map(\.name) == ["Colour B"])
    }
}
