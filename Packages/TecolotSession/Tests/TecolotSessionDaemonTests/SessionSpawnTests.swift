import Foundation
import Testing
import TecolotSessionDirectory
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

struct SessionSpawnTests {
    @Test func childClosesOtherDescriptorsAndKeepsReadyDescriptor() throws {
        let directory = URL(fileURLWithPath: "/tmp/tsp-\(getpid())-\(UInt32.random(in: 0 ... .max))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = open("/dev/null", O_RDONLY)
        try #require(original >= 0)
        let leaked = fcntl(original, F_DUPFD, 20)
        close(original)
        try #require(leaked >= 20)
        defer { close(leaked) }
        // This descriptor deliberately has no close-on-exec flag.
        #expect(fcntl(leaked, F_GETFD) & FD_CLOEXEC == 0)
        var ready: [Int32] = [0, 0]
        try #require(pipe(&ready) == 0)
        defer { close(ready[0]); close(ready[1]) }
        let script = "if test -e /dev/fd/\(leaked); then exit 9; fi; printf ready >&3"
        let pid = try SessionDirectory.spawn("/bin/sh", arguments: ["sh", "-c", script], readyFD: ready[1],
                                             log: directory.appendingPathComponent("child.log").path,
                                             newSession: false)
        var status: Int32 = 0
        try #require(waitpid(pid, &status, 0) == pid)
        try #require(status == 0)
        var bytes = [UInt8](repeating: 0, count: 5)
        let count = bytes.withUnsafeMutableBytes { read(ready[0], $0.baseAddress, $0.count) }
        #expect(count == 5)
        #expect(String(decoding: bytes, as: UTF8.self) == "ready")
    }
}
