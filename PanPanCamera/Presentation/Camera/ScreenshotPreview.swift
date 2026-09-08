#if DEBUG
import SwiftUI

/// An abstract UI test background, never a camera frame or processed photo.
struct ScreenshotPreview: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [PanPanTheme.softPink, Color(red: 0.75, green: 0.84, blue: 0.91)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Circle().stroke(.white.opacity(0.5), lineWidth: 3)
                .frame(width: 220, height: 220)
            Image(systemName: "viewfinder")
                .font(.system(size: 80, weight: .ultraLight))
                .foregroundStyle(.white.opacity(0.7))
        }
        .accessibilityHidden(true)
    }
}

enum ScreenshotReadiness {
    @MainActor
    static func record(_ screen: ScreenshotConfiguration.Screen) async {
        do {
            // Allow the real sheet presentation and its first layout to finish.
            try await Task.sleep(for: .seconds(1))
            let data = try JSONSerialization.data(withJSONObject: [
                "screen": screen.rawValue,
                "language": Bundle.main.preferredLocalizations.first ?? "",
                "locale": Locale.current.identifier
            ], options: [.sortedKeys])
            try data.write(to: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("panpan-screenshot-ready.json"), options: .atomic)
        } catch {
            // The capture script fails if this readiness record is absent.
            print("Screenshot readiness failed: \(error)")
        }
    }
}
#endif
