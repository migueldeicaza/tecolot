import Foundation
import Testing
@testable import Tecolot

struct CommandURLTests {
    private let token = "0123456789abcdef"
    private let request = CommandRequest(action: .newTab, directory: "/tmp/a b&c", command: "echo 'hi' && ls +x", holdsAfterExit: true)

    @Test func urlRoundTrips() throws {
        let url = try #require(CommandURL.url(for: request, token: token))
        #expect(url.scheme == "tecolot")
        #expect(CommandURL.request(from: url) == request)
        #expect(CommandURL.hasToken(token, url: url))
    }

    @Test func wrongOrMissingTokenFails() throws {
        let url = try #require(CommandURL.url(for: request, token: token))
        #expect(!CommandURL.hasToken("other", url: url))
        let unsigned = try #require(URL(string: "tecolot://new-tab?command=ls"))
        #expect(!CommandURL.hasToken(token, url: unsigned))
        #expect(CommandURL.request(from: unsigned)?.needsTrust == true)
        #expect(CommandURL.request(from: try #require(URL(string: "tecolot://new-window")))?.needsTrust == false)
        #expect(CommandURL.request(from: try #require(URL(string: "tecolot://delete-everything"))) == nil)
    }

    @Test func tokenFileIsPrivate() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let token = CommandToken.generate(processIdentifier: 42)
        try token.write(to: directory)
        #expect(CommandToken.read(from: directory) == token)
        let path = directory.appendingPathComponent(CommandToken.fileName).path
        let permissions = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
        let first = CommandToken.generate()
        let second = CommandToken.generate()
        #expect(first.token != second.token)
        #expect(first.token.count == 64)
    }
}
