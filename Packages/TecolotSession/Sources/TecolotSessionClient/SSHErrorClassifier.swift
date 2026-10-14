import Foundation

public struct SSHError: Error, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case network, authentication, hostKeyChanged, cancelled, channelRefused, other
    }
    public let kind: Kind
    public let message: String
    public let stderrLines: [String]
    public var retryAutomatically: Bool { kind == .network }
    public var stderr: String { stderrLines.joined(separator: "\n") }

    public init(kind: Kind, message: String, stderrLines: [String] = []) {
        self.kind = kind
        self.message = message
        self.stderrLines = Array(stderrLines.suffix(20))
    }
}

public enum SSHErrorClassifier {
    public static func classify(stderr: String, cancelled: Bool = false) -> SSHError {
        let lines = Array(stderr.split(whereSeparator: \.isNewline).map(String.init).suffix(20))
        let text = stderr.lowercased()
        let kind: SSHError.Kind
        let message: String
        if cancelled || ["askpass returned failure", "user cancel", "cancelled by user", "canceled by user"]
            .contains(where: { text.contains($0) }) {
            kind = .cancelled; message = "Connection cancelled."
        } else if text.contains("remote host identification has changed") || text.contains("host key verification failed") {
            kind = .hostKeyChanged; message = "The host key could not be verified. Check the SSH log."
        } else if text.contains("permission denied") || text.contains("too many authentication failures") {
            kind = .authentication; message = "Sign-in failed. Check your SSH keys or password."
        } else if ["administratively prohibited", "open failed", "session open refused", "session request failed"]
                    .contains(where: { text.contains($0) }) {
            kind = .channelRefused; message = "The server refused a shared connection channel."
        } else if ["connection timed out", "operation timed out", "connection refused", "network is unreachable",
                   "no route to host", "could not resolve hostname", "connection reset", "broken pipe",
                   "connection closed", "connection to", "connection timeout"].contains(where: { term in
                       term == "connection to" ? text.contains(term) && text.contains("closed by remote host") : text.contains(term)
                   }) {
            kind = .network; message = "The SSH connection was lost or could not be made."
        } else {
            kind = .other; message = "SSH failed. Check the SSH log."
        }
        return SSHError(kind: kind, message: message, stderrLines: lines)
    }
}
