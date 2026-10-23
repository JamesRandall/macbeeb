import AppKit
import BeebCore
import BeebROMs
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
    @State private var draft: MachineController.HardwareDraft
    @State private var snapshot: MachineController.HardwareSnapshot?
    @State private var error: String?
    @State private var clearing: Int?
    @Environment(\.openWindow) private var openWindow

    init(machine: MachineController) {
        self.machine = machine
        _draft = State(initialValue: machine.hardwareDraft)
    }

    private var pending: Bool { draft != machine.hardwareDraft }

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
                    openWindow(id: GuideWindow.windowID, value: draft.expansions.board.guidePage)
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
        .onChange(of: machine.hardwareDraft) { draft = machine.hardwareDraft }
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
            Button("Switch to a Model B") {
                machine.apply(draft)
                machine.switchToModelB(with: draft.expansions)
            }
                .buttonStyle(.borderedProminent)
        }
    }

    // MARK: The Model B

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                boardSection
                if draft.expansions.board.controllerROMBank != nil {
                    firmwareSection
                }
                memorySection
                if draft.expansions.board == .watford32K {
                    shadowSection
                }
                banksSection
            }
            .padding(20)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            restartBar
        }
        .animation(.snappy(duration: 0.25), value: draft)
    }

    private var expansions: BBCMicro.Expansions { draft.expansions }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("BBC Model B")
                    .font(.largeTitle.weight(.semibold))
                Text(memorySummary(expansions))
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }

    private func memorySummary(_ e: BBCMicro.Expansions) -> String {
        switch e.board {
        case .none: "32K of RAM, four ROM sockets"
        case .sidewaysRAM16, .sidewaysRAM32: "32K main RAM + \(e.board.extraRAM / 1024)K of sideways RAM"
        case .watford32K: "32K main RAM + 32K of shadow RAM"
        }
    }

    // MARK: Board

    private var boardSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Memory Board", detail: "One board at a time: they all plug into the same place.")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12)], spacing: 12) {
                ForEach(BBCMicro.MemoryBoard.allCases, id: \.self) { board in
                    BoardCard(board: board, selected: expansions.board == board, fitted: machine.expansions.board == board) {
                        draft.expansions.board = board
                    }
                }
            }
            if expansions.board.isSidewaysRAM {
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
                Picker("Socket", selection: $draft.expansions.sidewaysRAMSocket) {
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
            if expansions.board == .sidewaysRAM32 {
                GridRow {
                    Text("Second bank:")
                    Picker("Second bank", selection: $draft.expansions.secondBankBelow) {
                        Text("Bank \(expansions.sidewaysRAMSocket - 4)").tag(4)
                        Text("Bank \(expansions.sidewaysRAMSocket - 8)").tag(8)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .help("Where the module’s flying lead goes: IC76 pin 12 makes the second bank four below the first, pin 11 eight below")
                    Text(expansions.secondBankBelow == 4 ? "Lead on IC76 pin 12" : "Lead on IC76 pin 11")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: Firmware

    /// The ROM the board will use: the user's, if they've chosen one that's
    /// still there, else the bundled one.
    private var firmwareChoice: (firmware: Firmware?, path: String?, sha256: String) {
        let board = expansions.board
        if let path = draft.controllerROMPath, let data = FileManager.default.contents(atPath: path) {
            let bytes = [UInt8](data)
            if case .known(let firmware) = Firmware.identify(bytes, for: board) {
                return (firmware, path, Firmware.sha256(Array(bytes.prefix(firmware.size))))
            }
            return (nil, path, Firmware.sha256(bytes))
        }
        let standard = Firmware.standard(for: board)
        return (standard, nil, standard?.sha256 ?? "")
    }

    private var firmwareTitle: String {
        let choice = firmwareChoice
        return choice.firmware.map { "\($0.name) \($0.version)" } ?? "Your ROM"
    }

    private var firmwareSection: some View {
        let choice = firmwareChoice
        let bank = expansions.board.controllerROMBank ?? 0
        return VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Controller ROM", detail: "The board does nothing without its ROM: it switches the memory and adds the commands.")
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "cpu")
                    .font(.system(size: 26))
                    .foregroundStyle(.blue)
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 4) {
                    Text(firmwareTitle)
                        .font(.headline)
                    Text(choice.path == nil ? "Bundled with MacBeeb · in bank \(bank)"
                         : "\((choice.path! as NSString).lastPathComponent) · \(choice.firmware == nil ? "not a version MacBeeb knows" : "a known version") · in bank \(bank)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("SHA-256 \(choice.sha256)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    Button("Use Another Version…") { chooseFirmware() }
                        .help("Use your own dump of the board’s ROM; MacBeeb checks it against the versions it knows")
                    if choice.path != nil {
                        Button("Use the Bundled ROM") { draft.controllerROMPaths[expansions.board] = nil }
                            .buttonStyle(.link)
                    }
                }
            }
            .padding(14)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func chooseFirmware() {
        let panel = NSOpenPanel()
        panel.prompt = "Use"
        panel.message = "A dump of the \(expansions.board.displayName)’s ROM"
        guard panel.runModal() == .OK, let url = panel.url, let data = FileManager.default.contents(atPath: url.path) else { return }
        let board = expansions.board
        switch Firmware.identify([UInt8](data), for: board) {
        case .known:
            draft.controllerROMPaths[board] = url.path
        case .unknown(let sha256):
            let alert = NSAlert()
            alert.messageText = "This isn’t a version of the ROM MacBeeb knows"
            alert.informativeText = "Its SHA-256 is \(sha256). It may be another version, or a different ROM altogether. Use it anyway?"
            alert.addButton(withTitle: "Use It")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn {
                draft.controllerROMPaths[board] = url.path
            }
        case .wrongSize(let size, let expected):
            error = "That file is \(size) bytes; the \(board.displayName)’s ROM is \(expected / 1024)K (\(expected) bytes)."
        case .anotherBoard(let firmware):
            error = "That’s \(firmware.name) \(firmware.version), the ROM for the \(firmware.board.displayName)."
        }
    }

    // MARK: Shadow RAM

    private var shadowSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Shadow RAM", detail: "Two views of &3000–&7FFF: programs use the board’s RAM while the screen stays in main RAM.")
            ShadowMapView(mapping: pending ? nil : snapshot?.watfordMapping)
        }
    }

    // MARK: Memory

    private var memorySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Memory", detail: "The RAM chips, to scale.")
            PhysicalMemoryBar(expansions: expansions)
        }
    }

    // MARK: Banks

    private var plannedSlots: [PlannedSlot] {
        let ramBanks = Set(expansions.sidewaysRAMBanks)
        return (0..<16).map { bank in
            let running = snapshot?.slots[bank]
            if ramBanks.contains(bank) {
                // Its contents only carry over if it's RAM now too.
                let header = running?.kind == .ram && !pending ? running?.header : nil
                return PlannedSlot(bank: bank, kind: .ram, title: header?.name ?? "Sideways RAM",
                                   detail: expansions.board == .sidewaysRAM32 ? "32K module" : "16K module", hasImage: header != nil)
            }
            if expansions.board.controllerROMBank == bank {
                return PlannedSlot(bank: bank, kind: .rom, title: firmwareTitle, detail: "The board’s ROM", hasImage: true)
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
            if !expansions.sidewaysRAMBanks.isEmpty || !(snapshot?.slots.filter { $0.kind == .ram }.isEmpty ?? true) {
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
                        Text(draft.expansions == machine.expansions ? "Changing the board’s ROM restarts the BBC"
                             : "Fitting \(expansions.board == .none ? "no board" : "the " + expansions.board.displayName) restarts the BBC")
                            .font(.headline)
                        Text("As switching off and on: what’s in memory is lost. Discs stay in their drives.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Revert") { draft = machine.hardwareDraft }
                        .keyboardShortcut(.cancelAction)
                    Button("Restart BBC") { machine.apply(draft) }
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
        case .watford32K: "square.2.layers.3d"
        }
    }

    var blurb: String {
        switch self {
        case .none: "The Model B as it came: 32K, BASIC and DFS in two of its four ROM sockets."
        case .sidewaysRAM16: "A 16K bank of RAM in a ROM socket. Load ROM images from disc instead of fitting chips."
        case .sidewaysRAM32: "Two 16K banks on one module, wired like BeebMaster’s: room for two ROM images."
        case .watford32K: "Shadow RAM: programs keep 28K in every screen mode. Its own ROM switches the screen in and out."
        }
    }

    /// The guide page that explains it.
    var guidePage: String {
        switch self {
        case .none: "README"
        case .sidewaysRAM16, .sidewaysRAM32: "sideways-ram"
        case .watford32K: "watford-shadow-ram"
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
        var blocks = [Block(name: "Main RAM", size: 32, colour: .blue, help: "32K of main RAM at &0000–&7FFF, for programs and the screen")]
        blocks += expansions.sidewaysRAMBanks.map { bank in
            Block(name: "Bank \(bank)", size: 16, colour: .green,
                  help: "16K of sideways RAM, seen at &8000–&BFFF while bank \(bank) is selected")
        }
        if expansions.board == .watford32K {
            blocks.append(Block(name: "Watford board", size: 32, colour: .purple,
                                help: "32K on the Watford board, in place of main RAM at &3000–&7FFF (or all of &0000–&7FFF)"))
        }
        return blocks
    }

    private var caption: String {
        switch expansions.board {
        case .none: "Main RAM is &0000–&7FFF, for programs and the screen."
        case .sidewaysRAM16, .sidewaysRAM32: "Main RAM is &0000–&7FFF. Sideways RAM appears at &8000–&BFFF, one bank at a time."
        case .watford32K: "The board’s RAM stands in for main RAM at the same addresses; the screen is always in main RAM."
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
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(blocks.map(\.help).joined(separator: "; "))
    }
}

/// Shadow RAM's two views of memory: what programs see, and what the
/// video shows, to scale from &0000 to &8000; the latch as the BBC runs.
private struct ShadowMapView: View {
    /// The Watford latch now (nil: not running yet).
    let mapping: BBCMicro.WatfordMapping?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            row("Programs", detail: "The CPU, with the board on", segments: [
                ("Main RAM", "&0000", 3, .blue),
                ("Board RAM", "&3000", 5, .purple),
            ])
            row("Screen", detail: "The video, always", segments: [
                ("", "&0000", 3, .clear),
                ("Main RAM: the screen", "&3000", 5, .blue),
            ])
            HStack(spacing: 8) {
                Circle()
                    .fill(colour)
                    .frame(width: 8, height: 8)
                Text(status)
                    .contentTransition(.opacity)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .help("The board’s latch is set by writing to &FFFF (board RAM at &3000), &FFFE (BBC RAM) or &FFFC (board RAM everywhere). Its ROM switches it as the BBC draws on the screen.")
        }
        .padding(14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }

    private var colour: Color {
        switch mapping {
        case .upper, .all: .purple
        case .bbc: .blue
        case nil: .secondary
        }
    }

    private var status: String {
        switch mapping {
        case .upper: "Now: programs see the board’s RAM at &3000–&7FFF"
        case .all: "Now: the CPU sees the board’s RAM everywhere (&FFFC)"
        case .bbc: "Now: the CPU sees main RAM (the ROM switches to it to draw, and when the board is off)"
        case nil: "Restart the BBC to fit the board"
        }
    }

    private func row(_ title: String, detail: String, segments: [(String, String, Int, Color)]) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            .frame(width: 150, alignment: .leading)
            GeometryReader { geometry in
                HStack(spacing: 2) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                        let (name, start, size, colour) = segment
                        ZStack(alignment: .topLeading) {
                            RoundedRectangle(cornerRadius: 5)
                                .fill(colour == .clear ? AnyShapeStyle(.quaternary.opacity(0.4)) : AnyShapeStyle(colour.gradient))
                            Text(name)
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                            Text(start)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(colour == .clear ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.white.opacity(0.8)))
                                .padding(4)
                        }
                        .frame(width: (geometry.size.width - 2) * CGFloat(size) / 8)
                    }
                }
            }
            .frame(height: 34)
        }
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
