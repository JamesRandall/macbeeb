import AppKit
import BeebCore
import BeebHost
import BeebNetwork
import SwiftUI

/// The network laid out freely: machines as cards with their screens live,
/// the clock, and the bus they share drawn behind them. Pan by dragging the
/// background or scrolling, zoom by pinching or ⌘-scrolling.
struct NetworkCanvas: View {
    @Bindable var session: NetworkSession
    /// Asks the studio to open a station's window.
    var openStation: (UUID) -> Void
    var openDebugger: (UUID) -> Void
    var openHardware: (UUID) -> Void

    @State private var zoom = 1.0
    @State private var centre = CGPoint.zero
    @State private var panStart: CGPoint?
    @State private var zoomStart: Double?
    /// Nodes being dragged, and how far (in view points).
    @State private var dragging: (ids: Set<UUID>, translation: CGSize)?
    @State private var removing: Set<UUID>?
    @State private var size = CGSize(width: 800, height: 600)
    @AccessibilityFocusState private var focusedNode: UUID?

    static let grid = 20.0
    static let zoomRange = 0.25...2.5

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                background
                BusDrawing(nodes: session.project.nodes, position: { viewPoint(position(of: $0)) }, zoom: zoom,
                           lit: Set(session.controllers.keys), transmitting: session.transmitting)
                    .allowsHitTesting(false)
                ForEach(session.project.nodes) { node in
                    nodeView(node)
                        .scaleEffect(zoom)
                        .position(viewPoint(position(of: node)))
                }
                palette
                    .padding(12)
                if !session.project.problems.isEmpty {
                    problems
                        .frame(maxWidth: .infinity, alignment: .top)
                        .padding(.top, 12)
                }
                zoomControls
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(12)
            }
            .coordinateSpace(.named("canvas"))
            .clipped()
            .onAppear {
                size = geometry.size
                zoom = session.project.canvas.zoom
                centre = CGPoint(x: session.project.canvas.centre.x, y: session.project.canvas.centre.y)
                // A new network (zoom 0) starts with everything in view.
                if zoom <= 0 {
                    zoom = 1
                    DispatchQueue.main.async { fit(animated: false) }
                }
            }
            .onChange(of: geometry.size) { size = geometry.size }
            .background(ScrollCatcher { delta, zooming, location in
                scrolled(delta, zooming: zooming, at: location)
            })
            .gesture(MagnifyGesture()
                .onChanged { value in
                    if zoomStart == nil { zoomStart = zoom }
                    zoom = (zoomStart! * value.magnification).clamped(to: Self.zoomRange)
                }
                .onEnded { _ in
                    zoomStart = nil
                    rememberView()
                })
            .dropDestination(for: String.self) { items, location in
                guard let item = items.first.flatMap(PaletteItem.init(rawValue:)) else { return false }
                add(item, at: snapped(canvasPoint(location)))
                return true
            }
        }
        .confirmationDialog(removalTitle, isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                if let removing { session.remove(removing) }
                removing = nil
            }
        } message: {
            Text("Machines that are on are switched off, and their discs’ copies in the network are deleted.")
        }
        .onDeleteCommand {
            if !session.selection.isEmpty { removing = session.selection }
        }
        .focusable()
        .focusEffectDisabled()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Network canvas")
    }

    // MARK: Background

    private var background: some View {
        Canvas { context, size in
            // A faint dot grid that moves and scales with the canvas.
            let step = Self.grid * 2 * zoom
            guard step >= 6 else { return }
            let origin = viewPoint(.zero)
            let startX = origin.x.truncatingRemainder(dividingBy: step) - step
            let startY = origin.y.truncatingRemainder(dividingBy: step) - step
            let dot = max(1, 1.4 * zoom)
            var path = Path()
            var y = startY
            while y < size.height + step {
                var x = startX
                while x < size.width + step {
                    path.addEllipse(in: CGRect(x: x - dot / 2, y: y - dot / 2, width: dot, height: dot))
                    x += step
                }
                y += step
            }
            context.fill(path, with: .color(.secondary.opacity(0.25)))
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 2)
            .onChanged { value in
                if panStart == nil { panStart = centre }
                centre = CGPoint(x: panStart!.x - value.translation.width / zoom, y: panStart!.y - value.translation.height / zoom)
            }
            .onEnded { _ in
                panStart = nil
                rememberView()
            })
        .onTapGesture {
            session.selection = []
        }
        .accessibilityHidden(true)
    }

    // MARK: Nodes

    @ViewBuilder
    private func nodeView(_ node: NetworkNode) -> some View {
        let selected = session.selection.contains(node.id)
        let problem = session.project.problems.first { $0.nodes.contains(node.id) }
        Group {
            if node.kind == .clock {
                ClockCard(node: node, selected: selected)
            } else {
                MachineCard(session: session, node: node, selected: selected, problem: problem?.message,
                            showsScreen: zoom >= 0.35)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onTapGesture(count: 2) {
            if node.isMachine {
                if !session.isOn(node.id) { session.powerOn(node.id) }
                openStation(node.id)
            }
        }
        .simultaneousGesture(TapGesture().modifiers(.command).onEnded { toggleSelection(node.id) })
        .simultaneousGesture(TapGesture().modifiers(.shift).onEnded { toggleSelection(node.id) })
        .onTapGesture {
            if !NSEvent.modifierFlags.contains(.command) && !NSEvent.modifierFlags.contains(.shift) {
                session.selection = [node.id]
                if node.isMachine, session.isOn(node.id) { session.focus(node.id) }
            }
        }
        .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .named("canvas"))
            .onChanged { value in
                if dragging == nil {
                    if !session.selection.contains(node.id) { session.selection = [node.id] }
                    dragging = (session.selection, .zero)
                }
                dragging?.translation = value.translation
            }
            .onEnded { _ in
                guard let dragging else { return }
                for id in dragging.ids {
                    if let moved = session.node(id).map({ position(of: $0) }) {
                        session.move(id, to: snapped(CanvasPoint(x: moved.x, y: moved.y)))
                    }
                }
                self.dragging = nil
            })
        .contextMenu { contextMenu(node) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
        .accessibilityAction(named: "Open Window") { openStation(node.id) }
        .accessibilityFocused($focusedNode, equals: node.id)
    }

    private func toggleSelection(_ id: UUID) {
        if session.selection.contains(id) {
            session.selection.remove(id)
        } else {
            session.selection.insert(id)
        }
    }

    @ViewBuilder
    private func contextMenu(_ node: NetworkNode) -> some View {
        if node.isMachine {
            let on = session.isOn(node.id)
            Button(on ? "Power Off" : "Power On") { session.togglePower(node.id) }
            Button("Cold Boot") { session.coldBoot(node.id) }
            Button("Break") { session.pressBreak(node.id) }
                .disabled(!on)
            Button(session.isSuspended(node.id) ? "Resume Station" : "Suspend Station") {
                session.setSuspended(node.id, !session.isSuspended(node.id))
            }
            .disabled(!on)
            Divider()
            Button("Open Window") {
                if !on { session.powerOn(node.id) }
                openStation(node.id)
            }
            Button("Show Debugger") { openDebugger(node.id) }
                .disabled(!on)
            Button("Hardware Expansions…") { openHardware(node.id) }
                .disabled(!on)
            Button("Insert Disc in Drive 0…") { session.chooseDisc(for: node.id, drive: 0) }
            Button("Eject Drive 0") { session.eject(node.id, drive: 0) }
                .disabled(node.discs[0] == nil)
            if node.kind == .fileServer {
                Divider()
                Button("Start File Server") { session.startFileServer(node.id) }
            }
            if node.kind == .printServer {
                Divider()
                Button("Start Printer Server") { session.startPrinterServer(node.id) }
                OpenPrintCentreButton()
            }
            Divider()
            Button("Duplicate") { session.duplicate(node.id) }
        }
        Button("Remove…", role: .destructive) {
            removing = session.selection.contains(node.id) ? session.selection : [node.id]
        }
    }

    private var removalTitle: String {
        guard let removing else { return "" }
        if removing.count == 1, let node = session.node(removing.first!) {
            return "Remove “\(node.name)” from the network?"
        }
        return "Remove \(removing.count) items from the network?"
    }

    // MARK: Palette

    enum PaletteItem: String, CaseIterable, Identifiable {
        case modelB, master128, fileServer, printServer, clock

        var id: String { rawValue }

        var title: String {
            switch self {
            case .modelB: "BBC Model B"
            case .master128: "Master 128"
            case .fileServer: "File Server"
            case .printServer: "Printer Server"
            case .clock: "Clock"
            }
        }

        var symbol: String {
            switch self {
            case .modelB: "desktopcomputer"
            case .master128: "desktopcomputer.and.macbook"
            case .fileServer: "externaldrive.connected.to.line.below"
            case .printServer: "printer"
            case .clock: "metronome"
            }
        }
    }

    private var palette: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Add")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.top, 4)
            ForEach(PaletteItem.allCases) { item in
                Button {
                    add(item, at: snapped(canvasPoint(CGPoint(x: size.width / 2, y: size.height / 2))))
                } label: {
                    Label(item.title, systemImage: item.symbol)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(item == .clock && session.project.hasClock)
                .draggable(item.rawValue) {
                    Label(item.title, systemImage: item.symbol)
                        .padding(8)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
                .help(item == .clock && session.project.hasClock ? "The network has its clock" : "Drag onto the network, or click to add")
            }
        }
        .frame(width: 168)
        .padding(6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
    }

    private func add(_ item: PaletteItem, at point: CanvasPoint) {
        let id: UUID? = switch item {
        case .modelB: session.add(.station, model: .modelB, at: point)
        case .master128: session.add(.station, model: .master128, at: point)
        case .fileServer: session.add(.fileServer, at: point)
        case .printServer: session.add(.printServer, at: point)
        case .clock: session.add(.clock, at: point)
        }
        if let id { session.selection = [id] }
    }

    // MARK: Problems and zoom

    private var problems: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(session.project.problems, id: \.self) { problem in
                Label(problem.message, systemImage: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
                    .font(.callout)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.1), radius: 4, y: 1)
    }

    private var zoomControls: some View {
        HStack(spacing: 0) {
            Button { setZoom(zoom / 1.25) } label: { Image(systemName: "minus.magnifyingglass") }
                .help("Zoom out")
            Text("\(Int((zoom * 100).rounded()))%")
                .font(.caption.monospacedDigit())
                .frame(width: 44)
            Button { setZoom(zoom * 1.25) } label: { Image(systemName: "plus.magnifyingglass") }
                .help("Zoom in")
            Divider().frame(height: 16).padding(.horizontal, 4)
            Button { fit() } label: { Image(systemName: "arrow.up.left.and.down.right.magnifyingglass") }
                .help("Show the whole network")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.1), radius: 4, y: 1)
    }

    private func setZoom(_ value: Double) {
        withAnimation(.easeOut(duration: 0.15)) {
            zoom = value.clamped(to: Self.zoomRange)
        }
        rememberView()
    }

    /// Zooms and centres to show every node.
    func fit(animated: Bool = true) {
        let nodes = session.project.nodes
        guard !nodes.isEmpty else { return }
        let xs = nodes.map(\.position.x), ys = nodes.map(\.position.y)
        let width = (xs.max()! - xs.min()!) + MachineCard.width + 80
        let height = (ys.max()! - ys.min()!) + MachineCard.height + 80
        // Clear of the palette, on the left.
        let palette = 200.0
        let fitted = min((size.width - palette) / width, size.height / height, 1.5).clamped(to: Self.zoomRange)
        withAnimation(animated ? .easeInOut(duration: 0.25) : nil) {
            zoom = fitted
            centre = CGPoint(x: (xs.max()! + xs.min()!) / 2 - palette / 2 / fitted, y: (ys.max()! + ys.min()!) / 2)
        }
        rememberView()
    }

    private func scrolled(_ delta: CGSize, zooming: Bool, at location: CGPoint) {
        if zooming {
            // Keep the point under the pointer where it is.
            let before = canvasPoint(location)
            zoom = (zoom * (1 - delta.height / 200)).clamped(to: Self.zoomRange)
            let after = canvasPoint(location)
            centre.x += before.x - after.x
            centre.y += before.y - after.y
        } else {
            centre.x -= delta.width / zoom
            centre.y -= delta.height / zoom
        }
        rememberView()
    }

    private func rememberView() {
        let zoom = zoom, centre = centre
        session.update {
            $0.canvas.zoom = zoom
            $0.canvas.centre = CanvasPoint(x: centre.x, y: centre.y)
        }
    }

    // MARK: Geometry

    /// Where a node is drawn, in canvas points, allowing for a drag.
    private func position(of node: NetworkNode) -> CGPoint {
        var point = CGPoint(x: node.position.x, y: node.position.y)
        if let dragging, dragging.ids.contains(node.id) {
            point.x += dragging.translation.width / zoom
            point.y += dragging.translation.height / zoom
        }
        return point
    }

    private func viewPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - centre.x) * zoom + size.width / 2, y: (point.y - centre.y) * zoom + size.height / 2)
    }

    private func canvasPoint(_ point: CGPoint) -> CanvasPoint {
        CanvasPoint(x: (point.x - size.width / 2) / zoom + centre.x, y: (point.y - size.height / 2) / zoom + centre.y)
    }

    private func snapped(_ point: CanvasPoint) -> CanvasPoint {
        guard session.project.canvas.snapToGrid else { return point }
        return CanvasPoint(x: (point.x / Self.grid).rounded() * Self.grid, y: (point.y / Self.grid).rounded() * Self.grid)
    }
}

