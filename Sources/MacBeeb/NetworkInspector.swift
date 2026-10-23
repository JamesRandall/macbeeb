import AppKit
import BeebCore
import BeebNetwork
import SwiftUI

/// The studio's side panel: the network as a whole, or the machine (or
/// clock) selected.
struct NetworkInspector: View {
    @Bindable var session: NetworkSession
    var openStation: (UUID) -> Void
    var openDebugger: (UUID) -> Void
    var openHardware: (UUID) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if session.selection.count == 1, let node = session.node(session.selection.first!) {
                    if node.isMachine {
                        MachineInspector(session: session, node: node, openStation: openStation,
                                         openDebugger: openDebugger, openHardware: openHardware)
                            .id(node.id)
                    } else {
                        ClockInspector(session: session, node: node)
                    }
                } else if session.selection.count > 1 {
                    selectionSummary
                } else {
                    networkSummary
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(.background)
    }

    private var networkSummary: some View {
        VStack(alignment: .leading, spacing: 18) {
            InspectorSection("Network") {
                LabeledContent("Name") {
                    TextField("Name", text: Binding(get: { session.project.name },
                                                    set: { name in session.update { $0.name = name } }))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                }
                LabeledContent("Machines", value: "\(session.project.stations.count), \(session.controllers.count) on")
                LabeledContent("Clock", value: session.project.hasClock ? "Fitted" : "None")
                if session.status.speed > 0 && !session.controllers.isEmpty {
                    LabeledContent("Speed", value: String(format: "%.0f%% of real time", session.status.speed * 100))
                }
            }
            InspectorSection("Problems") {
                if session.project.problems.isEmpty {
                    Label("None", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                }
                ForEach(session.project.problems, id: \.self) { problem in
                    Label(problem.message, systemImage: "exclamationmark.triangle.fill")
                        .symbolRenderingMode(.multicolor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            InspectorSection("Debugging") {
                Toggle("Pause the network at a breakpoint", isOn: Binding(
                    get: { session.runtime.network.pausesOnBreakpoint },
                    set: { session.runtime.network.setPauseOnBreakpoint($0) }))
                Text("When one machine stops in its debugger, the others stop too, so none of them times out waiting for it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            InspectorSection("Canvas") {
                Toggle("Snap to grid", isOn: Binding(get: { session.project.canvas.snapToGrid },
                                                     set: { on in session.update { $0.canvas.snapToGrid = on } }))
            }
            InspectorSection("File") {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([session.url]) }
                Text(session.url.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var selectionSummary: some View {
        let ids = session.selection
        let machines = ids.compactMap { session.node($0) }.filter(\.isMachine)
        return InspectorSection("\(ids.count) Selected") {
            Button("Power On") { machines.forEach { session.powerOn($0.id) } }
            Button("Power Off") { machines.forEach { session.powerOff($0.id) } }
            Button("Break") { machines.forEach { session.pressBreak($0.id) } }
        }
    }
}

/// A titled group of rows.
struct InspectorSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            content
        }
    }
}

struct MachineInspector: View {
    let session: NetworkSession
    let node: NetworkNode
    var openStation: (UUID) -> Void
    var openDebugger: (UUID) -> Void
    var openHardware: (UUID) -> Void
    @State private var name = ""
    @State private var number = ""
    @State private var numberProblem: String?

    var body: some View {
        let controller = session.controllers[node.id]
        VStack(alignment: .leading, spacing: 18) {
            InspectorSection(node.kind.displayName) {
                LabeledContent("Name") {
                    TextField("Name", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .onSubmit { session.rename(node.id, to: name) }
                }
                LabeledContent("Station") {
                    TextField("Station", text: $number)
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .frame(width: 64)
                        .onSubmit(applyNumber)
                        .help("1 to 254; each machine on a network needs its own")
                }
                if let numberProblem {
                    Label(numberProblem, systemImage: "exclamationmark.triangle.fill")
                        .symbolRenderingMode(.multicolor)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
                LabeledContent("Role") {
                    Picker("Role", selection: Binding(get: { node.kind }, set: { kind in session.update { $0[node.id]?.kind = kind } })) {
                        ForEach([NetworkNode.Kind.station, .fileServer, .printServer], id: \.self) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    .labelsHidden()
                }
            }
            .onAppear {
                name = node.name
                number = node.stationNumber.map(String.init) ?? ""
            }
            .onChange(of: node.name) { name = node.name }
            .onChange(of: node.stationNumber) { number = node.stationNumber.map(String.init) ?? "" }

            if node.kind == .fileServer {
                InspectorSection("File Server") {
                    if let line = controller?.consoleLine {
                        LabeledContent("Console", value: line)
                            .font(.callout.monospaced())
                    }
                    Button("Start File Server") { session.startFileServer(node.id) }
                        .help("Runs Acorn's Level 1 file server from its disc, giving every other machine the shared directory A")
                    Text("Acorn's Level 1 file server runs on this BBC, from its disc. Every other machine on the network shares directory A: on them, type *NET, then SAVE, LOAD, CHAIN and *CAT use the server. Open its window to see the server's console.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if node.kind == .printServer {
                InspectorSection("Printer Server") {
                    if let line = controller?.consoleLine {
                        LabeledContent("Console", value: line)
                            .font(.callout.monospaced())
                    }
                    let jobs = PrintCentre.shared.jobs.filter { $0.printer.hasSuffix("station \(node.stationNumber ?? 0)") }
                    LabeledContent("Jobs", value: "\(jobs.count)")
                    HStack {
                        Button("Start Printer Server") { session.startPrinterServer(node.id) }
                        OpenPrintCentreButton()
                    }
                    Text("MacBeeb's printer server runs on this BBC and prints to its printer port; what it prints appears in the Print Centre. On the other machines, *FX5,4 chooses the network printer, then VDU 2 starts printing and VDU 3 stops.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            InspectorSection("Machine") {
                LabeledContent("Model") {
                    Picker("Model", selection: Binding(get: { node.setup?.model ?? .modelB }, set: { setModel($0) })) {
                        ForEach(BBCMicro.Model.allCases, id: \.self) { model in
                            Text(model.displayName).tag(model)
                        }
                    }
                    .labelsHidden()
                }
                if let controller {
                    Button("Hardware Expansions…") { openHardware(node.id) }
                        .disabled(controller.model != .modelB && !controller.videoNuLA)
                        .help("Boards, sideways RAM and VideoNuLA")
                }
            }

            InspectorSection("Power") {
                Toggle("On", isOn: Binding(get: { controller != nil }, set: { on in on ? session.powerOn(node.id) : session.powerOff(node.id) }))
                    .toggleStyle(.switch)
                if controller != nil {
                    Toggle("Suspended", isOn: Binding(get: { session.isSuspended(node.id) }, set: { session.setSuspended(node.id, $0) }))
                        .help("It stops where it is while the rest of the network runs on, so other machines waiting for it time out")
                    HStack {
                        Button("Break") { session.pressBreak(node.id) }
                        Button("Cold Boot") { session.coldBoot(node.id) }
                            .help("Switch it off and on again")
                    }
                }
            }

            InspectorSection("Discs") {
                ForEach(0..<2) { drive in
                    HStack {
                        Text("Drive \(drive)")
                            .foregroundStyle(.secondary)
                        Text(node.discs[drive]?.displayName ?? "Empty")
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(node.discs[drive] == nil ? .secondary : .primary)
                        Spacer()
                        Menu {
                            Button("Insert Disc…") { session.chooseDisc(for: node.id, drive: drive) }
                            Button("Eject") { session.eject(node.id, drive: drive) }
                                .disabled(node.discs[drive] == nil)
                        } label: {
                            Image(systemName: "opticaldiscdrive")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                }
                Text("The network keeps its own copies of its discs, so the machines never change your files.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Open Window") {
                    if controller == nil { session.powerOn(node.id) }
                    openStation(node.id)
                }
                Button("Debugger") { openDebugger(node.id) }
                    .disabled(controller == nil)
            }
        }
    }

    private func applyNumber() {
        guard let value = Int(number.trimmingCharacters(in: .whitespaces)) else {
            numberProblem = "A station number is a number from 1 to 254"
            return
        }
        numberProblem = session.setStationNumber(node.id, to: value)
        if numberProblem != nil {
            number = node.stationNumber.map(String.init) ?? ""
        }
    }

    private func setModel(_ model: BBCMicro.Model) {
        if let controller = session.controllers[node.id] {
            // The running machine changes (a power cycle), and tells the
            // network.
            controller.setModel(model)
        } else {
            session.update { $0[node.id]?.setup?.model = model }
        }
    }
}

struct ClockInspector: View {
    let session: NetworkSession
    let node: NetworkNode
    static let rates = [50_000, 100_000, 125_000, 200_000, 250_000]

    var body: some View {
        InspectorSection("Network Clock") {
            LabeledContent("Rate") {
                Picker("Rate", selection: Binding(get: { node.clockRate ?? NetworkNode.defaultClockRate },
                                                  set: { rate in session.update { $0[node.id]?.clockRate = rate } })) {
                    ForEach(Self.rates, id: \.self) { Text(ClockCard.rateText($0)).tag($0) }
                }
                .labelsHidden()
            }
            Text("An Econet carries nothing without a clock: the clock box sets the speed every station sends and receives at.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
