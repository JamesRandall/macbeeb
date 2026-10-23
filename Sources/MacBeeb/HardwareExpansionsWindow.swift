import AppKit
import BeebCore
import SwiftUI
import UniformTypeIdentifiers

/// Machine > Hardware Expansions: the Model B's memory board, its physical
/// memory, the sixteen sideways banks, and loading sideways RAM.
///
/// The board is chosen as a draft: fitting it restarts the BBC (as
/// switching off and on would), so nothing changes until Restart. Loading
/// and clearing sideways RAM works on the running BBC straight away.
struct HardwareExpansionsWindow: View {
    static let windowID = "hardware-expansions"
    let machine: MachineController
    @State private var draft: BBCMicro.Expansions
    @State private var snapshot: MachineController.HardwareSnapshot?
    @State private var error: String?
    @State private var clearing: Int?
    @Environment(\.openWindow) private var openWindow

    init(machine: MachineController) {
        self.machine = machine
        _draft = State(initialValue: machine.expansions)
    }

    private var pending: Bool { draft != machine.expansions }

    var body: some View {
        Group {
            if machine.model == .modelB {
                content
            } else {
                otherModel
            }
        }
        .frame(minWidth: 620, idealWidth: 700, minHeight: 520, idealHeight: 760)
        .navigationTitle("Hardware Expansions")
        .toolbar {
            ToolbarItem {
                Button("Guide", systemImage: "questionmark.circle") {
                    openWindow(id: GuideWindow.windowID, value: draft.board.guidePage)
                }
                .help("Open the Hardware Expansion Guide")
            }
        }
        .task(id: machine.hardwareChanges) {
            // The running machine, refreshed while the window's open (the
            // selected bank changes as the BBC runs).
            while !Task.isCancelled {
                if let new = await machine.hardwareSnapshot(), new != snapshot {
                    snapshot = new
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        .onChange(of: machine.expansions) { draft = machine.expansions }
        .alert("Sideways RAM", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
        }
        .confirmationDialog("Clear bank \(clearing ?? 0)?", isPresented: Binding(get: { clearing != nil },
                                                                              set: { if !$0 { clearing = nil } })) {
            Button("Clear Bank", role: .destructive) {
                if let bank = clearing { run { try await machine.clearSidewaysBank(bank) } }
            }
        } message: {
            Text("Everything in it is lost: a ROM image there disappears at the next Break.")
        }
    }

    // MARK: Not a Model B

    private var otherModel: some View {
        ContentUnavailableView {
            Label("Expansion boards are for the BBC Model B", systemImage: "memorychip")
        } description: {
            Text("The \(machine.model.displayName) has its own memory built in\(machine.model == .modelA ? "" : ": shadow RAM and sideways RAM"). Switch to a Model B to fit sideways RAM.")
        } actions: {
            Button("Switch to a Model B") { machine.switchToModelB(with: draft) }
                .buttonStyle(.borderedProminent)
        }
    }

    // MARK: The Model B

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                boardSection
                memorySection
                banksSection
            }
            .padding(20)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            restartBar
        }
        .animation(.snappy(duration: 0.25), value: draft)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("BBC Model B")
                    .font(.largeTitle.weight(.semibold))
                Text(memorySummary(draft))
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }

    private func memorySummary(_ e: BBCMicro.Expansions) -> String {
        e.board.extraRAM == 0 ? "32K of RAM, four ROM sockets" : "32K main RAM + \(e.board.extraRAM / 1024)K of sideways RAM"
    }

    // MARK: Board

