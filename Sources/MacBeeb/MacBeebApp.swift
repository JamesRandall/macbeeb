import AppKit
import BeebCore
import BeebLibrary
import BeebROMs
import SwiftUI

@main
struct MacBeebApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @FocusedValue(MachineController.self) private var machine

    var body: some Scene {
        WindowGroup("BBC Micro", id: MachineWindow.windowID) {
            MachineWindow()
        }
        // With Settings > Games > When MacBeeb opens set to the game
        // library, it opens alone.
        .defaultLaunchBehavior(ClassicsLibrary.launchesWithBookshelf ? .suppressed : .automatic)
        .restorationBehavior(ClassicsLibrary.launchesWithBookshelf ? .disabled : .automatic)
        .defaultSize(width: 960, height: 768)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About MacBeeb") { AboutPanel.show() }
            }
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { Updates.shared.checkForUpdates() }
                    .disabled(!Updates.shared.isAvailable)
            }
            CommandGroup(replacing: .help) {
                WhatsNewMenuItem()
                GuideMenuItem()
            }
            CommandGroup(replacing: .newItem) {
                BookshelfMenuItem()
                NewMachineMenuItem()
                Divider()
                Button("New Disc…") { machine?.newDisc() }
                    .keyboardShortcut("n")
                    .disabled(!(machine?.model.hasDiscInterface ?? false))
                Button("Open Disc…") { machine?.openDisc() }
                    .keyboardShortcut("o")
                    .disabled(!(machine?.model.hasDiscInterface ?? false))
                Menu("Open Recent Disc") {
                    ForEach(RecentDiscs.shared.urls, id: \.self) { url in
                        Button(url.lastPathComponent) { machine?.openRecentDisc(url) }
                            .help(url.path)
                    }
                    if !RecentDiscs.shared.urls.isEmpty {
                        Divider()
                    }
                    Button("Clear Menu") { RecentDiscs.shared.clear() }
                        .disabled(RecentDiscs.shared.urls.isEmpty)
                }
                .disabled(!(machine?.model.hasDiscInterface ?? false))
                Button("Insert Disc in Drive 0…") { machine?.openDisc(drive: 0, boot: false) }
                    .keyboardShortcut("o", modifiers: [.command, .option])
                    .disabled(machine == nil)
                Button("Insert Disc in Drive 1…") { machine?.openDisc(drive: 1, boot: false) }
                    .disabled(machine == nil)
                ForEach(0..<2) { drive in
                    Menu("Insert Bundled Disc in Drive \(drive)") {
                        ForEach(BeebROMs.BundledDisc.allCases, id: \.self) { disc in
                            Button(disc.displayName) { machine?.insertBundledDisc(disc, drive: drive) }
                        }
                    }
                    .disabled(!(machine?.model.hasDiscInterface ?? false))
                }
                Divider()
                Button("Show Disc Contents") { machine?.discContentsRequested = true }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                    .disabled(!(machine?.model.hasDiscInterface ?? false))
                Divider()
                Button("Eject Drive 0") { machine?.ejectDisc(drive: 0) }
                    .disabled(machine?.discNames[0] == nil)
                Button("Eject Drive 1") { machine?.ejectDisc(drive: 1) }
                    .disabled(machine?.discNames[1] == nil)
                Divider()
                Button("Load Tape…") { machine?.openTape() }
                    .keyboardShortcut("t", modifiers: [.command, .option])
                    .disabled(!(machine?.model.hasCassette ?? false))
                Button("Rewind Tape") { machine?.rewindTape() }
                    .disabled(machine?.tapeName == nil)
                Button("Eject Tape") { machine?.ejectTape() }
                    .disabled(machine?.tapeName == nil)
                // Here rather than replacing .saveItem, which SwiftUI on macOS 27
                // leaves out of the menu altogether.
                Divider()
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
                // Not F5/F6 alone (the BBC's keys) or ⌘F5 (VoiceOver).
                Button("Quick Save") { machine?.quickSave() }
                    .keyboardShortcut(KeyEquivalent(Character(UnicodeScalar(NSF6FunctionKey)!)), modifiers: [.command, .shift])
                    .disabled(machine?.snapshotOwner == nil || machine?.snapshotBusy == true)
                    .help("Saves the game in drive 0 exactly as it is; the last five are kept. Put a disc in to use it.")
                Button("Quick Load") { machine?.quickLoad() }
                    .keyboardShortcut(KeyEquivalent(Character(UnicodeScalar(NSF5FunctionKey)!)), modifiers: [.command, .shift])
                    .disabled(machine?.snapshotHistory.isEmpty ?? true || machine?.snapshotBusy == true)
                    .help("Goes back to the newest quick save of the disc in drive 0")
                Menu("Snapshots") {
                    if let machine, let owner = machine.snapshotOwner {
                        if machine.snapshotHistory.isEmpty {
                            Text("No snapshots of “\(owner.name)” yet")
                        }
                        ForEach(Array(machine.snapshotHistory.enumerated()), id: \.element.id) { index, snapshot in
                            Button("\(index + 1). \(snapshot.created.formatted(date: .abbreviated, time: .standard))") {
                                machine.quickLoad(snapshot)
                            }
                        }
                    } else {
                        Text("Put a disc in to take snapshots")
                    }
                }
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
                Picker("Monitor", selection: Binding(
                    get: { machine?.monitor ?? Monitor.saved },
                    set: { machine?.monitor = $0 }
                )) {
                    ForEach(Monitor.allCases) { monitor in
                        Text(monitor.name).tag(monitor)
                    }
                }
                .disabled(machine == nil)
                Menu("Zoom") {
                    ForEach(MachineController.zoomLevels, id: \.self) { level in
                        Toggle("\(Int(level * 100))%", isOn: Binding(get: { machine?.zoom == level },
                                                                    set: { _ in machine?.setZoom(level) }))
                    }
                }
                .disabled(machine == nil)
                Button("Actual Size") { machine?.setZoom(1) }
                    .keyboardShortcut("0")
                    .disabled(machine == nil)
                Button("Zoom In") { machine?.zoom(in: true) }
                    .keyboardShortcut("=")
                    .disabled(machine == nil)
                Button("Zoom Out") { machine?.zoom(in: false) }
                    .keyboardShortcut("-")
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
            CommandMenu("MCP") {
                MCPMenu()
            }
            CommandMenu("Machine") {
                Button(machine?.isStill == true ? "Resume" : "Pause") { machine?.togglePause() }
                    .keyboardShortcut("p")
                Button(machine?.speedLimited == false ? "Normal Speed" : "Full Speed") { machine?.toggleSpeedLimit() }
                    .keyboardShortcut("f", modifiers: [.command, .option])
                Divider()
                Button("Break") { machine?.pressBreak() }
                    .keyboardShortcut("b", modifiers: [.command])
                Button("Shift-Break (Boot Disc)") { machine?.shiftBreak() }
                    .keyboardShortcut("b", modifiers: [.command, .shift])
                Button("Ctrl-Break (Hard Reset)") { machine?.ctrlBreak() }
                    .keyboardShortcut("b", modifiers: [.command, .control])
                Button("Power Cycle") { machine?.powerCycle() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Divider()
                Toggle("Disc Drive Sounds", isOn: Binding(get: { machine?.discDriveSounds ?? true },
                                                           set: { machine?.setDiscDriveSounds($0) }))
                    .disabled(machine == nil)
                DiscKeysButton(machine: machine)
                Button("Capture or Release Mouse") { machine?.toggleMouseCapture() }
                    .keyboardShortcut("m", modifiers: [.command, .control])
                    .disabled(machine == nil || machine?.model == .masterCompact)
                Divider()
                Button("Rewind 5 Seconds") { machine?.rewind(seconds: 5) }
                    .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                    .disabled(machine == nil)
                Button("Rewind Timeline…") { machine?.showingTimeline = true }
                    .keyboardShortcut(.leftArrow, modifiers: [.command, .option, .shift])
                    .disabled(machine == nil)
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
                Picker("Second Processor", selection: Binding(
                    get: { machine?.fittedCoprocessor },
                    set: { machine?.setCoprocessor($0) }
                )) {
                    Text("None").tag(BBCMicro.Coprocessor?.none)
                    ForEach(BBCMicro.Coprocessor.allCases, id: \.self) { coprocessor in
                        Text(coprocessor.displayName).tag(BBCMicro.Coprocessor?.some(coprocessor))
                            .disabled(!coprocessor.fits(machine?.model ?? .modelB))
                    }
                }
                .disabled(!(machine?.model.hasTube ?? false))
                Picker("Disc Interface", selection: Binding(
                    get: { machine?.discInterface ?? .intel8271 },
                    set: { machine?.setDiscInterface($0) }
                )) {
                    ForEach(BBCMicro.DiscInterface.allCases, id: \.self) { interface in
                        Text(interface.displayName).tag(interface)
                    }
                }
                .disabled(machine?.model != .modelB)
                .help("The Model B's disc interface; the B+ and Masters have a 1770 built in")
                Button("Hardware Expansions…") { machine?.hardwareRequested = true }
                    .keyboardShortcut("e", modifiers: [.command, .option])
                    .disabled(machine == nil)
                    .help("The Model B's memory board and sideways ROM and RAM banks")
            }
        }

        WindowGroup("Debugger", id: "debugger", for: UUID.self) { $id in
            if let id, let machine = MachineController.all[id] {
                DebuggerWindow(model: machine.debugger, machineName: machine.model.displayName)
            }
        }
        .defaultSize(width: 1100, height: 760)

        WindowGroup("Hardware Expansions", id: HardwareExpansionsWindow.windowID, for: UUID.self) { $id in
            if let id, let machine = MachineController.all[id] {
                HardwareExpansionsWindow(machine: machine)
            }
        }
        .defaultSize(width: 700, height: 780)

        WindowGroup("Hardware Expansion Guide", id: GuideWindow.windowID, for: String.self) { $page in
            GuideWindow(page: page)
        }
        .defaultSize(width: 980, height: 760)

        WindowGroup("Disc Contents", id: DiscContentsWindow.windowID, for: UUID.self) { $id in
            if let id, let machine = MachineController.all[id] {
                DiscContentsWindow(machine: machine)
            }
        }
        .defaultSize(width: 620, height: 520)

        Window("Connect an AI Agent", id: MCPSetupView.windowID) {
            MCPSetupView()
        }
        .windowResizability(.contentSize)

        Window("MCP Activity", id: AgentLogView.windowID) {
            AgentLogView()
        }
        .defaultSize(width: 900, height: 560)

        Window(BookshelfView.title, id: BookshelfView.windowID) {
            BookshelfView()
        }
        .defaultSize(width: 1040, height: 780)
        .defaultLaunchBehavior(ClassicsLibrary.launchesWithBookshelf ? .presented : .automatic)

        Window("What's New", id: WhatsNewView.windowID) {
            WhatsNewView()
        }
        .defaultSize(width: 520, height: 520)

        Settings {
            SettingsView()
        }
    }
}

