import AppKit
import BeebNetwork
import SwiftUI

extension NetworkSelfTest {
    /// With `-MacBeebNetworkSelfTestTemplate hardware`, `-MacBeebROMLibraryFolder
    /// DIR` and `-MacBeebMachinesFile FILE` (a library and configurations of
    /// its own) and `-MacBeebHardwareSelfTestROMs DIR` (the
    /// ROM files to add): a BBC and a Master with the user's ROMs in their
    /// sockets and the Master's cartridges, as a network's stations; writes
    /// their screens after *HELP and *ROMS (path.txt), and pictures of their
    /// Hardware windows and the ROM Library.
    static func runHardware(_ path: String) {
        NSLog("MacBeeb: hardware self-test starting")
        let library = ROMLibrary.shared
        let romFolder = UserDefaults.standard.string(forKey: "MacBeebHardwareSelfTestROMs").map { URL(fileURLWithPath: $0) }
        let files = romFolder.flatMap { try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil) } ?? []
        for file in files where file.pathExtension == "rom" {
            _ = try? library.add(fileAt: file)
        }
        func rom(_ prefix: String) -> SocketContent? {
            library.roms.first { $0.name.hasPrefix(prefix) }.map { .rom($0.plugged) }
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("macbeeb-hardware-selftest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("Hardware.\(NetworkPackage.fileExtension)")
        guard var project = try? NetworkPackage.create(.bbcAndMaster, at: url) else {
            NSApp.terminate(nil)
            return
        }
        for index in project.nodes.indices where project.nodes[index].kind == .station {
            if project.nodes[index].setup?.model == .master128 {
                project.nodes[index].setup?.sockets = SocketSetup(
                    roms: [0: rom("InterSheet"), 1: rom("Computer Concepts InterWord"), 4: rom("Acornsoft Lisp")].compactMapValues { $0 },
                    cartridges: [0: .roms, 1: .ram32], romLinks: [4])
            } else {
                project.nodes[index].setup?.sockets = SocketSetup(
                    roms: [12: rom("Computer Concepts InterBase v2"), 13: rom("Acornsoft C System")].compactMapValues { $0 })
            }
        }
        try? NetworkPackage.save(project, to: url)
        try? NetworkPackage.syncROMs(of: project, into: url)
        guard let session = try? NetworkSession.session(for: url) else {
            NSApp.terminate(nil)
            return
        }
        let stations = session.project.stations.filter { $0.kind == .station }
        func offscreen<V: View>(_ view: V, width: Double, height: Double) -> NSWindow {
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: height),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.contentViewController = NSHostingController(rootView: view.frame(width: width, height: height))
            window.orderBack(nil)
            return window
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            var report = "ROMs in the library: \(library.roms.map(\.name).joined(separator: ", "))\n"
            for node in stations {
                guard let controller = session.controllers[node.id] else { continue }
                controller.host.send(.type(node.setup?.model == .master128 ? "*ROMS\n" : "*HELP\n"))
            }
            try? await Task.sleep(for: .seconds(4))
            for node in stations {
                guard let controller = session.controllers[node.id] else { continue }
                let text = (try? await controller.host.performAsync { $0.machine.screenText().joined(separator: "\n") }) ?? "(off)"
                report += "\n== \(node.name)\n\(text)\n"
                let window = offscreen(HardwareExpansionsWindow(machine: controller), width: 760, height: 1500)
                try? await Task.sleep(for: .seconds(2))
                capture(window, to: path.replacingOccurrences(of: ".png", with: "-\(node.name).png"))
            }
            // Clicking a link's control to ROM Socket and back again.
            if let master = stations.first(where: { $0.setup?.model == .master128 }), let controller = session.controllers[master.id],
               UserDefaults.standard.bool(forKey: "MacBeebHardwareSelfTestClicks") {
                let window = offscreen(HardwareExpansionsWindow(machine: controller), width: 760, height: 1500)
                try? await Task.sleep(for: .seconds(2))
                func segmented(_ view: NSView) -> [NSSegmentedControl] {
                    (view as? NSSegmentedControl).map { [$0] } ?? view.subviews.flatMap(segmented)
                }
                @MainActor func click(_ index: Int, segment: Int) {
                    let controls = segmented(window.contentView!)
                    report += "Segmented controls: \(controls.map { "\($0.label(forSegment: 0) ?? "")=\($0.selectedSegment)" })\n"
                    guard index < controls.count else { return }
                    controls[index].selectedSegment = segment
                    controls[index].sendAction(controls[index].action, to: controls[index].target)
                }
                // IC41 (LK18) is the second link: currently RAM.
                click(1, segment: 1)
                try? await Task.sleep(for: .seconds(1))
                capture(window, to: path.replacingOccurrences(of: ".png", with: "-click1.png"))
                click(1, segment: 0)
                try? await Task.sleep(for: .seconds(1))
                capture(window, to: path.replacingOccurrences(of: ".png", with: "-click2.png"))
                click(1, segment: 0)
            }
            // The Master saved as a configuration, and added to the network
            // from the palette.
            if let master = stations.first(where: { $0.setup?.model == .master128 }), let setup = master.setup,
               let saved = try? MachineConfigurations.shared.save(setup, as: "Inter Suite"),
               let id = session.add(saved, at: session.project.nextPosition(for: .station)) {
                session.selection = [id]
                try? await Task.sleep(for: .seconds(4))
                session.controllers[id]?.host.send(.type("*ROMS\n"))
                try? await Task.sleep(for: .seconds(3))
                let text = (try? await session.controllers[id]?.host.performAsync { $0.machine.screenText().joined(separator: "\n") }) ?? nil
                report += "\n== \(session.project[id]?.name ?? "?") (added from the saved configuration)\n\(text ?? "(off)")\n"
                let canvas = offscreen(NetworkStudioView(session: session, mode: .canvas), width: 1300, height: 800)
                try? await Task.sleep(for: .seconds(2))
                capture(canvas, to: path.replacingOccurrences(of: ".png", with: "-canvas.png"))
            }
            let configurations = offscreen(MachineConfigurationsWindow(), width: 820, height: 300)
            try? await Task.sleep(for: .seconds(1))
            capture(configurations, to: path.replacingOccurrences(of: ".png", with: "-configurations.png"))
            let libraryWindow = offscreen(ROMLibraryWindow(), width: 820, height: 420)
            try? await Task.sleep(for: .seconds(1))
            capture(libraryWindow, to: path.replacingOccurrences(of: ".png", with: "-library.png"))
            try? report.write(toFile: path.replacingOccurrences(of: ".png", with: ".txt"), atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
    }
}