    private var boardSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Memory Board", detail: "One board at a time: they all plug into the same place.")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12)], spacing: 12) {
                ForEach(BBCMicro.MemoryBoard.allCases, id: \.self) { board in
                    BoardCard(board: board, selected: draft.board == board, fitted: machine.expansions.board == board) {
                        draft.board = board
                    }
                }
            }
            if draft.board.isSidewaysRAM {
                wiring
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var wiring: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                Text("Socket:")
                    .gridColumnAlignment(.trailing)
                Picker("Socket", selection: $draft.sidewaysRAMSocket) {
                    Text("Bank 12").tag(12)
                    Text("Bank 13").tag(13)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("The free motherboard socket the module plugs into, which is its first bank (14 and 15 hold DFS and BASIC)")
                Text("The module’s first bank")
                    .foregroundStyle(.secondary)
            }
            if draft.board == .sidewaysRAM32 {
                GridRow {
                    Text("Second bank:")
                    Picker("Second bank", selection: $draft.secondBankBelow) {
                        Text("Bank \(draft.sidewaysRAMSocket - 4)").tag(4)
                        Text("Bank \(draft.sidewaysRAMSocket - 8)").tag(8)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .help("Where the module’s flying lead goes: IC76 pin 12 makes the second bank four below the first, pin 11 eight below")
                    Text(draft.secondBankBelow == 4 ? "Lead on IC76 pin 12" : "Lead on IC76 pin 11")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: Memory

    private var memorySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Memory", detail: "The chips, by size. Main RAM holds programs and the screen; sideways RAM pages in at &8000.")
            PhysicalMemoryBar(expansions: draft)
        }
    }

    // MARK: Banks

    private var plannedSlots: [PlannedSlot] {
        let ramBanks = Set(draft.sidewaysRAMBanks)
        return (0..<16).map { bank in
            let running = snapshot?.slots[bank]
            if ramBanks.contains(bank) {
                // Its contents only carry over if it's RAM now too.
                let header = running?.kind == .ram && !pending ? running?.header : nil
                return PlannedSlot(bank: bank, kind: .ram, title: header?.name ?? "Sideways RAM",
                                   detail: draft.board == .sidewaysRAM32 ? "32K module" : "16K module", hasImage: header != nil)
            }
            if let running, running.kind == .rom {
                return PlannedSlot(bank: bank, kind: .rom, title: running.header?.name ?? "ROM", detail: running.owner, hasImage: true)
            }
            if (12...15).contains(bank) {
                return PlannedSlot(bank: bank, kind: .emptySocket, title: "Empty socket", detail: "Motherboard socket", hasImage: false)
            }
            return PlannedSlot(bank: bank, kind: .notFitted, title: "Not fitted", detail: "", hasImage: false)
        }
    }

    private var banksSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Sideways Banks",
                         detail: "Sixteen bank numbers, chosen by ROMSEL (&FE30); the highest-numbered language starts at power on.")
            BankStrip(slots: plannedSlots, selected: pending ? nil : snapshot.map { Int($0.romsel & 0x0F) })
            if !draft.sidewaysRAMBanks.isEmpty || !(snapshot?.slots.filter { $0.kind == .ram }.isEmpty ?? true) {
                ramBanks
            }
        }
    }

    @ViewBuilder
    private var ramBanks: some View {
        let banks = (snapshot?.slots ?? []).filter { $0.kind == .ram }
        VStack(alignment: .leading, spacing: 0) {
            if pending {
                Label("Restart to fit the new board, then load its RAM.", systemImage: "arrow.clockwise")
                    .foregroundStyle(.secondary)
                    .padding(12)
            } else {
                ForEach(Array(banks.enumerated()), id: \.element.bank) { index, slot in
                    if index > 0 { Divider() }
                    RAMBankRow(slot: slot, powerOnImage: machine.powerOnImagePaths[slot.bank],
                               load: { url in run { try await machine.loadSidewaysImage(url, bank: slot.bank) } },
                               save: { url in run { try await machine.saveSidewaysBank(slot.bank, to: url) } },
                               clear: { clearing = slot.bank },
                               setPowerOnImage: { machine.setPowerOnImage($0, bank: slot.bank) })
                }
            }
        }
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: Restart

    private var restartBar: some View {
        Group {
            if pending {
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.arrow.circlepath")
                        .font(.title2)
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Fitting \(draft.board == .none ? "no board" : "the " + draft.board.displayName) restarts the BBC")
                            .font(.headline)
                        Text("As switching off and on: what’s in memory is lost. Discs stay in their drives.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Revert") { draft = machine.expansions }
                        .keyboardShortcut(.cancelAction)
                    Button("Restart BBC") { machine.setExpansions(draft) }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(.bar)
                .overlay(alignment: .top) { Divider() }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.25), value: pending)
    }

    private func run(_ action: @escaping () async throws -> Void) {
        Task {
            do {
                try await action()
            } catch {
                self.error = "\(error)"
            }
        }
    }
}

// MARK: - Pieces

private struct SectionTitle: View {
    let title: String
    let detail: String