/// The shared bus: a backbone between the rows of machines, and a drop from
/// each to it. It's a picture of a shared medium, not of the cabling.
struct BusDrawing: View {
    let nodes: [NetworkNode]
    let position: (NetworkNode) -> CGPoint
    let zoom: Double
    /// The nodes that are on.
    let lit: Set<UUID>
    /// The nodes sending just now: their drops glow.
    let transmitting: Set<UUID>

    var body: some View {
        Canvas { context, _ in
            guard nodes.count > 1 else { return }
            let points = nodes.map { (node: $0, point: position($0)) }
            let ys = points.map(\.point.y)
            let busY = (ys.min()! + ys.max()!) / 2
            let xs = points.map(\.point.x)
            let lineWidth = max(1.5, 3 * zoom)
            var backbone = Path()
            backbone.move(to: CGPoint(x: xs.min()!, y: busY))
            backbone.addLine(to: CGPoint(x: xs.max()!, y: busY))
            context.stroke(backbone, with: .color(.secondary.opacity(0.45)), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            for (node, point) in points {
                var drop = Path()
                drop.move(to: point)
                drop.addLine(to: CGPoint(x: point.x, y: busY))
                let on = lit.contains(node.id) || node.kind == .clock
                let sending = transmitting.contains(node.id)
                if sending {
                    context.stroke(drop, with: .color(.green.opacity(0.35)), style: StrokeStyle(lineWidth: lineWidth * 3, lineCap: .round))
                }
                context.stroke(drop, with: .color(sending ? .green : on ? Color.accentColor.opacity(0.55) : .secondary.opacity(0.3)),
                               style: StrokeStyle(lineWidth: lineWidth * 0.8, lineCap: .round, dash: on ? [] : [4 * zoom, 4 * zoom]))
                let tap = CGRect(x: point.x - lineWidth * 1.5, y: busY - lineWidth * 1.5, width: lineWidth * 3, height: lineWidth * 3)
                context.fill(Path(ellipseIn: tap), with: .color(on ? Color.accentColor : .secondary.opacity(0.5)))
            }
        }
    }
}

/// A machine on the canvas: its screen, live, and who it is.
struct MachineCard: View {
    let session: NetworkSession
    let node: NetworkNode
    let selected: Bool
    let problem: String?
    let showsScreen: Bool

