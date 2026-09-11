import SwiftUI

struct FilterPanel: View {
    @Binding var parameters: BeautyParameters

    var body: some View {
        PanelContainer(title: .filters, compact: true) {
            VStack(spacing: 8) {
                strengthControl
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 6) {
                    ForEach(FilterPreset.allCases) { preset in
                        ParameterToolButton(label: preset.label, selected: parameters.selectedFilter == preset,
                                            compact: true) {
                            parameters.select(preset)
                        }
                    }
                }
            }
        }
    }

    private var strengthControl: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(parameters.selectedFilter.label)
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
                Text(parameters.selectedFilter.detail)
                Text(L10n.filterStrengthRange)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            Slider(value: Binding(
                get: { parameters.value(for: parameters.selectedFilter) },
                set: { parameters.setValue($0, for: parameters.selectedFilter) }
            ), in: BeautyParameters.range, step: 1) { Text(parameters.selectedFilter.label) }
            .frame(minHeight: 44)
            .disabled(parameters.selectedFilter == .original)
            .accessibilityHint(Text(parameters.selectedFilter.detail) + Text(verbatim: " · ") +
                               Text(L10n.filterStrengthRange))
            .accessibilityValue(percentage)
        }
    }

    private var percentage: Text {
        Text(parameters.value(for: parameters.selectedFilter) / BeautyParameters.range.upperBound,
             format: .percent.precision(.fractionLength(0)))
    }
}
