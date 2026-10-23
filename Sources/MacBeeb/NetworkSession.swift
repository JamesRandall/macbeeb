import AppKit
import BeebCore
import BeebHost
import BeebNetwork
import BeebROMs
import Observation

/// An open network: its project, saved as it changes, and its machines,
/// running. Each machine that's on has a `MachineController`, whether or
/// not it has a window, so its window, tile and canvas card all show the
/// same running machine.
@MainActor
@Observable
final class NetworkSession: StationOwner {
    private(set) var project: NetworkProject
    /// Where it's saved: a `.macbeebnet` package. Changes are saved there
    /// as they're made.
    private(set) var url: URL
    @ObservationIgnored let runtime: NetworkRuntime
    /// The machines switched on, by node.
    private(set) var controllers: [UUID: MachineController] = [:]
    /// The nodes selected on the canvas.
    var selection: Set<UUID> = []
    /// The station typed into (in the tiles) and heard.
    private(set) var focused: UUID?
    /// The whole network is paused.
    private(set) var paused = false
    /// The network's status, refreshed a few times a second.
    private(set) var status = NetworkHost.Status()
    /// The nodes that put something on the line since the last refresh.
    private(set) var transmitting: Set<UUID> = []
    /// A save failed: why.
    private(set) var saveError: String?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var statusTimer: Timer?
    @ObservationIgnored let thumbnails = ThumbnailCache()

    /// The sessions open, by package.
    private(set) static var open: [URL: NetworkSession] = [:]

    /// The session for the network at `url`, opening it if it isn't.
    static func session(for url: URL) throws -> NetworkSession {
        let key = url.standardizedFileURL
        if let session = open[key] { return session }
        let session = try NetworkSession(url: key)
        open[key] = session
        return session
    }

