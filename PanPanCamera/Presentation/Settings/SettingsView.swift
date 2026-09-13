import SwiftUI

struct SettingsView: View {
    @Binding var debugOverlayEnabled: Bool
    @State private var testingGuidesAvailable = FaceAnalysisDebugMode.isAvailable
    @AppStorage(AppLanguage.storageKey) private var appLanguage = AppLanguage.system

    var body: some View {
        PanelContainer(title: .settings) {
            VStack(alignment: .leading, spacing: 16) {
                Text(L10n.appName).font(.largeTitle.bold())
                Text(L10n.language).font(.headline)
                NavigationLink {
                    LanguageSettingsView()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "globe")
                            .frame(width: 24)
                            .accessibilityHidden(true)
                        Text(appLanguage.label)
                        Spacer(minLength: 12)
                        Image(systemName: "chevron.forward")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                    .background(Color(uiColor: .secondarySystemBackground),
                                in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .foregroundStyle(PanPanTheme.ink)
                .accessibilityLabel(Text(L10n.language))
                .accessibilityValue(Text(appLanguage.label))
                if testingGuidesAvailable {
                    Divider()
                    Toggle(isOn: $debugOverlayEnabled) {
                        Text(L10n.testingGuides)
                    }
                    .onChange(of: debugOverlayEnabled) { _, enabled in
                        FaceAnalysisDebugMode.setEnabled(enabled)
                    }
                    .accessibilityIdentifier("settings.testingGuides")
                }
                Divider()
                Text(L10n.privacyTitle).font(.headline)
                Text(L10n.privacyDetail).font(.subheadline)
                Divider()
                Text(L10n.versionScope).font(.headline)
                Text(L10n.versionScopeDetail).font(.subheadline).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task {
            testingGuidesAvailable = await FaceAnalysisDebugMode.resolveAvailability()
            if !testingGuidesAvailable { debugOverlayEnabled = false }
        }
    }
}

private struct LanguageSettingsView: View {
    @AppStorage(AppLanguage.storageKey) private var appLanguage = AppLanguage.system

    var body: some View {
        List(AppLanguage.allCases) { language in
            Button {
                appLanguage = language
            } label: {
                HStack {
                    Text(language.label)
                    Spacer()
                    if language == appLanguage {
                        Image(systemName: "checkmark")
                            .fontWeight(.semibold)
                            .foregroundStyle(PanPanTheme.accent)
                            .accessibilityHidden(true)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(PanPanTheme.ink)
            .accessibilityAddTraits(language == appLanguage ? .isSelected : [])
        }
        .navigationTitle(Text(L10n.language))
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct FeaturePlaceholderView: View {
    let title: L10n
    let detail: L10n
    var current: L10n? = nil

    var body: some View {
        PanelContainer(title: title) {
            VStack(alignment: .leading, spacing: 16) {
                if let current { Text(current).font(.headline) }
                UnimplementedNotice(message: detail)
            }
        }
    }
}
