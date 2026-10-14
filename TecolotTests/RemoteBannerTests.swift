import AppKit
import Foundation
import Testing
import TecolotSessionClient
import TecolotWire
@testable import Tecolot

struct RemoteBannerTests {
    @Test func connectedHasNoBanner() {
        let info = HelperInfoMessage(build: "test", os: "linux", arch: "arm64",
                                     machineID: "machine", hostName: "host",
                                     runtimeDirectory: "/tmp", home: "/home/test",
                                     shell: "/bin/sh", receiveWindow: 1024)
        #expect(RemoteBannerContent.make(state: .connected(info, connectionGeneration: 1),
                                        destination: "host") == nil)
    }

    @Test func reconnectOffersImmediateRetryAndClose() throws {
        let banner = try #require(RemoteBannerContent.make(
            state: .reconnecting(attempt: 3, nextRetry: Date()), destination: "host"))
        #expect(banner.text == "Connection lost. Reconnecting… (attempt 3)")
        #expect(banner.primary?.title == "Reconnect Now")
        #expect(banner.primary?.action == .reconnect)
        #expect(banner.secondary?.title == "Close")
        #expect(banner.secondary?.action == .close)
    }

    @Test func signInNamesTheDestination() throws {
        let banner = try #require(RemoteBannerContent.make(state: .signInNeeded, destination: "server"))
        #expect(banner.text == "Reconnecting to server needs your sign-in.")
        #expect(banner.primary?.action == .signIn)
        #expect(banner.secondary?.action == .close)
    }

    @Test func failureShowsThePlainMessage() throws {
        let error = SSHError(kind: .hostKeyChanged, message: "Check the host key.",
                             stderrLines: ["REMOTE HOST IDENTIFICATION HAS CHANGED"])
        let banner = try #require(RemoteBannerContent.make(state: .failed(error), destination: "server"))
        #expect(banner.text == error.message)
        #expect(banner.primary?.action == .retry)
        #expect(banner.secondary?.action == .close)
    }

    @Test func installingLimitsProgressToValidPercentages() throws {
        for (progress, percent) in [(-1.0, 0), (0.5, 50), (2.0, 100), (.nan, 0)] {
            let banner = try #require(RemoteBannerContent.make(state: .installing(progress), destination: "host"))
            #expect(banner.text.contains("(\(percent) %)"))
            #expect(banner.primary?.action == .close)
        }
    }

    @Test func pendingStatesOfferCancelAndUnsupportedOffersClose() throws {
        for state: HostLinkState in [.idle, .resolving, .connecting, .authenticating, .probing,
                                    .confirmInstall(12_000_000), .startingBridge] {
            let banner = try #require(RemoteBannerContent.make(state: state, destination: "host"))
            #expect(banner.text.contains("host"))
            #expect(banner.primary?.title == "Cancel")
            #expect(banner.primary?.action == .close)
            #expect(banner.secondary?.action == nil)
        }
        let banner = try #require(RemoteBannerContent.make(state: .unsupported(os: "other", arch: "cpu"),
                                                          destination: "host"))
        #expect(banner.primary?.title == "Close")
        #expect(banner.primary?.action == .close)
        #expect(banner.text == "This host is not supported (other cpu).")
    }

    @Test func connectionStagesUseTheSameMessage() throws {
        for state: HostLinkState in [.connecting, .resolving, .probing, .startingBridge] {
            let banner = try #require(RemoteBannerContent.make(state: state, destination: "server"))
            #expect(banner.text == "Connecting to server…")
        }
        let banner = try #require(RemoteBannerContent.make(state: .authenticating, destination: "server"))
        #expect(banner.text == "Waiting for sign-in to server…")
    }
    @MainActor
    @Test func bannerButtonsKeepTheirActions() throws {
        let session = RemoteSession(socket: -1, clientName: "test", build: "test")
        let view = RemoteTerminalView(session: session, font: .monospacedSystemFont(ofSize: 12, weight: .regular))
        defer { session.close() }
        var primary = 0
        var secondary = 0
        view.showBanner("One action", actionTitle: "Close") { primary += 1 }
        let banner = try #require(view.subviews.compactMap { $0 as? RemoteSessionBanner }.first)
        let stack = try #require(banner.subviews.compactMap { $0 as? NSStackView }.first)
        let buttons = stack.views.compactMap { $0 as? NSButton }
        let first = try #require(buttons.first)
        first.performClick(nil)
        #expect(primary == 1)
        view.showBanner("Two actions", actionTitle: "Retry", action: { primary += 1 },
                        secondaryActionTitle: "Close", secondaryAction: { secondary += 1 })
        first.performClick(nil)
        try #require(buttons.last).performClick(nil)
        #expect(primary == 2)
        #expect(secondary == 1)
    }

}
