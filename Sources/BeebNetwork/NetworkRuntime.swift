import BeebCore
import BeebHost
import BeebPrint
import Foundation

/// A network project's machines, running: a `NetworkHost` with a station
/// for each machine that's switched on. Use from one thread (the app's main
/// thread); the network itself runs on its own.
public final class NetworkRuntime: @unchecked Sendable {
    public let network: NetworkHost
    /// The package the network's discs are kept in.
    public var packageURL: URL
    /// The stations switched on, by node.
    public private(set) var stations: [UUID: EmulatorHost] = [:]
    /// Builds each station's disc drive sounds.
    private let discDriveSounds: (@Sendable (BBCMicro.Model) -> DiscDriveSounds?)?

    /// `clockRate`: the Econet clock's (nil: no clock).
    public init(packageURL: URL, clockRate: Int?, discDriveSounds: (@Sendable (BBCMicro.Model) -> DiscDriveSounds?)? = nil) {
        self.packageURL = packageURL
        self.discDriveSounds = discDriveSounds
        network = NetworkHost(econetClockRate: .some(clockRate))
    }

    /// The clock's rate for a project: its clock node's, if it has one.
    public static func clockRate(of project: NetworkProject) -> Int? {
        project.nodes.first { $0.kind == .clock }.map { $0.clockRate ?? NetworkNode.defaultClockRate }
    }

    public func start() {
        network.start()
    }

    public func stop() {
        network.stop()
        stations.removeAll()
    }

    /// Switches a machine on: a new machine, as at power on, with the
    /// node's discs in its drives. If it's already on, its station.
    @discardableResult
    public func powerOn(_ node: NetworkNode, discDriveSoundsOn: Bool = false,
                        printer: (name: String, jobs: @Sendable (PrintJob) -> Void)? = nil) -> EmulatorHost? {
        guard node.isMachine, let setup = node.setup else { return nil }
        if let running = stations[node.id] { return running }
        let configuration = setup.configuration(econetStation: node.stationNumber)
        let host = network.addStation(id: node.id, discDriveSounds: discDriveSounds, discDriveSoundsOn: discDriveSoundsOn,
                                      printer: printer) {
            BBCMicro(configuration: configuration)
        }
        for (drive, media) in node.discs {
            insert(media, drive: drive, into: host)
        }
        stations[node.id] = host
        return host
    }

    /// Switches a machine off: it stops, and its memory is gone. Its discs
    /// have been written back as it went.
    public func powerOff(_ id: UUID) {
        guard stations[id] != nil else { return }
        network.removeStation(id: id)
        stations[id] = nil
    }

    /// Puts one of the package's discs in a station's drive; the BBC's
    /// writes go back to the package's copy.
    public func insert(_ media: MediaReference, drive: Int, into host: EmulatorHost) {
        let url = NetworkPackage.url(of: media, in: packageURL)
        guard let data = FileManager.default.contents(atPath: url.path),
              let format = Disc.ImageFormat(path: url.path) else { return }
        host.send(.insertDisc(image: [UInt8](data), format: format, drive: drive, onWrite: { bytes in
            try? Data(bytes).write(to: url, options: .atomic)
        }))
    }
}
