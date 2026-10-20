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
                Button("Open Program…") { machine?.openProgram() }
                    .keyboardShortcut("o")
                    .disabled(machine == nil)
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save Screenshot…") { machine?.saveScreenshot() }
                    .keyboardShortcut("s")
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
            .navigationTitle(machine.paused ? "BBC Micro (Paused)" : "BBC Micro")
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
