import Foundation

/// What MacBeeb shows when it opens: the welcome screen, or straight into
/// one of its three parts. Chosen on the welcome screen and in Settings.
enum LaunchScreen: String, CaseIterable, Identifiable {
    case welcome
    case machine
    case games
    case network

    var id: String { rawValue }

    static let defaultsKey = "MacBeebLaunchScreen"
    /// Before there was a welcome screen: true opened only the Game Library.
    private static let legacyBookshelfKey = "MacBeebStartWithClassics"

    var title: String {
        switch self {
        case .welcome: "The Welcome Screen"
        case .machine: "A BBC Micro"
        case .games: "The Game Library"
        case .network: "The Network Studio"
        }
    }

    /// The setting (an earlier "open with the Game Library" carries over).
    static var preference: LaunchScreen {
        get {
            let defaults = UserDefaults.standard
            if let saved = defaults.string(forKey: defaultsKey).flatMap(LaunchScreen.init(rawValue:)) { return saved }
            return defaults.bool(forKey: legacyBookshelfKey) ? .games : .welcome
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }

    /// What this launch shows: the setting as it was when the app started.
    /// Self-tests and window captures need a machine.
    nonisolated static let atLaunch: LaunchScreen = {
        let defaults = UserDefaults.standard
        if defaults.string(forKey: "MacBeebSelfTest") != nil || defaults.string(forKey: "MacBeebNetworkSelfTest") != nil
            || defaults.string(forKey: "MacBeebMCPSelfTest") != nil
            || defaults.string(forKey: "MacBeebCaptureDirectory") != nil {
            return .machine
        }
        return preference
    }()
}
