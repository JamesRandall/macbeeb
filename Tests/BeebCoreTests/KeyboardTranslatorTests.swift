import Testing
@testable import BeebCore
import BeebHost

struct KeyboardTranslatorTests {
    // macOS virtual key codes.
    let shiftKey: UInt16 = 0x38, key8: UInt16 = 0x1C, key2: UInt16 = 0x13, keyA: UInt16 = 0x00
    let semicolonKey: UInt16 = 0x29, optionKey: UInt16 = 0x3A, returnKey: UInt16 = 0x24, f13: UInt16 = 0x69

    @Test func physicalGoesByPosition() {
        var t = KeyboardTranslator(mode: .physical)
        #expect(t.flagsChanged(keyCode: shiftKey, modifiers: .shift) == [.key(.shift, down: true)])
        // Shift-8 on a Mac types "*", but here it's the BBC's 8 key: "(".
        #expect(t.keyDown(keyCode: key8, characters: "*", modifiers: .shift, isRepeat: false) == [.key(.digit8, down: true)])
        #expect(t.keyUp(keyCode: key8) == [.key(.digit8, down: false)])
        #expect(t.flagsChanged(keyCode: optionKey, modifiers: .option) == [.key(.shiftLock, down: true)])
    }

    @Test func macLayoutTypesTheCharacter() {
        var t = KeyboardTranslator(mode: .macLayout)
        _ = t.flagsChanged(keyCode: shiftKey, modifiers: .shift)
        // "*" is Shift-colon on the BBC.
        #expect(t.keyDown(keyCode: key8, characters: "*", modifiers: .shift, isRepeat: false)
                == [.key(.shift, down: true), .key(.colon, down: true)])
        #expect(t.keyUp(keyCode: key8) == [.key(.colon, down: false), .key(.shift, down: true)])
    }

    @Test func macLayoutReleasesShiftWhenTheBBCNeedsItUp() {
        var t = KeyboardTranslator(mode: .macLayout)
        #expect(t.flagsChanged(keyCode: shiftKey, modifiers: .shift) == [.key(.shift, down: true)])
        // Shift-2 is "@" on a US Mac; "@" is unshifted on the BBC.
        #expect(t.keyDown(keyCode: key2, characters: "@", modifiers: .shift, isRepeat: false)
                == [.key(.shift, down: false), .key(.at, down: true)])
        // Letting go of Shift first: the override holds until "@" is up.
        #expect(t.flagsChanged(keyCode: shiftKey, modifiers: []) == [])
        #expect(t.keyUp(keyCode: key2) == [.key(.at, down: false), .key(.shift, down: false)])
    }

    @Test func macLayoutPressesShiftWhenTheBBCNeedsIt() {
        var t = KeyboardTranslator(mode: .macLayout)
        // ":" is Shift-; on a Mac but its own key on the BBC; "+" is
        // unshifted = on a Mac... and Shift-; on the BBC.
        #expect(t.keyDown(keyCode: semicolonKey, characters: ":", modifiers: .shift, isRepeat: false)
                == [.key(.shift, down: false), .key(.colon, down: true)])
        _ = t.keyUp(keyCode: semicolonKey)
        #expect(t.keyDown(keyCode: 0x18, characters: "+", modifiers: .shift, isRepeat: false)
                == [.key(.shift, down: true), .key(.semicolon, down: true)])
    }

    @Test func lettersFollowShiftAndCapsLock() {
        var t = KeyboardTranslator(mode: .macLayout)
        #expect(t.keyDown(keyCode: keyA, characters: "A", modifiers: .shift, isRepeat: false) == [.key(.a, down: true)])
    }

    @Test func nonCharacterKeysGoByPosition() {
        var t = KeyboardTranslator(mode: .macLayout)
        #expect(t.keyDown(keyCode: returnKey, characters: "\r", modifiers: [], isRepeat: false) == [.key(.returnKey, down: true)])
        // Control-letter is a position too.
        #expect(t.keyDown(keyCode: keyA, characters: "\u{01}", modifiers: .control, isRepeat: false) == [.key(.a, down: true)])
        // Option types characters, so isn't Shift Lock.
        #expect(t.flagsChanged(keyCode: optionKey, modifiers: .option) == [])
    }

    @Test func repeatsAndUnknownKeysAreIgnored() {
        var t = KeyboardTranslator()
        #expect(t.keyDown(keyCode: keyA, characters: "a", modifiers: [], isRepeat: true) == [])
        #expect(t.keyDown(keyCode: f13, characters: nil, modifiers: [], isRepeat: false) == [])
        #expect(t.keyUp(keyCode: f13) == [])
    }

    @Test func customKeysWinInBothModes() {
        for mode in KeyboardMode.allCases {
            var t = KeyboardTranslator(mode: mode, customKeys: [f13: .copy, optionKey: .ctrl, keyA: .space])
            #expect(t.keyDown(keyCode: f13, characters: nil, modifiers: [], isRepeat: false) == [.key(.copy, down: true)])
            #expect(t.keyDown(keyCode: keyA, characters: "a", modifiers: [], isRepeat: false) == [.key(.space, down: true)])
            #expect(t.flagsChanged(keyCode: optionKey, modifiers: .option) == [.key(.ctrl, down: true)])
            #expect(t.flagsChanged(keyCode: optionKey, modifiers: []) == [.key(.ctrl, down: false)])
        }
    }

    @Test func capsLockTaps() {
        var t = KeyboardTranslator()
        #expect(t.flagsChanged(keyCode: MacKeyMap.capsLock, modifiers: .capsLock) == [.tapCapsLock])
        #expect(t.flagsChanged(keyCode: MacKeyMap.capsLock, modifiers: []) == [.tapCapsLock])
    }

    @Test func everyPrintableASCIICharacterTypes() {
        for code in UInt8(0x20)...0x7E {
            let character = Character(UnicodeScalar(code))
            #expect(BeebKey.forCharacter(character) != nil, "\(character)")
        }
        #expect(BeebKey.forCharacter("£")! == (.underline, true))
    }

    @Test func catalogueHasEveryKeyOnce() {
        let keys = BeebKey.catalogue.map(\.key)
        #expect(Set(keys).count == keys.count)
        // The main keys, Break and the Master's 19-key keypad.
        #expect(keys.count == 72 + 1 + 19)
        #expect(BeebKey.returnKey.name == "RETURN")
    }
}
