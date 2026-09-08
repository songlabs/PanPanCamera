import SwiftUI

struct SettingsView: View {
    var body: some View {
        PanelContainer(title: .settings) {
            VStack(alignment: .leading, spacing: 16) {
                Text(L10n.appName).font(.largeTitle.bold())
                Text(L10n.privacyTitle).font(.headline)
                Text(L10n.privacyDetail).font(.subheadline)
                Divider()
                Text(L10n.versionScope).font(.headline)
                Text(L10n.versionScopeDetail).font(.subheadline).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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
