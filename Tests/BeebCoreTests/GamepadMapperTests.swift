import Testing
@testable import BeebCore
import BeebHost

struct GamepadMapperTests {
    @Test func joystickModeMovesTheJoystick() {
        var m = GamepadMapper(mode: .joystick, keys: [.up: .colon, .b: .space])
        // The stick, not the up key; A fires.
        #expect(m.update(GamepadState(x: 0.2, y: 1, buttons: [.a])) == [.joystick(x: 0.2, y: 1, fire: true)])
        // Other buttons press their keys.
        #expect(m.update(GamepadState(x: 0.2, y: 1, buttons: [.b])) == [.key(.space, down: true),
                                                                       .joystick(x: 0.2, y: 1, fire: false)])
        // Nothing changed, nothing sent.
        #expect(m.update(GamepadState(x: 0.2, y: 1, buttons: [.b])) == [])
        #expect(m.reset() == [.key(.space, down: false), .joystick(x: 0, y: 0, fire: false)])
    }

    @Test func keysModePressesKeys() {
        var m = GamepadMapper(mode: .keys, keys: [.left: .z, .right: .x, .up: .colon, .a: .returnKey])
        // Left, not up (under the threshold), and A. The joystick stays put.
        #expect(Set(m.update(GamepadState(x: -0.9, y: 0.3, buttons: [.a]))) == [.key(.z, down: true),
                                                                                .key(.returnKey, down: true)])
        // Past the threshold up, and over to the right.
        let actions = m.update(GamepadState(x: 0.8, y: 0.6))
        #expect(Set(actions) == [.key(.z, down: false), .key(.returnKey, down: false), .key(.x, down: true),
                                 .key(.colon, down: true)])
        // Unmapped buttons do nothing.
        #expect(m.update(GamepadState(x: 0.8, y: 0.6, buttons: [.y])) == [])
    }

    @Test func changingTheMappingReleasesWhatsHeld() {
        var m = GamepadMapper(mode: .keys, keys: [.a: .space])
        let state = GamepadState(buttons: [.a])
        #expect(m.update(state) == [.key(.space, down: true)])
        m.keys = [.a: .returnKey]
        #expect(m.update(state) == [.key(.space, down: false), .key(.returnKey, down: true)])
        // To joystick mode: A fires instead.
        m.mode = .joystick
        #expect(m.update(state) == [.key(.returnKey, down: false), .joystick(x: 0, y: 0, fire: true)])
    }

    /// Two buttons on one key: it's held while either is.
    @Test func sharedKeysStayDown() {
        var m = GamepadMapper(mode: .keys, keys: [.a: .space, .b: .space])
        #expect(m.update(GamepadState(buttons: [.a])) == [.key(.space, down: true)])
        #expect(m.update(GamepadState(buttons: [.a, .b])) == [])
        #expect(m.update(GamepadState(buttons: [.b])) == [])
        #expect(m.update(GamepadState()) == [.key(.space, down: false)])
    }
}

extension GamepadMapper.Action: Hashable {
    public func hash(into hasher: inout Hasher) {
        if case .key(let key, let down) = self {
            hasher.combine(key)
            hasher.combine(down)
        }
    }
}
