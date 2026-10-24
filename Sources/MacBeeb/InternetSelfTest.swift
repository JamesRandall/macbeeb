import AppKit
import BeebNetwork
import SwiftUI

extension NetworkSelfTest {
    /// Two MacBeeb processes in one Internet Econet room, on the service
    /// set by `-MacBeebInternetEconetService URL` (a local one from
    /// acorn-internet-econet's `npm run dev` will do):
    ///
    /// - `-MacBeebNetworkSelfTestTemplate internetHost`: a network with a
    ///   Level 2 file server and the Guide BBC, shared into a new room; the
    ///   join code goes to path.code, then it runs for a while and captures
    ///   its canvas and Share sheet.
    /// - `-MacBeebNetworkSelfTestTemplate internetGuest`: waits for
    ///   path.code (the host's path), joins with a new network of one Model
    ///   B, then on it *NET, *I AM GUEST and *CAT on the host's server.
    ///
    /// Each writes what it saw to its path.txt. Credentials stay in memory.
    static func runInternet(_ path: String, host: Bool) {
        NSLog("MacBeeb: Internet Econet self-test (\(host ? "host" : "guest")) starting")
        let service = InternetEconetService.current
        var report = "Service: \(service.absoluteString)\n"
        func finish() {
            try? report.write(toFile: path.replacingOccurrences(of: ".png", with: ".txt"), atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
        func offscreen<V: View>(_ view: V, width: Double, height: Double) -> NSWindow {
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: height),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: view.frame(width: width, height: height))
            window.orderBack(nil)
            return window
        }
        func screen(_ session: NetworkSession, _ id: UUID) async -> String {
            (try? await session.controllers[id]?.host.performAsync { $0.machine.screenText().joined(separator: "\n") }) ?? "(off)"
        }
        let codeFile = UserDefaults.standard.string(forKey: "MacBeebInternetSelfTestCode") ?? path.replacingOccurrences(of: ".png", with: ".code")
        let clash = UserDefaults.standard.bool(forKey: "MacBeebInternetSelfTestClash")

        Task { @MainActor in
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("macbeeb-internet-selftest-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent("\(host ? "Host" : "Guest").\(NetworkPackage.fileExtension)")
            if host {
                // The Distributed Mandelbrot's server and Guide, without its workers.
                guard var project = try? NetworkPackage.create(.distributedMandelbrot, at: url) else { return finish() }
                project.nodes.removeAll { $0.name.hasPrefix("Worker") }
                try? NetworkPackage.save(project, to: url)
                guard let session = try? NetworkSession.session(for: url),
                      let server = session.project.nodes.first(where: { $0.kind == .fileServer }) else { return finish() }
                for _ in 0..<90 where !(await screen(session, server.id)).contains("Ready") {
                    try? await Task.sleep(for: .seconds(1))
                }
                report += "Server ready: \(await screen(session, server.id).contains("Ready"))\n"
                do {
                    try await session.share(on: service, name: "Self-test Classroom", shared: Set(session.project.stations.map(\.id)),
                                            screenSharing: true, showsScreens: true)
                } catch {
                    report += "Share failed: \(error)\n"
                    return finish()
                }
                guard let code = session.currentInvite?.code else { return finish() }
                try? code.write(toFile: codeFile, atomically: true, encoding: .utf8)
                report += "Code: \(code)\n"
                // Until the guest's been and gone (or two minutes).
                var sawGuest = false
                var sawScreens: Set<Int> = []
                for _ in 0..<120 {
                    try? await Task.sleep(for: .seconds(1))
                    if !session.remoteStations.isEmpty { sawGuest = true }
                    sawScreens.formUnion(session.remoteScreens.keys)
                    if sawGuest && FileManager.default.fileExists(atPath: codeFile + ".done") { break }
                }
                report += "Saw the guest's station: \(sawGuest)\n"
                report += "Guest's screens seen: \(sawScreens.sorted())\n"
                report += "Room: \(String(describing: session.room?.state)), participants \(session.room?.participants.map(\.name) ?? [])\n"
                report += "Stations: \(session.room?.stations.map { "\($0.station) \($0.label) \($0.online ? "online" : "offline")" } ?? [])\n"
                report += "Gateway: \(String(describing: session.internet?.gateway.counters))\n"
                let canvas = offscreen(NetworkStudioView(session: session, mode: .canvas), width: 1300, height: 800)
                let sheet = offscreen(InternetShareView(session: session), width: 520, height: 640)
                try? await Task.sleep(for: .seconds(2))
                capture(canvas, to: path.replacingOccurrences(of: ".png", with: "-canvas.png"))
                capture(sheet, to: path.replacingOccurrences(of: ".png", with: "-share.png"))
                report += "\n== Server\n\(await screen(session, server.id))\n"
                await session.leaveRoom()
                finish()
            } else {
                var code: String?
                for _ in 0..<180 {
                    code = try? String(contentsOfFile: codeFile, encoding: .utf8)
                    if code != nil { break }
                    try? await Task.sleep(for: .seconds(1))
                }
                guard let code else {
                    report += "No code from the host\n"
                    return finish()
                }
                report += "Code: \(code)\n"
                let api = RoomAPI(service: service)
                do {
                    let preview = try await api.resolve(code: code.lowercased().replacingOccurrences(of: "-", with: " "))
                    report += "Preview: \(preview.room.name), \(preview.participants) people, stations \(preview.stations.map { "\($0.station) \($0.label)" })\n"
                    let joined = try await api.join(roomId: preview.roomId, code: code, displayName: "Guest Mac")
                    var project = NetworkProject(name: preview.room.name)
                    project.nodes = [
                        // (With -MacBeebInternetSelfTestClash, station 1: the host's Guide's.)
                        NetworkNode(kind: .station, name: "Visitor", stationNumber: clash ? 1 : 7, setup: MachineSetup(model: .modelB),
                                    position: CanvasPoint()),
                        .clock(at: CanvasPoint(x: 0, y: NetworkProject.rowSpacing)),
                    ]
                    try NetworkPackage.save(project, to: url)
                    let session = try NetworkSession.session(for: url)
                    report += "Room allows screens: \(preview.room.allowsScreens)\n"
                    try session.enterRoom(service: service, roomId: preview.roomId, roomName: preview.room.name, joined: joined,
                                          shared: Set(session.project.stations.map(\.id)), showsScreens: preview.room.allowsScreens)
                    for _ in 0..<30 where !(session.internet?.gateway.remoteStations.contains(254) ?? false) {
                        try? await Task.sleep(for: .seconds(1))
                    }
                    report += "Sees the server: \(session.internet?.gateway.remoteStations.sorted() ?? [])\n"
                    if clash {
                        for _ in 0..<20 where session.roomConflicts.isEmpty { try? await Task.sleep(for: .seconds(1)) }
                        report += "Conflicts: \(session.roomConflicts.map { "\($0.name) \($0.station) -> \($0.suggestion ?? 0)" })\n"
                        let banner = offscreen(NetworkStudioView(session: session, mode: .canvas), width: 1300, height: 800)
                        try? await Task.sleep(for: .seconds(2))
                        capture(banner, to: path.replacingOccurrences(of: ".png", with: "-clash.png"))
                        if let conflict = session.roomConflicts.first, let number = conflict.suggestion {
                            report += "Renumbered: \(session.renumberForRoom(conflict.node, to: number) ?? "ok")\n"
                        }
                        for _ in 0..<20 where !(session.room?.stations.contains { $0.participantId == session.room?.participantId } ?? false) {
                            try? await Task.sleep(for: .seconds(1))
                        }
                        let mine = session.room?.stations.filter { $0.participantId == session.room?.participantId }.map(\.station) ?? []
                        report += "In the room as: \(mine), conflicts left: \(session.roomConflicts.count)\n"
                    }
                    guard let visitor = session.project.stations.first, let controller = session.controllers[visitor.id] else {
                        report += "No machine\n"
                        return finish()
                    }
                    try? await Task.sleep(for: .seconds(3))
                    controller.host.send(.type("*NET\n*I AM GUEST\n*CAT\n"))
                    for _ in 0..<60 where !(await screen(session, visitor.id)).contains("Owner") {
                        try? await Task.sleep(for: .seconds(1))
                    }
                    try? await Task.sleep(for: .seconds(2))
                    report += "Gateway: \(String(describing: session.internet?.gateway.counters))\n"
                    for _ in 0..<10 where session.remoteScreens.isEmpty { try? await Task.sleep(for: .seconds(1)) }
                    report += "Host's screens seen: \(session.remoteScreens.keys.sorted())\n"
                    report += "\n== Visitor\n\(await screen(session, visitor.id))\n"
                    let canvas = offscreen(NetworkStudioView(session: session, mode: .canvas), width: 1300, height: 800)
                    try? await Task.sleep(for: .seconds(2))
                    capture(canvas, to: path.replacingOccurrences(of: ".png", with: "-canvas.png"))
                    await session.leaveRoom()
                } catch {
                    report += "Failed: \(error)\n"
                }
                try? "done".write(toFile: codeFile + ".done", atomically: true, encoding: .utf8)
                finish()
            }
        }
    }
}
