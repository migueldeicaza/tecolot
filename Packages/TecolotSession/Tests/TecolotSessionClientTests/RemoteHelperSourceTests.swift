#if canImport(Darwin) && canImport(CryptoKit)
import CryptoKit
import Foundation
import Testing
import TecolotSessionClient

struct RemoteHelperSourceTests {
    @Test func hashesOnceAndCachesAFilePayload() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tecolot-source-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("helper")
        let contents = Data(String(repeating: "helper bytes\n", count: 1000).utf8)
        try contents.write(to: file)
        let source = try LocalHelperSource(helperURL: file, version: "1.2.3")
        let metadata = try #require(try source.metadata(for: "darwin-universal"))
        #expect(metadata.uncompressedSize == Int64(contents.count))
        #expect(metadata.sha256 == SHA256.hash(data: contents).map { String(format: "%02x", $0) }.joined())
        #expect(metadata.release == "1.2.3-\(metadata.sha256.prefix(8))")
        #expect(try source.metadata(for: "linux-x86_64") == nil)
        #expect(throws: RemoteBootstrapError.self) { try source.payload(for: "linux-x86_64", compressed: false, cacheDirectory: root) }
        let cache = root.appendingPathComponent("cache")
        let raw = try source.payload(for: "darwin-universal", compressed: false, cacheDirectory: cache)
        #expect(raw.fileURL == file)
        let zipped = try source.payload(for: "darwin-universal", compressed: true, cacheDirectory: cache)
        let stream = try zipped.openStream()
        defer { try? stream.close() }
        #expect(try stream.readToEnd()?.count == Int(zipped.byteCount))
        #expect(zipped.byteCount < metadata.uncompressedSize)
        let cachedBytes = try Data(contentsOf: zipped.fileURL)
        try Data("changed after source init".utf8).write(to: file)
        #expect(try source.metadata(for: "darwin-universal") == metadata)
        let again = try source.payload(for: "darwin-universal", compressed: true, cacheDirectory: cache)
        #expect(again.fileURL == zipped.fileURL)
        #expect(try Data(contentsOf: again.fileURL) == cachedBytes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: cache.path).count == 1)
    }
}

#endif
