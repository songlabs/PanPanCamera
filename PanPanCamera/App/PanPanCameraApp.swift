import SwiftUI

@main
@MainActor
struct PanPanCameraApp: App {
    @StateObject private var camera = CameraService()
    @AppStorage(AppLanguage.storageKey) private var appLanguage = AppLanguage.system

    var body: some Scene {
        WindowGroup {
            CameraView(camera: camera)
                .tint(PanPanTheme.accent)
                .preferredColorScheme(.light)
                .environment(\.locale, appLanguage.localeOverride ?? .autoupdatingCurrent)
        }
    }
}
