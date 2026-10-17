import Foundation
import TecolotSessionClient

enum RemoteBannerAction: Equatable, Sendable {
    case close, reconnect, signIn, retry
}

enum RemoteBannerContent {
    typealias Content = (text: String, primary: (title: String, action: RemoteBannerAction)?,
                         secondary: (title: String, action: RemoteBannerAction)?)

    private static func content(_ text: String, title: String = "Cancel", action: RemoteBannerAction = .close,
                                secondaryTitle: String? = nil, secondaryAction: RemoteBannerAction? = nil) -> Content {
        let secondary = secondaryTitle.flatMap { title in secondaryAction.map { (title: title, action: $0) } }
        return (text, (title, action), secondary)
    }

    static func make(state: HostLinkState, destination: String) -> Content? {
        switch state {
        case .connected:
            return nil
        case .idle, .resolving, .connecting, .probing, .startingBridge:
            return content("Connecting to \(destination)…")
        case .authenticating:
            return content("Waiting for sign-in to \(destination)…")
        case .confirmInstall:
            // The install question shows above the terminal when its turn comes.
            return content("Connecting to \(destination)…")
        case .installing(let progress):
            let percent = Int((min(1, max(0, progress.isFinite ? progress : 0)) * 100).rounded())
            return content("Installing the Tecolot helper on \(destination) (\(percent) %)…")
        case .reconnecting(let attempt, _):
            return content("Connection lost. Reconnecting… (attempt \(attempt))", title: "Reconnect Now",
                        action: .reconnect, secondaryTitle: "Close", secondaryAction: .close)
        case .signInNeeded:
            return content("Reconnecting to \(destination) needs your sign-in.", title: "Sign In",
                        action: .signIn, secondaryTitle: "Close", secondaryAction: .close)
        case .failed(let error):
            return content(error.message, title: "Retry", action: .retry,
                        secondaryTitle: "Close", secondaryAction: .close)
        case .unsupported(let os, let arch):
            return content("This host is not supported (\(os) \(arch)).", title: "Close")
        }
    }
}
