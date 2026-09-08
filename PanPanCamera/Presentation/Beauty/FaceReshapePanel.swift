import SwiftUI

struct FaceReshapePanel: View {
    @Binding var parameters: BeautyParameters

    var body: some View {
        VStack(spacing: 20) {
            ParameterSlider(tool: parameters.selectedFace.label, value: Binding(
                get: { parameters.value(for: parameters.selectedFace) },
                set: { parameters.setValue($0, for: parameters.selectedFace) }
            ))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 10)], spacing: 10) {
                ForEach(FaceTool.allCases) { tool in
                    ParameterToolButton(label: tool.label, selected: parameters.selectedFace == tool) {
                        parameters.select(tool)
                    }
                }
            }
        }
    }
}
