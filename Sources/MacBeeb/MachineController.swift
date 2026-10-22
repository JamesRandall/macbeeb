import AppKit
import BeebAgentKit
import BeebCapture
import BeebCore
import BeebDAP
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
    private(set) var paused = false
    /// An agent's holding the machine still between its tool calls
    /// (set_real_time). Resume lets it go.
    private(set) var heldForAgent = false
    /// Paused, by the user or for an agent.
    var isStill: Bool { paused || heldForAgent }
    private(set) var speedLimited = true
    /// The emulated model. New windows start with the last one chosen.
    private(set) var model: BBCMicro.Model
    /// How the window draws the picture. Shared by all windows.
    var displayStyle = DisplayStyle.saved {
        didSet { UserDefaults.standard.set(displayStyle.rawValue, forKey: DisplayStyle.defaultsKey) }
    }
    /// The monitor it's drawn on: colour, or green or amber monochrome.
    /// Shared by all windows.
    var monitor = Monitor.saved {
        didSet { UserDefaults.standard.set(monitor.rawValue, forKey: Monitor.defaultsKey) }
    }
    /// The window's renderer, for capturing the display as shown.
    @ObservationIgnored weak var renderer: Renderer?

    private static let modelDefaultsKey = "MacBeebModel"
    /// Whether a 6502 Second Processor is fitted. Remembered like the model.
    private(set) var secondProcessor: Bool
    private static let secondProcessorDefaultsKey = "MacBeebSecondProcessor"
    /// Which second processor, when one's fitted.
    private(set) var coprocessor: BBCMicro.Coprocessor
    private static let coprocessorDefaultsKey = "MacBeebCoprocessor"

    /// The second processor fitted, if any.
    var fittedCoprocessor: BBCMicro.Coprocessor? {
        secondProcessor && coprocessor.fits(model) ? coprocessor : nil
    }
    /// The Model B's disc interface. Remembered like the model.
    private(set) var discInterface: BBCMicro.DiscInterface
    private static let discInterfaceDefaultsKey = "MacBeebDiscInterface"
    /// Identifies this machine to its debugger window.
    let id = UUID()
    /// Open machines, for finding a debugger window's machine.
    static var all: [UUID: MachineController] = [:]
    /// The debugger's view of this machine.
    @ObservationIgnored private(set) lazy var debugger = DebuggerModel(host: host)
    /// Set when the debugger stops the machine, so the window opens.
    var debuggerRequested = false
    @ObservationIgnored private var lastDebugStop: StopReason?
    /// Why the debugger has stopped the machine, if it has.
    private(set) var debugStop: StopReason?
    /// The TV pixel under the mouse, while the debugger's open.
    var hoveredPixel: (x: Int, y: Int)?

    /// What's under the mouse: the screen address it came from.
    var inspection: String? {
        guard let (x, y) = hoveredPixel, debugger.isVisible,
              let metadata = host.frame?.metadata else { return nil }
        let index = (y / 2) * TVOutput.metadataWidth + x / 8
        guard index < metadata.count, let source = VideoSource(metadata: metadata[index]) else {
            return "x \(x), line \(y / 2): blanking"
        }
        let place = source.display ? "&\(hex(source.address, 4))" + (source.teletext ? "" : ", raster \(source.raster)") : "border"
        return "x \(x), line \(y / 2): \(place)"
    }

    /// The machine's indicator lights, refreshed a few times a second.
    private(set) var lights = BBCMicro.Lights()
    @ObservationIgnored private var lightsTimer: Timer?

    init() {
        let model = UserDefaults.standard.string(forKey: Self.modelDefaultsKey)
            .flatMap(BBCMicro.Model.init(rawValue:)) ?? .modelB
        self.model = model
        let secondProcessor = UserDefaults.standard.bool(forKey: Self.secondProcessorDefaultsKey)
        self.secondProcessor = secondProcessor
        let coprocessor = UserDefaults.standard.string(forKey: Self.coprocessorDefaultsKey)
            .flatMap(BBCMicro.Coprocessor.init(rawValue:)) ?? .mos6502
        self.coprocessor = coprocessor
        let discInterface = UserDefaults.standard.string(forKey: Self.discInterfaceDefaultsKey)
            .flatMap(BBCMicro.DiscInterface.init(rawValue:)) ?? .intel8271
        self.discInterface = discInterface
        let configuration = BeebROMs.configuration(for: model, secondProcessor: secondProcessor, coprocessor: coprocessor,
                                                   discInterface: discInterface)
        let discDriveSounds = UserDefaults.standard.object(forKey: Self.discDriveSoundsDefaultsKey) as? Bool ?? true
        self.discDriveSounds = discDriveSounds
        host = EmulatorHost(discDriveSounds: Self.discDriveSounds(for:), discDriveSoundsOn: discDriveSounds) {
            BBCMicro(configuration: configuration)
        }
        audio = AudioOutput(host: host)
        host.start()
        audio.start()
        if Joysticks.shared.machine == nil {
            Joysticks.shared.machine = self
        }
        startupDiscName = configuration.startupDisc?.name
        discNames[0] = startupDiscName
        lightsTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let lights = self.host.lights
                if lights != self.lights {
                    self.lights = lights
                }
                let held = self.host.isHeldForAgent
                if held != self.heldForAgent {
                    self.heldForAgent = held
                }
                let stop = self.host.debugStop
                if stop != self.debugStop {
                    self.debugStop = stop
                    if stop != nil {
                        self.debuggerRequested = true
                        self.debugger.refresh()
                    }
                }
            }
        }
        startAgentServer()
        DocumentationCapture.start(for: self)
        Self.all[id] = self
        runSelfTestIfRequested()
    }

    /// The first window's machine is the one `macbeeb-mcp --attach` drives.
    private static var agentServer: AgentSocketServer?
    /// Whether this is that machine.
    private(set) var servesAgents = false

    private func startAgentServer() {
        // Self-tests leave a running copy's servers alone.
        guard Self.agentServer == nil, UserDefaults.standard.string(forKey: "MacBeebSelfTest") == nil else { return }
        let server = AgentSocketServer(tools: LoggedTools(tools: AgentTools(context: host)))
        let host = host
        server.onConnection = { connected in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    AgentLog.shared.add(connected ? .connected : .disconnected)
                    // The last agent's gone: don't leave the machine held.
                    if !connected && AgentLog.shared.connections == 0 {
                        host.setHeldForAgent(false)
                    }
                }
            }
        }
        do {
            try server.start()
            Self.agentServer = server
            servesAgents = true
            AgentLog.shared.serverState = .serving
        } catch AgentSocketServer.StartError.inUse {
            AgentLog.shared.serverState = .inUse
        } catch {
            NSLog("MacBeeb: no agent socket: \(error)")
            AgentLog.shared.serverState = .failed(error.localizedDescription)
        }
        startDebugAdapter()
    }

    /// The first window's machine is the one DAP clients (VS Code) debug.
    private static var debugAdapter: DAPServer?
    static let debugAdapterEnabledKey = "MacBeebDebugAdapterEnabled"
    static let debugAdapterPortKey = "MacBeebDebugAdapterPort"

    private func startDebugAdapter() {
        let defaults = UserDefaults.standard
        guard Self.debugAdapter == nil, defaults.object(forKey: Self.debugAdapterEnabledKey) as? Bool ?? true else { return }
        let port = UInt16(exactly: defaults.integer(forKey: Self.debugAdapterPortKey)).flatMap { $0 == 0 ? nil : $0 } ?? DAPServer.defaultPort
        let server = DAPServer(host: host, port: port) { [weak self] model, secondProcessor in
            Task { @MainActor in self?.setHardware(model: model, secondProcessor: secondProcessor) }
        }
        do {
            try server.start()
            Self.debugAdapter = server
        } catch {
            NSLog("MacBeeb: no debug adapter on port \(port): \(error)")
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
            if let disc, UserDefaults.standard.bool(forKey: "MacBeebSelfTestDiscKeys") {
                await typeThroughWindowWithDiscKeys(disc)
            } else if let disc {
                insertDisc(URL(fileURLWithPath: disc))
                try? await Task.sleep(for: .seconds(25))
            } else if UserDefaults.standard.bool(forKey: "MacBeebSelfTestRewind") {
                host.send(.type("PRINT \"BEFORE\"\n"))
                try? await Task.sleep(for: .seconds(2))
                host.send(.type("CLS\n"))
                try? await Task.sleep(for: .seconds(1))
                showingTimeline = true
                try? await Task.sleep(for: .seconds(1.5))
                if let sheet = NSApp.windows.compactMap(\.attachedSheet).first,
                   let frameView = sheet.contentView?.superview,
                   let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) {
                    frameView.cacheDisplay(in: frameView.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?
                        .write(to: URL(fileURLWithPath: path.replacingOccurrences(of: ".png", with: "-rewind.png")))
                }
                // Back to before the CLS, still paused: the picture shows it.
                showingTimeline = false
                rewind(seconds: 4)
                try? await Task.sleep(for: .seconds(0.3))
            } else if UserDefaults.standard.bool(forKey: "MacBeebSelfTestProfile") {
                // A busy BASIC loop, profiled, with the Profile tab showing.
                UserDefaults.standard.set("Profile", forKey: "MacBeebDebuggerTab")
                host.send(.type("MODE 2\nREPEAT:GCOL0,RND(7):DRAW RND(1280),RND(1024):UNTIL FALSE\n"))
                try? await Task.sleep(for: .seconds(3))
                debugger.setProfiling(true)
                debuggerRequested = true
                try? await Task.sleep(for: .seconds(2))
                debugger.setProfiling(false)
                try? await Task.sleep(for: .seconds(0.5))
                if let window = NSApp.windows.first(where: { $0.title.hasPrefix("Debugger") }),
                   let frameView = window.contentView?.superview,
                   let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) {
                    frameView.cacheDisplay(in: frameView.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?
                        .write(to: URL(fileURLWithPath: path.replacingOccurrences(of: ".png", with: "-profile.png")))
                }
            } else if UserDefaults.standard.bool(forKey: "MacBeebSelfTestDebugger") {
                // Stop at OSWRCH as the key is echoed, then capture the
                // debugger window.
                debugger.addBreakpoint(Breakpoint(start: 0xFFEE))
                debugger.setTracing(true)
                try? await Task.sleep(for: .milliseconds(300))
                host.send(.type("P"))
                try? await Task.sleep(for: .seconds(2))
                if let window = NSApp.windows.first(where: { $0.title.hasPrefix("Debugger") }),
                   let frameView = window.contentView?.superview,
                   let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) {
                    frameView.cacheDisplay(in: frameView.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?
                        .write(to: URL(fileURLWithPath: path.replacingOccurrences(of: ".png", with: "-debugger.png")))
                }
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

    /// Presses Q through the window with `disc` in drive 0, which has Q
    /// mapped to 9, then with it ejected, then Return: "9Q" is typed.
    private func typeThroughWindowWithDiscKeys(_ disc: String) async {
        let settings = KeyboardSettings.shared
        let path = URL(fileURLWithPath: disc).standardizedFileURL.path
        defer { settings.removeAllMappings(disc: path) }
        settings.setMapping(keyCode: 0x0C, macKeyName: "Q", to: .digit9, disc: path)
        insertDisc(URL(fileURLWithPath: disc), boot: false)
        try? await Task.sleep(for: .milliseconds(200))
        guard let window = NSApp.windows.first(where: { $0.firstResponder is EmulatorNSView }),
              let view = window.firstResponder as? EmulatorNSView else { return }
        func key(_ code: UInt16, _ characters: String) async {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0,
                                                   windowNumber: window.windowNumber, context: nil,
                                                   characters: characters, charactersIgnoringModifiers: characters,
                                                   isARepeat: false, keyCode: code) else { continue }
                if type == .keyDown { view.keyDown(with: event) } else { view.keyUp(with: event) }
                try? await Task.sleep(for: .milliseconds(60))
            }
        }
        await key(0x0C, "q")
        ejectDisc(drive: 0)
        try? await Task.sleep(for: .milliseconds(200))
        await key(0x0C, "q")
        await key(0x24, "\r")
        try? await Task.sleep(for: .seconds(1))
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

    // MARK: Disc drive sounds

    private static let discDriveSoundsDefaultsKey = "MacBeebDiscDriveSounds"
    /// Whether the drives are heard (on unless turned off).
    private(set) var discDriveSounds: Bool

    func setDiscDriveSounds(_ on: Bool) {
        discDriveSounds = on
        UserDefaults.standard.set(on, forKey: Self.discDriveSoundsDefaultsKey)
        host.send(.setDiscDriveSounds(on))
    }

    /// Read once for each drive type, for every machine.
    nonisolated private static let sounds525 = BeebROMs.discDriveSounds(for: .modelB)
    nonisolated private static let sounds35 = BeebROMs.discDriveSounds(for: .masterCompact)

    nonisolated static func discDriveSounds(for model: BBCMicro.Model) -> DiscDriveSounds? {
        model == .masterCompact ? sounds35 : sounds525
    }

    // MARK: Zoom

    static let zoomLevels: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 2]

    /// The picture's zoom, as the window's size has it.
    @ObservationIgnored private var currentZoom = 1.0
    /// The zoom level the window's at, if it's at one (to within 1%).
    private(set) var zoom: Double? = 1

    func pictureZoomed(_ zoom: Double) {
        currentZoom = zoom
        let level = Self.zoomLevels.first { abs($0 - zoom) < 0.01 * $0 }
        if level != self.zoom {
            self.zoom = level
        }
    }

    func setZoom(_ zoom: Double) {
        NotificationCenter.default.post(name: EmulatorNSView.setZoom, object: host, userInfo: ["zoom": zoom])
    }

    /// The next level up (or down) from the zoom now.
    func zoom(in zoomIn: Bool) {
        let next = zoomIn ? Self.zoomLevels.first { $0 > currentZoom * 1.01 } : Self.zoomLevels.last { $0 < currentZoom * 0.99 }
        if let next { setZoom(next) }
    }

    /// Hands the Mac's mouse to the BBC's AMX mouse, or takes it back.
    func toggleMouseCapture() {
        NotificationCenter.default.post(name: EmulatorNSView.toggleMouseCapture, object: host)
    }

    func powerCycle() {
        // An empty drive 0 gets the system disc back.
        if discNames[0] == nil {
            discNames[0] = startupDiscName
        }
        host.send(.powerCycle)
    }

    // MARK: Rewind

    /// Shows the rewind timeline.
    var showingTimeline = false

    /// Goes back `seconds` of emulated time (as far as the history goes).
    func rewind(seconds: Double) {
        host.send(.perform { session in
            let m = session.machine
            guard let earliest = m.rewinder?.earliestCycle else { return }
            let back = UInt64(seconds * 2_000_000)
            Self.seek(session, to: m.cycles > earliest + back ? m.cycles - back : earliest)
        })
    }

    /// Seeks to a frame before `cycle` and runs up to it, so the TV has
    /// drawn the picture (even when paused).
    nonisolated static func seek(_ session: MachineSession, to cycle: UInt64) {
        guard let rewinder = session.machine.rewinder, let earliest = rewinder.earliestCycle else { return }
        let start = max(earliest, cycle > 40_000 ? cycle - 40_000 : 0)
        try? rewinder.seek(to: start)
        let m = session.machine
        if cycle > m.cycles {
            session.advance(cycles: Int(cycle - m.cycles))
        }
    }

    /// The rewind history's points: their cycles, and the current cycle.
    func rewindPoints() async -> (points: [UInt64], now: UInt64) {
        (try? await host.performAsync { session in
            (session.machine.rewinder?.points.map(\.cycle) ?? [], session.machine.cycles)
        }) ?? ([], 0)
    }

    /// A rewind point's thumbnail.
    func rewindThumbnail(_ index: Int) async -> CGImage? {
        let pixels = try? await host.performAsync { session -> [UInt32] in
            let points = session.machine.rewinder?.points ?? []
            return points.indices.contains(index) ? points[index].thumbnail : []
        }
        guard let pixels, pixels.count == Rewinder.thumbnailWidth * Rewinder.thumbnailHeight,
              let provider = CGDataProvider(data: Data(bytes: pixels, count: pixels.count * 4) as CFData) else { return nil }
        return CGImage(width: Rewinder.thumbnailWidth, height: Rewinder.thumbnailHeight, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: Rewinder.thumbnailWidth * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    func seek(to cycle: UInt64) {
        host.send(.perform { Self.seek($0, to: cycle) })
    }

    /// Pauses (or unpauses) without the menu's toggle.
    func setPaused(_ value: Bool) {
        paused = value
        host.send(.setPaused(value))
    }

    /// Switches model, which power cycles. Discs stay in the drives.
    func setModel(_ newModel: BBCMicro.Model) {
        guard newModel != model else { return }
        model = newModel
        UserDefaults.standard.set(newModel.rawValue, forKey: Self.modelDefaultsKey)
        changeMachine()
    }

    /// Switches model and second processor at once (one power cycle).
    func setHardware(model newModel: BBCMicro.Model, secondProcessor fitted: Bool) {
        guard newModel != model || fitted != secondProcessor else { return }
        model = newModel
        secondProcessor = fitted
        UserDefaults.standard.set(newModel.rawValue, forKey: Self.modelDefaultsKey)
        UserDefaults.standard.set(fitted, forKey: Self.secondProcessorDefaultsKey)
        changeMachine()
    }

    /// Changes the Model B's disc interface, which power cycles.
    func setDiscInterface(_ interface: BBCMicro.DiscInterface) {
        guard interface != discInterface else { return }
        discInterface = interface
        UserDefaults.standard.set(interface.rawValue, forKey: Self.discInterfaceDefaultsKey)
        if model == .modelB {
            changeMachine()
        }
    }

    /// Fits a second processor (nil removes it), which power cycles.
    func setCoprocessor(_ new: BBCMicro.Coprocessor?) {
        guard new != fittedCoprocessor else { return }
        secondProcessor = new != nil
        if let new { coprocessor = new }
        UserDefaults.standard.set(secondProcessor, forKey: Self.secondProcessorDefaultsKey)
        UserDefaults.standard.set(coprocessor.rawValue, forKey: Self.coprocessorDefaultsKey)
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
        let configuration = BeebROMs.configuration(for: model, secondProcessor: secondProcessor, coprocessor: coprocessor,
                                                   discInterface: discInterface)
        // As BBCMicro.insertDiscs: an empty drive 0, or one with the old
        // machine's system disc, gets the new machine's.
        let startup = configuration.startupDisc?.name
        if discNames[0] == nil || discNames[0] == startupDiscName {
            discNames[0] = startup
        }
        startupDiscName = startup
        host.send(.changeMachine(configuration))
    }

    func togglePause() {
        if heldForAgent && !paused {
            host.setHeldForAgent(false)
            heldForAgent = false
            return
        }
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
    /// The path of the disc image file in drive 0 (not a bundled disc's),
    /// whose own keys apply.
    private(set) var bootDiscPath: String?
    /// The bundled system disc the machine starts with (the Z80's CP/M,
    /// the Master 512's DOS Plus), if any.
    @ObservationIgnored private var startupDiscName: String?

    static let discTypes: [UTType] = Disc.ImageFormat.extensions.map { UTType(filenameExtension: $0) ?? .data }

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
            session.machine.insertTape(try? Tape(image: image))
            if load {
                session.machine.paste("*TAPE\nCHAIN \"\"\n")
            }
        })
        tapeName = url.lastPathComponent
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
    }

    func rewindTape() {
        host.send(.perform { $0.machine.rewindTape() })
    }

    func ejectTape() {
        host.send(.perform { $0.machine.insertTape(nil) })
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

    /// File > New Disc…: saves a blank, formatted disc image where the user
    /// says, and puts it in the drive they choose (without booting it:
    /// there's nothing on it to boot).
    func newDisc() {
        let empty = [0, 1].filter { discNames[$0] == nil }
        guard let choice = NewDiscPanel(model: model, emptyDrives: empty).run() else { return }
        do {
            try Data(choice.kind.image(title: choice.title)).write(to: choice.url, options: .atomic)
        } catch {
            NSAlert(error: error).runModal()
            return
        }
        if let drive = choice.drive {
            insertDisc(choice.url, drive: drive, boot: false)
        } else {
            RecentDiscs.shared.add(choice.url)
        }
    }

    /// Opens and boots a disc from File > Open Recent Disc, or says it's
    /// gone (and forgets it).
    func openRecentDisc(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            RecentDiscs.shared.remove(url)
            let alert = NSAlert()
            alert.messageText = "“\(url.lastPathComponent)” can’t be found"
            alert.informativeText = "It may have been moved, renamed or deleted, so it’s been taken off the list."
            alert.runModal()
            return
        }
        insertDisc(url)
    }

    /// Puts the disc image at `url` in `drive`. Writes go back to the file.
    func insertDisc(_ url: URL, drive: Int = 0, boot: Bool = true) {
        guard let data = try? Data(contentsOf: url) else {
            NSAlert(error: CocoaError(.fileReadUnknown)).runModal()
            return
        }
        let format = Disc.ImageFormat(path: url.path) ?? .ssd
        let writable = FileManager.default.isWritableFile(atPath: url.path)
        let onWrite: (@Sendable ([UInt8]) -> Void)? = writable ? { @Sendable (bytes: [UInt8]) in
            DispatchQueue.global(qos: .utility).async {
                try? Data(bytes).write(to: url, options: .atomic)
            }
        } : nil
        host.send(.insertDisc(image: [UInt8](data), format: format, drive: drive, onWrite: onWrite))
        discNames[drive] = url.lastPathComponent
        if drive == 0 {
            bootDiscPath = url.standardizedFileURL.path
        }
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        RecentDiscs.shared.add(url)
        if boot && drive == 0 {
            host.send(.shiftBreak)
        }
    }

    /// Puts one of the bundled discs in `drive`. Writes stay in memory.
    func insertBundledDisc(_ disc: BeebROMs.BundledDisc, drive: Int) {
        host.send(.insertDisc(image: disc.data, format: disc.format, drive: drive, onWrite: nil))
        discNames[drive] = disc.rawValue
        if drive == 0 {
            bootDiscPath = nil
        }
    }

    func ejectDisc(drive: Int) {
        host.send(.insertDisc(image: nil, format: .ssd, drive: drive, onWrite: nil))
        discNames[drive] = nil
        if drive == 0 {
            bootDiscPath = nil
        }
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
            coprocessor = file.configuration.coprocessor
            discInterface = file.configuration.discInterface
            discNames = [:]
            bootDiscPath = nil
            startupDiscName = nil
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
