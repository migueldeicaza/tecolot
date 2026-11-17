//
//  SettingsSearchResultsView.swift
//  Tecolot
//
//  The list that the Settings window shows while the user searches.
//
import SwiftUI

struct SettingsSearchResultsView: View {
    let query: String
    /// The page that the results come from, or nil for all pages.
    let scope: SettingsDestination?
    let results: [SettingsSearchResult]
    let open: (SettingID) -> Void

    static func countLabel(_ count: Int) -> String {
        count == 1 ? "1 result" : "\(count) results"
    }

    var body: some View {
        Group {
            if results.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                Form {
                    Section {
                        ForEach(results) { result in
                            SettingsSearchResultRow(result: result, open: open)
                        }
                    } header: {
                        HStack(alignment: .firstTextBaseline) {
                            Text(scope?.title ?? "All Settings")
                                .font(.headline)
                            Spacer()
                            Text(Self.countLabel(results.count))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .formStyle(.grouped)
                .accessibilityLabel("Settings search results")
            }
        }
        .navigationTitle("Search")
    }
}

struct SettingsSearchResultRow: View {
    let result: SettingsSearchResult
    let open: (SettingID) -> Void

    var body: some View {
        Button {
            open(result.id)
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    if !result.entry.breadcrumb.isEmpty {
                        Text(result.entry.breadcrumb)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(result.entry.title)
                    Text(result.entry.summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if let note = result.entry.note {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(result.entry.kind == .setting ? "Opens this setting" : "Opens this part of Settings")
    }
}

#Preview("Search Results") {
    SettingsSearchResultsView(
        query: "font",
        scope: nil,
        results: SettingsSearchEngine.search("tab"),
        open: { _ in }
    )
    .frame(width: 600, height: 520)
}