    init(_ title: String, detail: String) {
        self.title = title
        self.detail = detail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.title2.weight(.semibold))
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

extension BBCMicro.MemoryBoard {
    var symbolName: String {
        switch self {
        case .none: "rectangle.dashed"
        case .sidewaysRAM16: "memorychip"
        case .sidewaysRAM32: "memorychip.fill"
        }
    }

    var blurb: String {
        switch self {
        case .none: "The Model B as it came: 32K, BASIC and DFS in two of its four ROM sockets."
        case .sidewaysRAM16: "A 16K bank of RAM in a ROM socket. Load ROM images from disc instead of fitting chips."
        case .sidewaysRAM32: "Two 16K banks on one module, wired like BeebMaster’s: room for two ROM images."
        }
    }

    /// The guide page that explains it.
    var guidePage: String {
        switch self {
        case .none: "README"
        case .sidewaysRAM16, .sidewaysRAM32: "sideways-ram"
        }
    }
}

private struct BoardCard: View {
    let board: BBCMicro.MemoryBoard
    let selected: Bool
    let fitted: Bool
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    Image(systemName: board.symbolName)
                        .font(.system(size: 24, weight: .regular))
                        .foregroundStyle(selected ? Color.accentColor : .secondary)
                        .frame(height: 28)
                    Spacer()
                    if board.extraRAM > 0 {
                        Text("+\(board.extraRAM / 1024)K")
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(.green.opacity(0.18), in: Capsule())
                            .foregroundStyle(.green)
                    }
                }
                Text(board.displayName)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(board.blurb)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if fitted {
                    Label("Fitted", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
            .background(selected ? AnyShapeStyle(Color.accentColor.opacity(0.10)) : AnyShapeStyle(.quaternary.opacity(0.5)),
                        in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(selected ? Color.accentColor : Color.clear, lineWidth: 2)
            }
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint(fitted ? "Fitted now" : "")
        .help(board.blurb)
    }
}

/// The physical memory: each chip's share, to scale.
private struct PhysicalMemoryBar: View {
    let expansions: BBCMicro.Expansions

    private struct Block: Identifiable {
        var id: String { name }
        var name: String
        var size: Int
        var colour: Color
        var help: String
    }

    private var blocks: [Block] {
        [Block(name: "Main RAM", size: 32, colour: .blue, help: "32K of main RAM at &0000–&7FFF, for programs and the screen")]
            + expansions.sidewaysRAMBanks.map { bank in
                Block(name: "Bank \(bank)", size: 16, colour: .green,
                      help: "16K of sideways RAM, seen at &8000–&BFFF while bank \(bank) is selected")
            }
    }

    var body: some View {
        let total = blocks.reduce(0) { $0 + $1.size }
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geometry in
                HStack(spacing: 3) {
                    ForEach(blocks) { block in
                        RoundedRectangle(cornerRadius: 6)
                            .fill(block.colour.gradient)
                            .overlay {
                                HStack(spacing: 6) {
                                    Text(block.name).fontWeight(.semibold)
                                    Text("\(block.size)K").opacity(0.8)
                                }
                                .font(.callout)
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                                .padding(.horizontal, 4)
                            }
                            .frame(width: max(0, (geometry.size.width - CGFloat(blocks.count - 1) * 3) * CGFloat(block.size) / CGFloat(total)))
                            .help(block.help)
                            .transition(.scale(scale: 0.6, anchor: .leading).combined(with: .opacity))
                    }
                }
            }
            .frame(height: 34)
            Text(expansions.sidewaysRAMBanks.isEmpty
                 ? "Main RAM is &0000–&7FFF, for programs and the screen."
                 : "Main RAM is &0000–&7FFF. Sideways RAM appears at &8000–&BFFF, one bank at a time.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(blocks.map(\.help).joined(separator: "; "))
    }
}

struct PlannedSlot: Equatable {
    enum Kind { case rom, ram, emptySocket, notFitted }
    var bank: Int
    var kind: Kind
    var title: String
    var detail: String
    var hasImage: Bool
}

/// Banks 0-15 in a row: ROM, RAM, an empty socket or nothing; a dot under
/// the one selected in ROMSEL just now.
private struct BankStrip: View {
    let slots: [PlannedSlot]
    let selected: Int?

