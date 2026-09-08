import SwiftUI

struct FilterPanel: View {
    @Binding var selection: FilterPreset

    var body: some View {
        PanelContainer(title: .filters) {
            VStack(spacing: 20) {
                UnimplementedNotice(message: .filterDetail)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100))], spacing: 12) {
                    ForEach(FilterPreset.allCases) { preset in
                        ParameterToolButton(label: preset.label, selected: selection == preset) {
                            selection = preset
                        }
                    }
                }
            }
        }
    }
}
