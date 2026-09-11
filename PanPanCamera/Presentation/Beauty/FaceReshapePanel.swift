import SwiftUI

struct FaceReshapePanel: View {
    @Binding var parameters: BeautyParameters

    var body: some View {
        VStack(spacing: 8) {
            strengthControl
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 8)], spacing: 6) {
                ForEach(FaceTool.allCases) { tool in
                    ParameterToolButton(label: tool.label, selected: parameters.selectedFace == tool,
                                        compact: true) {
                        parameters.select(tool)
                    }
                }
            }
        }
    }

    private var strengthControl: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(parameters.selectedFace.label)
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
                Text(parameters.selectedFace.previewDetail)
                if let range = parameters.selectedFace.strengthRangeDetail {
                    Text(range)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            strengthSlider
                .frame(minHeight: 44)
                .accessibilityHint(strengthHint)
                .accessibilityValue(percentage)
        }
    }

    @ViewBuilder
    private var strengthSlider: some View {
        let value = Binding(
            get: { parameters.value(for: parameters.selectedFace) },
            set: { parameters.setValue($0, for: parameters.selectedFace) }
        )
        if parameters.selectedFace == .slim {
            Slider(value: value, in: BeautyParameters.range) { Text(parameters.selectedFace.label) }
        } else {
            Slider(value: value, in: BeautyParameters.range, step: 1) { Text(parameters.selectedFace.label) }
        }
    }

    private var percentage: Text {
        Text(parameters.value(for: parameters.selectedFace) / BeautyParameters.range.upperBound,
             format: .percent.precision(.fractionLength(0)))
    }

    private var strengthHint: Text {
        let detail = Text(parameters.selectedFace.previewDetail)
        guard let range = parameters.selectedFace.strengthRangeDetail else { return detail }
        return detail + Text(verbatim: " · ") + Text(range)
    }
}
