import AppKit
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
    private(set) var paused = false
    private(set) var speedLimited = true

    init() {
        let os = BeebROMs.data(.os12)
        let basic = BeebROMs.data(.basic2)
        let dfs = BeebROMs.data(.dfs12)
        host = EmulatorHost {
            BBCMicro(os: os, sidewaysROMs: [15: basic, 14: dfs])
        }
        audio = AudioOutput(host: host)
        host.start()
        audio.start()
        runSelfTestIfRequested()
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
            } else {
                host.send(.type("PRINT \"MACBEEB \";6*7\n"))
                try? await Task.sleep(for: .seconds(2))
            }
            let png = screenshotPNG()
            let report = "frame=\(host.frame?.number ?? -1) cycles=\(host.cycles) audioQueued=\(host.audioRing.count)\n"
            FileManager.default.createFile(atPath: path + ".txt", contents: Data(report.utf8))
            if let png {
                try? png.write(to: URL(fileURLWithPath: path))
            }
            NSApp.terminate(nil)
        }
    }

    func powerCycle() {
        host.send(.powerCycle)
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

    func pressBreak() {
        host.send(.pressBreak)
    }
}
