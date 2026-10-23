import AppKit
import BeebNetwork
import SwiftUI

/// `MacBeeb -MacBeebNetworkSelfTest /path/to/out.png`: opens a School
/// Classroom network (in a temporary folder), runs a different program on
/// each machine, saves pictures of the studio window, and quits. For
/// checking the studio end to end without looking at it.
@MainActor
enum NetworkSelfTest {
    static var path: String? { UserDefaults.standard.string(forKey: "MacBeebNetworkSelfTest") }

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
                "MODE 7:FOR I%=1 TO 20:PRINT CHR$(129+I% MOD 7);\"STATION 3 SAYS HELLO\":NEXT\n",
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
