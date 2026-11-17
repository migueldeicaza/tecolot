//
//  CrashReportsView.swift
//  Tecolot
//
//  Settings page for the crash reports that macOS saved for Tecolot. It
//  shows the report date, app version, exception, ID, and size.
//
import AppKit
import os
import SwiftUI
import UniformTypeIdentifiers

@Observable
@MainActor
final class CrashReportsModel {
    enum State: Equatable {
        case loading
        case loaded(CrashReportListing)
        case failed(String)
    }

    private(set) var state: State = .loading
    var errorMessage: String?
    private(set) var isExporting = false

    let store: CrashReportStore
    let defaults: UserDefaults
    /// App-wide, so a submission outlives this page.
    let submissions: CrashReportSubmissionCenter

    init(
        store: CrashReportStore = CrashReporting.store,
        defaults: UserDefaults = .standard,
        submissions: CrashReportSubmissionCenter? = nil
    ) {
        self.store = store
        self.defaults = defaults
        self.submissions = submissions ?? .shared
    }

    var destinationDescription: String {
        "the Tecolot project on sentry.io"
    }

    func reload(markSeen: Bool = false) async {
        let store = self.store
        let result = await Task.detached(priority: .userInitiated) {
            Result { try store.list() }
        }.value
        switch result {
        case .success(let listing):
            await submissions.refresh(keeping: Set(listing.reports.map(\.id)), prune: listing.isComplete)
            state = .loaded(listing)
            if markSeen {
                CrashReportSeenState(defaults: defaults).markSeen(listing)
            }
        case .failure(let error):
            CrashReporting.logger.error("Could not read the crash report folder: \(error.localizedDescription, privacy: .public)")
            state = .failed(error.localizedDescription)
        }
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Shows a report in Finder. macOS can move a report to Retired while
    /// the page is open, so the actions find the file again first.
    func reveal(_ report: CrashReport) {
        Task {
            guard let url = await currentURL(of: report) else { return }
            reveal(url)
        }
    }

    func open(_ report: CrashReport) {
        Task {
            guard let url = await currentURL(of: report) else { return }
            // macOS opens .ips files in Console.
            NSWorkspace.shared.open(url)
        }
    }

    private func currentURL(of report: CrashReport) async -> URL? {
        let store = self.store
        let result = await Task.detached(priority: .userInitiated) {
            Result { try store.currentURL(of: report) }
        }.value
        switch result {
        case .success(let url):
            return url
        case .failure:
            errorMessage = "The report is no longer on this Mac. macOS can remove old reports."
            await reload()
            return nil
        }
    }

    func revealFolder() {
        let directory = store.primaryDirectory
        if FileManager.default.fileExists(atPath: directory.path) {
            NSWorkspace.shared.activateFileViewerSelecting([directory])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([directory.deletingLastPathComponent()])
        }
    }

    func export(_ report: CrashReport) {
        let panel = NSSavePanel()
        panel.title = "Export Crash Report"
        panel.nameFieldStringValue = report.url.lastPathComponent
        panel.allowedContentTypes = [UTType(filenameExtension: CrashReportStore.fileExtension) ?? .json]
        panel.isExtensionHidden = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let store = self.store
        isExporting = true
        Task {
            defer { isExporting = false }
            do {
                // The copy can be large. Do not block the main actor.
                try await Task.detached(priority: .userInitiated) {
                    try store.export(report, to: destination)
                }.value
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Deletes all copies of a report.
    func delete(_ report: CrashReport) async {
        let store = self.store
        do {
            try await Task.detached(priority: .userInitiated) {
                try store.delete(report)
            }.value
        } catch {
            errorMessage = error.localizedDescription
        }
        await reload(markSeen: true)
    }

    func delete(_ url: URL) async {
        let store = self.store
        do {
            try await Task.detached(priority: .userInitiated) {
                try store.delete(url)
            }.value
        } catch {
            errorMessage = error.localizedDescription
        }
        await reload(markSeen: true)
    }
}

struct CrashReportsView: View {
    @State private var model: CrashReportsModel
    @State private var reportToDelete: CrashReport?
    @State private var damagedToDelete: DamagedCrashReport?
    @State private var reportToSubmit: CrashReport?

    init(model: CrashReportsModel? = nil) {
        _model = State(initialValue: model ?? CrashReportsModel())
    }

    var body: some View {
        Form {
            Section {
                Text("When Tecolot quits unexpectedly, macOS saves a crash report on this Mac. Tecolot does not send reports automatically.")
            }

            content

            Section("Storage") {
                Text("macOS saves the reports of all apps in this folder, moves older reports to its Retired subfolder, and removes old reports. Tecolot shows the reports from both folders.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                LabeledContent("Folder:") {
                    Text(model.store.primaryDirectory.path)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                HStack {
                    Spacer()
                    Button("Show Folder in Finder") {
                        model.revealFolder()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .task {
            await model.reload(markSeen: true)
            CrashReportNotice.shared.close()
        }
        .confirmationDialog(
            "Delete this crash report?",
            isPresented: deletePresentation,
            presenting: reportToDelete
        ) { report in
            Button("Delete Report", role: .destructive) {
                Task { await model.delete(report) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { report in
            Text("Tecolot removes report \(report.id) from this Mac. You cannot undo this.")
        }
        .confirmationDialog(
            "Delete this damaged file?",
            isPresented: damagedDeletePresentation,
            presenting: damagedToDelete
        ) { damaged in
            Button("Delete File", role: .destructive) {
                Task { await model.delete(damaged.url) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { damaged in
            Text("Tecolot removes \(damaged.url.lastPathComponent) from this Mac. You cannot undo this.")
        }
        .confirmationDialog(
            "Submit this crash report?",
            isPresented: submitPresentation,
            presenting: reportToSubmit
        ) { report in
            Button("Submit Report") {
                model.submissions.submit(report)
            }
            Button("Cancel", role: .cancel) {}
        } message: { report in
            Text("""
            Tecolot sends a part of report \(report.id) to \(model.destinationDescription). It sends the report only once.

            Tecolot sends the error, the stack of each thread, and the thread names. It also sends the loaded libraries and the versions of Tecolot and macOS.

            Tecolot does not send register values, memory, or identifiers of this Mac. The upload continues if you close Settings.
            """)
        }
        .alert("Report Submitted", isPresented: submittedPresentation) {
            Button("Copy ID") {
                if let id = model.submissions.completedEventID {
                    model.copyToPasteboard(id)
                }
                model.submissions.completedEventID = nil
            }
            Button("OK", role: .cancel) {
                model.submissions.completedEventID = nil
            }
        } message: {
            Text("Thank you. Sentry received the report with ID \(model.submissions.completedEventID ?? ""). Include this ID if you open a GitHub issue about the crash." + (model.submissions.completionWarning.map { "\n\n" + $0 } ?? ""))
        }
        .alert("Crash Report Not Sent", isPresented: submissionErrorPresentation) {
            Button("OK", role: .cancel) {
                model.submissions.errorMessage = nil
            }
        } message: {
            Text(model.submissions.errorMessage ?? "An unknown error occurred.")
        }
        .alert("Crash Report Error", isPresented: errorPresentation) {
            Button("OK", role: .cancel) {
                model.errorMessage = nil
            }
        } message: {
            Text(model.errorMessage ?? "An unknown error occurred.")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            Section("Reports") {
                ProgressView()
                    .frame(maxWidth: .infinity)
            }
        case .failed(let message):
            Section("Reports") {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Tecolot cannot read the crash report folder.")
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "exclamationmark.octagon")
                        .foregroundStyle(.red)
                }
                HStack {
                    Spacer()
                    Button("Try Again") {
                        Task { await model.reload() }
                    }
                }
            }
        case .loaded(let listing):
            Section("Reports") {
                if listing.reports.isEmpty {
                    ContentUnavailableView(
                        "No Crash Reports",
                        systemImage: "checkmark.seal",
                        description: Text("macOS has no crash report for this version of Tecolot.")
                    )
                } else {
                    // Keep this text next to the Submit and Export buttons.
                    Label(
                        "Submit sends only the stacks, the error, and the loaded libraries. Export saves the full macOS report, which also has register values and identifiers of this Mac. Share an exported report only if you agree.",
                        systemImage: "hand.raised"
                    )
                    .foregroundStyle(.secondary)
                    ForEach(listing.reports) { report in
                        CrashReportRow(
                            report: report,
                            canSubmit: model.submissions.canSubmit,
                            submission: model.submissions.submissions[report.id],
                            isSubmitting: model.submissions.inFlight.contains(report.id),
                            isAnySubmitting: !model.submissions.inFlight.isEmpty,
                            isExporting: model.isExporting,
                            submit: { reportToSubmit = report },
                            reveal: { model.reveal(report) },
                            open: { model.open(report) },
                            export: { model.export(report) },
                            copySentryID: { id in model.copyToPasteboard(id) },
                            delete: { reportToDelete = report }
                        )
                    }
                }
            }
            if !listing.damaged.isEmpty {
                Section("Damaged Files") {
                    ForEach(listing.damaged) { damaged in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(damaged.url.lastPathComponent)
                                Text(damaged.reason)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Show in Finder") {
                                model.reveal(damaged.url)
                            }
                            Button("Delete…", role: .destructive) {
                                damagedToDelete = damaged
                            }
                        }
                    }
                }
            }
        }
    }

    private var deletePresentation: Binding<Bool> {
        Binding(
            get: { reportToDelete != nil },
            set: { if !$0 { reportToDelete = nil } }
        )
    }

    private var damagedDeletePresentation: Binding<Bool> {
        Binding(
            get: { damagedToDelete != nil },
            set: { if !$0 { damagedToDelete = nil } }
        )
    }

    private var submitPresentation: Binding<Bool> {
        Binding(
            get: { reportToSubmit != nil },
            set: { if !$0 { reportToSubmit = nil } }
        )
    }

    private var submittedPresentation: Binding<Bool> {
        Binding(
            get: { model.submissions.completedEventID != nil },
            set: { if !$0 { model.submissions.completedEventID = nil } }
        )
    }

    private var submissionErrorPresentation: Binding<Bool> {
        Binding(
            get: { model.submissions.errorMessage != nil },
            set: { if !$0 { model.submissions.errorMessage = nil } }
        )
    }

    private var errorPresentation: Binding<Bool> {
        Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )
    }
}

private struct CrashReportRow: View {
    let report: CrashReport
    let canSubmit: Bool
    let submission: CrashReportSubmission?
    let isSubmitting: Bool
    let isAnySubmitting: Bool
    let isExporting: Bool
    let submit: () -> Void
    let reveal: () -> Void
    let open: () -> Void
    let export: () -> Void
    let copySentryID: (String) -> Void
    let delete: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(report.createdAt, format: .dateTime.year().month().day().hour().minute().second())
                    .font(.body)
                if let summary = report.summary {
                    Text(summary)
                        .font(.callout)
                }
                Text("Version \(report.displayVersion) · \(ByteCountFormatter.string(fromByteCount: report.size, countStyle: .file))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(report.id)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if let submission {
                    Label {
                        Text("Submitted \(submission.date, format: .dateTime.year().month().day().hour().minute())")
                    } icon: {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                    .font(.caption)
                }
            }
            Spacer()
            if isSubmitting {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Submitting")
            } else if canSubmit && submission == nil {
                Button("Submit…", action: submit)
                    .disabled(isAnySubmitting)
                    .help("Send the stacks, the error, and the loaded libraries of this report to the Tecolot project on sentry.io.")
            }
            Button("Export…", action: export)
                .disabled(isExporting)
                .help("Save a copy of the full macOS report. It has register values and identifiers of this Mac. Share it only if you agree.")
            Menu {
                Button("Open in Console", action: open)
                Button("Show in Finder", action: reveal)
                if let submission {
                    Button("Copy Sentry ID") {
                        copySentryID(submission.sentryEventID)
                    }
                }
                Divider()
                Button("Delete…", role: .destructive, action: delete)
                    .disabled(isSubmitting)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More actions")
        }
        .padding(.vertical, 2)
    }
}
