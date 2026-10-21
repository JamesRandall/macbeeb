import BeebCore

/// What a game controller is to the BBC.
public enum GamepadMode: String, CaseIterable, Sendable, Codable {
    /// An analogue joystick: the d-pad or left stick moves it, A or the
    /// right trigger fires, and the other buttons press their keys.
    case joystick
    /// Keys: every button, and each direction, presses its key.
    case keys
}

/// A game controller's buttons, with the d-pad and left stick as four
/// directions.
public enum GamepadButton: String, CaseIterable, Sendable, Codable {
    case up, down, left, right
    case a, b, x, y
    case leftShoulder, rightShoulder, leftTrigger, rightTrigger
    case leftStickButton, rightStickButton
    case menu, options

    /// What the joystick takes in joystick mode.
    public var isJoystick: Bool {
        switch self {
        case .up, .down, .left, .right, .a, .rightTrigger: true
        default: false
        }
    }
}

/// A controller as it is now.
public struct GamepadState: Equatable, Sendable {
    /// The d-pad, or the left stick when it's centred: -1 to 1, up and
    /// right positive.
    public var x: Double
    public var y: Double
    /// The buttons held, apart from the directions.
    public var buttons: Set<GamepadButton>

    public init(x: Double = 0, y: Double = 0, buttons: Set<GamepadButton> = []) {
        self.x = x
        self.y = y
        self.buttons = buttons
    }

    /// How far a direction goes before it's a key press.
    static let threshold = 0.5

    /// The buttons held, directions included.
    public var held: Set<GamepadButton> {
        var held = buttons
        if x <= -Self.threshold { held.insert(.left) }
        if x >= Self.threshold { held.insert(.right) }
        if y >= Self.threshold { held.insert(.up) }
        if y <= -Self.threshold { held.insert(.down) }
        return held
    }
}

/// Turns a controller's state into BBC key presses and joystick positions,
/// tracking what's held so it's released when the buttons, mode or keys
/// change.
public struct GamepadMapper: Sendable {
    public enum Action: Equatable, Sendable {
        case key(BeebKey, down: Bool)
        case joystick(x: Double, y: Double, fire: Bool)
    }

    public var mode: GamepadMode
    public var keys: [GamepadButton: BeebKey]

    private var heldKeys: Set<BeebKey> = []
    private var lastJoystick = Action.joystick(x: 0, y: 0, fire: false)

    public init(mode: GamepadMode = .joystick, keys: [GamepadButton: BeebKey] = [:]) {
        self.mode = mode
        self.keys = keys
    }

    /// The presses, releases and joystick movement that bring the BBC up
    /// to `state`.
    public mutating func update(_ state: GamepadState) -> [Action] {
        let held = state.held
        let joystick: Action
        let pressing: Set<GamepadButton>
        switch mode {
        case .joystick:
            joystick = .joystick(x: state.x, y: state.y, fire: held.contains(.a) || held.contains(.rightTrigger))
            pressing = held.filter { !$0.isJoystick }
        case .keys:
            joystick = .joystick(x: 0, y: 0, fire: false)
            pressing = held
        }
        let wanted = Set(pressing.compactMap { keys[$0] })
        var actions = heldKeys.subtracting(wanted).sorted { $0.rawValue < $1.rawValue }.map { Action.key($0, down: false) }
        actions += wanted.subtracting(heldKeys).sorted { $0.rawValue < $1.rawValue }.map { Action.key($0, down: true) }
        heldKeys = wanted
        if joystick != lastJoystick {
            actions.append(joystick)
            lastJoystick = joystick
        }
        return actions
    }

    /// Lets go of everything (the controller's gone).
    public mutating func reset() -> [Action] {
        update(GamepadState())
    }
}
