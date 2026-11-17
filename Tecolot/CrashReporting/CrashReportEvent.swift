//
//  CrashReportEvent.swift
//  Tecolot
//
//  Converts a macOS crash report to a Sentry event in an envelope. Sentry
//  symbolicates the addresses with the dSYMs that the release workflow
//  uploads. Tecolot makes the envelope only when the user submits a report.
//
//  The event contains: the app version and bundle identifier, the macOS
//  version and build, the Mac model and architecture, the exception, the
//  termination text, application-specific messages, the stack of each
//  thread with thread and queue names, and the loaded images. It does not
//  contain register values, instruction bytes, memory, the memory summary,
//  or the identifiers of the Mac or the user.
//
import Foundation

nonisolated enum CrashReportEvent {
    /// The tags that Tecolot adds to an event. Do not add others without a
    /// change to the crash reporting spec.
    enum Tag {
        static let appVersion = "app_version"
        static let buildNumber = "build_number"
        static let bundleIdentifier = "bundle_id"
        static let architecture = "arch"
        static let macOSVersion = "macos_version"
        static let source = "report_source"
    }

    /// The event as a JSON object. Each string in it has the home folder
    /// replaced with `~`.
    static func event(for report: DiagnosticReport, eventID: String) -> [String: Any] {
        redactingHome(in: unredactedEvent(for: report, eventID: eventID)) as? [String: Any] ?? [:]
    }

    private static func unredactedEvent(for report: DiagnosticReport, eventID: String) -> [String: Any] {
        let header = report.header
        let bundleIdentifier = header.bundleIdentifier ?? "com.tirania.Tecolot"
        let version = header.appVersion ?? "unknown"
        let build = header.buildVersion ?? "unknown"
        let architecture = report.architecture ?? "unknown"
        let osVersion = report.osVersionNumber ?? "unknown"

        var images = ImageTable(images: report.images)
        // The main executable is always in the list, so Sentry can match the
        // event with its dSYM.
        if !report.images.isEmpty {
            images.use(0)
        }

        var threadValues: [[String: Any]] = []
        for (index, thread) in report.threads.enumerated() {
            var value: [String: Any] = [
                "id": index,
                "crashed": thread.triggered,
                "current": thread.triggered
            ]
            if let name = thread.name ?? thread.queue {
                value["name"] = name
            }
            if let stacktrace = stacktrace(thread.frames, images: &images) {
                value["stacktrace"] = stacktrace
            }
            threadValues.append(value)
        }

        let faultingThread = report.faultingThread
            ?? report.threads.firstIndex(where: \.triggered)
        var exception: [String: Any] = [
            "type": report.exception?.type ?? "Crash",
            "value": exceptionValue(report),
            "mechanism": mechanism(report)
        ]
        if let faultingThread {
            exception["thread_id"] = faultingThread
        }
        // An Objective-C exception has its own backtrace, from the throw.
        // Else the exception has the stack of the crashed thread.
        // All its frames are return addresses.
        if let backtrace = report.lastExceptionBacktrace,
           let stacktrace = stacktrace(backtrace, images: &images, adjustment: "all") {
            exception["stacktrace"] = stacktrace
        } else if let faultingThread, report.threads.indices.contains(faultingThread),
                  let stacktrace = stacktrace(report.threads[faultingThread].frames, images: &images) {
            exception["stacktrace"] = stacktrace
        }

        var contexts: [String: Any] = [
            "os": compact([
                "type": "os",
                "name": "macOS",
                "version": osVersion,
                "build": report.osBuild
            ]),
            "device": compact([
                "type": "device",
                "family": "Mac",
                "model": report.modelCode,
                "arch": architecture
            ]),
            "app": compact([
                "type": "app",
                "app_identifier": bundleIdentifier,
                "app_name": header.appName,
                "app_version": version,
                "app_build": build
            ])
        ]
        var crash: [String: Any] = [:]
        if let indicator = report.terminationIndicator {
            crash["termination"] = indicator
        }
        if !report.applicationSpecificInformation.isEmpty {
            crash["application_specific_information"] = report.applicationSpecificInformation
        }
        if !crash.isEmpty {
            crash["type"] = "default"
            contexts["crash"] = crash
        }

        var event: [String: Any] = [
            "event_id": eventID,
            "platform": "native",
            "level": "fatal",
            "release": "\(bundleIdentifier)@\(version)+\(build)",
            "dist": build,
            "environment": "production",
            "tags": [
                Tag.appVersion: version,
                Tag.buildNumber: build,
                Tag.bundleIdentifier: bundleIdentifier,
                Tag.architecture: architecture,
                Tag.macOSVersion: osVersion,
                Tag.source: "macos-ips"
            ],
            "contexts": contexts,
            "exception": ["values": [exception]],
            "threads": ["values": threadValues],
            "debug_meta": ["images": images.debugImages]
        ]
        if let date = report.crashDate {
            event["timestamp"] = date.timeIntervalSince1970
        }
        return event
    }

    /// A Sentry envelope with one event item.
    static func envelope(for report: DiagnosticReport, eventID: String, clientVersion: String, now: Date = Date()) throws -> Data {
        let event = event(for: report, eventID: eventID)
        let payload = try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys, .withoutEscapingSlashes])
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let envelopeHeader: [String: Any] = [
            "event_id": eventID,
            "sent_at": formatter.string(from: now),
            "sdk": ["name": "tecolot.ips", "version": clientVersion]
        ]
        let itemHeader: [String: Any] = [
            "type": "event",
            "length": payload.count,
            "content_type": "application/json"
        ]
        var data = try JSONSerialization.data(withJSONObject: envelopeHeader, options: [.sortedKeys])
        data.append(0x0A)
        data.append(try JSONSerialization.data(withJSONObject: itemHeader, options: [.sortedKeys]))
        data.append(0x0A)
        data.append(payload)
        data.append(0x0A)
        return data
    }

    // MARK: Parts

    /// For example "SIGSEGV: KERN_INVALID_ADDRESS at 0x10". A message from
    /// a library, for example a Swift runtime error, comes at the end.
    static func exceptionValue(_ report: DiagnosticReport) -> String {
        var parts: [String] = []
        if let signal = report.exception?.signal {
            parts.append(signal)
        }
        if let subtype = report.exception?.subtype {
            parts.append(subtype)
        }
        if let message = report.exception?.message {
            parts.append(message)
        }
        if parts.isEmpty, let indicator = report.terminationIndicator {
            parts.append(indicator)
        }
        var value = parts.joined(separator: ": ")
        let messages = report.applicationSpecificInformation.keys.sorted()
            .flatMap { report.applicationSpecificInformation[$0] ?? [] }
            .filter { !$0.isEmpty && $0 != "abort() called" }
        if let first = messages.first {
            value += value.isEmpty ? first : " — \(first)"
        }
        return value.isEmpty ? "Tecolot quit unexpectedly" : value
    }

    static func mechanism(_ report: DiagnosticReport) -> [String: Any] {
        var meta: [String: Any] = [:]
        if let name = report.exception?.type, let number = machExceptionNumbers[name] {
            let codes = report.exception?.rawCodes ?? []
            meta["mach_exception"] = [
                "name": name,
                "exception": number,
                "code": codes.count > 0 ? codes[0] : 0,
                "subcode": codes.count > 1 ? codes[1] : 0
            ]
        }
        if let name = report.exception?.signal {
            var signal: [String: Any] = ["name": name]
            if report.terminationNamespace == "SIGNAL", let code = report.terminationCode {
                signal["number"] = code
            } else if let number = signalNumbers[name] {
                signal["number"] = number
            }
            meta["signal"] = signal
        }
        var mechanism: [String: Any] = ["type": "mach", "handled": false]
        if !meta.isEmpty {
            mechanism["meta"] = meta
        }
        return mechanism
    }

    static let machExceptionNumbers: [String: Int] = [
        "EXC_BAD_ACCESS": 1, "EXC_BAD_INSTRUCTION": 2, "EXC_ARITHMETIC": 3,
        "EXC_EMULATION": 4, "EXC_SOFTWARE": 5, "EXC_BREAKPOINT": 6,
        "EXC_SYSCALL": 7, "EXC_MACH_SYSCALL": 8, "EXC_RPC_ALERT": 9,
        "EXC_CRASH": 10, "EXC_RESOURCE": 11, "EXC_GUARD": 12,
        "EXC_CORPSE_NOTIFY": 13
    ]

    static let signalNumbers: [String: Int] = [
        "SIGILL": 4, "SIGTRAP": 5, "SIGABRT": 6, "SIGFPE": 8, "SIGKILL": 9,
        "SIGBUS": 10, "SIGSEGV": 11, "SIGSYS": 12, "SIGPIPE": 13, "SIGTERM": 15
    ]

    /// A Sentry stack trace: the oldest call first. Inline frames are not
    /// sent, because Sentry finds them again from the dSYM.
    /// `adjustment` tells Sentry which addresses are return addresses. In a
    /// thread stack, the first frame is the current instruction.
    static func stacktrace(
        _ frames: [DiagnosticReport.Frame],
        images: inout ImageTable,
        adjustment: String = "all_but_first"
    ) -> [String: Any]? {
        var result: [[String: Any]] = []
        for frame in frames where !frame.isInline {
            guard let index = frame.imageIndex, let offset = frame.imageOffset,
                  let image = images.use(index) else { continue }
            let address = image.base &+ offset
            var value: [String: Any] = [
                "instruction_addr": hex(address),
                "image_addr": hex(image.base),
                "in_app": images.isInApp(index)
            ]
            if let path = image.path {
                value["package"] = path
            }
            if let symbol = frame.symbol {
                value["function"] = symbol
                if let location = frame.symbolLocation, location <= offset {
                    value["symbol_addr"] = hex(address &- location)
                }
            }
            result.append(value)
        }
        guard !result.isEmpty else { return nil }
        return [
            "frames": Array(result.reversed()),
            "instruction_addr_adjustment": adjustment
        ]
    }

    /// The images that the event refers to, as Sentry debug images.
    struct ImageTable {
        let images: [DiagnosticReport.Image]
        private var used: Set<Int> = []

        /// The app bundle path, from the main executable, image 0.
        private let bundlePrefix: String?

        init(images: [DiagnosticReport.Image]) {
            self.images = images
            if let main = images.first?.path, let range = main.range(of: ".app/Contents/") {
                bundlePrefix = String(main[..<range.lowerBound]) + ".app/"
            } else {
                bundlePrefix = nil
            }
        }

        @discardableResult
        mutating func use(_ index: Int) -> DiagnosticReport.Image? {
            guard images.indices.contains(index) else { return nil }
            used.insert(index)
            return images[index]
        }

        /// The main executable and the images in the app bundle.
        func isInApp(_ index: Int) -> Bool {
            guard images.indices.contains(index) else { return false }
            if index == 0 { return true }
            guard let bundlePrefix, let path = images[index].path else { return false }
            return path.hasPrefix(bundlePrefix)
        }

        var debugImages: [[String: Any]] {
            used.sorted().compactMap { index in
                let image = images[index]
                guard let uuid = image.uuid, !uuid.isEmpty else { return nil }
                return compact([
                    "type": "macho",
                    "debug_id": uuid.lowercased(),
                    "code_file": image.path,
                    "image_addr": hex(image.base),
                    "image_size": image.size,
                    "arch": image.arch
                ])
            }
        }
    }

    static func hex(_ value: UInt64) -> String {
        "0x" + String(value, radix: 16)
    }

    /// macOS writes user paths as /Users/USER/*. This also replaces the
    /// home folder in any text, for example in an error message.
    static func redactHome(_ text: String, home: String = NSHomeDirectory()) -> String {
        guard home.count > 1, text.contains(home) else { return text }
        var result = ""
        var rest = Substring(text)
        while let range = rest.range(of: home) {
            // Replace only a whole path component: /Users/ann, not /Users/anna.
            let next = rest[range.upperBound...].first
            if next == nil || next == "/" || !(next!.isLetter || next!.isNumber || next == "_" || next == "-" || next == ".") {
                result += rest[..<range.lowerBound] + "~"
            } else {
                result += rest[..<range.upperBound]
            }
            rest = rest[range.upperBound...]
        }
        return result + rest
    }

    /// Applies `redactHome` to every string in a JSON object.
    static func redactingHome(in value: Any, home: String = NSHomeDirectory()) -> Any {
        switch value {
        case let string as String:
            return redactHome(string, home: home)
        case let dictionary as [String: Any]:
            return dictionary.mapValues { redactingHome(in: $0, home: home) }
        case let array as [Any]:
            return array.map { redactingHome(in: $0, home: home) }
        default:
            return value
        }
    }

    private static func compact(_ values: [String: Any?]) -> [String: Any] {
        values.compactMapValues { $0 }
    }
}
