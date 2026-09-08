import SwiftUI

@main
@MainActor
struct PanPanCameraApp: App {
    @StateObject private var camera = CameraService()

    var body: some Scene {
        WindowGroup {
            CameraView(camera: camera)
                .tint(PanPanTheme.accent)
                .preferredColorScheme(.light)
        }
    }
}
