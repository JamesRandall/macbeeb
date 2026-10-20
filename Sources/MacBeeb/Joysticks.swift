import BeebHost
import GameController

/// Maps game controllers to the BBC's analogue joysticks: the first
/// controller is joystick 0 (left stick or d-pad, A to fire), the second is
/// joystick 1.
@MainActor
final class Joysticks {
    private let host: EmulatorHost
    private var observers: [NSObjectProtocol] = []

    init(host: EmulatorHost) {
        self.host = host
        GCController.shouldMonitorBackgroundEvents = false
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.configure() }
        })
        observers.append(center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.configure() }
        })
        configure()
    }

    private func configure() {
        for (index, controller) in GCController.controllers().prefix(2).enumerated() {
            guard let pad = controller.extendedGamepad else { continue }
            let host = self.host
            pad.valueChangedHandler = { pad, _ in
                // The d-pad takes over from the stick when pressed.
                let dx = pad.dpad.xAxis.value, dy = pad.dpad.yAxis.value
                let x = dx != 0 ? dx : pad.leftThumbstick.xAxis.value
                let y = dy != 0 ? dy : pad.leftThumbstick.yAxis.value
                let fire = pad.buttonA.isPressed || pad.rightTrigger.isPressed
                host.send(.joystick(index, x: Double(x), y: Double(y), fire: fire))
            }
        }
    }
}
