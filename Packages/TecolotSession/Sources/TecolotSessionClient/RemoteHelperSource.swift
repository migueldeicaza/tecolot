import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

public struct RemoteHelperMetadata: Hashable, Sendable {
    public let binaryID: String
    public let version: String
    public let sha256: String
    public let uncompressedSize: Int64
    public var release: String { "\(version)-\(sha256.prefix(8))" }

    public init(binaryID: String, version: String, sha256: String, uncompressedSize: Int64) {
        self.binaryID = binaryID
        self.version = version
        self.sha256 = sha256.lowercased()
        self.uncompressedSize = uncompressedSize
    }
}

/// A payload is a file, so an upload does not retain the full helper in memory.
public struct RemoteHelperPayload: Sendable {
    public let fileURL: URL
    public let byteCount: Int64
    public let compressed: Bool

    public init(fileURL: URL, byteCount: Int64, compressed: Bool) {
        self.fileURL = fileURL
        self.byteCount = byteCount
        self.compressed = compressed
    }

    public func openStream() throws -> FileHandle { try FileHandle(forReadingFrom: fileURL) }
}

public protocol RemoteHelperSource: Sendable {
    var askpassHelperPath: String? { get }
    func metadata(for binaryID: String) throws -> RemoteHelperMetadata?
    func payload(for binaryID: String, compressed: Bool, cacheDirectory: URL) throws -> RemoteHelperPayload
}

public extension RemoteHelperSource {
    var askpassHelperPath: String? { nil }
}

#if canImport(Darwin) && canImport(CryptoKit)
/// The app's existing macOS helper. Linux builds require a different source.
public final class LocalHelperSource: RemoteHelperSource, @unchecked Sendable {
    private let helperURL: URL
    private let helperMetadata: RemoteHelperMetadata
    private let lock = NSLock()
    public var askpassHelperPath: String? { helperURL.path }

    public convenience init(executable: URL, version: String) throws {
        try self.init(helperURL: executable, version: version)
    }

    public init(helperURL: URL, version: String) throws {
        try RemoteBootstrap.validateComponent(version)
        let handle = try FileHandle(forReadingFrom: helperURL)
        defer { try? handle.close() }
        var digest = SHA256()
        var size: Int64 = 0
        while let bytes = try handle.read(upToCount: 1024 * 1024), !bytes.isEmpty {
            digest.update(data: bytes)
            size += Int64(bytes.count)
        }
        self.helperURL = helperURL
        helperMetadata = RemoteHelperMetadata(binaryID: "darwin-universal", version: version,
                                              sha256: digest.finalize().map { String(format: "%02x", $0) }.joined(),
                                              uncompressedSize: size)
    }

    public func metadata(for binaryID: String) throws -> RemoteHelperMetadata? {
        binaryID == helperMetadata.binaryID ? helperMetadata : nil
    }

    public func payload(for binaryID: String, compressed: Bool, cacheDirectory: URL) throws -> RemoteHelperPayload {
        guard binaryID == helperMetadata.binaryID else { throw RemoteBootstrapError.unsupportedBinary(binaryID) }
        if !compressed {
            return RemoteHelperPayload(fileURL: helperURL, byteCount: helperMetadata.uncompressedSize, compressed: false)
        }
        lock.lock()
        defer { lock.unlock() }
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let cached = cacheDirectory.appendingPathComponent("\(helperMetadata.sha256).gz")
        if !FileManager.default.fileExists(atPath: cached.path) {
            let temporary = cacheDirectory.appendingPathComponent("\(helperMetadata.sha256)-\(UUID().uuidString).tmp")
            guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else {
                throw RemoteBootstrapError.invalidResponse("Cannot create the helper cache file")
            }
            defer { try? FileManager.default.removeItem(at: temporary) }
            let output = try FileHandle(forWritingTo: temporary)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
            process.arguments = ["-c", "-n", helperURL.path]
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            try output.close()
            guard process.terminationStatus == 0 else {
                throw RemoteBootstrapError.invalidResponse("Cannot compress the helper")
            }
            // A different source can have filled the same cache while gzip ran.
            if !FileManager.default.fileExists(atPath: cached.path) {
                do { try FileManager.default.moveItem(at: temporary, to: cached) }
                catch {
                    guard FileManager.default.fileExists(atPath: cached.path) else { throw error }
                }
            }
        }
        let size = try cached.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        return RemoteHelperPayload(fileURL: cached, byteCount: Int64(size), compressed: true)
    }
}

#endif
