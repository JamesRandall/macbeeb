import AppKit
import BeebAgentKit
import BeebCapture
import BeebCore
import BeebHost
import BeebROMs
import Observation
import UniformTypeIdentifiers

/// One emulated machine and its window's actions.
@MainActor
@Observable
final class MachineController {
    let host: EmulatorHost
    private let audio: AudioOutput
    private var joysticks: Joysticks?
    private(set) var paused = false
    private(set) var speedLimited = true
    /// The emulated model. New windows start with the last one chosen.
    private(set) var model: BBCMicro.Model
    /// How the window draws the picture. Shared by all windows.
    var displayStyle = DisplayStyle.saved {
        didSet { UserDefaults.standard.set(displayStyle.rawValue, forKey: DisplayStyle.defaultsKey) }
    }
    /// The window's renderer, for capturing the display as shown.
    @ObservationIgnored weak var renderer: Renderer?

    private static let modelDefaultsKey = "MacBeebModel"
    /// Whether a 6502 Second Processor is fitted. Remembered like the model.
    private(set) var secondProcessor: Bool
    private static let secondProcessorDefaultsKey = "MacBeebSecondProcessor"
    /// The machine's indicator lights, refreshed a few times a second.
    private(set) var lights = BBCMicro.Lights()
    @ObservationIgnored private var lightsTimer: Timer?

