import Combine

@MainActor
final class CameraToolState: ObservableObject {
    @Published var panel: CameraPanel?
    @Published var beautyCategory: BeautyCategory = .skin
    @Published var filterPreset: FilterPreset = .original
    @Published var makeupTool: MakeupTool = .lip
    let aspectRatio: AspectRatioState = .nativeSensor
    let timer: TimerState = .off
}
