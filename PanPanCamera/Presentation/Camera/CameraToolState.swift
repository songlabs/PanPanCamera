import Combine

@MainActor
final class CameraToolState: ObservableObject {
    @Published var panel: CameraPanel?
    @Published var beautyCategory: BeautyCategory = .skin
    let aspectRatio: AspectRatioState = .nativeSensor
    let timer: TimerState = .off
}
