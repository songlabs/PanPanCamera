import SwiftUI

/// Manual stable keys: all five translations live in Localizable.xcstrings.
enum L10n: String, CaseIterable {
    case appName = "app.name"
    case photo = "mode.photo"
    case video = "mode.video"
    case portrait = "mode.portrait"
    case album = "camera.album"
    case shutter = "camera.shutter"
    case livePreview = "camera.livePreview"
    case flash = "camera.flash"
    case flashOff = "camera.flash.off"
    case flashAuto = "camera.flash.auto"
    case flashOn = "camera.flash.on"
    case flashUnavailable = "camera.flash.unavailable"
    case aspectRatio = "camera.aspectRatio"
    case nativeSensor = "camera.nativeSensor"
    case aspectRatioDetail = "camera.aspectRatio.detail"
    case timer = "camera.timer"
    case timerOff = "camera.timer.off"
    case timerDetail = "camera.timer.detail"
    case settings = "camera.settings"
    case switchCamera = "camera.switch"
    case frontCamera = "camera.front"
    case backCamera = "camera.back"
    case permissionTitle = "permission.title"
    case permissionDetail = "permission.detail"
    case permissionRestricted = "permission.restricted"
    case openSettings = "permission.openSettings"
    case requestingPermission = "permission.requesting"
    case startingCamera = "camera.starting"
    case cameraUnavailable = "camera.unavailable"
    case cameraUnavailableDetail = "camera.unavailable.detail"
    case cameraInterrupted = "camera.interrupted"
    case cameraFailed = "camera.failed"
    case retry = "action.retry"
    case close = "action.close"
    case backToCamera = "action.backToCamera"
    case captureFailed = "error.capture"
    case switchFailed = "error.switch"
    case errorTitle = "error.title"
    case captureResult = "capture.result"
    case capturedImage = "capture.image"
    case memoryOnly = "capture.memoryOnly"
    case albumDetail = "album.detail"
    case comingSoon = "feature.unavailable"
    case previewOnly = "feature.previewOnly"
    case skin = "beauty.skin"
    case face = "beauty.face"
    case beautyCategory = "beauty.category"
    case intensity = "beauty.intensity"
    case auto = "beauty.auto"
    case smooth = "skin.smooth"
    case brighten = "skin.brighten"
    case tone = "skin.tone"
    case blemish = "skin.blemish"
    case darkCircles = "skin.darkCircles"
    case slim = "face.slim"
    case faceWidth = "face.width"
    case chin = "face.chin"
    case forehead = "face.forehead"
    case cheekbones = "face.cheekbones"
    case eyes = "face.eyes"
    case eyeSpacing = "face.eyeSpacing"
    case eyeHeight = "face.eyeHeight"
    case nose = "face.nose"
    case noseWidth = "face.noseWidth"
    case noseLength = "face.noseLength"
    case mouth = "face.mouth"
    case mouthShape = "face.mouthShape"
    case mouthWidth = "face.mouthWidth"
    case filters = "filter.title"
    case original = "filter.original"
    case natural = "filter.natural"
    case clear = "filter.clear"
    case warm = "filter.warm"
    case cool = "filter.cool"
    case filterDetail = "filter.detail"
    case makeup = "makeup.title"
    case lip = "makeup.lip"
    case blush = "makeup.blush"
    case eyeMakeup = "makeup.eye"
    case brow = "makeup.brow"
    case makeupDetail = "makeup.detail"
    case privacyTitle = "settings.privacy"
    case privacyDetail = "settings.privacy.detail"
    case versionScope = "settings.scope"
    case versionScopeDetail = "settings.scope.detail"
}

extension Text {
    init(_ key: L10n) { self.init(LocalizedStringKey(key.rawValue)) }
}

extension CameraFailure {
    var localizedKey: L10n {
        switch self {
        case .captureFailed: return .captureFailed
        case .switchFailed: return .switchFailed
        }
    }
}

extension CameraMode {
    var label: L10n {
        switch self { case .photo: return .photo; case .video: return .video; case .portrait: return .portrait }
    }
}

extension FlashMode {
    var label: L10n {
        switch self { case .off: return .flashOff; case .auto: return .flashAuto; case .on: return .flashOn }
    }
    var symbol: String {
        switch self { case .off: return "bolt.slash"; case .auto: return "bolt.badge.a"; case .on: return "bolt.fill" }
    }
}

extension BeautyCategory {
    var label: L10n { self == .skin ? .skin : .face }
}

extension SkinTool {
    var label: L10n {
        switch self {
        case .auto: return .auto
        case .smooth: return .smooth
        case .brighten: return .brighten
        case .tone: return .tone
        case .blemish: return .blemish
        case .darkCircles: return .darkCircles
        }
    }
}

extension FaceTool {
    var label: L10n {
        switch self {
        case .auto: return .auto
        case .slim: return .slim
        case .width: return .faceWidth
        case .chin: return .chin
        case .forehead: return .forehead
        case .cheekbones: return .cheekbones
        case .eyes: return .eyes
        case .eyeSpacing: return .eyeSpacing
        case .eyeHeight: return .eyeHeight
        case .noseWidth: return .noseWidth
        case .noseLength: return .noseLength
        case .mouthShape: return .mouthShape
        case .mouthWidth: return .mouthWidth
        }
    }
}

extension FilterPreset {
    var label: L10n {
        switch self {
        case .original: return .original
        case .natural: return .natural
        case .clear: return .clear
        case .warm: return .warm
        case .cool: return .cool
        }
    }
}

extension MakeupTool {
    var label: L10n {
        switch self { case .lip: return .lip; case .blush: return .blush; case .eye: return .eyeMakeup; case .brow: return .brow }
    }
    var symbol: String {
        switch self { case .lip: return "mouth"; case .blush: return "circle.lefthalf.filled"; case .eye: return "eye"; case .brow: return "eyebrow" }
    }
}