    static let width = 236.0
    static let height = 230.0

    var body: some View {
        let controller = session.controllers[node.id]
        VStack(alignment: .leading, spacing: 8) {
            screen(controller)
            HStack(spacing: 8) {
                StationBadge(number: node.stationNumber, problem: problem != nil)
                VStack(alignment: .leading, spacing: 1) {
                    Text(node.name)
                        .font(.headline)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if session.transmitting.contains(node.id) {
                    Image(systemName: "dot.radiowaves.up.forward")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.green)
                        .help("Sending on the network")
                        .accessibilityLabel("Sending")
                }
                StateIndicator(state: state(controller))
            }
            if node.kind != .station, let controller {
                Label(controller.consoleLine ?? "Starting…", systemImage: "text.alignleft")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help("The server's console: its last line")
            }
        }
        .padding(10)
        .frame(width: Self.width)
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(selected ? Color.accentColor : problem != nil ? Color.orange.opacity(0.8) : Color.secondary.opacity(0.2),
                              lineWidth: selected ? 2.5 : 1)
        }
        .shadow(color: .black.opacity(selected ? 0.18 : 0.10), radius: selected ? 10 : 5, y: 2)
        .help(problem ?? "\(node.name): double-click to open its window")
        .accessibilityLabel("\(node.name), \(subtitle), \(state(controller).label)")
    }

