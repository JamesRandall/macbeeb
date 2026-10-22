// New, formatted discs: the DFS and ADFS filing systems take them as their
// own *FORM would leave them, and save to them.

import Foundation
import Testing
@testable import BeebCore
import BeebROMs

struct BlankDiscTests {
    @Test func adfsMapChecksumsMatchARealDisc() {
        let disc = BeebROMs.BundledDisc.dosPlus.data
        #expect(ADFSMap.checksum(disc[0..<0x100]) == disc[0xFF])
        #expect(ADFSMap.checksum(disc[0x100..<0x200]) == disc[0x1FF])
    }

    @Test(arguments: BlankDisc.allCases)
    func sizesAndReadsBack(_ kind: BlankDisc) throws {
        let image = kind.image(title: "Games")
        let expected = switch kind {
        case .dfs40: 100
        case .dfs80, .dfsDoubleSided40: 200
        case .dfsDoubleSided80: 400
        case .adfsS: 160
        case .adfsM: 320
        case .adfsL: 640
        }
        #expect(image.count == expected * 1024)
        if !kind.isADFS {
            let sides = try DFSDisc.sides(ofImage: image, doubleSided: kind.format == .dsd)
            #expect(sides.count == kind.sides)
            #expect(sides.allSatisfy { $0.title == "Games" && $0.files.isEmpty })
        }
        // And through the drive and back.
        let disc = try Disc.fromImage(image, format: kind.format)
        #expect(try Disc.fromImage(disc.toImage(kind.format), format: kind.format).toImage(kind.format)
                == disc.toImage(kind.format))
    }

    @Test func titlesAreCutToFit() throws {
        let side = try DFSDisc(side: BlankDisc.dfs80.image(title: "A very long title"))
        #expect(side.title == "A very long")
    }

    @Test(arguments: [BlankDisc.dfs40, .dfs80])
    func dfsSavesToIt(_ kind: BlankDisc) throws {
        let machine = try bootModelBWithDFS()
        machine.insertDisc(try Disc.fromImage(kind.image(title: "BLANK"), format: kind.format))
        let catalogue = command(machine, "*CAT")
        #expect(catalogue.contains { $0.contains("BLANK") }, "\(catalogue)")
        let screen = command(machine, "10PRINT \"SAVED OK\"\nSAVE \"PROG\"\nNEW\nCHAIN \"PROG\"", maxSeconds: 30)
        #expect(screen.contains { $0.contains("SAVED OK") }, "\(screen)")
        let disc = try #require(machine.drives[0].disc)
        let side = try DFSDisc(side: disc.toImage(kind.format))
        #expect(side.file(named: "PROG") != nil)
    }

    @Test func dfsSecondSide() throws {
        let machine = try bootModelBWithDFS()
        let kind = BlankDisc.dfsDoubleSided80
        machine.insertDisc(try Disc.fromImage(kind.image(title: "TWO"), format: kind.format))
        command(machine, "10PRINT \"SIDE 2\"\nSAVE \":2.PROG\"", maxSeconds: 30)
        let catalogue = command(machine, "*CAT 2")
        #expect(catalogue.contains { $0.contains("TWO") } && catalogue.contains { $0.contains("PROG") }, "\(catalogue)")
        let disc = try #require(machine.drives[0].disc)
        let sides = try DFSDisc.sides(ofImage: disc.toImage(.dsd), doubleSided: true)
        #expect(sides[0].files.isEmpty && sides[1].file(named: "PROG") != nil)
    }

    @Test(arguments: [(BBCMicro.Model.master128, BlankDisc.adfsS), (.master128, .adfsM), (.masterCompact, .adfsL)])
    func adfsSavesToIt(_ model: BBCMicro.Model, _ kind: BlankDisc) throws {
        let machine = BBCMicro(configuration: BeebROMs.configuration(for: model))
        machine.insertDisc(try Disc.fromImage(kind.image(title: "Blank ADFS"), format: kind.format))
        #expect(machine.runUntilIdle())
        if model != .masterCompact {
            command(machine, "*ADFS")
        }
        let catalogue = command(machine, "*CAT")
        #expect(catalogue.contains { $0.contains("Blank ADFS") }, "\(catalogue)")
        let screen = command(machine, "10PRINT \"SAVED OK\"\nSAVE \"PROG\"\nNEW\nCHAIN \"PROG\"", maxSeconds: 30)
        #expect(screen.contains { $0.contains("SAVED OK") }, "\(screen)")
        let free = command(machine, "*FREE")
        #expect(!free.contains { $0.contains("Bad") || $0.contains("Broken") }, "\(free)")
    }
}
