# Crash reporting for Tecolot

Status: implemented on branch `tecolot-crash2`. This spec replaces the Sentry
Native and Breakpad design in `tecolot-main/CRASH_REPORTING_SPEC.md`.

## Summary

Tecolot does not capture crashes. When Tecolot crashes, macOS writes a crash
report (`.ips`, JSON, version 2). Tecolot reads its own reports, shows them in
**Settings > Crash Reports**, and sends one to Sentry only when the user clicks
**Submit…** and confirms. At that time, Tecolot converts the report to a
Sentry event. The release workflow uploads the dSYMs, so Sentry can
symbolicate the stacks.

This design has no crash handler in the process, no third-party SDK, no
exception ports that child shells inherit, and no binary payloads. It works on
all macOS versions that Tecolot supports (15.5 and later).

## Why not the Crash Report Extension

The `CrashReportExtension` framework (`CrashReporterExtension`,
`CrashedProcess`) is in the macOS 27 SDK. A spike built an ExtensionKit
extension for it and crashed the app on macOS 27.0.1 (26A434) and 27.2.1
(26B131). The result:

- ReportCrashService looks for the extension:
  `Checking for crash reporter extension for com.tirania.Tecolot.debug`.
- The call fails: `Failed to find extension point for identifier
  com.apple.crash-reporter.extension` (pkd `-10814`, ExtensionKit error 13).
- The cause is in
  `/System/Library/ExtensionKit/ExtensionPoints/com.apple.crash-reporter.extension.appexpt`:
  `EXSupportedPlatforms = [iOS]` and `EXRequiredEntitlements =
  {com.apple.private.crash-reporter = true}`.
- Xcode 27.3 has only an iOS template for this extension.

Thus the extension point is not available to macOS apps. When Apple enables
it, the extension can write richer reports to an App Group, and the store can
read them next to the `.ips` files. The spike code (corpse reader, report
writer, project wiring) is not in the branch.

## Behavior

### Finding reports

- macOS writes `~/Library/Logs/DiagnosticReports/<process>-<date>.ips`, and
  later moves the file to the `Retired` subfolder. Tecolot reads both
  folders. The app is not sandboxed, so it can read them.
- A report belongs to Tecolot when the file name starts with the executable
  name and a dash, the extension is `.ips`, the header `bundleID` is the
  running app's bundle identifier, and the header `bug_type` is `309`
  (crash). Debug and Release builds have different bundle identifiers, so
  each build shows only its own reports.
- A file with Tecolot's name that Tecolot cannot parse is listed as damaged.
  A report of another type (for example a hang) or of another bundle
  identifier is not listed.
- The report ID is the header `incident_id`. A report in both folders is
  listed once.
- Tecolot reads only regular files (no links, FIFOs, or devices) up to
  16 MiB. It parses the body only of its own crash reports, and caches rows
  by path, size, and modification date.
- macOS keeps the file name when it moves a report to Retired. Each action
  (open, show, export, submit, delete) finds the report again by name and
  incident ID in both folders. Delete removes all copies.
- macOS removes old reports. Tecolot has no retention rule. It deletes a
  report only when the user asks, and only a file with Tecolot's report name
  directly in one of the two folders.
- When the Retired folder cannot be read, the listing is partial. Then
  Tecolot does not remove seen IDs or submission records.

### Notice

- After launch, a worker lists the reports. When a report is not in the seen
  list (`CrashReportsSeenIDs` in user defaults), a small non-activating panel
  says that Tecolot quit unexpectedly, with **Dismiss** and **Show Crash
  Reports**.
- At the first launch with this feature, Tecolot records the existing reports
  as seen (also when there are none) and shows no notice.
- Each way to close the notice (its buttons, its close button, or the
  Settings page) marks its reports as seen.
- When the Settings window action is not available yet, the notice uses the
  **Settings…** menu item. If neither exists, no page is kept for the next
  ⌘,.

### Settings page

