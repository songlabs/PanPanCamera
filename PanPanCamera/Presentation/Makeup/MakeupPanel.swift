import SwiftUI

struct MakeupPanel: View {
    @Binding var parameters: BeautyParameters

    var body: some View {
        PanelContainer(title: .makeup, compact: true) {
            VStack(spacing: 8) {
                strengthControl
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 6) {
                    ForEach(MakeupTool.allCases) { tool in
                        ParameterToolButton(label: tool.label, selected: parameters.selectedMakeup == tool,
                                            compact: true) {
                            parameters.select(tool)
                        }
                    }
                }
            }
        }
    }

    private var strengthControl: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(parameters.selectedMakeup.label)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                percentage
                    .font(.system(.title3, design: .rounded, weight: .medium))
                    .monospacedDigit()
                    .fixedSize()
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(parameters.selectedMakeup.detail)
                Text(L10n.makeupStrengthRange)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            Slider(value: Binding(
                get: { parameters.value(for: parameters.selectedMakeup) },
                set: { parameters.setValue($0, for: parameters.selectedMakeup) }
            ), in: BeautyParameters.range, step: 1) { Text(parameters.selectedMakeup.label) }
            .frame(minHeight: 44)
            .accessibilityHint(Text(parameters.selectedMakeup.detail) + Text(verbatim: " · ") +
                               Text(L10n.makeupStrengthRange))
            .accessibilityValue(percentage)
        }
    }

    private var percentage: Text {
        Text(parameters.value(for: parameters.selectedMakeup) / BeautyParameters.range.upperBound,
             format: .percent.precision(.fractionLength(0)))
    }
}
