import AppKit
import SwiftUI

@main
struct MacBeebApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @FocusedValue(MachineController.self) private var machine

    var body: some Scene {
        WindowGroup("BBC Micro") {
            MachineWindow()
        }
        .defaultSize(width: 960, height: 768)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Disc…") { machine?.openDisc() }
                    .keyboardShortcut("o")
                    .disabled(machine == nil)
                Button("Insert Disc in Drive 0…") { machine?.openDisc(drive: 0, boot: false) }
                    .keyboardShortcut("o", modifiers: [.command, .option])
                    .disabled(machine == nil)
                Button("Insert Disc in Drive 1…") { machine?.openDisc(drive: 1, boot: false) }
                    .disabled(machine == nil)
                Divider()
                Button("Eject Drive 0") { machine?.ejectDisc(drive: 0) }
                    .disabled(machine?.discNames[0] == nil)
                Button("Eject Drive 1") { machine?.ejectDisc(drive: 1) }
                    .disabled(machine?.discNames[1] == nil)
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save Screenshot…") { machine?.saveScreenshot() }
                    .keyboardShortcut("s")
                    .disabled(machine == nil)
                Button(machine?.recordingURL == nil ? "Start Recording…" : "Stop Recording") { machine?.toggleRecording() }
                    .keyboardShortcut("r", modifiers: [.command, .option])
                    .disabled(machine == nil)
            }
            CommandGroup(replacing: .pasteboard) {
                Button("Copy Screenshot") { machine?.copyScreenshot() }
                    .keyboardShortcut("c")
                    .disabled(machine == nil)
                Button("Paste Text") { machine?.pasteText() }
                    .keyboardShortcut("v")
                    .disabled(machine == nil)
            }
            CommandMenu("Machine") {
                Button(machine?.paused == true ? "Resume" : "Pause") { machine?.togglePause() }
                    .keyboardShortcut("p")
                Button(machine?.speedLimited == false ? "Normal Speed" : "Full Speed") { machine?.toggleSpeedLimit() }
                    .keyboardShortcut("f", modifiers: [.command, .option])
                Divider()
                Button("Break") { machine?.pressBreak() }
                    .keyboardShortcut("b", modifiers: [.command])
                Button("Shift-Break (Boot Disc)") { machine?.shiftBreak() }
                    .keyboardShortcut("b", modifiers: [.command, .shift])
                Button("Power Cycle") { machine?.powerCycle() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }
    }
}

struct MachineWindow: View {
    @State private var machine = MachineController()

    var body: some View {
        EmulatorView(host: machine.host)
            .frame(minWidth: 368, minHeight: 288)
            .background(.black)
            .focusedSceneValue(machine)
            .navigationTitle(title)
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first(where: { ["ssd", "dsd"].contains($0.pathExtension.lowercased()) }) else {
                    return false
                }
                machine.insertDisc(url)
                return true
            }
            .onOpenURL { url in
                machine.insertDisc(url)
            }
    }

    private var title: String {
        var title = machine.discNames[0].map { "BBC Micro — \($0)" } ?? "BBC Micro"
        if machine.paused {
            title += " (Paused)"
        }
        if machine.recordingURL != nil {
            title += " ● Recording"
        }
        return title
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when run as a plain executable (swift run) rather than an
        // app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
