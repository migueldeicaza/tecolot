import Foundation
import Testing
@testable import Tecolot

struct CommandLineToolInstallerTests {
    private struct Fixture {
        let root: URL
        let installer: CommandLineToolInstaller

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let executable = root.appendingPathComponent("Tecolot.app/Contents/MacOS/Tecolot")
            try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: executable.path, contents: Data(),
                                           attributes: [.posixPermissions: 0o755])
            installer = CommandLineToolInstaller(executable: executable)
        }

        var link: URL { root.appendingPathComponent("bin/teco") }

        func cleanUp() { try? FileManager.default.removeItem(at: root) }
    }

    @Test func installsAndUninstalls() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        #expect(fixture.installer.status(link: fixture.link) == .notInstalled)
        try fixture.installer.install(at: fixture.link)
        #expect(fixture.installer.status(link: fixture.link) == .installed(link: fixture.link, current: true))
        try fixture.installer.uninstall(link: fixture.link)
        #expect(fixture.installer.status(link: fixture.link) == .notInstalled)
    }

    @Test func refusesToReplaceAnotherTool() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try FileManager.default.createDirectory(at: fixture.link.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: fixture.link.path, contents: Data("#!/bin/sh".utf8))
        #expect(throws: CommandLineToolInstaller.InstallError.self) {
            try fixture.installer.install(at: fixture.link)
        }
        try fixture.installer.uninstall(link: fixture.link)
        #expect(FileManager.default.fileExists(atPath: fixture.link.path))
    }

    @Test func replacesALinkToAnotherCopy() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try FileManager.default.createDirectory(at: fixture.link.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: fixture.link.path,
                                                   withDestinationPath: "/Old/Tecolot.app/Contents/MacOS/Tecolot")
        #expect(fixture.installer.status(link: fixture.link) == .installed(link: fixture.link, current: false))
        try fixture.installer.install(at: fixture.link)
        #expect(fixture.installer.status(link: fixture.link) == .installed(link: fixture.link, current: true))
    }
}
