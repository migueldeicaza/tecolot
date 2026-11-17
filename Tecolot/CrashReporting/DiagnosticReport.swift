//
//  DiagnosticReport.swift
//  Tecolot
//
//  Reads a macOS crash report (`.ips`, version 2). The file has two JSON
//  documents: a one-line header, then the report body. Tecolot reads only
//  the fields below. It does not read register values, instruction bytes,
//  the memory summary, or the identifiers of the Mac.
//
import Foundation

nonisolated struct DiagnosticReport: Sendable {
    nonisolated struct Header: Sendable, Equatable {
        var incidentID: String
        var bundleIdentifier: String?
        var appName: String?
        var appVersion: String?
        var buildVersion: String?
        var timestamp: String?
        /// For example "macOS 27.0.1 (26A434)".
        var osVersion: String?
        var bugType: String?
    }

    nonisolated struct Exception: Sendable, Equatable {
        var type: String?
        var signal: String?
        var subtype: String?
        var message: String?
        var rawCodes: [UInt64]
    }

    nonisolated struct Frame: Sendable, Equatable {
        var imageIndex: Int?
        var imageOffset: UInt64?
        var symbol: String?
        var symbolLocation: UInt64?
        var sourceFile: String?
        var sourceLine: Int?
        /// An inlined function. Its address is the same as the next frame's.
        var isInline: Bool
    }

    nonisolated struct Thread: Sendable, Equatable {
        var name: String?
        var queue: String?
        var triggered: Bool
        var frames: [Frame]
    }

    nonisolated struct Image: Sendable, Equatable {
        var name: String?
        var path: String?
        var uuid: String?
        var base: UInt64
        var size: UInt64
        var arch: String?
    }

    var header: Header
    var captureTime: String?
    var modelCode: String?
    var cpuType: String?
    var osTrain: String?
    var osBuild: String?
    var exception: Exception?
    /// The termination text, for example "Segmentation fault: 11".
    var terminationIndicator: String?
    var terminationNamespace: String?
    var terminationCode: Int64?
    /// Application-specific information: messages that libraries set before
    /// a crash, for example a Swift runtime error. Keyed by library name.
    var applicationSpecificInformation: [String: [String]]
    var faultingThread: Int?
    var threads: [Thread]
    /// The backtrace of an Objective-C exception that ended the process.
    var lastExceptionBacktrace: [Frame]?
    var images: [Image]

    /// Parses only the first line. Throws `.otherKind` for a report that is
    /// not a crash. Returns the header and the start of the body.
    static func parseHeader(_ data: Data) throws -> (header: Header, bodyStart: Data.Index) {
        guard let newline = data.firstIndex(of: 0x0A) else {
            throw CrashReportStoreError.notACrashReport
        }
        guard let header = try? JSONSerialization.jsonObject(with: data[data.startIndex..<newline]) as? [String: Any],
              let incidentID = header["incident_id"] as? String,
              UUID(uuidString: incidentID) != nil else {
            throw CrashReportStoreError.notACrashReport
        }
        let result = Header(
            incidentID: incidentID.uppercased(),
            bundleIdentifier: header["bundleID"] as? String,
            appName: header["app_name"] as? String,
            appVersion: header["app_version"] as? String,
            buildVersion: header["build_version"] as? String,
            timestamp: header["timestamp"] as? String,
            osVersion: header["os_version"] as? String,
            bugType: header["bug_type"] as? String
        )
        guard result.bugType == "309" else {
            throw CrashReportStoreError.otherKind
        }
        return (result, data.index(after: newline))
    }

    init(data: Data) throws {
        let (header, bodyStart) = try Self.parseHeader(data)
        self.header = header

        guard let body = try? JSONSerialization.jsonObject(with: data[bodyStart...]) as? [String: Any] else {
            throw CrashReportStoreError.notACrashReport
        }
        captureTime = body["captureTime"] as? String
        modelCode = body["modelCode"] as? String
        cpuType = body["cpuType"] as? String
        let os = body["osVersion"] as? [String: Any]
        osTrain = os?["train"] as? String
        osBuild = os?["build"] as? String

        if let exception = body["exception"] as? [String: Any] {
            self.exception = Exception(
                type: exception["type"] as? String,
                signal: exception["signal"] as? String,
                subtype: exception["subtype"] as? String,
                message: exception["message"] as? String,
                rawCodes: (exception["rawCodes"] as? [Any] ?? []).compactMap(Self.unsigned)
            )
        }
        let termination = body["termination"] as? [String: Any]
        terminationIndicator = termination?["indicator"] as? String
        terminationNamespace = termination?["namespace"] as? String
        terminationCode = (termination?["code"] as? NSNumber)?.int64Value

        var asi: [String: [String]] = [:]
        for (library, value) in body["asi"] as? [String: Any] ?? [:] {
            if let lines = value as? [String] {
                asi[library] = lines
            } else if let line = value as? String {
                asi[library] = [line]
            }
        }
        applicationSpecificInformation = asi
        faultingThread = (body["faultingThread"] as? NSNumber)?.intValue

        threads = (body["threads"] as? [[String: Any]] ?? []).map { thread in
            Thread(
                name: thread["name"] as? String,
                queue: thread["queue"] as? String,
                triggered: thread["triggered"] as? Bool ?? false,
                frames: Self.frames(thread["frames"])
            )
        }
        if let backtrace = body["lastExceptionBacktrace"] {
            lastExceptionBacktrace = Self.frames(backtrace)
        }
        images = (body["usedImages"] as? [[String: Any]] ?? []).map { image in
            Image(
                name: image["name"] as? String,
                path: image["path"] as? String,
                uuid: image["uuid"] as? String,
                base: Self.unsigned(image["base"]) ?? 0,
                size: Self.unsigned(image["size"]) ?? 0,
                arch: image["arch"] as? String
            )
        }
        guard exception != nil || !threads.isEmpty else {
            throw CrashReportStoreError.notACrashReport
        }
    }

    /// The crash time. macOS writes "2026-11-15 22:28:05.9862 -0500".
    var crashDate: Date? {
        for value in [captureTime, header.timestamp].compactMap({ $0 }) {
            if let date = Self.parseDate(value) {
                return date
            }
        }
        return nil
    }

    /// For example "EXC_BAD_ACCESS (SIGSEGV)".
    var exceptionSummary: String? {
        guard let exception else { return terminationIndicator }
        switch (exception.type, exception.signal) {
        case let (type?, signal?): return "\(type) (\(signal))"
        case let (type?, nil): return type
        case let (nil, signal?): return signal
        default: return terminationIndicator
        }
    }

    /// The version from the OS train, for example "27.0.1".
    var osVersionNumber: String? {
        let source = osTrain ?? header.osVersion
        return source?.split(separator: " ").first { $0.first?.isNumber == true }.map(String.init)
    }

    /// The architecture of the main executable, for example "arm64".
    var architecture: String? {
        if let arch = images.first?.arch { return arch }
        switch cpuType {
        case "ARM-64": return "arm64"
        case "X86-64": return "x86_64"
        default: return nil
        }
    }

    static func parseDate(_ string: String) -> Date? {
        for formatter in dateFormatters {
            if let date = formatter.date(from: string) {
                return date
            }
        }
        return nil
    }

    /// The formatters are made one time and not changed after this.
    private static let dateFormatters: [DateFormatter] =
        ["yyyy-MM-dd HH:mm:ss.SSSS Z", "yyyy-MM-dd HH:mm:ss.SS Z", "yyyy-MM-dd HH:mm:ss Z"].map { format in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            return formatter
        }

    private static func frames(_ value: Any?) -> [Frame] {
        (value as? [[String: Any]] ?? []).map { frame in
            Frame(
                imageIndex: (frame["imageIndex"] as? NSNumber)?.intValue,
                imageOffset: unsigned(frame["imageOffset"]),
                symbol: frame["symbol"] as? String,
                symbolLocation: unsigned(frame["symbolLocation"]),
                sourceFile: frame["sourceFile"] as? String,
                sourceLine: (frame["sourceLine"] as? NSNumber)?.intValue,
                isInline: frame["inline"] as? Bool ?? false
            )
        }
    }

    /// A JSON number as UInt64. JSONSerialization gives a value above
    /// Int64.max as an NSNumber of type "Q", or on some systems as an
    /// NSDecimalNumber. A negative or fractional value is nil.
    static func unsigned(_ value: Any?) -> UInt64? {
        if let decimal = value as? NSDecimalNumber {
            return UInt64(decimal.stringValue)
        }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return nil
        }
        switch String(cString: number.objCType) {
        case "Q", "L", "I", "S", "C":
            return number.uint64Value
        case "f", "d":
            let double = number.doubleValue
            guard double >= 0, double < 18_446_744_073_709_551_616, double.rounded() == double else { return nil }
            return UInt64(double)
        default:
            return number.int64Value >= 0 ? UInt64(number.int64Value) : nil
        }
    }
}
