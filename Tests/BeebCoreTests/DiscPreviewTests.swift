// Disc images as Quick Look shows them.

import Foundation
import Testing
@testable import BeebCore
import BeebROMs

struct DiscPreviewTests {
    @Test func dfsBothSides() throws {
        var sides = try DFSDisc.sides(ofImage: BlankDisc.dfsDoubleSided80.image(title: "Games <1>"), doubleSided: true)
        try sides[0].save(name: "ELITE", loadAddress: 0xFFFF_1900, executionAddress: 0xFFFF_8023, contents: [1, 2],
                          locked: true)
        try sides[1].save(directory: "W", name: "DATA", loadAddress: 0x3000, executionAddress: 0, contents: [3])
        let html = DiscPreview.html(image: DFSDisc.image(sides: sides), fileName: "games.dsd")
        #expect(html.contains("<h1>Games &lt;1&gt;</h1>"))
        #expect(html.contains("Side 0") && html.contains("Side 2"))
        #expect(html.contains("<td>ELITE</td><td>FF1900</td><td>FF8023</td><td>000002</td><td>L</td>"))
        #expect(html.contains("<td>W.DATA</td><td>003000</td>"))
    }

    @Test func adfsDirectories() throws {
        var volume = DiscVolume.adfs(try ADFSDisc(image: BlankDisc.adfsL.image(title: "Work")))
        try volume.createDirectory(at: .init(), name: "Games")
        let games = try #require(try volume.items(at: .init()).first)
        try volume.save(at: .init(directory: games.startSector), name: "Elite", loadAddress: 0, executionAddress: 0,
                        contents: [1])
        let html = DiscPreview.html(image: volume.image, fileName: "work.adl")
        #expect(html.contains("<h1>Work</h1>") && html.contains("📁 Games"))
        #expect(html.contains("<h2>$.Games</h2>") && html.contains("<td>Elite</td><td>00000000</td>"))
    }

    @Test func otherDiscs() {
        #expect(DiscPreview.html(image: [UInt8](repeating: 0, count: 2048), fileName: "blank.ssd")
            .contains("isn’t formatted for DFS or ADFS"))
        #expect(DiscPreview.html(image: BeebROMs.BundledDisc.gemData.data, fileName: "gem.img").contains("DOS disc"))
        #expect(DiscPreview.html(image: BeebROMs.BundledDisc.dosPlus.data, fileName: "dosplus.adl").contains("dosboot"))
    }
}
