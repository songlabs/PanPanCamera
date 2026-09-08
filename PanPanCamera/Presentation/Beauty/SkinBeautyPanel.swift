import SwiftUI

struct SkinBeautyPanel: View {
    @Binding var parameters: BeautyParameters

    var body: some View {
        VStack(spacing: 20) {
            ParameterSlider(tool: parameters.selectedSkin.label, value: Binding(
                get: { parameters.value(for: parameters.selectedSkin) },
                set: { parameters.setValue($0, for: parameters.selectedSkin) }
            ))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 10)], spacing: 10) {
                ForEach(SkinTool.allCases) { tool in
                    ParameterToolButton(label: tool.label, selected: parameters.selectedSkin == tool) {
                        parameters.select(tool)
                    }
                }
            }
        }
    }
}
