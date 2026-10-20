// Kevin Edwards' protection decoders for Alien 8, Nightshade and Lunar
// Jetman: notoriously sensitive to CPU and VIA timing. The disc is used with
// his permission and isn't redistributed, so these run only when jsbeeb's
// copy is in reference/.

import Foundation
import Testing
@testable import BeebCore
import BeebROMs

struct ProtectionTests {
    static let discURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("reference/jsbeeb/public/discs/Protection.ssd")

    static var discAvailable: Bool { FileManager.default.fileExists(atPath: discURL.path) }

    @Test(.enabled(if: discAvailable), arguments: ["ALIEN8", "NIGHTSH", "JETMAN"])
    func decodes(_ name: String) throws {
        let machine = BBCMicro(os: BeebROMs.data(.os12),
                               sidewaysROMs: [15: BeebROMs.data(.basic2), 14: BeebROMs.data(.dfs12)])
        machine.insertDisc(try Disc.fromSSD([UInt8](Data(contentsOf: Self.discURL))))
        machine.runUntilIdle()
        machine.paste("CHAIN \"B.\(name)\"\n")
        // A successful decode jumps to the game at &E00.
        #expect(machine.runUntil(address: 0x0E00, maxSeconds: 20))
    }
}
