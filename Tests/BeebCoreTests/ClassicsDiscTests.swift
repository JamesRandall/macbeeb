// Manual verification of the bookshelf's games against their real discs,
// which aren't in the repository. Download each game's disc from its
// BBCMicro.co.uk page into a folder outside the repository, then:
//
//   MACBEEB_CLASSICS_DISCS=/path/to/folder make test
//
// Without it these tests don't run.

import Foundation
import Testing
@testable import BeebCore
import BeebLibrary
import BeebROMs

private let discFolder = ProcessInfo.processInfo.environment["MACBEEB_CLASSICS_DISCS"].map { URL(fileURLWithPath: $0) }

@Suite(.enabled(if: discFolder != nil, "Set MACBEEB_CLASSICS_DISCS to a folder of the games' downloaded discs"))
struct ClassicsDiscTests {
    /// The downloaded disc for `game`, found by its contents.
    func disc(for game: CuratedGame) throws -> DiskCandidate? {
        let files = try FileManager.default.contentsOfDirectory(at: discFolder!, includingPropertiesForKeys: nil)
        for url in files {
            if let candidate = try? GameLibrary.candidate(at: url), Catalogue.classics.game(forDigest: candidate.digest) == game {
                return candidate
            }
        }
        return nil
    }

    /// Boots `game`'s disc on the machine the catalogue gives it, as Play
    /// does: Shift held through power on.
    func boot(_ game: CuratedGame, _ candidate: DiskCandidate, seconds: Double) throws -> BBCMicro {
        let requirement = game.machine
        let machine = BBCMicro(configuration: BeebROMs.configuration(for: requirement.model,
                                                                      secondProcessor: requirement.coprocessor != nil,
                                                                      coprocessor: requirement.coprocessor ?? .mos6502))
        machine.insertDisc(try Disc.fromImage([UInt8](candidate.data), format: candidate.format))
        machine.setKey(.shift, down: true)
        machine.run(seconds: 1)
        machine.setKey(.shift, down: false)
        machine.run(seconds: seconds)
        return machine
    }

    @Test(arguments: Catalogue.classics.allGames)
    func bootsPastBASIC(_ game: CuratedGame) throws {
        guard let candidate = try disc(for: game) else {
            Issue.record("No disc for \(game.title) in \(discFolder!.path)")
            return
        }
        let machine = try boot(game, candidate, seconds: 25)
        // Still at BASIC's prompt, or an error, means it didn't start.
        let text = machine.teletextScreenText() ?? []
        #expect(!text.contains { $0.hasPrefix(">") || $0.contains("Bad command") || $0.contains("not found") },
                "\(game.title): \(text)")
    }
}
