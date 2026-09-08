import SwiftUI

enum PanPanTheme {
    static let accent = Color(red: 0.89, green: 0.36, blue: 0.51)
    static let softPink = Color(red: 1, green: 0.91, blue: 0.94)
    static let ink = Color(red: 0.23, green: 0.18, blue: 0.21)
    static let iconSize: CGFloat = 19
}

struct CameraIconButton: View {
    let symbol: String
    let label: L10n
    var value: L10n? = nil
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: PanPanTheme.iconSize, weight: .medium))
                .frame(minWidth: 44, minHeight: 44)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
        .accessibilityValue(value.map { Text($0) } ?? Text(verbatim: ""))
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }
}

struct UnimplementedNotice: View {
    var message: L10n = .previewOnly

    var body: some View {
        Label { Text(message) } icon: { Image(systemName: "info.circle") }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PanPanTheme.softPink, in: RoundedRectangle(cornerRadius: 14))
    }
}

struct PanelContainer<Content: View>: View {
    let title: L10n
    @ViewBuilder var content: () -> Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                content()
                    .padding(20)
                    .frame(maxWidth: 640)
                    .frame(maxWidth: .infinity)
            }
            .navigationTitle(Text(title))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: { Text(L10n.close) }
                }
            }
        }
        .presentationDetents(panelDetents)
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(28)
    }

    private var panelDetents: Set<PresentationDetent> {
        #if DEBUG
        if ScreenshotConfiguration(arguments: ProcessInfo.processInfo.arguments).isEnabled {
            return [.large]
        }
        #endif
        return [.medium, .large]
    }
}