    var body: some View {
        HStack(spacing: 4) {
            ForEach(slots, id: \.bank) { slot in
                VStack(spacing: 4) {
                    cell(slot)
                    Circle()
                        .fill(selected == slot.bank ? Color.accentColor : .clear)
                        .frame(width: 5, height: 5)
                }
                .help(help(slot))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(help(slot))
            }
        }
        .animation(.easeOut(duration: 0.12), value: selected)
    }

    private func cell(_ slot: PlannedSlot) -> some View {
        let colour: Color = switch slot.kind {
        case .rom: .blue
        case .ram: .green
        case .emptySocket, .notFitted: .secondary
        }
        return VStack(spacing: 2) {
            Text("\(slot.bank)")
                .font(.system(.headline, design: .rounded).monospacedDigit())
            Text(label(slot))
                .font(.system(size: 9, weight: .semibold))
                .textCase(.uppercase)
                .lineLimit(1)
        }
        .foregroundStyle(slot.kind == .notFitted ? AnyShapeStyle(.tertiary) : AnyShapeStyle(colour))
        .frame(maxWidth: .infinity, minHeight: 46)
        .background {
            RoundedRectangle(cornerRadius: 7)
                .fill(slot.kind == .rom || slot.kind == .ram ? colour.opacity(0.14) : .clear)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(slot.kind == .notFitted ? AnyShapeStyle(.quaternary) : AnyShapeStyle(colour.opacity(0.5)),
                              style: StrokeStyle(lineWidth: 1, dash: slot.kind == .emptySocket || slot.kind == .notFitted ? [3, 2] : []))
        }
    }

    private func label(_ slot: PlannedSlot) -> String {
        switch slot.kind {
        case .rom: "ROM"
        case .ram: "RAM"
        case .emptySocket: "Empty"
        case .notFitted: "—"
        }
    }

    private func help(_ slot: PlannedSlot) -> String {
        var text = "Bank \(slot.bank): \(slot.title)"
        if !slot.detail.isEmpty { text += " (\(slot.detail))" }
        if selected == slot.bank { text += ". Selected now" }
        return text
    }
}

/// A sideways RAM bank in the running BBC: what's in it, and loading,
/// saving and clearing it.
private struct RAMBankRow: View {
    let slot: BBCMicro.SidewaysSlot
    let powerOnImage: String?
    let load: (URL) -> Void
    let save: (URL) -> Void
    let clear: () -> Void
    let setPowerOnImage: (URL?) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text("\(slot.bank)")
                .font(.system(.title2, design: .rounded).weight(.semibold).monospacedDigit())
                .foregroundStyle(.green)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(slot.header?.name ?? "No ROM image")
                    .font(.headline)
                    .foregroundStyle(slot.header == nil ? .secondary : .primary)
                Group {
                    if let header = slot.header {
                        Text("\(header.isLanguage ? "Language" : "Service") ROM · \(header.copyright)")
                    } else {
                        Text("Empty, or data rather than a ROM")
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                if let powerOnImage {
                    Label("At power on: \((powerOnImage as NSString).lastPathComponent)", systemImage: "power")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Load ROM Image…") {
                if let url = chooseImage(prompt: "Load") { load(url) }
            }
            .help("Put a ROM image (up to 16K) into bank \(slot.bank) now; the BBC finds it at the next Break")
            Menu {
                Button("Save Contents…") {
                    let panel = NSSavePanel()
                    panel.nameFieldStringValue = "\(slot.header?.title ?? "Bank \(slot.bank)").rom"
                    if panel.runModal() == .OK, let url = panel.url { save(url) }
                }
                Button("Clear…", role: .destructive, action: clear)
                Divider()
                Button(powerOnImage == nil ? "Load an Image at Power On…" : "Change Power-On Image…") {
                    if let url = chooseImage(prompt: "Choose") { setPowerOnImage(url) }
                }
                if powerOnImage != nil {
                    Button("Start Empty at Power On") { setPowerOnImage(nil) }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More for bank \(slot.bank)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func chooseImage(prompt: String) -> URL? {
        let panel = NSOpenPanel()
        panel.prompt = prompt
        panel.message = "A sideways ROM image, up to 16K (.rom, .bin, or any file)"
        panel.allowedContentTypes = [.data]
        return panel.runModal() == .OK ? panel.url : nil
    }
}
