import AppKit
import BeebAgentKit
import BeebNetwork
import SwiftUI

/// `MacBeeb -MacBeebNetworkSelfTest /path/to/out.png`: opens a School
/// Classroom network (in a temporary folder), runs a different program on
/// each machine, saves pictures of the studio window, and quits. For
/// checking the studio end to end without looking at it.
@MainActor
enum NetworkSelfTest {
    static var path: String? {
        UserDefaults.standard.string(forKey: "MacBeebNetworkSelfTest") ?? UserDefaults.standard.string(forKey: "MacBeebMCPSelfTest")
    }

    /// `-MacBeebMCPSelfTest /path/to/transcript.txt`: drives a network
    /// through the MCP tools, as an agent would (in-process, not over the
    /// socket), writes what they said, and quits.
    static func runMCPIfRequested() -> Bool {
        guard let path = UserDefaults.standard.string(forKey: "MacBeebMCPSelfTest") else { return false }
        let tools = AgentTools(defaultContext: { nil }, directory: AppMachineDirectory())
        Thread.detachNewThread {
            var transcript = ""
            func call(_ name: String, _ arguments: JSONValue = [:]) -> String {
                let result = tools.call(name, arguments: arguments)
                let text = result.content.compactMap { if case .text(let t) = $0 { t } else { nil } }.joined()
                transcript += "> \(name) \(arguments)\n\(result.isError ? "ERROR " : "")\(text)\n\n"
                return text
            }
            _ = call("network_create", ["template": "school_classroom", "name": .string("MCP Test \(Int(Date().timeIntervalSince1970))")])
            _ = call("list_machines")
            // The file server starts itself.
            Thread.sleep(forTimeInterval: 15)
            _ = call("type_text", ["machine": "BBC 1", "text": "*NET\n10 PRINT \"AGENT\"\nSAVE \"AGENT\"\n"])
            Thread.sleep(forTimeInterval: 6)
            _ = call("type_text", ["machine": "1", "text": "*FX5,4\nVDU 2:PRINT \"PRINTED BY AN AGENT\":VDU 3\n"])
            Thread.sleep(forTimeInterval: 10)
            _ = call("network_status")
            _ = call("network_trace", ["limit": 12])
            _ = call("econet_status", ["machine": "File Server"])
            _ = call("screenshot", ["machine": "BBC 9"])
            let jobs = call("print_jobs")
            if let id = jobs.split(separator: ":").first.map(String.init) {
                _ = call("print_job", ["id": .string(id)])
                _ = call("export_print_job_pdf", ["id": .string(id)])
            }
            _ = call("network_power", ["machine": "File Server", "action": "off"])
            _ = call("type_text", ["machine": "BBC 2", "text": "*NET\n*CAT\n"])
            Thread.sleep(forTimeInterval: 8)
            _ = call("read_screen_text", ["machine": "BBC 2"])
            try? transcript.write(toFile: path, atomically: true, encoding: .utf8)
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
        return true
    }

    /// Shows the studio in a window of its own (no scene needed, so it
    /// works whatever windows the app restores).
    static func runIfRequested() {
        guard let path else { return }
        NSLog("MacBeeb: network self-test starting")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("macbeeb-network-selftest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("School Classroom.\(NetworkPackage.fileExtension)")
        try? NetworkPackage.save(NetworkTemplate.schoolClassroom.makeProject(), to: url)
        guard let session = try? NetworkSession.session(for: url) else {
            NSLog("MacBeeb: network self-test: can't open the network")
            NSApp.terminate(nil)
            return
        }
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1180, height: 780),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        let hosting = NSHostingController(rootView: NetworkStudioView(session: session).frame(width: 1180, height: 780))
        window.contentViewController = hosting
        window.title = session.project.name
        window.orderBack(nil)
        Task { @MainActor in
            // The file server starts itself; give it time.
            try? await Task.sleep(for: .seconds(10))
            let programs = [
                "*NET\n10 PRINT \"SAVED ON THE FILE SERVER\"\nSAVE \"HELLO\"\n*CAT\n",
                "MODE 2:FOR I%=0 TO 7:GCOL0,I%:X%=I%*160:MOVE X%,0:MOVE X%,1023:PLOT 85,X%+159,0:PLOT 85,X%+159,1023:NEXT\n",
                "MODE 1:FOR I%=0 TO 300 STEP 10:GCOL0,1+I% MOD 3:MOVE 640,512:DRAW 640+I%*COS(I%),512+I%*SIN(I%):NEXT\n",
                "*FX5,4\nVDU 2:PRINT \"HELLO FROM STATION 3, OVER ECONET\":FOR I%=1 TO 12:PRINT \"LINE \";I%:NEXT:VDU 3\n",
                "10 PRINT \"STATION 4 \";:GOTO 10\nRUN\n",
            ]
            for (node, program) in zip(session.project.stations.filter { $0.kind == .station }, programs) {
                session.controllers[node.id]?.host.send(.type(program))
            }
            try? await Task.sleep(for: .seconds(8))
            // Station 2 runs what station 1 saved.
            if let second = session.project.stations.filter({ $0.kind == .station }).dropFirst().first {
                session.controllers[second.id]?.host.send(.type("*NET\nCHAIN \"HELLO\"\n"))
            }
            try? await Task.sleep(for: .seconds(4))
            capture(window, to: path)
            session.selection = [session.project.stations[0].id]
            try? await Task.sleep(for: .seconds(1))
            capture(window, to: path.replacingOccurrences(of: ".png", with: "-selected.png"))
            // The Print Centre, with what station 3 printed.
            try? await Task.sleep(for: .seconds(8))
            let prints = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 760),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            prints.contentViewController = NSHostingController(rootView: PrintCentreWindow().frame(width: 1000, height: 760))
            prints.orderBack(nil)
            try? await Task.sleep(for: .seconds(2))
            capture(prints, to: path.replacingOccurrences(of: ".png", with: "-print.png"))
            NSApp.terminate(nil)
        }
    }

    private static func capture(_ window: NSWindow, to path: String) {
        guard let view = window.contentView?.superview,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            NSLog("MacBeeb: network self-test: no window")
            return
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
