# Sentry Native with Breakpad for macOS

This Swift package contains a static Sentry Native library with the Breakpad crash backend. It builds for arm64 and x86_64 on macOS 15.5 or later. It has no HTTP transport and needs no separate crash handler process.

The build pins Sentry Native 0.17.6 at `7afc37457d7fcc37fb0bace9c8045d3fa687717f`. The build script obtains the Breakpad revision from that source tree. The package includes both licenses in `Licenses/`.

## Products

- `SentryNativeBreakpad.sdkVersion` gives the SDK version.
- `LocalCrashReporter` starts the SDK with a local transport and no DSN. It accepts only envelopes with an `event` item and gives each one to a Swift closure. It removes the SDK's installation ID from events.
- `SentryEnvelope` is a strict envelope reader. It rejects partial files.
- `import CSentryNative` gives the complete C API.

## Binary download

`Package.swift` uses `.binaryTarget(name:url:checksum:)`. The ZIP is the `sentry-native-0.17.6` release asset of the Tecolot repository. Xcode and SwiftPM download it and verify its checksum when they resolve packages. No Makefile step is necessary. `Tecolot.xcodeproj` references this directory as a local package.

Do not replace the published ZIP. A new build needs a new release tag, a new URL, and a new checksum in `Package.swift`.

## Build from source

From the Tecolot repository root, run:

```sh
make sentry-native
SENTRY_NATIVE_LOCAL=1 swift build -c release --package-path tools/SentryNativeBreakpad
```

The Makefile runs `build.sh` only when the XCFramework is absent or the script changed. The script downloads the pinned source and builds `Artifacts/CSentryNative.xcframework`. It needs Xcode command line tools, CMake, and Git. `Artifacts/`, `.build/`, and `.build-native/` are ignored by Git. No compiled Sentry or Breakpad files belong in a commit.

`SENTRY_NATIVE_LOCAL=1` makes the manifest use the local XCFramework instead of the published ZIP. The `Sentry Native` workflow (`.github/workflows/sentry-native.yml`) uses it to check the source build. That workflow runs only when this package, its licenses in the app, or the Makefile change.

When the pinned version changes, `build.sh` moves an existing clone to the new tag and removes the old CMake cache.

## Publish a new build

1. Change the pinned version in `build.sh` and `archive.sh`.
2. Run `make sentry-native-archive`. It writes the ZIP and prints its SwiftPM checksum.
3. Create a new prerelease, for example `sentry-native-<version>`, with the ZIP as its only asset. Do not mark it as the latest release.
4. Download the asset and check that `swift package compute-checksum` gives the same checksum.
5. Change the URL and checksum in `Package.swift`.

## SDK behavior

These facts come from the Sentry Native 0.17.6 source:

- At a crash, Breakpad writes a minidump. The SDK puts the crash event and the minidump into an envelope in its database. The transport is suspended in the crash handler, so no transport code runs there.
- During the next `sentry_init`, the SDK reads the pending envelope and calls the transport synchronously. The envelope is in raw form at that time, so `sentry_envelope_get_event` returns null. `LocalCrashReporter` parses the serialized bytes instead.
- The SDK deletes its pending envelope after the transport returns, also when the transport did not save it. If the app cannot write the report, the report is lost. The app logs the error.
- `sentry_close` does not remove the Breakpad handler.
- Breakpad sets a Mach exception port on the task for bad access, bad instruction, arithmetic, and breakpoint exceptions. A forked child keeps this port across `execve`. Breakpad answers `KERN_FAILURE` for another task, so the kernel then uses the host handler, but each child exception goes through the app first. An app that starts child processes must reset the port in the child. Tecolot does this with a `pthread_atfork` child handler.
- The app bundle must contain `Licenses/Sentry-Native-LICENSE` and `Licenses/Breakpad-LICENSE`. Tecolot keeps copies in `Tecolot/CrashReporting/Licenses/`, and the workflow checks that they match.

Crash reports can contain private data from memory. Do not give the SDK a DSN if reports must stay on the Mac.
