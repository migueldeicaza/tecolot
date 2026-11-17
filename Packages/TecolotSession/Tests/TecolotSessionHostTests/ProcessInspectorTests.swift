import Foundation
import Testing
@testable import TecolotSessionHost

struct ProcessInspectorTests {
    @Test func idleShellHasNoChildrenBeforeAndAfterAControlledChild() throws {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", #"""
        printf 'idle\n'
        read start
        sleep 600 &
        child=$!
        printf 'busy\n'
        read stop
        kill "$child"
        wait "$child" 2>/dev/null
        printf 'idle\n'
        read quit
        """#]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            if process.isRunning {
                try? input.fileHandleForWriting.write(contentsOf: Data("start\nstop\nquit\n".utf8))
            }
            process.waitUntilExit()
        }
        #expect(try line(from: output.fileHandleForReading) == "idle")
        #expect(!ProcessInspector.hasChildren(process.processIdentifier))
        try input.fileHandleForWriting.write(contentsOf: Data("start\n".utf8))
        #expect(try line(from: output.fileHandleForReading) == "busy")
        #expect(ProcessInspector.hasChildren(process.processIdentifier))
        try input.fileHandleForWriting.write(contentsOf: Data("stop\n".utf8))
        #expect(try line(from: output.fileHandleForReading) == "idle")
        #expect(!ProcessInspector.hasChildren(process.processIdentifier))
        #expect(!ProcessInspector.hasChildren(0))
    }

    /// Each line acknowledges a process-tree change before it is inspected.
    private func line(from handle: FileHandle) throws -> String {
        var bytes = Data()
        while true {
            let byte = try #require(try handle.read(upToCount: 1))
            #expect(!byte.isEmpty)
            if byte.isEmpty || byte == Data([10]) {
                break
            }
            bytes.append(byte)
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
