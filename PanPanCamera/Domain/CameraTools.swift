enum CameraPanel: String, Identifiable {
    case beauty, filters, makeup, settings, album, aspectRatio, timer
    var id: Self { self }
}

enum BeautyCategory: String, CaseIterable, Identifiable {
    case skin, face
    var id: Self { self }
}

enum FilterPreset: String, CaseIterable, Identifiable {
    case original, natural, clear, warm, cool
    var id: Self { self }
}

enum MakeupTool: String, CaseIterable, Identifiable {
    case lip, blush, eye, brow
    var id: Self { self }
}

// Explicit fixed states until cropping and delayed capture are implemented.
enum AspectRatioState { case nativeSensor }
enum TimerState { case off }
