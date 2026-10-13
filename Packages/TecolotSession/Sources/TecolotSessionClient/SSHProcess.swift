import Dispatch
import Foundation
import Synchronization
import TecolotTransport
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Owns one ssh child. Pipe reads and writes run on worker queues.
final class SSHProcess: @unchecked Sendable {
    let process = Process()
    let input = Pipe()
    let output = Pipe()
    private let errors = Pipe()
    private let log = Mutex(Data())
    private let workers = DispatchGroup()
    private let writer = DispatchQueue(label: "tecolot.ssh-input")
    private let errorReader = DispatchQueue(label: "tecolot.ssh-errors")
    private let outputReader = DispatchQueue(label: "tecolot.ssh-output")
    private let cancelled = Mutex(false)
    private let token: String
    private let askpass: AskpassServer
    var stderr: String { log.withLock { String(decoding: $0, as: UTF8.self) } }
    var pid: Int32 { process.processIdentifier }
    var isRunning: Bool { process.isRunning }

    init(path: String, arguments: [String], environment: [String: String],
         askpass: AskpassServer, token: String, nullInput: Bool = false) {
        self.askpass = askpass
        self.token = token
        // A different child must not inherit a pipe and keep its reader open.
        for pipe in [input, output, errors] {
            UnixSocket.setCloseOnExec(pipe.fileHandleForReading.fileDescriptor)
            UnixSocket.setCloseOnExec(pipe.fileHandleForWriting.fileDescriptor)
        }
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.environment = environment
        if nullInput { process.standardInput = FileHandle.nullDevice }
        else { process.standardInput = input }
        process.standardOutput = output
        process.standardError = errors
        UnixSocket.setNoSignalOnBrokenPipe(input.fileHandleForWriting.fileDescriptor)
    }

    func start(queue: DispatchQueue, captureOutput: Bool,
               completion: @escaping @Sendable (SSHProcess, Int32, Data) -> Void) throws {
        let captured = Mutex(Data())
        // Register both reads and the exit callback before a short child can exit.
        workers.enter()
        if captureOutput { workers.enter() }
        process.terminationHandler = { [self] child in
            let status = child.terminationStatus
            workers.notify(queue: queue) { [self] in
                process.terminationHandler = nil
                askpass.unregister(token: token)
                completion(self, status, captured.withLock { $0 })
            }
        }
        do { try process.run() }
        catch {
            process.terminationHandler = nil
            workers.leave()
            if captureOutput { workers.leave() }
            askpass.unregister(token: token)
            throw error
        }
        errorReader.async { [self] in
            defer { workers.leave() }
            while let bytes = try? errors.fileHandleForReading.read(upToCount: 4096), !bytes.isEmpty {
                log.withLock { data in
                    data.append(bytes)
                    // Bound the log even when ssh prints a very long line.
                    if data.count > 64 * 1024 { data.removeFirst(data.count - 64 * 1024) }
                }
            }
            try? errors.fileHandleForReading.close()
        }
        if captureOutput {
            outputReader.async { [self] in
                defer { workers.leave() }
                let data = output.fileHandleForReading.readDataToEndOfFile()
                captured.withLock { $0 = data }
                try? output.fileHandleForReading.close()
            }
        }
    }

    func write(_ data: Data) {
        writer.async { [self] in
            guard !cancelled.withLock({ $0 }) else { return }
            try? input.fileHandleForWriting.write(contentsOf: data)
            try? input.fileHandleForWriting.close()
        }
    }

    func upload(file: URL, queue: DispatchQueue,
                progress: @escaping @Sendable (Double) -> Void) {
        writer.async { [self] in
            defer { try? input.fileHandleForWriting.close() }
            guard !cancelled.withLock({ $0 }) else { return }
            do {
                let source = try FileHandle(forReadingFrom: file)
                defer { try? source.close() }
                let total = max(1, try source.seekToEnd())
                try source.seek(toOffset: 0)
                var sent: UInt64 = 0
                while !cancelled.withLock({ $0 }),
                      let bytes = try source.read(upToCount: 64 * 1024), !bytes.isEmpty {
                    try input.fileHandleForWriting.write(contentsOf: bytes)
                    sent += UInt64(bytes.count)
                    let value = min(1, Double(sent) / Double(total))
                    queue.async { progress(value) }
                }
            } catch { stop() }
        }
    }

    func bridgeDescriptors() throws -> (Int32, Int32) {
        let readFD = dup(output.fileHandleForReading.fileDescriptor)
        let writeFD = dup(input.fileHandleForWriting.fileDescriptor)
        guard readFD >= 0, writeFD >= 0 else {
            if readFD >= 0 { close(readFD) }
            if writeFD >= 0 { close(writeFD) }
            throw TransportError("dup bridge")
        }
        UnixSocket.setCloseOnExec(readFD)
        UnixSocket.setCloseOnExec(writeFD)
        UnixSocket.setNoSignalOnBrokenPipe(writeFD)
        try? output.fileHandleForReading.close()
        try? input.fileHandleForWriting.close()
        return (readFD, writeFD)
    }

    func stop() {
        cancelled.withLock { $0 = true }
        if process.isRunning { process.terminate() }
        writer.async { [self] in try? input.fileHandleForWriting.close() }
        askpass.unregister(token: token)
    }
}
