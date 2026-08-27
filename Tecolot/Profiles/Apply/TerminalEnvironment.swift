//
//  TerminalEnvironment.swift
//  Tecolot
//
//  Builds the complete environment for a terminal child process.
//

import Foundation

/// A profile-specific environment change.
///
/// A nil value removes a variable inherited from the app. An empty string is
/// a real, empty value. Later entries with the same name take precedence.
public struct TerminalEnvironmentVariable: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var value: String?

    public init(id: UUID = UUID(), name: String, value: String?) {
        self.id = id
        self.name = name
        self.value = value
    }
}

/// Creates the environment passed to a terminal child process.
///
/// The parent environment is the base. Terminal identity values are replaced
/// so a nested terminal does not identify itself as its parent terminal.
public enum TerminalEnvironment {
    private static let localeVariables = ["LC_ALL", "LC_CTYPE", "LANG"]

    private static let staleTerminalVariables: Set<String> = [
        "TERM",
        "TERMINFO",
        "TERMINFO_DIRS",
        "COLORTERM",
        "TERM_PROGRAM",
        "TERM_PROGRAM_VERSION",
        "TERM_FEATURES",
        "TERM_VERSION",
        "TERM_SESSION_ID",
        "ITERM_SESSION_ID",
        "VTE_VERSION",
        "GHOSTTY_RESOURCES_DIR",
        "GHOSTTY_SURFACE_ID",
        "GHOSTTY_SHELL_FEATURES",
        "WEZTERM_PANE",
        "WEZTERM_EXECUTABLE",
        "KITTY_PID",
        "KITTY_WINDOW_ID",
        "TECOLOT_RESOURCES_DIR",
        "TECOLOT_SHELL_FEATURES",
        "TECOLOT_ZSH_ZDOTDIR",
        "TECOLOT_SHELL_INTEGRATION_XDG_DIR",
        "TECOLOT_BASH_ENV",
        "TECOLOT_BASH_RCFILE",
        "TECOLOT_BASH_INJECT",
        "TECOLOT_BASH_UNEXPORT_HISTFILE"
    ]

    private static let shellStateVariables: Set<String> = [
        "PWD",
        "OLDPWD",
        "SHLVL",
        "_"
    ]

    private static let xcodeVariables: Set<String> = [
        "__XCODE_BUILT_PRODUCTS_DIR_PATHS",
        "__XPC_DYLD_LIBRARY_PATH",
        "DYLD_FRAMEWORK_PATH",
        "DYLD_INSERT_LIBRARIES",
        "DYLD_LIBRARY_PATH",
        "LD_LIBRARY_PATH",
        "SECURITYSESSIONID",
        "XPC_SERVICE_NAME"
    ]

    /// Returns the inherited environment with Tecolot's terminal values.
    public static func base(
        parentEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        termName: String
    ) -> [String] {
        var environment = parentEnvironment

        staleTerminalVariables.union(shellStateVariables).forEach {
            environment.removeValue(forKey: $0)
        }

        // Xcode adds these to the launched app. They can make child commands
        // load development libraries instead of the versions installed by macOS.
        if environment["__XCODE_BUILT_PRODUCTS_DIR_PATHS"] != nil {
            xcodeVariables.forEach { environment.removeValue(forKey: $0) }
        }

        // Finder and LaunchServices usually provide no locale variables. A
        // UTF-8 default keeps terminal programs able to process non-ASCII text.
        if !localeVariables.contains(where: { !(environment[$0]?.isEmpty ?? true) }) {
            environment["LANG"] = "en_US.UTF-8"
        }

        environment["TERM"] = termName
        if let resourceURL = Bundle.main.resourceURL {
            environment["TERMINFO"] = resourceURL
                .appendingPathComponent("terminfo", isDirectory: true)
                .path
        }
        environment["COLORTERM"] = "truecolor"
        environment["TERM_FEATURES"] = TerminalFeatureReporting.featureString
        return encoded(environment)
    }

    /// Applies the profile's final set and unset operations.
    public static func applying(
        _ overrides: [TerminalEnvironmentVariable],
        to environment: [String]
    ) -> [String] {
        var values = decoded(environment)
        for entry in overrides where isValidName(entry.name) {
            if let value = entry.value, !value.contains("\0") {
                values[entry.name] = value
            } else {
                values.removeValue(forKey: entry.name)
            }
        }
        return encoded(values)
    }

    /// Applies the terminal identity values for the selected TERM name.
    public static func applyingTerminalIdentity(
        termName: String,
        termProgram: String,
        termVersion: String,
        to environment: [String]
    ) -> [String] {
        var identity = [
            TerminalEnvironmentVariable(name: "TERM_PROGRAM_VERSION", value: nil),
            TerminalEnvironmentVariable(name: "TERM_PROGRAM", value: nil),
            TerminalEnvironmentVariable(name: "TERM_VERSION", value: nil)
        ]
        if termName == "xterm-ghostty" {
            identity[1].value = termProgram
            identity[2].value = termVersion
        }
        return applying(identity, to: environment)
    }

    private static func decoded(_ environment: [String]) -> [String: String] {
        environment.reduce(into: [:]) { result, entry in
            guard let separator = entry.firstIndex(of: "=") else { return }
            result[String(entry[..<separator])] = String(entry[entry.index(after: separator)...])
        }
    }

    private static func encoded(_ environment: [String: String]) -> [String] {
        environment.keys.sorted().compactMap { name in
            guard let value = environment[name] else { return nil }
            return "\(name)=\(value)"
        }
    }

    private static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("=") && !name.contains("\0")
    }
}