Each row shows the date, the exception (for example `EXC_BAD_ACCESS
(SIGSEGV)`), the version, the size, the ID, and the submission state. The
actions are **Submit…** (Release builds only), **Export…**, **Open in
Console**, **Show in Finder**, **Copy Sentry ID**, and **Delete…**.

### Submission

- Only a user click and a confirmation start a submission. Each report is
  sent at most once. `Submissions.json` in
  `~/Library/Application Support/<bundle id>/CrashReports/` (0600) records
  the Sentry ID.
- The Sentry event ID is the incident ID without dashes, so a second
  submission of a report has the same event ID.
- The event contains: the app version, build, and bundle identifier; the macOS
  version and build; the Mac model and architecture; the exception type,
  signal, subtype, and Mach codes; the termination text; application-specific
  messages (`asi`); the stack of each thread, oldest call first, without
  inline frames; thread and queue names; and the debug images that the
  frames use, plus the main executable.
- The event does not contain register values, instruction bytes, the memory
  summary, `crashReporterKey`, `deviceIdentifierForVendor`, the parent
  process, or other identifiers. macOS already writes user paths as
  `/Users/USER/*`. Tecolot also replaces the home folder with `~` in every
  string of the event.
- When Sentry accepts the report but the record cannot be written, the
  success alert shows the Sentry ID and a warning. It is not an error.
- The request goes to the envelope endpoint of the DSN in Info.plist
  (`TecolotCrashReportDSN`, set only in the Release configuration) with an
  ephemeral `URLSession` and no cookies. Tecolot does not retry. A `429`
  shows the clamped `Retry-After` time.
- **Export…** copies the original `.ips` file. The UI says that this file
  also has register values and identifiers of the Mac.

### Release workflow

- Check that the app's Info.plist has a valid `TecolotCrashReportDSN`.
- Check that the dSYM UUIDs match the app binary for arm64 and x86_64.
- Upload the dSYMs with `sentry-cli` (pinned version and SHA-256, secret
  `SENTRY_KEY`). Without the secret, the step warns and continues.
- Attach `Tecolot-<version>-dSYMs.zip` to the GitHub release.

## Code

| File | Contents |
| --- | --- |
| `Tecolot/CrashReporting/CrashReporting.swift` | Launch hook, settings navigation, notice panel, Debug crash trigger |
| `Tecolot/CrashReporting/CrashReportStore.swift` | Listing, delete, export, seen state |
| `Tecolot/CrashReporting/DiagnosticReport.swift` | `.ips` parser |
| `Tecolot/CrashReporting/CrashReportEvent.swift` | Sentry event and envelope |
| `Tecolot/CrashReporting/CrashReportSubmitter.swift` | DSN, HTTP request, submission log, submission center |
| `Tecolot/Settings/CrashReportsView.swift` | Settings page |
| `TecolotTests/CrashReport*Tests.swift` | Tests |

## Checks

- Unit tests: listing and filters, both folders, damaged files, delete limits,
  export, seen state, event fields, frame order and addresses, debug images,
  no registers or identifiers in the envelope, envelope framing, DSN parsing,
  HTTP errors, rate limits, the submission log, and one submission per
  report.
- Manual: build Debug, run
  `TECOLOT_CRASH_TEST=worker build/Build/Products/Debug/Tecolot.app/Contents/MacOS/Tecolot`
  outside the debugger (a debugger stops macOS from writing a report), wait
  about 10 s for the `.ips` file, start the app again, and check the notice
  and the Settings page. On macOS 27.2.1, the report was ready 9 s after the
  crash.

## Limits

- Tecolot does not show a report for a crash of `tecolot-sessiond` or of a
  program in a terminal.
- macOS can remove a report before the user sees it.
- A report that macOS cannot write (for example, a full disk) is lost.
- A Release crash on a Mac without the dSYM upload shows unsymbolicated app
  frames in Sentry. System frames have symbols from the report.
