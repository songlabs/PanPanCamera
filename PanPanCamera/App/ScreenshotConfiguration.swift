/// Launch-only configuration. Release builds never parse screenshot arguments.
struct ScreenshotConfiguration {
    enum Screen: String, CaseIterable {
        case camera, beauty, reshape, filter, makeup, settings
    }

    let screen: Screen?
    var isEnabled: Bool { screen != nil }

    init(arguments: [String]) {
        #if DEBUG
        guard arguments.contains("--screenshot-mode") else {
            screen = nil
            return
        }
        if let index = arguments.firstIndex(of: "--screenshot-screen") {
            screen = arguments.indices.contains(index + 1) ? Screen(rawValue: arguments[index + 1]) : nil
        } else {
            screen = .camera
        }
        #else
        screen = nil
        #endif
    }
}
