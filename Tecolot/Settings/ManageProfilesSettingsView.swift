//
//  ManageProfilesSettingsView.swift
//  Tecolot
//
//  Profile management. Profile settings live in the separate sidebar pages.
//
import SwiftUI
import AppKit
import SwiftTerm
import UniformTypeIdentifiers

struct ManageProfilesSettingsView: View {
    private enum RenameMode {
        case alert
        case inline
    }
    
    private struct RenameTarget: Equatable {
        let profile: TerminalProfile
        let mode: RenameMode
    }
    
    @EnvironmentObject private var profiles: ProfileStore
    @EnvironmentObject private var themes: ThemeStore
    @Binding var activeProfileID: TerminalProfile.ID?
    @State private var showImporter = false
    @State private var showExporter = false
    @State private var exportDocument: ProfileExportDocument?
    @State private var errorMessage: String?
    @State private var renameTarget: RenameTarget?
    @State private var renameText = ""
    @FocusState private var renameFocus: TerminalProfile.ID?
    
    private var selectedProfile: TerminalProfile? {
        activeProfileID.flatMap {
            profiles.profile(withID: $0)
        }
    }

    private var profileListSelection: Binding<TerminalProfile.ID> {
        Binding(
            get: {
                activeProfileID ?? profiles.defaultProfileID
            },
            set: {
                activeProfileID = $0
            }
        )
    }

