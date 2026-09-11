import SwiftUI

struct SkinBeautyPanel: View {
    @Binding var parameters: BeautyParameters

    var body: some View {
        VStack(spacing: 8) {
            strengthControl
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 6) {
                ForEach(SkinTool.allCases) { tool in
                    ParameterToolButton(label: tool.label, selected: parameters.selectedSkin == tool,
                                        compact: true) {
                        parameters.select(tool)
                    }
                }
            }
        }
    }

    // Match FaceReshapePanel's compact metrics without changing its UI or sliders.
    private var strengthControl: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(parameters.selectedSkin.label)
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
                Text(parameters.selectedSkin.detail)
                Text(parameters.selectedSkin.strengthRangeDetail)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            Slider(value: Binding(
                get: { parameters.value(for: parameters.selectedSkin) },
                set: { parameters.setValue($0, for: parameters.selectedSkin) }
            ), in: BeautyParameters.range, step: 1) { Text(parameters.selectedSkin.label) }
            .frame(minHeight: 44)
            .accessibilityHint(Text(parameters.selectedSkin.detail) + Text(verbatim: " · ") +
                               Text(parameters.selectedSkin.strengthRangeDetail))
            .accessibilityValue(percentage)
        }
    }

    private var percentage: Text {
        Text(parameters.value(for: parameters.selectedSkin) / BeautyParameters.range.upperBound,
             format: .percent.precision(.fractionLength(0)))
    }
}
