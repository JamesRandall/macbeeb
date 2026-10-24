import BeebNetwork
import SwiftUI

/// A network station in its own window: the same window a standalone
/// machine has, menus and all. Closing it leaves the station running.
struct StationWindow: View {
    static let windowID = "station"

    /// Which station: its network's package and its node.
    struct Ref: Codable, Hashable {
        var network: URL
        var node: UUID
    }

    let ref: Ref?

    var body: some View {
        if let ref, let session = NetworkSession.existing(ref.network),
           let controller = session.controllers[ref.node] {
            MachineScreen(machine: controller)
                .id(ObjectIdentifier(controller))
        } else {
            ContentUnavailableView {
                Label("Not Running", systemImage: "power")
            } description: {
                Text("This machine is switched off, or its network isn’t open.")
            }
            .frame(minWidth: 368, minHeight: 288)
        }
    }
}