    var body: some View {
        Group {
            if profiles.profiles.isEmpty {
                ContentUnavailableView {
                    Label("No Profiles", systemImage: "person.crop.circle.badge.plus")
                } description: {
                    Text("Create a profile to customize terminal settings.")
                } actions: {
                    Button("New Profile", action: addProfile)
                }
            } else {
                profileList
            }
        }
        .onAppear {
            repairActiveProfileSelection()
        }
        .onChange(of: profiles.profiles.map(\.id)) {
            repairActiveProfileSelection()
        }
        .onChange(of: renameFocus) { oldFocus, newFocus in
            guard oldFocus != nil, newFocus == nil, let renameTarget else {
                return
            }
            // Text field lost focus, check whether a commit of the profile name
            // is needed.
            guard renameText != renameTarget.profile.name else {
                self.renameTarget = nil
                return
            }
            renameProfile()
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url):
                let gotAccess = url.startAccessingSecurityScopedResource()
                defer {
                    if gotAccess {
                        url.stopAccessingSecurityScopedResource()
                    }
                }
                do {
                    activeProfileID = try profiles.importProfile(from: url).id
                } catch {
                    report(error)
                }
            case .failure(let error):
                report(error)
            }
        }
        .fileExporter(
            isPresented: $showExporter,
            document: exportDocument,
            contentType: .json,
            defaultFilename: exportDocument?.filename ?? "Profile"
        ) { result in
            if case .failure(let error) = result {
                report(error)
            }
            exportDocument = nil
        }
        .alert("Could Not Change Profile", isPresented: errorPresentation) {
            Button("OK") {
                errorMessage = nil
            }
        } message: {
            Text(errorMessage ?? "An unknown error occurred.")
        }
        .alert("Rename Profile", isPresented: renamePresentation) {
            TextField("Name", text: $renameText)
            Button("Rename", action: renameProfile)
                .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) {
                renameTarget = nil
            }
        } message: {
            Text("Enter a new name for the profile.")
        }
    }

    private var profileList: some View {
        VStack(spacing: 0) {
            List(selection: profileListSelection) {
                ForEach(profiles.profiles) { profile in
                    HStack {
                        nameView(for: profile)
                        
                        if profile.id == profiles.defaultProfileID {
                            Spacer()
                            Image(systemName: "star.fill")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .help("Default profile")
                        }
                    }
                    .tag(profile.id)
                }
            }
            Divider()
            HStack(spacing: 8) {
                Button {
                    addProfile()
                } label: {
                    Image(systemName: "plus")
                }
                Button {
                    deleteSelectedProfile()
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(activeProfileID == nil || profiles.profiles.count <= 1)

                Menu {
                    Button("Duplicate", action: duplicateSelectedProfile)
                        .disabled(selectedProfile == nil)
                    Button("Rename…", action: presentRename)
                        .disabled(selectedProfile == nil)
                    if let profile = selectedProfile, profile.id != profiles.defaultProfileID {
                        Button("Make “\(profile.name)” the Default", action: setSelectedProfileAsDefault)
                    }
                    Menu("New from Preset") {
                        Button("Pro") {
                            addPreset(name: "Pro", theme: "Pro", fontSize: 12)
                        }
                        Button("Homebrew") {
                            addPreset(name: "Homebrew", theme: "Homebrew", fontSize: 13)
                        }
                        Button("Man Page") {
                            addPreset(name: "Man Page", theme: "Man Page", fontSize: 12)
                        }
                        Button("Solarized Light") {
                            addPreset(
                                name: "Solarized Light",
                                theme: "iTerm2 Solarized Light",
                                fontSize: 12
                            )
                        }
                    }
                    Divider()
                    Button("Import…") {
                        showImporter = true
                    }
                    Button("Export…", action: exportSelectedProfile)
                        .disabled(selectedProfile == nil)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 30)
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(6)
        }
    }
    
    @ViewBuilder
    private func nameView(for profile: TerminalProfile) -> some View {
        if
            let renameTarget,
            renameTarget.mode == .inline,
            renameTarget.profile.id == profile.id {
            TextField("Name", text: $renameText)
                .fixedSize(horizontal: true, vertical: false)
                .focused($renameFocus, equals: profile.id)
                .onAppear {
                    // Immediately focus the text field to start editing.
                    // Otherwise the click just makes the text field appear and
                    // you need another click to start editing.
                    renameFocus = profile.id
                }
                .onKeyPress(.escape) {
                    // Revert the change and cancel editing.
                    self.renameText = profile.name
                    self.renameTarget = nil
                    return .handled
                }
        } else {
            Text(profile.name)
                .onTapGesture {
                    if activeProfileID == profile.id {
                        beginInlineRename(of: profile)
                    } else {
                        activeProfileID = profile.id
                    }
                }
        }
    }

    private func addProfile() {
        do {
            activeProfileID = try profiles.addNewProfile().id
        } catch {
            report(error)
        }
    }

    private func addPreset(name: String, theme: String, fontSize: Double) {
        var uniqueName = name
        var counter = 2
        while profiles.profile(named: uniqueName) != nil {
            uniqueName = "\(name) \(counter)"
            counter += 1
        }
        var profile = TerminalProfile(name: uniqueName)
        let themeName = themes.theme(named: theme).name
        profile.setThemeName(themeName, isDark: false)
        profile.setThemeName(themeName, isDark: true)
        profile.fontSize = fontSize
        do {
            try profiles.add(profile)
            activeProfileID = profile.id
        } catch {
            report(error)
        }
    }

    private func deleteSelectedProfile() {
        guard let activeProfileID else {
            return
        }
        do {
            try profiles.delete(activeProfileID)
            self.activeProfileID = profiles.defaultProfileID
        } catch {
            report(error)
        }
    }

    private func duplicateSelectedProfile() {
        guard let activeProfileID else {
            return
        }
        do {
            self.activeProfileID = try profiles.duplicate(activeProfileID).id
        } catch {
            report(error)
        }
    }

    private func presentRename() {
        guard let profile = selectedProfile else {
            return
        }
        renameTarget = RenameTarget(profile: profile, mode: .alert)
        renameText = profile.name
    }

    private func renameProfile() {
        guard let renameTarget else {
            return
        }
        do {
            try profiles.rename(
                renameTarget.profile.id,
                to: renameText.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            self.renameTarget = nil
        } catch {
            report(error)
        }
    }
    
    private func beginInlineRename(of profile: TerminalProfile) {
        renameTarget =  RenameTarget(profile: profile, mode: .inline)
        renameText = profile.name
    }
    
    private func setSelectedProfileAsDefault() {
        guard let activeProfileID else {
            return
        }
        do {
            try profiles.setDefault(activeProfileID)
        } catch {
            report(error)
        }
    }

    private func exportSelectedProfile() {
        guard let profile = selectedProfile else {
            return
        }
        exportDocument = ProfileExportDocument(profile: profile)
        showExporter = true
    }

    private func repairActiveProfileSelection() {
        activeProfileID = SettingsView.repairedProfileID(
            selectedID: activeProfileID,
            profileIDs: profiles.profiles.map(\.id),
            defaultID: profiles.defaultProfileID
        )
    }

    private var errorPresentation: Binding<Bool> {
        Binding(
            get: {
                errorMessage != nil
            },
            set: {
                if !$0 {
                    errorMessage = nil
                }
            }
        )
    }

    private func report(_ error: Error) {
        errorMessage = error.localizedDescription
    }

    private var renamePresentation: Binding<Bool> {
        Binding(
            get: {
                renameTarget?.mode == .alert
            },
            set: {
                if !$0 {
                    renameTarget = nil
                }
            }
        )
    }
}

#Preview("Manage Profiles") {
    @Previewable @State var activeProfileID: TerminalProfile.ID? = SettingsPreviewData.profiles.defaultProfileID

    ManageProfilesSettingsView(activeProfileID: $activeProfileID)
        .environmentObject(SettingsPreviewData.profiles)
        .environmentObject(SettingsPreviewData.themes)
        .environmentObject(SettingsPreviewData.themeIndex)
        .environmentObject(SystemAppearance(isDark: false))
        .frame(width: 640, height: 520)
}
