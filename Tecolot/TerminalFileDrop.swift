import AppKit

enum TerminalFileDrop {
    @MainActor
    static func hasFileURLs(in pasteboard: NSPasteboard) -> Bool {
        pasteboard.canReadObject(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        )
    }

    @MainActor
    static func text(from pasteboard: NSPasteboard, dialect: TerminalShellDialect) -> String? {
        guard
            let urls = pasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]
            ) as? [URL], !urls.isEmpty else {
            return nil
        }
        var arguments: [String] = []
        for url in urls {
            guard let argument = shellQuotedPath(url.path, dialect: dialect) else {
                return nil
            }
            arguments.append(argument)
        }
        return arguments.joined(separator: " ") + " "
    }

    /// Produces one literal argument at an ordinary shell argument boundary,
    /// outside an already-open quote. Never emits literal C0 or DEL characters.
    /// Unknown destinations use a compatibility fallback with no parsing guarantee.
    static func shellQuotedPath(_ path: String, dialect: TerminalShellDialect) -> String? {
        guard
            !path.unicodeScalars.contains(where: {
                $0.value == 0
            }) else {
            return nil
        }
        if dialect == .unknown {
            return fallbackEscapedPath(path)
        }

        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/_-.:")
        // Nushell expands unquoted components of three or more dots into parent paths.
        let expandsMultiDots = dialect == .nushell && path.split(separator: "/").contains {
            $0.count >= 3 && $0.allSatisfy {
                $0 == "."
            }
        }
        if
            !path.isEmpty, !expandsMultiDots, path.unicodeScalars.allSatisfy({
                safe.contains($0)
            }) {
            return path
        }
        let quote = dialect == .nushell || dialect == .elvish ? "\"" : "'"
        var result = quote
        for scalar in path.unicodeScalars {
            switch (dialect, scalar.value) {
            case (.bash, 1...31), (.bash, 127), (.zsh, 1...31), (.zsh, 127):
                result += "'$'\\x" + hex(scalar) + "''"
            case (.fish, 1...31), (.fish, 127):
                result += "'\\x" + hex(scalar) + "'"
            case (.nushell, 1...31), (.nushell, 127):
                result += "\\u{" + hex(scalar) + "}"
            case (.elvish, 1...31), (.elvish, 127):
                result += "\\x" + hex(scalar)
            case (.bash, 39), (.zsh, 39):
                result += "'\\''"
            case (.fish, 39), (.fish, 92), (.nushell, 34), (.nushell, 92),
                 (.elvish, 34), (.elvish, 92):
                result += "\\"
                result.unicodeScalars.append(scalar)
            default:
                result.unicodeScalars.append(scalar)
            }
        }
        return result + quote
    }

    private static func hex(_ scalar: Unicode.Scalar) -> String {
        let digits = String(scalar.value, radix: 16)
        return digits.count == 1 ? "0" + digits : digits
    }

    private static func fallbackEscapedPath(_ path: String) -> String {
        // Ghostty.Shell.escape's printable character set. Sanitize controls
        // first so even the generated backslashes are escaped. These paths may
        // intentionally fail to resolve; an unknown parser is not made safe.
        let escaped = CharacterSet(charactersIn: "\\ ()[]{}<>\"'`!#$&;|*?\t")
        var printable = ""
        for scalar in path.unicodeScalars {
            if scalar.value < 32 || scalar.value == 127 {
                printable += "\\x" + hex(scalar)
            } else {
                printable.unicodeScalars.append(scalar)
            }
        }
        var result = ""
        for scalar in printable.unicodeScalars {
            if escaped.contains(scalar) {
                result += "\\"
            }
            result.unicodeScalars.append(scalar)
        }
        return result
    }
}
