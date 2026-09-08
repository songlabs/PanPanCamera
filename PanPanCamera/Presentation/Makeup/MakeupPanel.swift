import SwiftUI

struct MakeupPanel: View {
    @Binding var selection: MakeupTool

    var body: some View {
        PanelContainer(title: .makeup) {
            VStack(spacing: 20) {
                UnimplementedNotice(message: .makeupDetail)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110))], spacing: 12) {
                    ForEach(MakeupTool.allCases) { tool in
                        VStack(spacing: 8) {
                            Image(systemName: tool.symbol)
                                .font(.system(size: 24, weight: .light))
                                .accessibilityHidden(true)
                            ParameterToolButton(label: tool.label, selected: selection == tool) {
                                selection = tool
                            }
                        }
                    }
                }
            }
        }
    }
}
