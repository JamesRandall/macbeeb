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
        host = EmulatorHost {
            BBCMicro(os: os, sidewaysROMs: [15: basic])
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
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            host.send(.type("PRINT \"MACBEEB \";6*7\n"))
            try? await Task.sleep(for: .seconds(2))
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

    /// Loads a program from a DFS disc image straight into memory, then
    /// runs it. (Until the disc system's in, this is how to run software.)
    func openProgram() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "ssd") ?? .data]
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url) else { return }
        let bytes = [UInt8](data)
        guard let disc = try? DFSDisc(side: bytes), !disc.files.isEmpty else {
            NSAlert(error: CocoaError(.fileReadCorruptFile)).runModal()
            return
        }
        // The !BOOT file is usually a text loader; prefer the first program.
        let file = disc.files.first { $0.name.uppercased() != "!BOOT" } ?? disc.files[0]
        host.send(.loadProgram(disc: bytes, file: file.fullName))
        let isBASIC = disc.contents(of: file).first == 0x0D
        host.send(.paste(isBASIC ? "RUN\n" : "CALL &\(String(file.executionAddress & 0xFFFF, radix: 16, uppercase: true))\n"))
    }
}
