import SwiftUI

@MainActor
struct BeautyPanel: View {
    @Binding var parameters: BeautyParameters
    @Binding var category: BeautyCategory

    var body: some View {
        PanelContainer(title: category.label, compact: category == .face) {
            VStack(spacing: category == .face ? 8 : 20) {
                Picker(selection: $category) {
                    ForEach(BeautyCategory.allCases) { category in Text(category.label).tag(category) }
                } label: { Text(L10n.beautyCategory) }
                .pickerStyle(.segmented)
                if category == .skin {
                    SkinBeautyPanel(parameters: $parameters)
                    UnimplementedNotice(message: .beautySkinUnavailableDetail)
                } else {
                    FaceReshapePanel(parameters: $parameters)
                }
            }
        }
    }
}

struct ParameterSlider: View {
    let tool: L10n
    @Binding var value: Double

    var body: some View {
        VStack(spacing: 8) {
            Text(tool).font(.headline)
            Text(value, format: .number.precision(.fractionLength(0)))
                .font(.system(.largeTitle, design: .rounded, weight: .medium))
                .monospacedDigit()
                .accessibilityHidden(true)
            Slider(value: $value, in: BeautyParameters.range, step: 1) {
                Text(tool)
            }
            .accessibilityHint(Text(L10n.intensity))
            .accessibilityValue(Text(value, format: .number.precision(.fractionLength(0))))
        }
    }
}

struct ParameterToolButton: View {
    let label: L10n
    let selected: Bool
    var compact: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font((compact ? Font.footnote : .subheadline)
                    .weight(selected ? .semibold : .regular))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: compact)
                .padding(.horizontal, 8)
                .padding(.vertical, compact ? 6 : 12)
                .frame(maxWidth: .infinity, minHeight: compact ? 44 : 48)
                .background(selected ? PanPanTheme.softPink : Color(uiColor: .secondarySystemBackground),
                            in: RoundedRectangle(cornerRadius: 16))
                .overlay {
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(selected ? PanPanTheme.accent : .clear, lineWidth: 1.5)
                }
        }
        .buttonStyle(.plain)
        .foregroundStyle(PanPanTheme.ink)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
