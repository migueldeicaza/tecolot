//
// ProcessInspector.swift
// TecolotSessionHost
//
// Reads the foreground process of the session's PTY, for pane icons, the
// file-drop quoting dialect and the close confirmation.
//

import Foundation
import TecolotWire
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

enum ProcessInspector {
    static func decodeCString(_ buffer: [CChar]) -> String {
        String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static func foreground(ptyDescriptor: Int32) -> WireProcess? {
        guard ptyDescriptor >= 0 else { return nil }
        let group = tcgetpgrp(ptyDescriptor)
        guard group > 0 else { return nil }
        let path = executablePath(group) ?? ""
        let name = processName(group) ?? (path as NSString).lastPathComponent
        return WireProcess(pid: group, name: name, path: path)
    }

    static func hasChildren(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        #if canImport(Darwin)
        return proc_listchildpids(pid, nil, 0) > 0
        #else
        let path = "/proc/\(pid)/task/\(pid)/children"
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return false }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        #endif
    }

    static func executablePath(_ pid: Int32) -> String? {
        #if canImport(Darwin)
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = buffer.withUnsafeMutableBufferPointer {
            proc_pidpath(pid, $0.baseAddress, UInt32($0.count))
        }
        guard length > 0 else { return nil }
        return decodeCString(buffer)
        #else
        return try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/\(pid)/exe")
        #endif
    }

    static func processName(_ pid: Int32) -> String? {
        #if canImport(Darwin)
        var buffer = [CChar](repeating: 0, count: 256)
        let length = buffer.withUnsafeMutableBufferPointer {
            proc_name(pid, $0.baseAddress, UInt32($0.count))
        }
        guard length > 0 else { return nil }
        return decodeCString(buffer)
        #else
        guard let text = try? String(contentsOfFile: "/proc/\(pid)/comm", encoding: .utf8) else { return nil }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
        #endif
    }
}
