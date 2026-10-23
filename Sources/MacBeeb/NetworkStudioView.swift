import AppKit
import BeebCore
import BeebNetwork
import SwiftUI

/// A network's window: its machines on the canvas or side by side in
/// tiles, and the inspector for what's selected.
struct NetworkStudioWindow: View {
    static let windowID = "network"
    let url: URL?
    @State private var session: NetworkSession?
    @State private var error: String?
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Group {
            if let session {
                NetworkStudioView(session: session)
            } else if let error {
                ContentUnavailableView {
                    Label("Can’t Open the Network", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                }
            } else {
                ProgressView()
            }
        }
        .frame(minWidth: 760, minHeight: 520)
        .onAppear(perform: load)
        .onDisappear {
            session?.close()
            session = nil
        }
    }

    private func load() {
        guard session == nil, let url else {
            if url == nil { error = "There’s no network to show." }
            return
        }
        do {
            session = try NetworkSession.session(for: url)
        } catch {
            self.error = "\(error)"
            RecentNetworks.shared.remove(url)
        }
    }
}

struct NetworkStudioView: View {
    @Bindable var session: NetworkSession
    @State private var mode = Mode.canvas
    @State private var showsInspector = true
    @State private var confirmingReset = false
    @State private var confirmingPowerOff = false
    @Environment(\.openWindow) private var openWindow

    enum Mode: String, CaseIterable {
        case canvas, tiles
    }

    var body: some View {
        HStack(spacing: 0) {
            Group {
                switch mode {
                case .canvas:
                    NetworkCanvas(session: session, openStation: openStation, openDebugger: openDebugger, openHardware: openHardware)
                case .tiles:
                    NetworkTiles(session: session, openStation: openStation)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if showsInspector {
                Divider()
                NetworkInspector(session: session, openStation: openStation, openDebugger: openDebugger, openHardware: openHardware)
                    .frame(width: 290)
                    .transition(.move(edge: .trailing))
            }
        }
        .navigationTitle(session.project.name)
        .navigationSubtitle(subtitle)
        .toolbar { toolbar }
        .focusedSceneValue(commandTarget)
        .focusedSceneValue(session)
        .confirmationDialog("Reset every machine?", isPresented: $confirmingReset) {
            Button("Break All") { session.resetAll() }
        } message: {
            Text("Each machine gets a Break, as if its Break key were pressed. Programs that are running stop.")
        }
        .confirmationDialog("Switch every machine off?", isPresented: $confirmingPowerOff) {
            Button("Power Off All", role: .destructive) { session.powerOffAll() }
        } message: {
            Text("What’s in their memory is lost. Their discs are kept.")
        }
        .alert("Can’t save the network", isPresented: Binding(get: { session.saveError != nil }, set: { _ in })) {
            Button("OK") {}
        } message: {
            Text(session.saveError ?? "")
        }
    }

    /// What the Machine and File menus act on: the station in the tiles
    /// with the keyboard, or the one machine selected on the canvas.
    private var commandTarget: MachineController? {
        switch mode {
        case .tiles:
            return session.focused.flatMap { session.controllers[$0] }
        case .canvas:
            guard session.selection.count == 1, let id = session.selection.first else { return nil }
            return session.controllers[id]
        }
    }

    private var subtitle: String {
        let on = session.controllers.count
        let machines = session.project.nodes.filter(\.isMachine).count
        var text = "\(on) of \(machines) on"
        if session.paused {
            text += " · Paused"
        } else if !session.status.stoppedStations.isEmpty && session.runtime.network.pausesOnBreakpoint {
            text += " · Paused for the debugger"
        } else if on > 0 && session.status.speed > 0 {
            text += String(format: " · %.0f%% speed", min(session.status.speed, 9.99) * 100)
        }
        return text
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Picker("View", selection: $mode) {
                Label("Canvas", systemImage: "point.3.connected.trianglepath.dotted").tag(Mode.canvas)
                Label("Tiles", systemImage: "square.grid.2x2").tag(Mode.tiles)
            }
            .pickerStyle(.segmented)
            .help("Arrange the network, or use its machines side by side")
        }
        ToolbarItemGroup {
            Button { session.powerOnAll() } label: { Label("Power On All", systemImage: "power") }
                .help("Switch on every machine")
            Button { confirmingPowerOff = true } label: { Label("Power Off All", systemImage: "power.circle") }
                .help("Switch off every machine")
                .disabled(session.controllers.isEmpty)
            Button { confirmingReset = true } label: { Label("Break All", systemImage: "arrow.counterclockwise") }
                .help("Press Break on every machine")
                .disabled(session.controllers.isEmpty)
            Button { session.setPaused(!session.paused) } label: {
                Label(session.paused ? "Resume Network" : "Pause Network", systemImage: session.paused ? "play.fill" : "pause.fill")
            }
            .help(session.paused ? "Carry on: every machine starts again together" : "Stop time on the whole network: nothing times out")
        }
        ToolbarItem {
            Button { withAnimation(.easeInOut(duration: 0.2)) { showsInspector.toggle() } } label: {
                Label("Inspector", systemImage: "sidebar.right")
            }
            .help(showsInspector ? "Hide the inspector" : "Show the inspector")
        }
    }

    private func openStation(_ id: UUID) {
        openWindow(id: StationWindow.windowID, value: StationWindow.Ref(network: session.url, node: id))
    }

    private func openDebugger(_ id: UUID) {
        guard let controller = session.controllers[id] else { return }
        openWindow(id: "debugger", value: controller.id)
    }

    private func openHardware(_ id: UUID) {
        guard let controller = session.controllers[id] else { return }
        openWindow(id: HardwareExpansionsWindow.windowID, value: controller.id)
    }
}

/// The machines side by side, each live and full size enough to use. The
/// one with the keyboard has a ring round it, and it's the one heard.
struct NetworkTiles: View {
    @Bindable var session: NetworkSession
    var openStation: (UUID) -> Void

