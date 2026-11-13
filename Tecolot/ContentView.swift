import AppKit
import SwiftUI

/// The per-window theme picker: applies the selection to this session only,
/// with escape hatches to make it the profile-wide theme or reset
struct ThemePickerPopover: View {
    var controller: TerminalSessionController
    @ObservedObject var themes: ThemeStore
    @ObservedObject var themeIndex: ThemeCatalogIndex
    @ObservedObject var profiles: ProfileStore
    /// controller.effectiveTheme depends on the system appearance. This
    /// popover is in an NSHostingController, so observe it here.
    @ObservedObject var systemAppearance: SystemAppearance
    @State private var errorMessage: String?

    var body: some View {
        VStack {
            ThemeBrowserView(
                themes: themes,
                themeIndex: themeIndex,
                profiles: profiles,
                selectedThemeName: controller.effectiveTheme.name
            ) { theme in
                controller.applyThemeOverride(theme.name)
            }
            .padding(.top)
            .frame(minWidth: 520, minHeight: 420, maxHeight: 500)
            Divider()
            HStack {
                Button("Reset to Profile Theme") {
                    controller.applyThemeOverride(nil)
                }
                .disabled(controller.themeOverride == nil)
                Spacer()
                Button("Use for All Windows") {
                    do {
                        try controller.useThemeForAllWindows(in: profiles)
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
                .help("Makes this theme the profile default, updating every window that uses the profile")
            }
            .padding(10)
        }
        .alert("Could Not Change Profile Theme", isPresented: Binding(
            get: {
                errorMessage != nil
            },
            set: {
                if !$0 {
                    errorMessage = nil
                }
            }
        )) {
            Button("OK", role: .cancel) {
                errorMessage = nil
            }
        } message: {
            Text(errorMessage ?? "An unknown error occurred.")
        }
    }
}

#Preview("Theme Picker") {
    @Previewable @State var controller = TerminalSessionController(startsProcess: false)

    ThemePickerPopover(
        controller: controller,
        themes: SettingsPreviewData.themes,
        themeIndex: SettingsPreviewData.themeIndex,
        profiles: SettingsPreviewData.profiles,
        systemAppearance: SystemAppearance(isDark: false)
    )
}
