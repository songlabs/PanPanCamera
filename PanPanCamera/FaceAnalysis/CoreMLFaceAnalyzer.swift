import CoreImage
import CoreML
import CoreVideo
import Foundation

/// Export contract, not a claim that arbitrary pretrained models are compatible.
/// See docs/FaceAnalysisArchitecture.md for the artifact/licensing release blocker.
struct CoreMLFaceModelAsset {
    let compiledURL: URL
    let inputWidth: Int
    let inputHeight: Int
    let outputName: String
}

struct CoreMLFaceModelAssets {
    let detection: CoreMLFaceModelAsset
    let landmarks: CoreMLFaceModelAsset
    let parsing: CoreMLFaceModelAsset
    let topology: FaceLandmarkTopology
    let parsingClasses: [FaceSemanticClass]

    // Deliberately no resource lookup or remote download. This must be replaced
    // by an audited, pinned asset manifest AFTER conversion/device validation.
    static let bundled: Self? = nil
}

/// Each instance and its lazy model belong to the engine queue for their lifetime.
final class CoreMLFacePrediction {
    private let asset: CoreMLFaceModelAsset
    private let context: CIContext
    private lazy var model: Result<MLModel, Error> = Result {
        guard asset.compiledURL.isFileURL, asset.compiledURL.pathExtension == "mlmodelc",
              (16...1024).contains(asset.inputWidth), (16...1024).contains(asset.inputHeight)
        else { throw FaceAnalysisFailure.invalidModel }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        let model = try MLModel(contentsOf: asset.compiledURL, configuration: configuration)
        guard let constraint = model.modelDescription.inputDescriptionsByName["image"]?.imageConstraint,
              constraint.pixelsWide == asset.inputWidth, constraint.pixelsHigh == asset.inputHeight,
              constraint.pixelFormatType == kCVPixelFormatType_32BGRA,
              model.modelDescription.outputDescriptionsByName[asset.outputName]?.type == .multiArray
        else { throw FaceAnalysisFailure.invalidModel }
        return model
    }

    init(asset: CoreMLFaceModelAsset, context: CIContext) { self.asset = asset; self.context = context }

    func predict(_ image: CIImage, faceBox: CGRect? = nil) throws -> MLMultiArray {
        dispatchPrecondition(condition: .notOnQueue(.main))
        let model = try model.get()
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, asset.inputWidth, asset.inputHeight,
            kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        guard status == kCVReturnSuccess, let buffer else { throw FaceAnalysisFailure.invalidImage }
        let zero = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        // Exported model handles RGB normalization and any aspect distortion.
        // Entire normalized image is supplied, never a guessed forehead crop.
        let scaled = zero.transformed(by: CGAffineTransform(
            scaleX: CGFloat(asset.inputWidth) / image.extent.width,
            y: CGFloat(asset.inputHeight) / image.extent.height))
        context.render(scaled, to: buffer, bounds: scaled.extent, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        var inputs: [String: Any] = ["image": MLFeatureValue(pixelBuffer: buffer)]
        if let faceBox {
            let roi = try MLMultiArray(shape: [4], dataType: .float32)
            for (index, value) in [faceBox.minX, faceBox.minY, faceBox.width, faceBox.height].enumerated() {
                roi[index] = NSNumber(value: Double(value))
            }
            inputs["face_box"] = MLFeatureValue(multiArray: roi)
        }
        let output = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: inputs))
        guard let values = output.featureValue(for: asset.outputName)?.multiArrayValue else {
            throw FaceAnalysisFailure.invalidOutput
        }
        return values
    }
}

final class CoreMLFaceAnalyzer: FaceAnalyzer {
    private let assets: CoreMLFaceModelAssets?
    private lazy var context = CIContext(options: [.cacheIntermediates: false])
    private lazy var detector = assets.map { CoreMLFaceDetector(prediction: CoreMLFacePrediction(asset: $0.detection, context: context)) }
    private lazy var landmarks = assets.map { CoreMLFaceLandmarkDetector(
        prediction: CoreMLFacePrediction(asset: $0.landmarks, context: context), topology: $0.topology) }
    private lazy var parser = assets.map { CoreMLFaceParser(
        prediction: CoreMLFacePrediction(asset: $0.parsing, context: context), classes: $0.parsingClasses) }

    init(assets: CoreMLFaceModelAssets? = CoreMLFaceModelAssets.bundled) { self.assets = assets }

    func faces(in normalizedImage: CIImage) throws -> [AnalyzedFace] {
        guard let detector else { throw FaceAnalysisFailure.modelsUnavailable }
        return try detector.detect(normalizedImage).map { detection in
            // Failures are independent: parsing can keep Skin alive without points,
            // and valid points can keep Makeup/Shape alive without parsing.
            let points = try? landmarks?.detect(normalizedImage, faceBox: detection.box)
            let masks = try? parser?.parse(normalizedImage, faceBox: detection.box)
            return AnalyzedFace(boundingBox: detection.box, confidence: detection.confidence,
                landmarks: points ?? .unavailable, semanticMasks: masks)
        }
    }
}
