import BeebCore
import BeebHost
import SwiftUI

/// The window's toolbar: the common actions, and the machine's lights.
/// Customisable, and hidden with View > Hide Toolbar.
struct MachineToolbar: CustomizableToolbarContent {
    let machine: MachineController

    var body: some CustomizableToolbarContent {
        ToolbarItem(id: "model", placement: .navigation) {
            Menu {
                Picker("Model", selection: Binding(get: { machine.model }, set: { machine.setModel($0) })) {
                    ForEach(BBCMicro.Model.allCases, id: \.self) { model in
                        Text(model.displayName).tag(model)
                    }
                }
                .pickerStyle(.inline)
                Divider()
                Toggle("6502 Second Processor", isOn: Binding(get: { machine.secondProcessor },
                                                             set: { machine.setSecondProcessor($0) }))
            } label: {
                Label("Model", systemImage: "desktopcomputer")
            }
            .help("Choose the machine (power cycles)")
        }

        ToolbarItem(id: "disc") {
            Menu {
                Button("Open and Boot Disc…") { machine.openDisc() }
                Button("Insert in Drive 0…") { machine.openDisc(drive: 0, boot: false) }
                Button("Insert in Drive 1…") { machine.openDisc(drive: 1, boot: false) }
                Divider()
                Button("Eject Drive 0") { machine.ejectDisc(drive: 0) }
                    .disabled(machine.discNames[0] == nil)
                Button("Eject Drive 1") { machine.ejectDisc(drive: 1) }
                    .disabled(machine.discNames[1] == nil)
            } label: {
                Label("Disc", systemImage: "opticaldiscdrive")
            } primaryAction: {
                machine.openDisc()
            }
            .help("Open and boot a disc; hold for more")
        }

        ToolbarItem(id: "tape") {
            Menu {
                Button("Load Tape…") { machine.openTape() }
                Button("Rewind Tape") { machine.rewindTape() }
                    .disabled(machine.tapeName == nil)
                Button("Eject Tape") { machine.ejectTape() }
                    .disabled(machine.tapeName == nil)
            } label: {
                Label("Tape", systemImage: "recordingtape")
            } primaryAction: {
                machine.openTape()
            }
            .help("Load a tape; hold for more")
        }

        ToolbarItem(id: "break") {
            Button { machine.pressBreak() } label: {
                Label("Break", systemImage: "arrow.counterclockwise")
            }
            .help("Break")
        }

        ToolbarItem(id: "boot", showsByDefault: false) {
            Button { machine.shiftBreak() } label: {
                Label("Boot Disc", systemImage: "arrow.counterclockwise.circle")
            }
            .help("Shift-Break: boot the disc in drive 0")
        }

        ToolbarItem(id: "power") {
            Button { machine.powerCycle() } label: {
                Label("Power Cycle", systemImage: "power")
            }
            .help("Switch off and on again")
        }

        ToolbarItem(id: "pause") {
            Button { machine.togglePause() } label: {
                Label(machine.paused ? "Resume" : "Pause", systemImage: machine.paused ? "play.fill" : "pause.fill")
            }
            .help(machine.paused ? "Resume" : "Pause")
        }

        ToolbarItem(id: "speed") {
            Toggle(isOn: Binding(get: { !machine.speedLimited }, set: { _ in machine.toggleSpeedLimit() })) {
                Label("Full Speed", systemImage: "hare")
            }
            .help("Run as fast as possible")
        }

        ToolbarItem(id: "screenshot") {
            Button { machine.saveScreenshot() } label: {
                Label("Screenshot", systemImage: "camera")
            }
            .help("Save a screenshot")
        }

        ToolbarItem(id: "record") {
            Button { machine.toggleRecording() } label: {
                Label(machine.recordingURL == nil ? "Record" : "Stop Recording",
                      systemImage: machine.recordingURL == nil ? "record.circle" : "stop.circle.fill")
                    .foregroundStyle(machine.recordingURL == nil ? Color.primary : Color.red)
            }
            .help(machine.recordingURL == nil ? "Record a video" : "Stop recording")
        }

        ToolbarItem(id: "state") {
            Menu {
                Button("Save State…") { machine.saveState() }
                Button("Load State…") { machine.loadState() }
            } label: {
                Label("Save State", systemImage: "square.and.arrow.down.on.square")
            } primaryAction: {
                machine.saveState()
            }
            .help("Save the machine's state; hold to load one")
        }

        ToolbarItem(id: "display", showsByDefault: false) {
            Menu {
                Picker("Display", selection: Binding(get: { machine.displayStyle }, set: { machine.displayStyle = $0 })) {
                    ForEach(DisplayStyle.allCases) { style in
                        Text(style.name).tag(style)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Label("Display", systemImage: "tv")
            }
            .help("Display style")
        }

        ToolbarItem(id: "keyboard", showsByDefault: false) {
            Menu {
                Picker("Keyboard", selection: Binding(get: { KeyboardSettings.shared.mode },
                                                      set: { KeyboardSettings.shared.mode = $0 })) {
                    ForEach(KeyboardMode.allCases) { mode in
                        Text(mode.name).tag(mode)
                    }
                }
                .pickerStyle(.inline)
                Divider()
                SettingsLink { Text("Keyboard Settings…") }
            } label: {
                Label("Keyboard", systemImage: "keyboard")
            }
            .help("Keyboard layout")
        }

        ToolbarItem(id: "lights", placement: .primaryAction) {
            MachineLights(lights: machine.lights)
        }
    }
}

/// The BBC's keyboard LEDs, the cassette motor and the drive lights.
struct MachineLights: View {
    let lights: BBCMicro.Lights

    var body: some View {
        HStack(spacing: 10) {
            light("CAPS", lights.capsLock, .red)
            light("SHIFT", lights.shiftLock, .red)
            light("MOTOR", lights.cassetteMotor, .red)
            light("0", lights.drives[0], .orange)
            light("1", lights.drives[1], .orange)
        }
        .padding(.horizontal, 6)
        .help("Caps Lock, Shift Lock, cassette motor, drives 0 and 1")
    }

    private func light(_ label: String, _ on: Bool, _ colour: Color) -> some View {
        VStack(spacing: 2) {
            Circle()
                .fill(on ? colour : Color.secondary.opacity(0.25))
                .shadow(color: on ? colour.opacity(0.8) : .clear, radius: 3)
                .frame(width: 7, height: 7)
            Text(label)
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement()
        .accessibilityLabel("\(label) light \(on ? "on" : "off")")
    }
}
