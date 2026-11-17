import CSentryNative
import Foundation

/// The binary in this package uses Sentry Native and the Breakpad backend.
public enum SentryNativeBreakpad {
    public static var sdkVersion: String {
        String(cString: sentry_sdk_version())
    }
}

/// A crash event envelope that the SDK gives to the local transport.
public struct LocalCrashEnvelope: Sendable {
    /// The event ID from the envelope's event item.
    public let eventID: String
    /// The complete serialized Sentry envelope.
    public let data: Data
}

/// Starts Sentry Native with Breakpad and a local transport.
///
/// The reporter has no DSN and no HTTP transport. Breakpad writes a pending
/// crash envelope into the SDK database when the process crashes. During the
/// next `start(_:)`, the SDK gives that envelope to `saveCrashEnvelope`. The
/// SDK deletes its pending copy after the handler returns, even when the
/// handler fails to save it.
public enum LocalCrashReporter {
    public struct Configuration: Sendable {
        /// The SDK working database. Use a Caches directory.
        public var databaseURL: URL
        /// The Sentry release value, for example `tecolot@1.0 (42)`.
        public var release: String
        /// Tags that the SDK adds to each event.
        public var tags: [String: String]
        /// Receives each crash event envelope. Envelopes without an event item
        /// are discarded before this call. The SDK calls it synchronously from
        /// `start(_:)` for crashes from earlier runs. It is never called from a
        /// signal handler.
        public var saveCrashEnvelope: @Sendable (LocalCrashEnvelope) -> Void

        public init(
            databaseURL: URL,
            release: String,
            tags: [String: String],
            saveCrashEnvelope: @escaping @Sendable (LocalCrashEnvelope) -> Void
        ) {
            self.databaseURL = databaseURL
            self.release = release
            self.tags = tags
            self.saveCrashEnvelope = saveCrashEnvelope
        }
    }

    public struct StartError: Error, CustomStringConvertible, Sendable {
        public let code: Int32
        public var description: String { "sentry_init failed with code \(code)" }
    }

    private final class TransportState {
        let save: @Sendable (LocalCrashEnvelope) -> Void

        init(save: @escaping @Sendable (LocalCrashEnvelope) -> Void) {
            self.save = save
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var started = false

    public static var isRunning: Bool {
        lock.withLock { started }
    }

    /// Starts the SDK and installs the crash handler. Call this once, early.
    public static func start(_ configuration: Configuration) throws {
        try lock.withLock {
            guard !started else { return }

            guard let options = sentry_options_new() else {
                throw StartError(code: -1)
            }
            sentry_options_set_database_path(options, configuration.databaseURL.path)
            sentry_options_set_release(options, configuration.release)
            sentry_options_set_auto_session_tracking(options, 0)
            sentry_options_set_debug(options, 0)

            let state = TransportState(save: configuration.saveCrashEnvelope)
            guard let transport = sentry_transport_new({ envelope, state in
                guard let envelope else { return }
                defer { sentry_envelope_free(envelope) }
                guard let state else { return }
                let transportState = Unmanaged<TransportState>.fromOpaque(state).takeUnretainedValue()
                guard let crashEnvelope = LocalCrashReporter.crashEnvelope(from: envelope) else {
                    return
                }
                transportState.save(crashEnvelope)
            }) else {
                sentry_options_free(options)
                throw StartError(code: -2)
            }
            sentry_transport_set_state(transport, Unmanaged.passRetained(state).toOpaque())
            sentry_transport_set_free_func(transport) { state in
                guard let state else { return }
                Unmanaged<TransportState>.fromOpaque(state).release()
            }
            sentry_options_set_transport(options, transport)

            // sentry_init takes ownership of the options, also on failure.
            let result = sentry_init(options)
            guard result == 0 else {
                throw StartError(code: result)
            }
            // A null user stops the SDK from adding its persistent
            // installation ID as `user.id`.
            sentry_set_user(sentry_value_new_null())
            for (key, value) in configuration.tags.sorted(by: { $0.key < $1.key }) {
                sentry_set_tag(key, value)
            }
            started = true
        }
    }

    /// Closes the SDK during a normal quit. The crash handler can stay
    /// installed. Do not rely on this call for fatal crashes.
    public static func close() {
        lock.withLock {
            guard started else { return }
            sentry_close()
            started = false
        }
    }

    /// Returns the serialized envelope only when it contains an event item
    /// with an event ID. An envelope that the SDK loads from its database is
    /// in raw form, so the check parses the serialized bytes.
    private static func crashEnvelope(from envelope: OpaquePointer) -> LocalCrashEnvelope? {
        var size = 0
        guard let bytes = sentry_envelope_serialize(envelope, &size) else { return nil }
        defer { sentry_free(bytes) }
        guard size > 0 else { return nil }
        let data = Data(bytes: bytes, count: size)
        guard let parsed = try? SentryEnvelope(data: data),
              parsed.containsEvent,
              let eventID = parsed.eventID else {
            return nil
        }
        return LocalCrashEnvelope(eventID: eventID, data: data)
    }
}
