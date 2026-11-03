import Testing
@testable import Tecolot

struct TecoCommandTests {
    @Test func commandArgumentsAreQuoted() {
        #expect(TecoOpenOptions.commandLine(from: []) == nil)
        #expect(TecoOpenOptions.commandLine(from: ["ls -la | head"]) == "ls -la | head")
        #expect(TecoOpenOptions.commandLine(from: ["--", "echo", "it's", "a b"]) == "echo 'it'\\''s' 'a b'")
    }
}