    init() {
        let model = UserDefaults.standard.string(forKey: Self.modelDefaultsKey)
            .flatMap(BBCMicro.Model.init(rawValue:)) ?? .modelB
        self.model = model
        let secondProcessor = UserDefaults.standard.bool(forKey: Self.secondProcessorDefaultsKey)
        self.secondProcessor = secondProcessor
        let configuration = BeebROMs.configuration(for: model, secondProcessor: secondProcessor)
        host = EmulatorHost {
            BBCMicro(configuration: configuration)
        }
        audio = AudioOutput(host: host)
        host.start()
        audio.start()
        joysticks = Joysticks(host: host)
        lightsTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let lights = self.host.lights
                if lights != self.lights {
                    self.lights = lights
                }
            }
        }
        startAgentServer()
        runSelfTestIfRequested()
    }

    /// The first window's machine is the one `macbeeb-mcp --attach` drives.
    private static var agentServer: AgentSocketServer?

    private func startAgentServer() {
        guard Self.agentServer == nil else { return }
        let server = AgentSocketServer(tools: AgentTools(context: host))
        do {
            try server.start()
            Self.agentServer = server
        } catch {
            NSLog("MacBeeb: no agent socket: \(error)")
        }
    }

    /// `MacBeeb -MacBeebSelfTest /path/to/out.png`: types a command, then
    /// saves what the window is showing and quits. For checking the app
    /// end to end without looking at it.
    private func runSelfTestIfRequested() {
        guard let path = UserDefaults.standard.string(forKey: "MacBeebSelfTest") else { return }
        let disc = UserDefaults.standard.string(forKey: "MacBeebSelfTestDisc")
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            if let disc {
                insertDisc(URL(fileURLWithPath: disc))
                try? await Task.sleep(for: .seconds(25))
            } else if UserDefaults.standard.bool(forKey: "MacBeebSelfTestMacLayout") {
                await typeThroughWindowInMacLayout()
            } else {
                host.send(.type("PRINT \"MACBEEB \";6*7\n"))
                try? await Task.sleep(for: .seconds(2))
            }
            let png = screenshotPNG()
            // The display as drawn, at twice the TV's size.
            if let image = renderer?.renderImage(width: EmulatorHost.Frame.width * 2, height: EmulatorHost.Frame.height * 2),
               let display = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
                try? display.write(to: URL(fileURLWithPath: path.replacingOccurrences(of: ".png", with: "-display.png")))
            }
            // The whole window, toolbar included.
            if let frameView = NSApp.windows.first(where: { $0.firstResponder is EmulatorNSView })?.contentView?.superview,
               let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) {
                frameView.cacheDisplay(in: frameView.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: path.replacingOccurrences(of: ".png", with: "-window.png")))
            }
            let report = "frame=\(host.frame?.number ?? -1) cycles=\(host.cycles) audioQueued=\(host.audioRing.count)\n"
            FileManager.default.createFile(atPath: path + ".txt", contents: Data(report.utf8))
            if let png {
                try? png.write(to: URL(fileURLWithPath: path))
            }
            NSApp.terminate(nil)
        }
    }

    /// Types PRINT 6*7 as Mac key events through the window, with "*" as
    /// Shift-8 (US/UK layouts), in Mac layout mode.
    private func typeThroughWindowInMacLayout() async {
        let settings = KeyboardSettings.shared
        let savedMode = settings.mode
        settings.mode = .macLayout
        defer { settings.mode = savedMode }
        try? await Task.sleep(for: .milliseconds(100))
        guard let window = NSApp.windows.first(where: { $0.firstResponder is EmulatorNSView }),
              let view = window.firstResponder as? EmulatorNSView else { return }

        func key(_ code: UInt16, _ characters: String, shift: Bool = false) async {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: shift ? .shift : [],
                                                   timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                   characters: characters, charactersIgnoringModifiers: characters,
                                                   isARepeat: false, keyCode: code) else { continue }
                if type == .keyDown { view.keyDown(with: event) } else { view.keyUp(with: event) }
                try? await Task.sleep(for: .milliseconds(60))
            }
        }
        func shift(_ down: Bool) async {
            guard let event = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: down ? .shift : [],
                                               timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                               characters: "", charactersIgnoringModifiers: "",
                                               isARepeat: false, keyCode: 0x38) else { return }
            view.flagsChanged(with: event)
            try? await Task.sleep(for: .milliseconds(60))
        }

        for (code, character) in [(UInt16(0x23), "P"), (0x0F, "R"), (0x22, "I"), (0x2D, "N"), (0x11, "T"),
                                  (0x31, " "), (0x16, "6")] {
            await key(code, character)
        }
        await shift(true)
        await key(0x1C, "*", shift: true)
        await shift(false)
        await key(0x1A, "7")
        await key(0x24, "\r")
        try? await Task.sleep(for: .seconds(1))
    }

    func powerCycle() {
        host.send(.powerCycle)
    }

    /// Switches model, which power cycles. Discs stay in the drives.
    func setModel(_ newModel: BBCMicro.Model) {
        guard newModel != model else { return }
        model = newModel
        UserDefaults.standard.set(newModel.rawValue, forKey: Self.modelDefaultsKey)
        changeMachine()
    }

    /// Fits or removes the 6502 Second Processor, which power cycles.
    func setSecondProcessor(_ fitted: Bool) {
        guard fitted != secondProcessor else { return }
        secondProcessor = fitted
        UserDefaults.standard.set(fitted, forKey: Self.secondProcessorDefaultsKey)
        changeMachine()
    }

    private func changeMachine() {
        host.send(.changeMachine(BeebROMs.configuration(for: model, secondProcessor: secondProcessor)))
    }

    func togglePause() {
        paused.toggle()
        host.send(.setPaused(paused))
    }

    func toggleSpeedLimit() {
        speedLimited.toggle()
        host.send(.setSpeedLimited(speedLimited))
    }

    /// Pastes the clipboard's text into the BBC as if typed (fast).
    func pasteText() {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        // Mac line endings become Return.
        host.send(.paste(text.replacingOccurrences(of: "\r\n", with: "\n")))
    }

    private func screenshotPNG() -> Data? {
        guard let frame = host.frame else { return nil }
        return Screenshot.png(pixels: frame.pixels, width: EmulatorHost.Frame.width, height: EmulatorHost.Frame.height)
    }

    func copyScreenshot() {
        guard let png = screenshotPNG() else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
    }

    func saveScreenshot() {
        guard let png = screenshotPNG() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        panel.nameFieldStringValue = "BBC Micro \(formatter.string(from: Date())).png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try png.write(to: url)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    /// Disc images the BBC has in its drives, by drive.
    private(set) var discNames: [Int: String] = [:]

    static let discTypes: [UTType] = [
        UTType(filenameExtension: "ssd") ?? .data,
        UTType(filenameExtension: "dsd") ?? .data,
    ]

    /// Asks for a disc image, puts it in `drive`, and (for drive 0, if
    /// `boot`) Shift-Breaks to boot it.
    // MARK: Tape

    static let tapeTypes: [UTType] = [
        UTType(filenameExtension: "uef") ?? .data,
        UTType(filenameExtension: "csw") ?? .data,
    ]

    private(set) var tapeName: String?

    func openTape() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Self.tapeTypes
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        insertTape(url)
    }

    /// Puts a tape in the recorder and, with `load`, types *TAPE and
    /// CHAIN "" to load its first program.
    func insertTape(_ url: URL, load: Bool = true) {
        let image: [UInt8]
        do {
            image = [UInt8](try Data(contentsOf: url))
            _ = try Tape(image: image)
        } catch {
            NSAlert(error: error).runModal()
            return
        }
        host.send(.perform { session in
            session.machine.tape = try? Tape(image: image)
            if load {
                session.machine.paste("*TAPE\nCHAIN \"\"\n")
            }
        })
        tapeName = url.lastPathComponent
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
    }

    func rewindTape() {
        host.send(.perform { $0.machine.tape?.rewind() })
    }

    func ejectTape() {
        host.send(.perform { $0.machine.tape = nil })
        tapeName = nil
    }

    // MARK: Discs

    func openDisc(drive: Int = 0, boot: Bool = true) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Self.discTypes
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        insertDisc(url, drive: drive, boot: boot)
    }

    /// Puts the disc image at `url` in `drive`. Writes go back to the file.
    func insertDisc(_ url: URL, drive: Int = 0, boot: Bool = true) {
        guard let data = try? Data(contentsOf: url) else {
            NSAlert(error: CocoaError(.fileReadUnknown)).runModal()
            return
        }
        let doubleSided = url.pathExtension.lowercased() == "dsd"
        let writable = FileManager.default.isWritableFile(atPath: url.path)
        let onWrite: (@Sendable ([UInt8]) -> Void)? = writable ? { @Sendable (bytes: [UInt8]) in
            DispatchQueue.global(qos: .utility).async {
                try? Data(bytes).write(to: url, options: .atomic)
            }
        } : nil
        host.send(.insertDisc(image: [UInt8](data), doubleSided: doubleSided, drive: drive, onWrite: onWrite))
        discNames[drive] = url.lastPathComponent
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        if boot && drive == 0 {
            host.send(.shiftBreak)
        }
    }

    func ejectDisc(drive: Int) {
        host.send(.insertDisc(image: nil, doubleSided: false, drive: drive, onWrite: nil))
        discNames[drive] = nil
    }

    func shiftBreak() {
        host.send(.shiftBreak)
    }

    private(set) var recordingURL: URL?

    /// Starts recording to a movie the user picks, or stops.
    func toggleRecording() {
        if recordingURL != nil {
            host.send(.stopRecording { error in
                Task { @MainActor in
                    if let error {
                        NSAlert(error: error).runModal()
                    }
                }
            })
            recordingURL = nil
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie]
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        panel.nameFieldStringValue = "BBC Micro \(formatter.string(from: Date())).mp4"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let codec: VideoRecorder.Codec = url.pathExtension.lowercased() == "mov" ? .proRes : .h264
        host.send(.startRecording(url, codec))
        recordingURL = url
    }

    static let stateType = UTType(filenameExtension: SaveStateFile.fileExtension) ?? .data

    func saveState() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [Self.stateType]
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        panel.nameFieldStringValue = "BBC Micro \(formatter.string(from: Date())).\(SaveStateFile.fileExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        host.send(.saveState(url) { error in
            guard let error else { return }
            Task { @MainActor in NSAlert(error: error).runModal() }
        })
    }

    func loadState() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [Self.stateType]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadState(url)
    }

    func loadState(_ url: URL) {
        do {
            let file = try SaveStateFile(data: Data(contentsOf: url))
            host.send(.loadState(file))
            model = file.configuration.model
            secondProcessor = file.configuration.secondProcessorROM != nil
            discNames = [:]
            tapeName = file.snapshot.hasTape ? "Tape" : nil
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    func pressBreak() {
        host.send(.pressBreak)
    }
}
