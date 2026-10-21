import AppKit
import BeebCore
import BeebHost
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            KeyboardSettingsView()
                .tabItem { Label("Keyboard", systemImage: "keyboard") }
            DebuggingSettingsView()
                .tabItem { Label("Debugging", systemImage: "ladybug") }
        }
        .frame(width: 520, height: 460)
    }
}

struct KeyboardSettingsView: View {
    @State private var settings = KeyboardSettings.shared
    @State private var recorder: KeyRecorder?

    var body: some View {
        Form {
            Section {
                Picker("Keys", selection: $settings.mode) {
                    ForEach(KeyboardMode.allCases) { mode in
                        Text(mode.name).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
                Text(settings.mode == .physical
                     ? "Each Mac key is the BBC key in the same place: Shift-8 types “(” as on a BBC. Best for games."
                     : "Keys type what the Mac's layout says: Shift-8 types “*”. Best for typing. Control, the arrows and function keys still go by position, and Option types characters rather than being Shift Lock.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("For", selection: $settings.editingDisc) {
                    Text("All discs").tag(String?.none)
                    if !discs.isEmpty {
                        Divider()
                    }
                    ForEach(discs, id: \.self) { path in
                        Text(Self.discName(path)).tag(String?.some(path))
                    }
                }
                if settings.mappings(for: disc).isEmpty {
                    Text(disc == nil
                         ? "No custom keys. Add one to put any BBC key on any Mac key (it takes priority in both modes)."
                         : "No keys for this disc. Keys added here apply while it's in drive 0, on top of the keys for all discs.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(settings.mappings(for: disc)) { mapping in
                    HStack {
                        Text(mapping.macKeyName)
                            .frame(minWidth: 120, alignment: .leading)
                        Image(systemName: "arrow.right")
                            .foregroundStyle(.secondary)
                        Picker("BBC key", selection: Binding(
                            get: { mapping.key },
                            set: { settings.setMapping(keyCode: mapping.keyCode, macKeyName: mapping.macKeyName, to: $0,
                                                       disc: disc) }
                        )) {
                            ForEach(BeebKey.catalogue, id: \.key) { entry in
                                Text(entry.name).tag(entry.key)
                            }
                        }
                        .labelsHidden()
                        Button {
                            settings.removeMapping(keyCode: mapping.keyCode, disc: disc)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove")
                    }
                }
            } header: {
                Text("Custom keys")
            } footer: {
                HStack {
                    if recorder != nil {
                        Text("Press the Mac key to map…")
                            .foregroundStyle(.secondary)
                        Button("Cancel") { stopRecording() }
                    } else {
                        Button("Add Mapping…") { startRecording() }
                    }
                    Spacer()
                    Button("Remove All") { settings.removeAllMappings(disc: disc) }
                        .disabled(settings.mappings(for: disc).isEmpty)
                }
            }
        }
        .formStyle(.grouped)
        .onDisappear { stopRecording() }
    }

    /// The disc whose keys are showing (nil: all discs').
    private var disc: String? { settings.editingDisc }

    /// Discs to choose from: those in the machines' drive 0, those with
    /// keys, and the one showing.
    private var discs: [String] {
        let all = MachineController.all.values.compactMap(\.bootDiscPath) + settings.discMappings.keys
            + [settings.editingDisc].compactMap { $0 }
        return Set(all).sorted { Self.discName($0).localizedStandardCompare(Self.discName($1)) == .orderedAscending }
    }

    /// "Elite.ssd (Games)": the image's name and its folder's.
    static func discName(_ path: String) -> String {
        let url = URL(fileURLWithPath: path)
        return "\(url.lastPathComponent) (\(url.deletingLastPathComponent().lastPathComponent))"
    }

    private func startRecording() {
        let disc = disc
        recorder = KeyRecorder { event in
            let name = KeyboardSettings.name(of: event)
            // Start from what the key does now, then let the user pick.
            let current = settings.translator(disc: disc).translate(keyCode: event.keyCode, characters: event.characters,
                                                                    modifiers: .init(event.modifierFlags))?.key ?? .space
            settings.setMapping(keyCode: event.keyCode, macKeyName: name, to: current, disc: disc)
            stopRecording()
        }
    }

    private func stopRecording() {
        recorder?.stop()
        recorder = nil
    }
}

/// Captures the next key press (including modifier keys) in the app.
@MainActor
final class KeyRecorder {
    private var monitor: Any?

    init(onKey: @escaping (NSEvent) -> Void) {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            // Modifier presses only: ignore their releases.
            if event.type == .flagsChanged && !Self.isPress(event) {
                return nil
            }
            onKey(event)
            return nil
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }

    private static func isPress(_ event: NSEvent) -> Bool {
        let flag: NSEvent.ModifierFlags = switch event.keyCode {
        case 0x38, 0x3C: .shift
        case 0x3B, 0x3E: .control
        case 0x3A, 0x3D: .option
        case 0x37, 0x36: .command
        case 0x39: .capsLock
        default: .function
        }
        return event.modifierFlags.contains(flag)
    }
}

struct DebuggingSettingsView: View {
    @AppStorage(MachineController.debugAdapterEnabledKey) private var enabled = true
    @AppStorage(MachineController.debugAdapterPortKey) private var port = Int(6502)

    var body: some View {
        Form {
            Section {
                Toggle("Let editors debug the BBC (Debug Adapter Protocol)", isOn: $enabled)
                TextField("Port", value: $port, format: .number.grouping(.never))
                    .disabled(!enabled)
                Text("VS Code and other editors that speak DAP connect to localhost on this port, to set breakpoints in your source (with ld65 debug info), step, and inspect the machine. The MacBeeb extension for VS Code is in Tools/vscode-macbeeb. Changes take effect next launch.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
