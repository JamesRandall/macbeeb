import AppKit
import BeebCore
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
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { Updates.shared.checkForUpdates() }
                    .disabled(!Updates.shared.isAvailable)
            }
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
                Divider()
                Button("Load Tape…") { machine?.openTape() }
                    .keyboardShortcut("t", modifiers: [.command, .option])
                    .disabled(machine == nil)
                Button("Rewind Tape") { machine?.rewindTape() }
                    .disabled(machine?.tapeName == nil)
                Button("Eject Tape") { machine?.ejectTape() }
                    .disabled(machine?.tapeName == nil)
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save Screenshot…") { machine?.saveScreenshot() }
                    .keyboardShortcut("s")
                    .disabled(machine == nil)
                Divider()
                Button("Save State…") { machine?.saveState() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(machine == nil)
                Button("Load State…") { machine?.loadState() }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                    .disabled(machine == nil)
                Divider()
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
            CommandGroup(after: .toolbar) {
                Picker("Display", selection: Binding(
                    get: { machine?.displayStyle ?? DisplayStyle.saved },
                    set: { machine?.displayStyle = $0 }
                )) {
                    ForEach(DisplayStyle.allCases) { style in
                        Text(style.name).tag(style)
                    }
                }
                .disabled(machine == nil)
                Divider()
            }
            CommandMenu("Debug") {
                Button("Show Debugger") { machine?.debuggerRequested = true }
                    .keyboardShortcut("d", modifiers: [.command, .option])
                    .disabled(machine == nil)
                Button(machine?.debugStop == nil ? "Break into Debugger" : "Continue") {
                    if let machine {
                        machine.debugger.pauseOrContinue()
                        machine.debuggerRequested = machine.debugStop == nil
                    }
                }
                .keyboardShortcut("y", modifiers: [.command, .control])
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
                Divider()
                Picker("Model", selection: Binding(
                    get: { machine?.model ?? .modelB },
                    set: { machine?.setModel($0) }
                )) {
                    ForEach(BBCMicro.Model.allCases, id: \.self) { model in
                        Text(model.displayName).tag(model)
                    }
                }
                .pickerStyle(.inline)
                .disabled(machine == nil)
                Toggle("6502 Second Processor", isOn: Binding(
                    get: { machine?.secondProcessor ?? false },
                    set: { machine?.setSecondProcessor($0) }
                ))
                .disabled(machine == nil)
            }
        }

        WindowGroup("Debugger", id: "debugger", for: UUID.self) { $id in
            if let id, let machine = MachineController.all[id] {
                DebuggerWindow(model: machine.debugger, machineName: machine.model.displayName)
            }
        }
        .defaultSize(width: 1100, height: 760)

        Settings {
            SettingsView()
        }
    }
}

struct MachineWindow: View {
    @State private var machine = MachineController()
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        EmulatorView(host: machine.host, style: machine.displayStyle, onRenderer: { machine.renderer = $0 },
                     onHover: { machine.hoveredPixel = $0.map { (x: $0.0, y: $0.1) } })
            .overlay(alignment: .bottomLeading) {
                if let inspection = machine.inspection {
                    Text(inspection)
                        .font(.system(.callout, design: .monospaced))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                        .padding(8)
                        .allowsHitTesting(false)
                }
            }
            .frame(minWidth: 368, minHeight: 288)
            .background(.black)
            .focusedSceneValue(machine)
            .navigationTitle(title)
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first else { return false }
                return open(url)
            }
            .onOpenURL { url in
                _ = open(url)
            }
            .onChange(of: machine.debuggerRequested) {
                if machine.debuggerRequested {
                    machine.debuggerRequested = false
                    openWindow(id: "debugger", value: machine.id)
                }
            }
            .toolbar(id: "machine") {
                MachineToolbar(machine: machine)
            }
            .toolbarRole(.editor)
    }

    private func open(_ url: URL) -> Bool {
        switch url.pathExtension.lowercased() {
        case "ssd", "dsd":
            machine.insertDisc(url)
        case "uef", "csw":
            machine.insertTape(url)
        case SaveStateFile.fileExtension:
            machine.loadState(url)
        default:
            return false
        }
        return true
    }

    private var title: String {
        let name = machine.model.displayName + (machine.secondProcessor ? " + 6502 Second Processor" : "")
        var title = machine.discNames[0].map { "\(name) — \($0)" } ?? name
        if machine.paused {
            title += " (Paused)"
        }
        if machine.recordingURL != nil {
            title += " ● Recording"
        }
        return title
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when run as a plain executable (swift run) rather than an
        // app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        // Starts the background update checks.
        _ = Updates.shared
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
