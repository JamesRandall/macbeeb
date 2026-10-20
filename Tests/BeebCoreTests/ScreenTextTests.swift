import Testing
@testable import BeebCore

struct ScreenTextTests {
    @Test(arguments: [0, 1, 2, 3, 4, 5, 6, 7])
    func readsTextInEveryMode(_ mode: Int) {
        let machine = bootModelB()
        machine.paste("MODE \(mode)\nPRINT \"Hello, BBC!\"\nCOLOUR 129:COLOUR 0:PRINT \"Mode \(mode) [ok]\"\n")
        #expect(machine.runUntilIdle())
        let screen = machine.screenText()
        #expect(screen.contains("Hello, BBC!"), "\(screen.prefix(8))")
        #expect(screen.contains("Mode \(mode) [ok]"), "\(screen.prefix(8))")
    }

    @Test func readsAfterScrolling() {
        let machine = bootModelB()
        machine.paste("MODE 1\nFOR I=1 TO 40:PRINT \"LINE \";I:NEXT\n")
        #expect(machine.runUntilIdle())
        let screen = machine.screenText()
        #expect(screen.contains("LINE 40"), "\(screen)")
        #expect(!screen.contains("LINE 1"))
    }
}
