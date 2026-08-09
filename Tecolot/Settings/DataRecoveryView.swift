import SwiftUI
import TerminalProfilesKit

struct DataRecoveryView: View {
    @ObservedObject var issueCenter: PersistenceIssueCenter
    let recovery: DataRecoveryCoordinator

    @State private var errorMessage: String?
    @State private var restoreIssue: PersistenceIssue?
    @State private var resetIssue: PersistenceIssue?
    @State private var trashIssue: PersistenceIssue?

    private var sections: [DataRecoverySection] {
        PersistenceDomain.allCases.compactMap { domain in
            let issues = issueCenter.issues.filter { $0.domain == domain }
            return issues.isEmpty ? nil : DataRecoverySection(domain: domain, issues: issues)
        }
    }

    var body: some View {
        Group {
            if issueCenter.issues.isEmpty {
                ContentUnavailableView(
                    "All Data Is Healthy",
                    systemImage: "externaldrive.badge.checkmark",
                    description: Text("Tecolot found no data that needs attention.")
                )
            } else {
                issueList
            }
        }
        .alert("Recovery Failed", isPresented: errorPresentation) {
            Button("OK", role: .cancel) {
                errorMessage = nil
            }
        } message: {
            Text(errorMessage ?? "An unknown error occurred.")
        }
        .confirmationDialog(
            "Restore this backup?",
            isPresented: restorePresentation,
            presenting: restoreIssue
        ) { issue in
            Button("Restore Backup") {
                restore(issue)
            }
            Button("Cancel", role: .cancel) {}
        } message: { issue in
            Text("This replaces \(issue.sourceURL.lastPathComponent) with its saved backup.")
        }
        .confirmationDialog(
            "Reset Tecolot preferences?",
            isPresented: resetPresentation,
            presenting: resetIssue
        ) { _ in
            Button("Reset Preferences", role: .destructive) {
                recovery.resetPreferences()
                resetIssue = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This restores the General settings to their defaults. Profiles and themes are not changed.")
        }
        .confirmationDialog(
            "Move this file to Trash?",
            isPresented: trashPresentation,
            presenting: trashIssue
        ) { issue in
            Button("Move to Trash", role: .destructive) {
                moveToTrash(issue)
            }
            Button("Cancel", role: .cancel) {}
        } message: { issue in
            Text("Tecolot will stop loading \(issue.sourceURL.lastPathComponent). You can recover it from Trash.")
        }
    }

    private var issueList: some View {
        List {
            ForEach(sections) { section in
                Section(section.domain.displayName) {
                    ForEach(section.issues) { issue in
                        DataRecoveryRow(
                            issue: issue,
                            hasBackup: recovery.availableBackup(for: issue) != nil,
                            canMoveToTrash: recovery.canMoveToTrash(issue),
                            reveal: { recovery.reveal(issue) },
                            retry: { recovery.retry(issue) },
                            restore: { restoreIssue = issue },
                            resetPreferences: { resetIssue = issue },
                            moveToTrash: { trashIssue = issue }
                        )
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    private var errorPresentation: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private var restorePresentation: Binding<Bool> {
        Binding(
            get: { restoreIssue != nil },
            set: { if !$0 { restoreIssue = nil } }
        )
    }

    private var trashPresentation: Binding<Bool> {
        Binding(
            get: { trashIssue != nil },
            set: { if !$0 { trashIssue = nil } }
        )
    }

    private var resetPresentation: Binding<Bool> {
        Binding(
            get: { resetIssue != nil },
            set: { if !$0 { resetIssue = nil } }
        )
    }

    private func restore(_ issue: PersistenceIssue) {
        do {
            try recovery.restore(issue)
            restoreIssue = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func moveToTrash(_ issue: PersistenceIssue) {
        Task {
            do {
                try await recovery.moveToTrash(issue)
                trashIssue = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct DataRecoverySection: Identifiable {
    var id: PersistenceDomain { domain }
    let domain: PersistenceDomain
    let issues: [PersistenceIssue]
}

private struct DataRecoveryRow: View {
    let issue: PersistenceIssue
    let hasBackup: Bool
    let canMoveToTrash: Bool
    let reveal: () -> Void
    let retry: () -> Void
    let restore: () -> Void
    let resetPreferences: () -> Void
    let moveToTrash: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(issue.sourceURL.lastPathComponent)
                    .font(.headline)
                Spacer()
                Text(issue.kindLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(issue.message)
                .font(.callout)
                .textSelection(.enabled)
            if let versionDescription = issue.versionDescription {
                Text(versionDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Reveal", action: reveal)
                Button("Retry", action: retry)
                Button("Restore Backup", action: restore)
                    .disabled(!hasBackup)
                if issue.domain == .preferences {
                    Button("Reset Preferences", action: resetPreferences)
                }
                Spacer()
                Button("Move to Trash", role: .destructive, action: moveToTrash)
                    .disabled(!canMoveToTrash)
            }
            .controlSize(.small)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }
}

private extension PersistenceIssue {
    var kindLabel: String {
        switch kind {
        case .unreadable: return "Unreadable"
        case .invalidFormat: return "Invalid Format"
        case .validationFailed: return "Invalid Data"
        case .unsupportedVersion: return "Newer Version"
        case .backupFailed: return "Backup Failed"
        case .migrationFailed: return "Migration Failed"
        case .writeFailed: return "Save Failed"
        }
    }

    var versionDescription: String? {
        switch (foundVersion, supportedVersion) {
        case let (found?, supported?):
            return "Schema version \(found); supported through version \(supported)."
        case let (nil, supported?):
            return "Supported through schema version \(supported)."
        default:
            return nil
        }
    }
}

#Preview("Data Recovery") {
    let _ = SettingsPreviewData.sampleIssue

    DataRecoveryView(
        issueCenter: SettingsPreviewData.issueCenter,
        recovery: SettingsPreviewData.recovery
    )
    .frame(width: 680, height: 420)
}

#Preview("Data Recovery Row") {
    let issue = SettingsPreviewData.sampleIssue

    DataRecoveryRow(
        issue: issue,
        hasBackup: false,
        canMoveToTrash: false,
        reveal: {},
        retry: {},
        restore: {},
        resetPreferences: {},
        moveToTrash: {}
    )
    .padding()
    .frame(width: 680)
}