    var body: some View {
        let shown = session.project.stations.filter { session.isOn($0.id) && (tiles.isEmpty || tiles.contains($0.id)) }
        VStack(spacing: 0) {
            tileBar
            Divider()
            if shown.isEmpty {
                ContentUnavailableView {
                    Label("No Machines On", systemImage: "power")
                } description: {
                    Text("Switch machines on in the canvas, or with Power On All.")
                } actions: {
                    Button("Power On All") { session.powerOnAll() }
                }
            } else {
                GeometryReader { geometry in
                    let columns = columnCount(shown.count, width: geometry.size.width)
                    let rows = Int((Double(shown.count) / Double(columns)).rounded(.up))
                    let spacing = 10.0
                    let width = (geometry.size.width - spacing * Double(columns + 1)) / Double(columns)
                    let height = min((geometry.size.height - spacing * Double(rows + 1)) / Double(rows), width / Renderer.aspect + 30)
                    ScrollView {
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(width), spacing: spacing), count: columns), spacing: spacing) {
                            ForEach(shown) { node in
                                if let controller = session.controllers[node.id] {
                                    StationTile(session: session, node: node, controller: controller,
                                                focused: session.focused == node.id, openStation: openStation)
                                        .frame(height: max(160, height))
                                }
                            }
                        }
                        .padding(spacing)
                    }
                }
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private var tiles: [UUID] { session.project.workspace.tiles }

    private func columnCount(_ count: Int, width: Double) -> Int {
        let chosen = session.project.workspace.columns
        if chosen > 0 { return min(chosen, max(count, 1)) }
        // As square as fits.
        let fit = max(1, Int(width / 300))
        return min(fit, max(1, Int(Double(count).squareRoot().rounded(.up))))
    }

    private var tileBar: some View {
        HStack(spacing: 12) {
            Menu {
                Button("Every Machine That’s On") { session.update { $0.workspace.tiles = [] } }
                Divider()
                ForEach(session.project.stations) { node in
                    Toggle(node.name, isOn: Binding(
                        get: { tiles.isEmpty || tiles.contains(node.id) },
                        set: { on in
                            session.update { project in
                                var chosen = project.workspace.tiles.isEmpty ? project.stations.map(\.id) : project.workspace.tiles
                                if on { chosen.append(node.id) } else { chosen.removeAll { $0 == node.id } }
                                project.workspace.tiles = chosen
                            }
                        }))
                }
            } label: {
                Label("Show", systemImage: "square.grid.2x2")
            }
            .fixedSize()
            Picker("Columns", selection: Binding(get: { session.project.workspace.columns },
                                                 set: { value in session.update { $0.workspace.columns = value } })) {
                Text("Fit").tag(0)
                ForEach([2, 3, 4], id: \.self) { Text("\($0)").tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            Spacer()
            Button { session.focusNext(false) } label: { Image(systemName: "chevron.left") }
                .help("The previous machine gets the keyboard")
                .keyboardShortcut("[", modifiers: [.command, .option])
            Button { session.focusNext() } label: { Image(systemName: "chevron.right") }
                .help("The next machine gets the keyboard")
                .keyboardShortcut("]", modifiers: [.command, .option])
            if let id = session.focused, let node = session.node(id) {
                Label("\(node.name) has the keyboard", systemImage: "keyboard")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

/// One machine in the tiles.
struct StationTile: View {
    let session: NetworkSession
    let node: NetworkNode
    let controller: MachineController
    let focused: Bool
    var openStation: (UUID) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                StationBadge(number: node.stationNumber)
                Text(node.name)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Text(node.setup?.summary ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if focused {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("Heard")
                }
                Button { openStation(node.id) } label: { Image(systemName: "macwindow") }
                    .buttonStyle(.borderless)
                    .help("Open in its own window")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            EmulatorView(host: controller.host, style: controller.displayStyle, monitor: controller.monitor,
                         keyboardDisc: { controller.bootDiscPath }, takesFocus: focused,
                         onFocus: { session.focus(node.id) })
                .background(.black)
        }
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(focused ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: focused ? 3 : 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(node.name)\(focused ? ", has the keyboard" : "")")
    }
}