/// Machine > Controls for This Disc: the keyboard and gamepad settings,
/// showing those for the disc image in drive 0.
struct DiscKeysButton: View {
    let machine: MachineController?
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("Controls for This Disc…") {
            KeyboardSettings.shared.editingDisc = machine?.bootDiscPath
            openSettings()
        }
        .disabled(machine?.bootDiscPath == nil)
    }
}

/// File > Game Library.
struct BookshelfMenuItem: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Game Library") { openWindow(id: BookshelfView.windowID) }
            .keyboardShortcut("k", modifiers: [.command, .shift])
    }
}

/// File > New BBC Micro Window: another machine (or the first, when
/// MacBeeb opened with only the bookshelf).
struct NewMachineMenuItem: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("New BBC Micro Window") { openWindow(id: MachineWindow.windowID) }
            .keyboardShortcut("n", modifiers: [.command, .option])
    }
}

struct MachineWindow: View {
    static let windowID = "machine"
    @State private var machine = MachineController()

    var body: some View {
        MachineScreen(machine: machine)
    }
}

/// A machine's picture, menus and toolbar: a standalone machine's window,
/// or a network station's.
struct MachineScreen: View {
    @Bindable var machine: MachineController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        EmulatorView(host: machine.host, style: machine.displayStyle, monitor: machine.monitor, onRenderer: { machine.renderer = $0 },
                     onHover: { machine.hoveredPixel = $0.map { (x: $0.0, y: $0.1) } },
                     onZoom: { machine.pictureZoomed($0) }, keyboardDisc: { machine.bootDiscPath },
                     onBecomeKey: {
                         Joysticks.shared.machine = machine
                         if !machine.isStation {
                             MachineController.frontmost = machine
                         }
                     },
                     onClose: {
                         // A station runs on without its window.
                         guard !machine.isStation else { return }
                         // Closed (the bookshelf may keep the app open):
                         // it stops, and the bookshelf stops using it.
                         machine.setPaused(true)
                         if MachineController.frontmost === machine {
                             MachineController.frontmost = nil
                         }
                     })
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
            .overlay(alignment: .top) {
                if let toast = machine.toast {
                    Text(toast)
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.regularMaterial, in: Capsule())
                        .padding(10)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                        .accessibilityAddTraits(.updatesFrequently)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: machine.toast)
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
            .onAppear {
                guard !machine.isStation else { return }
                if WhatsNew.shouldShowOnLaunch() {
                    openWindow(id: WhatsNewView.windowID)
                }
                if let launch = MachineController.pendingLaunch {
                    MachineController.pendingLaunch = nil
                    MachineController.frontmost = machine
                    launch(machine)
                }
            }
            .onChange(of: machine.bookshelfRequested) {
                if machine.bookshelfRequested {
                    machine.bookshelfRequested = false
                    openWindow(id: BookshelfView.windowID)
                }
            }
            .onChange(of: machine.toast) {
                if let toast = machine.toast {
                    NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                                         userInfo: [.announcement: toast, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
                }
            }
            .onChange(of: machine.hardwareRequested) {
                if machine.hardwareRequested {
                    machine.hardwareRequested = false
                    openWindow(id: HardwareExpansionsWindow.windowID, value: machine.id)
                }
            }
            .onChange(of: machine.discContentsRequested) {
                if machine.discContentsRequested {
                    machine.discContentsRequested = false
                    openWindow(id: DiscContentsWindow.windowID, value: machine.id)
                }
            }
            .sheet(isPresented: $machine.showingTimeline) {
                RewindSheet(machine: machine)
            }
            .toolbar(id: "machine") {
                MachineToolbar(machine: machine)
            }
            .bringsLibraryForwardOnArrival()
            .toolbarRole(.editor)
    }

    private func open(_ url: URL) -> Bool {
        switch url.pathExtension.lowercased() {
        case _ where Disc.ImageFormat(path: url.path) != nil:
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
        var name = machine.model.displayName + (machine.fittedCoprocessor.map { " + " + $0.displayName } ?? "")
        if machine.model == .modelB {
            if machine.expansions.board != .none {
                name += " + " + machine.expansions.board.displayName
            }
            if machine.expansions.sidewaysRAM != .none {
                name += " + " + machine.expansions.sidewaysRAM.displayName
            }
        }
        if let station = machine.station {
            name = station.stationTitle(machine) + " — " + name
        }
        if machine.videoNuLA {
            name += " + VideoNuLA"
        }
        var title = machine.discNames[0].map { "\(name) — \($0)" } ?? name
        if machine.paused {
            title += " (Paused)"
        } else if machine.heldForAgent {
            title += " (Held by AI Agent)"
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
        // Picks up downloads awaited before the app last quit.
        _ = ClassicsLibrary.shared
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
