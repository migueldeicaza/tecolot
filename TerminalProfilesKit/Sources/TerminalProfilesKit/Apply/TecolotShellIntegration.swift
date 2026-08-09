//
//  TecolotShellIntegration.swift
//  TerminalProfilesKit
//
//  Adds terminal identity and automatic shell integration to child processes.
//

import Foundation

public enum TecolotShellIntegration {
    public static let terminalProgram = "tecolot"
    /// Shell integration must not change the profile's cursor shape or blink
    /// state. Applications inside the terminal can still request a style.
    public static let shellFeatures = "title"

    /// The directory that contains Tecolot's installable shell integration.
    public static var resourcesDirectory: URL? {
        guard let directory = Bundle.module.resourceURL else { return nil }
        let integration = directory.appendingPathComponent("shell-integration", isDirectory: true)
        guard FileManager.default.fileExists(atPath: integration.path) else { return nil }
        return directory
    }

    /// The version that child processes receive in TERM_PROGRAM_VERSION.
    public static var terminalProgramVersion: String {
        let info = Bundle.main.infoDictionary
        return info?["CFBundleShortVersionString"] as? String
            ?? info?["CFBundleVersion"] as? String
            ?? "unknown"
    }

    /// Adds Tecolot variables and, for a supported interactive shell, updates
    /// the launch arguments and environment to load the bundled integration.
    public static func configure(
        _ parameters: LaunchParameters,
        automatic: Bool,
        resourcesDirectory: URL? = resourcesDirectory,
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        terminalProgramVersion: String = terminalProgramVersion
    ) -> LaunchParameters {
        var result = parameters
        set("TERM_PROGRAM", terminalProgram, in: &result.environment)
        set("TERM_PROGRAM_VERSION", terminalProgramVersion, in: &result.environment)
        set("TECOLOT_SHELL_FEATURES", shellFeatures, in: &result.environment)

        guard let resourcesDirectory else { return result }
        let resourcesPath = resourcesDirectory.standardizedFileURL.path
        set("TECOLOT_RESOURCES_DIR", resourcesPath, in: &result.environment)
        guard automatic else { return result }

        let shell = URL(fileURLWithPath: result.executable).lastPathComponent
        switch shell {
        case "bash":
            configureBash(
                &result,
                resourcesPath: resourcesPath,
                processEnvironment: processEnvironment
            )
        case "elvish", "fish":
            configureXDG(
                &result.environment,
                resourcesPath: resourcesPath,
                processEnvironment: processEnvironment
            )
        case "nu":
            configureXDG(
                &result.environment,
                resourcesPath: resourcesPath,
                processEnvironment: processEnvironment
            )
            if supportsNushellInjection(arguments: result.args) {
                result.args.insert(contentsOf: ["--execute", "use tecolot *"], at: 0)
            }
        case "zsh":
            configureZsh(
                &result.environment,
                resourcesPath: resourcesPath,
                processEnvironment: processEnvironment
            )
        default:
            break
        }

        return result
    }

    private static func configureBash(
        _ parameters: inout LaunchParameters,
        resourcesPath: String,
        processEnvironment: [String: String]
    ) {
        // Apple's Bash does not load ENV for this POSIX startup sequence.
        guard parameters.executable != "/bin/bash" else { return }
        let script = resourcesPath + "/shell-integration/bash/tecolot.bash"
        guard FileManager.default.isReadableFile(atPath: script) else { return }

        var injectionFlags = ["1"]
        var filteredArguments: [String] = []
        var index = parameters.args.startIndex
        while index < parameters.args.endIndex {
            let argument = parameters.args[index]
            if argument == "-" || argument == "--" {
                filteredArguments.append(contentsOf: parameters.args[index...])
                break
            }
            if argument == "--posix" || isShortOption(argument, containing: "c") {
                return
            }
            if argument == "--norc" || argument == "--noprofile" {
                injectionFlags.append(argument)
            } else if argument == "--rcfile" || argument == "--init-file" {
                let valueIndex = parameters.args.index(after: index)
                guard valueIndex < parameters.args.endIndex else { return }
                set("TECOLOT_BASH_RCFILE", parameters.args[valueIndex], in: &parameters.environment)
                index = valueIndex
            } else {
                filteredArguments.append(argument)
            }
            index = parameters.args.index(after: index)
        }

        if let oldEnvironment = value(for: "ENV", in: parameters.environment)
            ?? processEnvironment["ENV"] {
            set("TECOLOT_BASH_ENV", oldEnvironment, in: &parameters.environment)
        }
        set("ENV", script, in: &parameters.environment)
        set("TECOLOT_BASH_INJECT", injectionFlags.joined(separator: " "), in: &parameters.environment)

        if value(for: "HISTFILE", in: parameters.environment) == nil {
            if let historyFile = processEnvironment["HISTFILE"] {
                set("HISTFILE", historyFile, in: &parameters.environment)
            } else if let home = value(for: "HOME", in: parameters.environment)
                ?? processEnvironment["HOME"] {
                set("HISTFILE", home + "/.bash_history", in: &parameters.environment)
                set("TECOLOT_BASH_UNEXPORT_HISTFILE", "1", in: &parameters.environment)
            }
        }
        parameters.args = ["--posix"] + filteredArguments
    }

    private static func configureXDG(
        _ environment: inout [String],
        resourcesPath: String,
        processEnvironment: [String: String]
    ) {
        let integrationPath = resourcesPath + "/shell-integration"
        let oldValue = value(for: "XDG_DATA_DIRS", in: environment)
            ?? processEnvironment["XDG_DATA_DIRS"]
            ?? "/usr/local/share:/usr/share"
        let paths = oldValue.split(separator: ":").map(String.init)
        let newValue = ([integrationPath] + paths.filter { $0 != integrationPath })
            .joined(separator: ":")
        set("TECOLOT_SHELL_INTEGRATION_XDG_DIR", integrationPath, in: &environment)
        set("XDG_DATA_DIRS", newValue, in: &environment)
    }

    private static func configureZsh(
        _ environment: inout [String],
        resourcesPath: String,
        processEnvironment: [String: String]
    ) {
        if let oldDirectory = value(for: "ZDOTDIR", in: environment)
            ?? processEnvironment["ZDOTDIR"] {
            set("TECOLOT_ZSH_ZDOTDIR", oldDirectory, in: &environment)
        }
        set("ZDOTDIR", resourcesPath + "/shell-integration/zsh", in: &environment)
    }

    private static func supportsNushellInjection(arguments: [String]) -> Bool {
        for argument in arguments {
            if argument == "-" || argument == "--" { return true }
            if argument == "--command"
                || argument == "--lsp"
                || isShortOption(argument, containing: "c") {
                return false
            }
        }
        return true
    }

    private static func isShortOption(_ argument: String, containing option: Character) -> Bool {
        argument.first == "-"
            && !argument.hasPrefix("--")
            && argument.dropFirst().contains(option)
    }

    private static func value(for name: String, in environment: [String]) -> String? {
        let prefix = name + "="
        guard let entry = environment.last(where: { $0.hasPrefix(prefix) }) else { return nil }
        return String(entry.dropFirst(prefix.count))
    }

    private static func set(_ name: String, _ value: String, in environment: inout [String]) {
        let prefix = name + "="
        environment.removeAll { $0.hasPrefix(prefix) }
        environment.append(prefix + value)
    }
}
