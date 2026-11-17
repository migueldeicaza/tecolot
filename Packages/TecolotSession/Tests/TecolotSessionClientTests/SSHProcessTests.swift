import Dispatch
import Foundation
import Synchronization
import Testing
@testable import TecolotSessionClient

private final class SSHCompletionQueueProbe: @unchecked Sendable {
    private let key = DispatchSpecificKey<Bool>()

    init(_ queue: DispatchQueue) { queue.setSpecific(key: key, value: true) }
    var isOnQueue: Bool { DispatchQueue.getSpecific(key: key) == true }
}

private struct SSHCompletion: Sendable {
    var count = 0
    var status: Int32?
    var output = Data()
    var stderr = ""
    var onQueue = true
}

struct SSHProcessTests {
    @Test func shortChildrenCompleteOnceAfterBothStreamsDrain() async throws {
        let root = URL(fileURLWithPath: "/tmp/ssh-process-\(UUID().uuidString)", isDirectory: true)
        let server = try AskpassServer(runtimeDirectory: root)
        defer {
            server.close()
            try? FileManager.default.removeItem(at: root)
        }
        let queue = DispatchQueue(label: "tecolot.test.ssh-completion")
        let probe = SSHCompletionQueueProbe(queue)
        let results = Mutex(Array(repeating: SSHCompletion(), count: 64))
        var children: [SSHProcess] = []
        defer { for child in children { child.stop() } }

        for batch in 0..<4 {
            let indices = (batch * 16)..<((batch + 1) * 16)
            for index in indices {
                let status = index.isMultiple(of: 2) ? 0 : 255
                let script = """
                i=0
                while [ "$i" -lt 128 ]; do
                  printf 'stdout-\(index)\\n'
                  printf 'stderr-\(index)\\n' >&2
                  i=$((i + 1))
                done
                exit \(status)
                """
                let token = server.register(host: "process-test", handler: { _, reply in reply(nil) })
                let child = SSHProcess(path: "/bin/sh", arguments: ["-c", script],
                                       environment: ProcessInfo.processInfo.environment,
                                       askpass: server, token: token, nullInput: true)
                children.append(child)
                try child.start(queue: queue, captureOutput: true) { child, status, output in
                    results.withLock { values in
                        values[index].count += 1
                        values[index].status = status
                        values[index].output = output
                        values[index].stderr = child.stderr
                        values[index].onQueue = values[index].onQueue && probe.isOnQueue
                    }
                }
            }
            try await eventually("short SSH child callbacks") {
                results.withLock { values in indices.allSatisfy { values[$0].count > 0 } }
            }
        }

        queue.sync {}
        let completed = results.withLock { $0 }
        for (index, result) in completed.enumerated() {
            #expect(result.count == 1)
            #expect(result.status == (index.isMultiple(of: 2) ? 0 : 255))
            #expect(result.output == Data(String(repeating: "stdout-\(index)\n", count: 128).utf8))
            #expect(result.stderr == String(repeating: "stderr-\(index)\n", count: 128))
            #expect(result.onQueue)
        }
    }
}