    private var subtitle: String {
        let model = node.setup?.summary ?? ""
        return node.kind == .station ? model : "\(node.kind.displayName) · \(model)"
    }

    @ViewBuilder
    private func screen(_ controller: MachineController?) -> some View {
        ZStack(alignment: .bottomTrailing) {
            Color.black
            if let controller, showsScreen {
                StationThumbnail(cache: session.thumbnails, id: node.id, host: controller.host)
            } else if controller == nil {
                VStack(spacing: 4) {
                    Image(systemName: "power")
                        .font(.title2)
                    Text("Off")
                        .font(.caption)
                }
                .foregroundStyle(.white.opacity(0.45))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if node.kind != .station {
                Label(node.kind == .fileServer ? "FILE SERVER" : "PRINTER SERVER",
                      systemImage: node.kind == .fileServer ? "externaldrive.connected.to.line.below" : "printer")
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.ultraThinMaterial, in: Capsule())
                    .environment(\.colorScheme, .dark)
                    .padding(6)
            }
        }
        .aspectRatio(Renderer.aspect, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(.black.opacity(0.4), lineWidth: 1)
        }
    }

    private func state(_ controller: MachineController?) -> StateIndicator.State {
        guard let controller else { return .off }
        if controller.debugStop != nil { return .debugger }
        if session.paused { return .networkPaused }
        if controller.paused { return .suspended }
        return .on
    }
}