    private init(url: URL) throws {
        self.url = url
        let loaded = try NetworkPackage.load(from: url)
        project = loaded
        runtime = NetworkRuntime(packageURL: url, clockRate: NetworkRuntime.clockRate(of: loaded),
                                 discDriveSounds: MachineController.discDriveSounds(for:))
        runtime.start()
        for node in project.nodes where node.isMachine && node.poweredOn {
            powerOn(node.id, remember: false)
        }
        focused = project.workspace.tiles.first { controllers[$0] != nil } ?? controllers.keys.sorted { $0.uuidString < $1.uuidString }.first
        controllers[focused ?? UUID()]?.setAudible(true)
        runtime.network.setAudioStation(focused)
        statusTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let status = self.runtime.network.status
                guard status != self.status else {
                    if !self.transmitting.isEmpty { self.transmitting = [] }
                    return
                }
                let before = self.status.traffic
                let sent = Set(status.traffic.compactMap { station, traffic in
                    traffic.bytes != before[station]?.bytes ? station : nil
                })
                let nodes = Set(self.project.nodes.filter { $0.stationNumber.map { sent.contains(UInt8(clamping: $0)) } ?? false }.map(\.id))
                if nodes != self.transmitting { self.transmitting = nodes }
                self.status = status
            }
        }
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        RecentNetworks.shared.add(url)
    }

    /// Closes the network: its machines stop, and it's saved.
    func close() {
        saveNow()
        statusTimer?.invalidate()
        for controller in controllers.values {
            controller.detachFromNetwork()
        }
        controllers.removeAll()
        runtime.stop()
        Self.open[url] = nil
    }

    // MARK: Saving

    /// Changes the project and saves it shortly (changes in quick
    /// succession, like a drag, save once).
    func update(_ change: (inout NetworkProject) -> Void) {
        var project = self.project
        change(&project)
        guard project != self.project else { return }
        let clock = NetworkRuntime.clockRate(of: project)
        if clock != NetworkRuntime.clockRate(of: self.project) {
            runtime.network.setClock(clock)
        }
        self.project = project
        scheduleSave()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        do {
            try NetworkPackage.save(project, to: url)
            saveError = nil
        } catch {
            saveError = error.localizedDescription
        }
    }

    /// Saves a copy elsewhere and carries on with the copy.
    func saveAs(_ newURL: URL) throws {
        saveNow()
        let key = newURL.standardizedFileURL
        if FileManager.default.fileExists(atPath: key.path) {
            try FileManager.default.removeItem(at: key)
        }
        try FileManager.default.copyItem(at: url, to: key)
        Self.open[url] = nil
        url = key
        runtime.packageURL = key
        Self.open[key] = self
        update { $0.name = key.deletingPathExtension().lastPathComponent }
        // Discs already in drives keep writing to the old copies until
        // they're changed; put the package's copies back in.
        for (id, controller) in controllers {
            for (drive, media) in project[id]?.discs ?? [:] {
                runtime.insert(media, drive: drive, into: controller.host)
            }
        }
        saveNow()
        RecentNetworks.shared.add(key)
    }

    // MARK: Nodes

    func node(_ id: UUID) -> NetworkNode? { project[id] }

    /// Adds a machine (or the clock) at a canvas point, switched on.
    @discardableResult
    func add(_ kind: NetworkNode.Kind, model: BBCMicro.Model = .modelB, at point: CanvasPoint) -> UUID? {
        var node: NetworkNode
        if kind == .clock {
            guard !project.hasClock else { return nil }
            node = .clock(at: point)
        } else {
            let preferred = kind.conventionalStation.flatMap { project.stationNumberProblem($0, for: UUID()) == nil ? $0 : nil }
            guard let number = preferred ?? project.freeStationNumber() else { return nil }
            let base = kind == .station ? (model == .modelB ? "BBC" : model.displayName) : kind.displayName
            let name = kind == .station ? project.freeName("\(base) \(number)") : project.freeName(base)
            node = NetworkNode(kind: kind, name: name, stationNumber: number, setup: MachineSetup(model: model), position: point)
        }
        update { $0.nodes.append(node) }
        if node.isMachine {
            powerOn(node.id)
        }
        return node.id
    }

    /// A copy of a machine beside it, with the next free station number
    /// and copies of its discs.
    func duplicate(_ id: UUID) {
        guard var node = project[id], node.isMachine, let number = project.freeStationNumber(from: (node.stationNumber ?? 0) + 1) else { return }
        node.id = UUID()
        node.stationNumber = number
        node.name = project.freeName(node.name)
        node.position.x += 40
        node.position.y += 40
        node.discs = node.discs.compactMapValues { media in
            try? NetworkPackage.importMedia(NetworkPackage.url(of: media, in: url), into: url)
        }
        update { $0.nodes.append(node) }
        if node.poweredOn {
            powerOn(node.id)
        }
    }

    /// Takes nodes off the network: their machines stop, and their discs'
    /// copies go.
    func remove(_ ids: Set<UUID>) {
        for id in ids {
            powerOff(id, remember: false)
        }
        update { project in project.nodes.removeAll { ids.contains($0.id) } }
        selection.subtract(ids)
        project.workspace.tiles.removeAll { ids.contains($0) }
        removeUnusedMedia()
        saveNow()
    }

    func move(_ id: UUID, to point: CanvasPoint) {
        update { $0[id]?.position = point }
    }

    func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        update { $0[id]?.name = trimmed }
    }

    /// Changes a station's number, unless another machine has it or it's
    /// reserved. Returns why not, if not.
    @discardableResult
    func setStationNumber(_ id: UUID, to number: Int) -> String? {
        if let problem = project.stationNumberProblem(number, for: id) { return problem }
        update { $0[id]?.stationNumber = number }
        return nil
    }

    // MARK: Power

    func isOn(_ id: UUID) -> Bool { controllers[id] != nil }

    /// Switches a machine on: a fresh machine, as at power on.
    func powerOn(_ id: UUID, remember: Bool = true, startingServer: Bool = true) {
        guard controllers[id] == nil, let node = project[id], node.isMachine, let setup = node.setup else { return }
        let printerName = node.kind == .printServer
            ? "\(node.name) · station \(node.stationNumber ?? 0)"
            : "\(node.name)'s printer port"
        guard let host = runtime.powerOn(node, printer: (printerName, PrintCentre.receiver())) else { return }
        let controller = MachineController(station: id, host: host, setup: setup, owner: self)
        controller.watchesConsole = node.kind != .station
        for (drive, media) in node.discs {
            controller.noteNetworkDisc(media.displayName, drive: drive)
        }
        controllers[id] = controller
        if remember {
            update { $0[id]?.poweredOn = true }
        }
        if startingServer && node.kind == .fileServer && node.startsServerWhenOn {
            startFileServer(id)
        }
        if startingServer && node.kind == .printServer && node.startsServerWhenOn {
            startPrinterServer(id)
        }
        if focused == nil {
            focus(id)
        }
    }

    /// Switches a machine off: it stops, and what's in its memory is gone.
    func powerOff(_ id: UUID, remember: Bool = true) {
        guard let controller = controllers.removeValue(forKey: id) else { return }
        controller.detachFromNetwork()
        runtime.powerOff(id)
        thumbnails.forget(id)
        if focused == id {
            focused = nil
            runtime.network.setAudioStation(nil)
        }
        if remember {
            update { $0[id]?.poweredOn = false }
        }
    }

    func togglePower(_ id: UUID) {
        isOn(id) ? powerOff(id) : powerOn(id)
    }

    /// Power off and on: a cold boot, as switching it off and on.
    func coldBoot(_ id: UUID) {
        guard let controller = controllers[id] else {
            powerOn(id)
            return
        }
        controller.host.send(.powerCycle)
    }

    func pressBreak(_ id: UUID) {
        controllers[id]?.host.send(.pressBreak)
    }

    /// A suspended station stops where it is while the others run on.
    func isSuspended(_ id: UUID) -> Bool { controllers[id]?.paused ?? false }

    func setSuspended(_ id: UUID, _ suspended: Bool) {
        controllers[id]?.setPaused(suspended)
    }

    func powerOnAll() {
        for node in project.nodes where node.isMachine {
            powerOn(node.id)
        }
    }

    func powerOffAll() {
        for id in Array(controllers.keys) {
            powerOff(id)
        }
    }

    /// Break on every machine.
    func resetAll() {
        for controller in controllers.values {
            controller.host.send(.pressBreak)
        }
    }

    /// Pauses the whole network: no time passes anywhere, so nothing on
    /// it times out.
    func setPaused(_ paused: Bool) {
        self.paused = paused
        runtime.network.setPaused(paused)
    }

    // MARK: Discs

    /// Asks for a disc image and puts it in a machine's drive: into the
    /// running machine if it's on, else for when it's switched on.
    func chooseDisc(for id: UUID, drive: Int) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = MachineController.discTypes
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK, let source = panel.url else { return }
        insertDisc(source, into: id, drive: drive)
    }

    func insertDisc(_ source: URL, into id: UUID, drive: Int) {
        if let controller = controllers[id] {
            controller.insertDisc(source, drive: drive, boot: false)
            return
        }
        do {
            let media = try NetworkPackage.importMedia(source, into: url)
            update { $0[id]?.discs[drive] = media }
            removeUnusedMedia()
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    func eject(_ id: UUID, drive: Int) {
        if let controller = controllers[id] {
            controller.ejectDisc(drive: drive)
        } else {
            update { $0[id]?.discs[drive] = nil }
            removeUnusedMedia()
        }
    }

    private func removeUnusedMedia() {
        for old in NetworkPackage.unusedMedia(of: project, in: url) {
            try? FileManager.default.removeItem(at: old)
        }
    }

    // MARK: Servers

    /// What a file server should type to start Acorn's Level 1 server:
    /// `CH."FS"`, then its questions answered, giving every other machine
    /// on the network the class's shared directory, A.
    func fileServerStartup(for id: UUID) -> String {
        let clients = project.stations.filter { $0.id != id && $0.kind == .station }.compactMap(\.stationNumber)
        var text = "CH.\"FS\"\n3\nY\n"
        for station in clients.prefix(30) {
            text += "A\n\(station)\n"
        }
        return text + "\n"
    }

    /// Starts Acorn's Level 1 file server on a machine: the network's copy
    /// of the server disc goes in its drive 0 (if it hasn't one), it's
    /// reset, and the start-up is typed, as the server's manual says.
    func startFileServer(_ id: UUID) {
        if !isOn(id) { powerOn(id, startingServer: false) }
        guard let controller = controllers[id] else { return }
        if project[id]?.discs[0] == nil {
            let disc = BeebROMs.BundledDisc.econetLevel1
            let staged = FileManager.default.temporaryDirectory.appendingPathComponent("Econet Level 1.ssd")
            try? Data(disc.data).write(to: staged)
            controller.insertDisc(staged, drive: 0, boot: false)
        }
        controller.host.send(.pressBreak)
        let startup = fileServerStartup(for: id)
        Task { @MainActor in
            // After Break's banner.
            try? await Task.sleep(for: .seconds(1.5))
            controller.host.send(.type(startup))
        }
    }

    /// Starts MacBeeb's printer server on a machine: the server disc goes
    /// in its drive 0 (if it hasn't one), and it boots it (Shift-Break).
    /// Its printer's jobs go to the Print Centre.
    func startPrinterServer(_ id: UUID) {
        if !isOn(id) { powerOn(id, startingServer: false) }
        guard let controller = controllers[id] else { return }
        if project[id]?.discs[0] == nil, let image = try? PrinterServer.disc() {
            let staged = FileManager.default.temporaryDirectory.appendingPathComponent("Printer Server.ssd")
            try? Data(image).write(to: staged)
            controller.insertDisc(staged, drive: 0, boot: false)
        }
        controller.host.send(.shiftBreak)
    }

    /// What a server's console says: its last non-blank line.
    func serverStatus(_ id: UUID) -> String? {
        guard let controller = controllers[id] else { return nil }
        return controller.consoleLine
    }

    // MARK: Focus

    /// The station typed into in the tiles, and heard.
    func focus(_ id: UUID?) {
        guard focused != id else { return }
        if let old = focused {
            controllers[old]?.setAudible(false)
        }
        focused = id.flatMap { controllers[$0] != nil ? $0 : nil }
        if let focused {
            controllers[focused]?.setAudible(true)
        }
        runtime.network.setAudioStation(focused)
    }

    /// The next (or previous) machine that's on, by station number.
    func focusNext(_ forward: Bool = true) {
        let on = project.stations.filter { controllers[$0.id] != nil }.map(\.id)
        guard !on.isEmpty else { return }
        let index = focused.flatMap { on.firstIndex(of: $0) } ?? (forward ? on.count - 1 : 0)
        focus(on[(index + (forward ? 1 : on.count - 1)) % on.count])
    }

    // MARK: StationOwner

    func stationSetupChanged(_ controller: MachineController) {
        guard let id = controller.stationID else { return }
        let setup = controller.setup
        update { $0[id]?.setup = setup }
    }

    func station(_ controller: MachineController, willInsert source: URL, drive: Int) -> URL? {
        guard let id = controller.stationID else { return nil }
        // Already one of the package's copies.
        if source.standardizedFileURL.path.hasPrefix(NetworkPackage.mediaURL(in: url).standardizedFileURL.path) {
            return source
        }
        do {
            let media = try NetworkPackage.importMedia(source, into: url)
            update { $0[id]?.discs[drive] = media }
            removeUnusedMedia()
            return NetworkPackage.url(of: media, in: url)
        } catch {
            NSAlert(error: error).runModal()
            return nil
        }
    }

    func station(_ controller: MachineController, didEject drive: Int) {
        guard let id = controller.stationID else { return }
        update { $0[id]?.discs[drive] = nil }
        removeUnusedMedia()
    }

    func stationNumber(_ controller: MachineController) -> Int? {
        controller.stationID.flatMap { project[$0]?.stationNumber }
    }

    func stationTitle(_ controller: MachineController) -> String {
        guard let id = controller.stationID, let node = project[id] else { return "Station" }
        return node.stationNumber.map { "\(node.name) · station \($0)" } ?? node.name
    }
}
