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
    case skin = "beauty.skin"
    case face = "beauty.face"
    case beautyCategory = "beauty.category"
    case intensity = "beauty.intensity"
    case auto = "beauty.auto"
    case beautyOverall = "beauty.overall"
    case skinOverallDetail = "beauty.skin.overallDetail"
    case skinOverallRange = "beauty.skin.overallRange"
    case skinStrengthRange = "beauty.skin.strengthRange"
    case skinSmoothDetail = "skin.smooth.detail"
    case skinBrightenDetail = "skin.brighten.detail"
    case skinToneDetail = "skin.tone.detail"
    case skinBlemishDetail = "skin.blemish.detail"
    case skinDarkCirclesDetail = "skin.darkCircles.detail"
    case faceOverallDetail = "beauty.face.overallDetail"
    case faceOverallRange = "beauty.face.overallRange"
    case faceStrengthRange = "beauty.face.strengthRange"
    case faceUnavailableDetail = "beauty.face.unavailableDetail"
    case faceSlimDetail = "face.slim.detail"
    case faceWidthDetail = "face.width.detail"
    case faceChinDetail = "face.chin.detail"
    case faceForeheadDetail = "face.forehead.detail"
    case faceCheekbonesDetail = "face.cheekbones.detail"
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
    case language = "settings.language"
    case languageSystem = "language.system"
    case languageJapanese = "language.japanese"
    case languageSimplifiedChinese = "language.simplifiedChinese"
    case languageTraditionalChinese = "language.traditionalChinese"
    case languageEnglish = "language.english"
    case languageKorean = "language.korean"
    case privacyTitle = "settings.privacy"
    case privacyDetail = "settings.privacy.detail"
    case versionScope = "settings.scope"
    case versionScopeDetail = "settings.scope.detail"
}

extension Text {
    init(_ key: L10n) { self.init(LocalizedStringKey(key.rawValue)) }
}

enum AppLanguage: String, CaseIterable, Identifiable {
    static let storageKey = "appLanguage"

    case system
    case japanese = "ja"
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"
    case english = "en"
    case korean = "ko"

    var id: Self { self }

    var localeIdentifier: String? {
        self == .system ? nil : rawValue
    }

    var localeOverride: Locale? {
        guard let localeIdentifier else { return nil }
        return Locale(identifier: localeIdentifier)
    }

    var label: L10n {
        switch self {
        case .system: return .languageSystem
        case .japanese: return .languageJapanese
        case .simplifiedChinese: return .languageSimplifiedChinese
        case .traditionalChinese: return .languageTraditionalChinese
        case .english: return .languageEnglish
        case .korean: return .languageKorean
        }
    }
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
    var detail: L10n {
        switch self {
        case .auto: return .skinOverallDetail
        case .smooth: return .skinSmoothDetail
        case .brighten: return .skinBrightenDetail
        case .tone: return .skinToneDetail
        case .blemish: return .skinBlemishDetail
        case .darkCircles: return .skinDarkCirclesDetail
        }
    }

    var strengthRangeDetail: L10n { self == .auto ? .skinOverallRange : .skinStrengthRange }

    var label: L10n {
        switch self {
        case .auto: return .beautyOverall
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
        case .auto: return .beautyOverall
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

    var previewDetail: L10n {
        switch self {
        case .auto: return .faceOverallDetail
        case .slim: return .faceSlimDetail
        case .width: return .faceWidthDetail
        case .chin: return .faceChinDetail
        case .forehead: return .faceForeheadDetail
        case .cheekbones: return .faceCheekbonesDetail
        case .eyes, .eyeSpacing, .eyeHeight, .noseWidth, .noseLength, .mouthShape, .mouthWidth:
            return .faceUnavailableDetail
        }
    }

    var strengthRangeDetail: L10n? {
        switch self {
        case .auto: return .faceOverallRange
        case .slim, .width, .chin, .forehead, .cheekbones: return .faceStrengthRange
        case .eyes, .eyeSpacing, .eyeHeight, .noseWidth, .noseLength, .mouthShape, .mouthWidth:
            return nil
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