/// A machine's screen, from the thumbnail cache.
struct StationThumbnail: View {
    let cache: ThumbnailCache
    let id: UUID
    let host: EmulatorHost

    var body: some View {
        Group {
            if let image = cache.images[id] {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.medium)
            } else {
                Color.black
            }
        }
        .onAppear { cache.show(id, host: host) }
        .onDisappear { cache.hide(id) }
    }
}

struct StationBadge: View {
    let number: Int?
    var problem = false

    var body: some View {
        Text(number.map(String.init) ?? "–")
            .font(.system(size: 12, weight: .bold, design: .rounded).monospacedDigit())
            .foregroundStyle(.white)
            .frame(minWidth: 30, minHeight: 22)
            .padding(.horizontal, 3)
            .background(problem ? Color.orange : Color.accentColor, in: RoundedRectangle(cornerRadius: 6))
            .accessibilityLabel(number.map { "Station \($0)" } ?? "No station number")
    }
}

/// On, off, suspended: a shape as well as a colour, so it doesn't rely on
/// colour alone.
struct StateIndicator: View {
    enum State {
        case on, off, suspended, networkPaused, debugger

        var label: String {
            switch self {
            case .on: "On"
            case .off: "Off"
            case .suspended: "Suspended"
            case .networkPaused: "Paused"
            case .debugger: "Stopped in the debugger"
            }
        }

        var symbol: String {
            switch self {
            case .on: "circle.fill"
            case .off: "circle"
            case .suspended: "pause.circle.fill"
            case .networkPaused: "pause.circle"
            case .debugger: "ladybug.circle.fill"
            }
        }

        var colour: Color {
            switch self {
            case .on: .green
            case .off: .secondary
            case .suspended: .orange
            case .networkPaused: .blue
            case .debugger: .red
            }
        }
    }

    let state: State

    var body: some View {
        Image(systemName: state.symbol)
            .font(.system(size: 13))
            .foregroundStyle(state.colour)
            .help(state.label)
            .accessibilityLabel(state.label)
    }
}

/// The network's clock on the canvas.
struct ClockCard: View {
    let node: NetworkNode
    let selected: Bool

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "metronome")
                .font(.system(size: 26))
                .foregroundStyle(Color.accentColor)
                .frame(width: 56, height: 56)
                .background(Color.accentColor.opacity(0.12), in: Circle())
            Text("Clock")
                .font(.headline)
            Text(Self.rateText(node.clockRate ?? NetworkNode.defaultClockRate))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(width: 130)
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: selected ? 2.5 : 1)
        }
        .shadow(color: .black.opacity(selected ? 0.18 : 0.10), radius: selected ? 10 : 5, y: 2)
        .help("The network's clock: every Econet needs one")
        .accessibilityLabel("Network clock, \(Self.rateText(node.clockRate ?? NetworkNode.defaultClockRate))")
    }

    static func rateText(_ rate: Int) -> String {
        "\(rate / 1000) kbit/s"
    }
}

/// Scroll-wheel and trackpad scrolling over the canvas, which SwiftUI
/// doesn't offer: pans, or with ⌘ zooms.
struct ScrollCatcher: NSViewRepresentable {
    var onScroll: (CGSize, Bool, CGPoint) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.onScroll = onScroll
    }

    final class CatcherView: NSView {
        var onScroll: (CGSize, Bool, CGPoint) -> Void = { _, _, _ in }
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, event.window === self.window else { return event }
                let point = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(point) else { return event }
                let scale = event.hasPreciseScrollingDeltas ? 1.0 : 10.0
                self.onScroll(CGSize(width: event.scrollingDeltaX * scale, height: event.scrollingDeltaY * scale),
                              event.modifierFlags.contains(.command),
                              CGPoint(x: point.x, y: self.bounds.height - point.y))
                return nil
            }
        }

        override func removeFromSuperview() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            super.removeFromSuperview()
        }
    }
}

extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
