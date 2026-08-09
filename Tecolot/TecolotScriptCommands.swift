//
//  TecolotScriptCommands.swift
//  Tecolot
//
//  AppleScript commands declared in Tecolot.sdef.
//

import AppKit

@objc(OpenTerminalScriptCommand)
final class OpenTerminalScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        let directory = directParameter as? String
        WindowOpener.openWindow(spec: LaunchSpec(workingDirectory: directory))
        return nil
    }
}

@objc(OpenTerminalTabScriptCommand)
final class OpenTerminalTabScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        var spec = WindowOpener.inheritedTabSpec()
        if let directory = directParameter as? String, !directory.isEmpty {
            spec.workingDirectory = directory
        }
        WindowOpener.openTab(spec: spec)
        return nil
    }
}
