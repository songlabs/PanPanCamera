#if DEBUG
import CoreImage
import ImageIO
import Metal
import XCTest
@testable import PanPanCamera

/// Synthetic pixels only. These tests require Apple's Core Image / Metal runtime;
/// graph creation, Swift parsing and host-side geometry checks cannot replace them.
final class FaceCorrectionPixelTests: XCTestCase {
    private let extent = CGRect(x: 0, y: 0, width: 256, height: 384)
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    func testFixedFrameZeroAndHundredPixelsAndLocalArtifacts() async throws {
        try await Task.detached { [self] in
            let buffer = try fixtureBuffer()
            let source = CIImage(cvPixelBuffer: buffer)
            let face = fixtureFace()
            let step = FaceCorrectionPreviewStep()
            let processor = BeautyImageProcessor()
            let zeroGeometry = FaceCorrectionGeometry.result(faces: [face],
                configuration: configuration(0), extent: extent)
            let fullGeometry = FaceCorrectionGeometry.result(faces: [face],
                configuration: configuration(1), extent: extent)
            XCTAssertTrue(zeroGeometry.warps.isEmpty)
            XCTAssertTrue(zeroGeometry.smallFaceWarps.allSatisfy { $0.visibleOffset == .zero })
            XCTAssertEqual(fullGeometry.warps.count, 12)
            let direct0 = try step.makeOutput(source: source, warps: zeroGeometry.warps)
            XCTAssertNil(direct0)
            let direct100 = try XCTUnwrap(step.makeOutput(source: source, warps: fullGeometry.warps))

            func preview(_ strength: Double) throws -> BeautyPreviewProcessingResult {
                // Same buffer object, face, orientation, mirror and drawable extent.
                try processor.previewResult(for: BeautyPreviewFrame(pixelBuffer: buffer,
                    orientation: .up, mirrored: false, faces: [face],
                    configuration: configuration(strength)),
                    displayRotationAngle: 0, targetSize: extent.size)
            }
            let preview0 = try preview(0)
            let preview100 = try preview(1)
            XCTAssertNil(preview0.image) // Production shows the original layer at zero.
            let previewWarps = try XCTUnwrap(preview100.geometryDebug?.smallFaceWarps)
            XCTAssertEqual(previewWarps.count, fullGeometry.smallFaceWarps.count)
            for (actual, expected) in zip(previewWarps, fullGeometry.smallFaceWarps) {
                XCTAssertEqual(actual.kind, expected.kind)
                // Preview reconstructs/fits the face box, even for an identity transform.
                // Floating-point round trips are not bit-identical (about 7e-15 px here).
                // One billionth of a pixel tolerates arithmetic noise, not geometry changes.
                XCTAssertEqual(actual.center.x, expected.center.x, accuracy: 1e-9)
                XCTAssertEqual(actual.center.y, expected.center.y, accuracy: 1e-9)
                XCTAssertEqual(actual.radius, expected.radius, accuracy: 1e-9)
                XCTAssertEqual(actual.visibleOffset.dx, expected.visibleOffset.dx, accuracy: 1e-9)
                XCTAssertEqual(actual.visibleOffset.dy, expected.visibleOffset.dy, accuracy: 1e-9)
            }
            let processed100 = try XCTUnwrap(preview100.image)
            let original = try pixels(source)
            let zero = try pixels(preview0.image ?? source)
            let full = try pixels(processed100)
            let direct = try pixels(direct100)
            XCTAssertEqual(processed100.extent, extent)
            XCTAssertEqual(direct.bytes, full.bytes, "Renderer input must retain the Face Correction output")

            let topLeftRows = rowsStartAtTop(try pixels(coordinateRamp()).bytes)
            let zeroDiff = difference(original.bytes, zero.bytes, warps: fullGeometry.warps,
                                      topLeftRows: topLeftRows)
            let fullDiff = difference(zero.bytes, full.bytes, warps: fullGeometry.warps,
                                      topLeftRows: topLeftRows)
            let map = try step.displacementMap(for: fullGeometry.warps, extent: extent)
            // Keep the former consumer only in this test, using the SAME production
            // map, to measure the pre-fix behavior on Apple rather than speculate.
            let legacy = try CoreImageRendering.filter("CIDisplacementDistortion", parameters: [
                kCIInputImageKey: source.clampedToExtent(),
                "inputDisplacementImage": map.image, kCIInputScaleKey: map.scale
            ], in: extent)
            let legacyPixels = try pixels(legacy)
            let report: [String: Any] = [
                "input": "fixed synthetic grid; no real camera image",
                "extent": [256, 384], "orientation": "up", "mirrored": false,
                "readbackRowsStartAtTop": topLeftRows,
                "faceAuto": 0.5, "scalePixels": Double(map.scale),
                "mapExtent": [Double(map.image.extent.minX), Double(map.image.extent.minY),
                              Double(map.image.extent.width), Double(map.image.extent.height)],
                "mapReadbackFormat": "RGBAf, extendedLinearSRGB",
                "neutralMapRGBA": floatPixel(map.image, at: CGPoint(x: 1, y: 1)).map(Double.init),
                "smallFace0": zeroDiff.json, "smallFace100": fullDiff.json,
                "legacyConsumer100": difference(zero.bytes, legacyPixels.bytes,
                                                warps: fullGeometry.warps, topLeftRows: topLeftRows).json,
                "warps": fullGeometry.warps.map { warp in
                    ["center": [Double(warp.center.x), Double(warp.center.y)],
                     "radius": [Double(warp.radius)],
                     "visibleOffsetPixels": [Double(warp.visibleOffset.dx), Double(warp.visibleOffset.dy)],
                     "measuredMapRGBA": floatPixel(map.image, at: warp.center).map(Double.init)]
                }
            ]
            // Write before assertions, so a failed pixel regression leaves evidence.
            let directory = try saveArtifacts(original: original.image, zero: zero.image,
                full: full.image, diff: fullDiff.absoluteRGBA, map: map.image,
                legacy: legacyPixels.image, report: report)
            print("FaceCorrection synthetic pixel artifacts (local only): \(directory.path)")
            print("FaceCorrection pixel metrics: \(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))")
            XCTAssertEqual(zeroDiff.all.changed, 0)
            XCTAssertEqual(zeroDiff.all.maximum, 0)
            XCTAssertEqual(original.bytes, zero.bytes)
            XCTAssertNotEqual(zero.bytes, full.bytes, "Small Face 100 must change rendered pixels")
            assertLocalizedChange(fullDiff)
        }.value
    }

    func testNoFaceAndDisabledRemainExactPixelBypasses() async throws {
        try await Task.detached { [self] in
            let buffer = try fixtureBuffer()
            let source = CIImage(cvPixelBuffer: buffer)
            let processor = BeautyImageProcessor()
            let expected = try pixels(source).bytes
            for (faces, config) in [([DetectedFace](), configuration(1)), ([fixtureFace()], .disabled)] {
                let frame = BeautyPreviewFrame(pixelBuffer: buffer, orientation: .up,
                    mirrored: false, faces: faces, configuration: config)
                let result = try processor.previewResult(for: frame,
                    displayRotationAngle: 0, targetSize: extent.size)
                XCTAssertNil(result.image)
                XCTAssertEqual(try pixels(result.image ?? source).bytes, expected)
                XCTAssertNil(try FaceCorrectionPreviewStep().makeOutput(source: source,
                    faces: faces, configuration: config))
            }
        }.value
    }

    func testOverlappingVectorsAccumulateWithoutErasureClippingOrOrderDependence() async throws {
        try await Task.detached { [self] in
            let source = try coordinateRamp()
            let center = CGPoint(x: extent.midX, y: extent.midY)
            let step = FaceCorrectionPreviewStep()
            let offsets = [CGVector(dx: 12, dy: 0), CGVector(dx: 2, dy: 0), CGVector(dx: 0, dy: 7)]
            let warps = offsets.map {
                FaceCorrectionWarp(kind: .widthLeft, center: center, radius: 48, visibleOffset: $0)
            }
            for ordered in [warps, Array(warps.reversed())] {
                let map = try step.displacementMap(for: ordered, extent: extent)
                let encoded = floatPixel(map.image, at: center)
                XCTAssertEqual((Double(encoded[0]) - 0.5) * Double(map.scale), -14, accuracy: 0.05)
                XCTAssertEqual((Double(encoded[1]) - 0.5) * Double(map.scale), -7, accuracy: 0.05)
                XCTAssertEqual(encoded[3], 1, accuracy: 0.001)
                let output = try XCTUnwrap(step.makeOutput(source: source, warps: ordered))
                let before = floatPixel(source, at: center), after = floatPixel(output, at: center)
                XCTAssertEqual(Double(after[0] - before[0]) * Double(extent.width), -14, accuracy: 0.25)
                XCTAssertEqual(Double(after[1] - before[1]) * Double(extent.height), -7, accuracy: 0.25)
            }
            let opposite = FaceCorrectionWarp(kind: .widthRight, center: center, radius: 48,
                                              visibleOffset: CGVector(dx: -12, dy: 0))
            let cancelled = try XCTUnwrap(step.makeOutput(source: source, warps: [warps[0], opposite]))
            let expected = floatPixel(source, at: center), actual = floatPixel(cancelled, at: center)
            XCTAssertEqual(actual[0], expected[0], accuracy: 0.001)
            XCTAssertEqual(actual[1], expected[1], accuracy: 0.001)
        }.value
    }

    func testEveryFaceControlChangesFixedPreviewPixelsAtZeroHalfAndFull() async throws {
        try await Task.detached { [self] in
            let buffer = try fixtureBuffer()
            let source = CIImage(cvPixelBuffer: buffer)
            let processor = BeautyImageProcessor()
            let original = try pixels(source).bytes
            let topLeftRows = rowsStartAtTop(try pixels(coordinateRamp()).bytes)
            for tool in [FaceTool.slim, .width, .chin, .forehead, .cheekbones] {
                var outputs: [[UInt8]] = []
                var changes: [Double] = []
                for strength in [0.0, 0.5, 1.0] {
                    var parameters = BeautyParameters()
                    for makeup in MakeupTool.allCases { parameters.setValue(0, for: makeup) }
                    parameters.setValue(0, for: SkinTool.auto)
                    for other in FaceTool.allCases where other != .auto { parameters.setValue(0, for: other) }
                    parameters.setValue(strength * 100, for: tool)
                    let result = try processor.previewResult(for: BeautyPreviewFrame(pixelBuffer: buffer,
                        orientation: .up, mirrored: false, faces: [fixtureFace()],
                        configuration: parameters.processingConfiguration), displayRotationAngle: 0,
                        targetSize: extent.size)
                    let bytes = try pixels(result.image ?? source).bytes
                    if strength == 0 { XCTAssertNil(result.image); XCTAssertEqual(bytes, original) }
                    else { XCTAssertNotNil(result.image) }
                    let diff = difference(original, bytes, warps: result.geometryDebug?.warps ?? [],
                                          topLeftRows: topLeftRows)
                    if strength > 0 {
                        XCTAssertGreaterThan(diff.inside.changed, 0, tool.rawValue)
                        XCTAssertLessThanOrEqual(diff.outside.maximum, 2, tool.rawValue)
                        XCTAssertLessThanOrEqual(diff.outside.mean, 0.05, tool.rawValue)
                    }
                    outputs.append(bytes)
                    changes.append(diff.all.mean)
                }
                XCTAssertNotEqual(outputs[0], outputs[1], tool.rawValue)
                XCTAssertNotEqual(outputs[1], outputs[2], tool.rawValue)
                XCTAssertGreaterThan(changes[1], changes[0], tool.rawValue)
                XCTAssertGreaterThan(changes[2], changes[1], tool.rawValue)
                print("BeautyStrength fixed Preview pixels: \(tool.rawValue) zero/half/full mean differences=\(changes)")
            }
        }.value
    }

    func testDefaultEffectsRetainEveryControlsPixelContributionAndLatestStrength() async throws {
        try await Task.detached { [self] in
            let source = try coordinateRamp()
            let face = fixtureFace()
            let step = FaceCorrectionPreviewStep()
            let controls: [(FaceTool, FaceCorrectionWarp.Kind)] = [
                (.slim, .slimLeft), (.width, .widthLeft), (.chin, .chinCenter),
                (.forehead, .foreheadLeft), (.cheekbones, .cheekbonesLeft)
            ]
            for (tool, kind) in controls {
                var samples: [[Float]] = []
                var expected: CGVector = .zero
                for strength in [0.0, 0.5, 1.0, 0.0] {
                    var parameters = BeautyParameters() // Other face controls stay enabled at 50.
                    parameters.setValue(strength * 100, for: tool)
                    let config = parameters.processingConfiguration
                    let warps = FaceCorrectionGeometry.warps(faces: [face], configuration: config, extent: extent)
                    parameters.setValue(100, for: tool)
                    let fullWarps = FaceCorrectionGeometry.warps(faces: [face],
                        configuration: parameters.processingConfiguration, extent: extent)
                    let anchor = try XCTUnwrap(fullWarps.first { $0.kind == kind })
                    // Match the one-pixel readback's sample center exactly.
                    let point = CGPoint(x: floor(anchor.center.x) + 0.5, y: floor(anchor.center.y) + 0.5)
                    let output = try XCTUnwrap(step.makeOutput(source: source, warps: warps))
                    samples.append(floatPixel(output, at: point))
                    // Independent oracle: changing one slider adds only that tool's
                    // feathered vectors, even while every other effect remains on.
                    let toolKinds: [FaceCorrectionWarp.Kind]
                    switch tool {
                    case .slim: toolKinds = [.slimLeft, .slimRight]
                    case .width: toolKinds = [.widthLeft, .widthRight]
                    case .chin: toolKinds = [.chinLeft, .chinCenter, .chinRight]
                    case .forehead: toolKinds = [.foreheadLeft, .foreheadRight]
                    default: toolKinds = [.cheekbonesLeft, .cheekbonesRight]
                    }
                    let selected = fullWarps.filter { toolKinds.contains($0.kind) }
                    expected = selected.reduce(CGVector.zero) { total, warp in
                        let distance = hypot(point.x - warp.center.x, point.y - warp.center.y)
                        let weight = min(1, max(0, (warp.radius - distance) / (warp.radius * 0.7)))
                        return CGVector(dx: total.dx - warp.visibleOffset.dx * weight,
                                        dy: total.dy - warp.visibleOffset.dy * weight)
                    }
                    if tool == .slim {
                        expected = CGVector(dx: -slimOffset(selected, at: point), dy: 0)
                    }
                }
                for (index, strength) in [(1, 0.5), (2, 1.0), (3, 0.0)] {
                    let dx = Double(samples[index][0] - samples[0][0]) * Double(extent.width)
                    let dy = Double(samples[index][1] - samples[0][1]) * Double(extent.height)
                    XCTAssertEqual(dx, Double(expected.dx) * strength, accuracy: 0.15, tool.rawValue)
                    XCTAssertEqual(dy, Double(expected.dy) * strength, accuracy: 0.15, tool.rawValue)
                }
            }
        }.value
    }

    func testMapAndSamplingPreservePixelUnitsXYSignFalloffAndNonzeroExtent() async throws {
        try await Task.detached { [self] in
            // RG coordinate ramps reveal the sampled X/Y position, independently
            // of grid visibility. No color-management disabling or camera motion.
            let shiftedExtent = extent.offsetBy(dx: 37, dy: 19)
            let center = CGPoint(x: shiftedExtent.midX, y: shiftedExtent.midY)
            let ramp = try coordinateRamp().transformed(by: CGAffineTransform(translationX: 37, y: 19))
            let step = FaceCorrectionPreviewStep()
            for offset in [CGVector(dx: 12.5, dy: 0), CGVector(dx: -12.5, dy: 0),
                           CGVector(dx: 0, dy: 7.5), CGVector(dx: 0, dy: -7.5)] {
                let warp = FaceCorrectionWarp(kind: .widthLeft, center: center,
                                               radius: 48, visibleOffset: offset)
                let map = try step.displacementMap(for: [warp], extent: shiftedExtent)
                XCTAssertEqual(map.image.extent, shiftedExtent)
                let rgba = floatPixel(map.image, at: center)
                XCTAssertEqual((Double(rgba[0]) - 0.5) * Double(map.scale), -Double(offset.dx), accuracy: 0.05)
                XCTAssertEqual((Double(rgba[1]) - 0.5) * Double(map.scale), -Double(offset.dy), accuracy: 0.05)
                XCTAssertEqual(rgba[3], 1, accuracy: 0.001)
                let corner = floatPixel(map.image, at: CGPoint(x: 40, y: 22))
                XCTAssertEqual(corner[0], 0.5, accuracy: 0.001)
                XCTAssertEqual(corner[1], 0.5, accuracy: 0.001)
                let feather = floatPixel(map.image, at: CGPoint(x: center.x + 32, y: center.y))
                let magnitude = hypot(Double(feather[0]) - 0.5, Double(feather[1]) - 0.5)
                print("FaceCorrection map samples: offset=\(offset) scale=\(map.scale) " +
                      "extent=\(map.image.extent) centerRGBA=\(rgba) neutralRGBA=\(corner) falloffRGBA=\(feather)")
                XCTAssertGreaterThan(magnitude, 0.01)
                XCTAssertLessThan(magnitude, 0.49)

                let output = try XCTUnwrap(step.makeOutput(source: ramp, warps: [warp]))
                let actual = floatPixel(output, at: center)
                let before = floatPixel(ramp, at: center)
                XCTAssertEqual(Double(actual[0] - before[0]) * Double(extent.width),
                               -Double(offset.dx), accuracy: 0.25)
                XCTAssertEqual(Double(actual[1] - before[1]) * Double(extent.height),
                               -Double(offset.dy), accuracy: 0.25)
                XCTAssertEqual(output.extent, shiftedExtent)
                let legacy = try CoreImageRendering.filter("CIDisplacementDistortion", parameters: [
                    kCIInputImageKey: ramp.clampedToExtent(),
                    "inputDisplacementImage": map.image, kCIInputScaleKey: map.scale
                ], in: shiftedExtent)
                let legacyPixel = floatPixel(legacy, at: center)
                print("FaceCorrection sampling pixels: expected=\([-offset.dx, -offset.dy]) " +
                      "actual=\([Double(actual[0] - before[0]) * Double(extent.width), Double(actual[1] - before[1]) * Double(extent.height)]) " +
                      "legacy=\([Double(legacyPixel[0] - before[0]) * Double(extent.width), Double(legacyPixel[1] - before[1]) * Double(extent.height)])")
            }
            let productionWarps = FaceCorrectionGeometry.warps(faces: [fixtureFace()],
                configuration: configuration(1), extent: extent)
            XCTAssertEqual(productionWarps.count, 12)
            let productionRamp = try coordinateRamp()
            let productionOutput = try XCTUnwrap(step.makeOutput(source: productionRamp, warps: productionWarps))
            for warp in productionWarps {
                let before = floatPixel(productionRamp, at: warp.center)
                let after = floatPixel(productionOutput, at: warp.center)
                let sampledDX = Double(after[0] - before[0]) * Double(extent.width)
                let sampledDY = Double(after[1] - before[1]) * Double(extent.height)
                let sample = CGPoint(x: floor(warp.center.x) + 0.5, y: floor(warp.center.y) + 0.5)
                XCTAssertEqual(sampledDX, -Double(slimOffset(productionWarps, at: sample)), accuracy: 0.25)
                XCTAssertEqual(sampledDY, -Double(warp.visibleOffset.dy), accuracy: 0.25)
                print("FaceCorrection production direction: kind=\(warp.kind) " +
                      "visibleOffset=\(warp.visibleOffset) sampledOffset=\([sampledDX, sampledDY])")
            }
        }.value
    }

    func testMetalDestinationPixelFormatCapabilityProbe() async throws {
        try await Task.detached { [self] in
            let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(),
                                       "Metal is required for the destination format probe")
            let queue = try XCTUnwrap(device.makeCommandQueue())
            let renderer = CoreImageRendering.MetalRenderer(device: queue.device)
            let ramp = try coordinateRamp()

            for pixelFormat in [MTLPixelFormat.bgra8Unorm_srgb, .bgra8Unorm] {
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: pixelFormat,
                    width: Int(extent.width), height: Int(extent.height), mipmapped: false)
                descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
                descriptor.storageMode = .shared
                let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
                let command = try XCTUnwrap(queue.makeCommandBuffer())
                var renderError: Error?
                do {
                    try renderer.render(ramp, to: texture, commandBuffer: command,
                                        bounds: extent, colorSpace: colorSpace)
                } catch {
                    renderError = error
                }
                command.commit()
                command.waitUntilCompleted()

                var bytes = [UInt8](repeating: 0, count: Int(extent.width * extent.height) * 4)
                bytes.withUnsafeMutableBytes {
                    texture.getBytes($0.baseAddress!, bytesPerRow: Int(extent.width) * 4,
                        from: MTLRegionMake2D(0, 0, Int(extent.width), Int(extent.height)), mipmapLevel: 0)
                }
                let alpha = stride(from: 3, to: bytes.count, by: 4).map { bytes[$0] }
                let rgbNonzero = stride(from: 0, to: bytes.count, by: 4).reduce(into: 0) { count, index in
                    if bytes[index] != 0 || bytes[index + 1] != 0 || bytes[index + 2] != 0 {
                        count += 1
                    }
                }
                let green = stride(from: 1, to: bytes.count, by: 4).map { bytes[$0] }
                let report: [String: Any] = [
                    "renderAPI": "CIRenderDestination.startTask",
                    "pixelFormat": pixelFormat == .bgra8Unorm_srgb ? "bgra8Unorm_srgb" : "bgra8Unorm",
                    "renderTaskCreated": renderError == nil,
                    "renderTaskError": renderError.map { String(describing: $0) } ?? "none",
                    "commandBufferStatus": command.status.rawValue,
                    "commandBufferError": command.error.map { String(describing: $0) } ?? "none",
                    "alphaWritten": alpha.allSatisfy { $0 == 255 },
                    "opaquePixelCount": alpha.reduce(into: 0) { if $1 == 255 { $0 += 1 } },
                    "rgbNonzeroPixelCount": rgbNonzero,
                    "coordinateSpan": Int(green.max() ?? 0) - Int(green.min() ?? 0)
                ]
                print("Metal destination pixel format probe: " +
                      String(decoding: try JSONSerialization.data(withJSONObject: report,
                          options: [.sortedKeys]), as: UTF8.self))
            }
        }.value
    }

    func testProductionMetalColorChannelAndTransferRemainSane() async throws {
        try await Task.detached { [self] in
            let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(),
                                       "Metal is required for Preview color verification")
            let queue = try XCTUnwrap(device.makeCommandQueue())
            let renderer = CoreImageRendering.MetalRenderer(device: queue.device)
            // RGBA source patches: black, white, 50% gray, and a red-dominant color.
            let sourceBytes: [UInt8] = [
                0, 0, 0, 255, 255, 255, 255, 255,
                128, 128, 128, 255, 204, 77, 26, 255
            ]
            let size = CGSize(width: 4, height: 1)
            let image = CIImage(bitmapData: Data(sourceBytes), bytesPerRow: 16, size: size,
                                format: .RGBA8, colorSpace: colorSpace)
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                width: 4, height: 1, mipmapped: false)
            descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
            descriptor.storageMode = .shared
            let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
            let command = try XCTUnwrap(queue.makeCommandBuffer())
            try renderer.render(image, to: texture, commandBuffer: command,
                                bounds: CGRect(origin: .zero, size: size), colorSpace: colorSpace)
            command.commit()
            command.waitUntilCompleted()
            XCTAssertEqual(command.status, .completed, "\(String(describing: command.error))")

            var output = [UInt8](repeating: 0, count: 16)
            output.withUnsafeMutableBytes {
                texture.getBytes($0.baseAddress!, bytesPerRow: 16,
                    from: MTLRegionMake2D(0, 0, 4, 1), mipmapLevel: 0)
            }
            let pixels = stride(from: 0, to: output.count, by: 4).map {
                Array(output[$0..<($0 + 4)]) // Metal BGRA byte order.
            }
            XCTAssertTrue(pixels.allSatisfy { $0[3] == 255 })
            XCTAssertLessThanOrEqual(pixels[0][0...2].max() ?? 255, 2)
            XCTAssertGreaterThanOrEqual(pixels[1][0...2].min() ?? 0, 253)
            XCTAssertLessThanOrEqual(Int(pixels[2][0...2].max() ?? 255) -
                                       Int(pixels[2][0...2].min() ?? 0), 2)
            XCTAssertGreaterThanOrEqual(pixels[2][0], 112)
            XCTAssertLessThanOrEqual(pixels[2][0], 144)
            XCTAssertGreaterThan(pixels[3][2], pixels[3][1], "Red must remain red in BGRA storage")
            XCTAssertGreaterThan(pixels[3][1], pixels[3][0])
            for (actual, expected) in zip(pixels[3], [UInt8(26), 77, 204, 255]) {
                XCTAssertLessThanOrEqual(abs(Int(actual) - Int(expected)), 8)
            }
            print("Metal BGRA8Unorm color regression pixels (BGRA): \(pixels)")
        }.value
    }

    func testProductionMetalRenderTargetContainsLocalizedPixelChanges() async throws {
        try await Task.detached { [self] in
            let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "Metal is required for Preview pixel verification")
            let queue = try XCTUnwrap(device.makeCommandQueue())
            let renderer = CoreImageRendering.MetalRenderer(device: queue.device)
            let buffer = try fixtureBuffer()
            let source = CIImage(cvPixelBuffer: buffer)
            let processor = BeautyImageProcessor()
            let zeroOutput = try processor.previewImage(for: BeautyPreviewFrame(
                pixelBuffer: buffer, orientation: .up, mirrored: false,
                faces: [fixtureFace()], configuration: configuration(0)),
                displayRotationAngle: 0, targetSize: extent.size)
            XCTAssertNil(zeroOutput)
            let output = try XCTUnwrap(processor.previewImage(for: BeautyPreviewFrame(
                pixelBuffer: buffer, orientation: .up, mirrored: false,
                faces: [fixtureFace()], configuration: configuration(1)),
                displayRotationAngle: 0, targetSize: extent.size))
            func render(_ image: CIImage) throws -> [UInt8] {
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                    width: Int(extent.width), height: Int(extent.height), mipmapped: false)
                descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
                descriptor.storageMode = .shared
                let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
                let command = try XCTUnwrap(queue.makeCommandBuffer())
                // Identical submission primitive, bounds and format to BeautyPreviewRenderer.
                try renderer.render(image, to: texture, commandBuffer: command,
                                    bounds: extent, colorSpace: colorSpace)
                command.commit()
                command.waitUntilCompleted()
                XCTAssertEqual(command.status, .completed, "\(String(describing: command.error))")
                var bytes = [UInt8](repeating: 0, count: Int(extent.width * extent.height) * 4)
                bytes.withUnsafeMutableBytes {
                    texture.getBytes($0.baseAddress!, bytesPerRow: Int(extent.width) * 4,
                        from: MTLRegionMake2D(0, 0, Int(extent.width), Int(extent.height)), mipmapLevel: 0)
                }
                XCTAssertTrue(stride(from: 3, to: bytes.count, by: 4).allSatisfy { bytes[$0] == 255 },
                              "Opaque BGRA output must be written; an empty completed command is not render success")
                return bytes
            }
            let original = try render(source)
            let zero = try render(zeroOutput ?? source)
            let full = try render(output)
            let warps = FaceCorrectionGeometry.warps(faces: [fixtureFace()],
                configuration: configuration(1), extent: extent)
            // Calibrate raw readback rows against known CI Y coordinates, using
            // the same render target; never infer locality from changed pixels.
            let topLeftRows = rowsStartAtTop(try render(coordinateRamp()))
            let zeroDiff = difference(original, zero, warps: warps, topLeftRows: topLeftRows)
            XCTAssertEqual(original, zero, "Small Face 0 must match the same Metal render-path baseline")
            print("FaceCorrection Metal smallFace0 pixel metrics: \(zeroDiff.json)")
            let diff = difference(zero, full, warps: warps, topLeftRows: topLeftRows)
            print("FaceCorrection Metal texture pixel metrics: \(diff.json)")
            assertLocalizedChange(diff)
        }.value
    }

    func testSlimFieldEveryRegionContributesWithoutOverwriteAndBoundsOverlap() async throws {
        try await Task.detached { [self] in
            let step = FaceCorrectionPreviewStep()
            let controls = FaceCorrectionGeometry.warps(faces: [fixtureFace()],
                configuration: configuration(1), extent: extent)
            XCTAssertEqual(controls.count, 12)
            for index in controls.indices {
                let anchor = controls[index]
                let point = CGPoint(x: floor(anchor.center.x) + 0.5, y: floor(anchor.center.y) + 0.5)
                func offset(_ warps: [FaceCorrectionWarp]) throws -> CGFloat {
                    let map = try step.displacementMap(for: warps, extent: extent)
                    return (0.5 - CGFloat(floatPixel(map.image, at: point)[0])) * map.scale
                }
                let baseline = try offset(controls)
                let expected = slimOffset(controls, at: point)
                XCTAssertEqual(baseline, expected, accuracy: 0.03)
                XCTAssertEqual(try offset(Array(controls.reversed())), baseline, accuracy: 0.03)
                XCTAssertLessThanOrEqual(abs(baseline), controls.map { abs($0.visibleOffset.dx) }.max()! + 0.03)
                var changed = controls
                changed[index] = FaceCorrectionWarp(kind: anchor.kind, center: anchor.center,
                    radius: anchor.radius, visibleOffset: CGVector(dx: anchor.visibleOffset.dx + 2, dy: 0))
                let actualDelta = try offset(changed) - baseline
                XCTAssertGreaterThan(actualDelta, 0.1, "Control \(index) must reach the actual map")
                XCTAssertEqual(actualDelta, slimOffset(changed, at: point) - expected, accuracy: 0.04)
            }
        }.value
    }

    func testSlimMapStrengthAndSupportEdgeRemainContinuous() async throws {
        try await Task.detached { [self] in
            let step = FaceCorrectionPreviewStep()
            let full = FaceCorrectionGeometry.warps(faces: [fixtureFace()],
                configuration: configuration(1), extent: extent)
            let center = try XCTUnwrap(full.first).center
            let sample = CGPoint(x: floor(center.x) + 0.5, y: floor(center.y) + 0.5)
            var values: [CGFloat] = []
            for strength in [0.49, 0.50, 0.51] {
                let controls = FaceCorrectionGeometry.warps(faces: [fixtureFace()],
                    configuration: configuration(strength), extent: extent)
                let map = try step.displacementMap(for: controls, extent: extent)
                let value = (0.5 - CGFloat(floatPixel(map.image, at: sample)[0])) * map.scale
                XCTAssertEqual(value, slimOffset(full, at: sample) * strength, accuracy: 0.03)
                values.append(value)
            }
            XCTAssertEqual(values[2] - values[1], values[1] - values[0], accuracy: 0.01)
            let single = FaceCorrectionWarp(kind: .slimLeft, center: CGPoint(x: 128.5, y: 192.5),
                                           radius: 48, visibleOffset: CGVector(dx: 12, dy: 0))
            let map = try step.displacementMap(for: [single], extent: extent)
            for distance in [47.0, 48.0, 49.0] {
                let p = CGPoint(x: single.center.x + distance, y: single.center.y)
                let value = (0.5 - CGFloat(floatPixel(map.image, at: p)[0])) * map.scale
                XCTAssertEqual(value, slimOffset([single], at: p), accuracy: 0.01)
                XCTAssertLessThan(abs(value), 0.03)
            }
        }.value
    }

    func testFullStrengthSlimMapHasNoHorizontalFold() async throws {
        try await Task.detached { [self] in
            // Face Auto = 1 as well as Slim = 1: exercise the full 12%-width input,
            // including overlapping outer supports in the background around the face.
            let warps = FaceCorrectionGeometry.warps(faces: [fixtureFace()],
                configuration: BeautyConfiguration(enabled: true, faceOverallStrength: 1,
                                                    faceSlimStrength: 1), extent: extent)
            let map = try FaceCorrectionPreviewStep().displacementMap(for: warps, extent: extent)
            let width = Int(extent.width), height = Int(extent.height)
            var values = [Float](repeating: 0, count: width * height * 4)
            let context = CIContext(options: [.cacheIntermediates: false])
            values.withUnsafeMutableBytes {
                context.render(map.image, toBitmap: $0.baseAddress!, rowBytes: width * 16,
                    bounds: extent, format: .RGBAf,
                    colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
            }
            var minimumJacobian: CGFloat = 1
            for row in 0..<height {
                for x in 0..<(width - 1) {
                    let i = (row * width + x) * 4
                    // Inverse X(p) = p.x + (R(p)-0.5)*scale must stay increasing.
                    let jacobian = 1 + CGFloat(values[i + 4] - values[i]) * map.scale
                    minimumJacobian = min(minimumJacobian, jacobian)
                }
            }
            XCTAssertGreaterThan(minimumJacobian, 0.1, "Full-strength outer overlap must not fold")
            let faceBox = fixtureFace().boundingBox
            let chin = CGPoint(x: extent.width * faceBox.midX,
                               y: extent.height * (faceBox.minY + faceBox.height * 0.03))
            let point = CGPoint(x: floor(chin.x) + 0.5, y: floor(chin.y) + 0.5)
            XCTAssertLessThan(abs(slimOffset(warps, at: point)), 0.5)
        }.value
    }

    // Independent scalar oracle for Apple's rendered normalized field. Tests above
    // compare real RG readback and source sampling; graph creation alone cannot pass.
    private func slimOffset(_ warps: [FaceCorrectionWarp], at point: CGPoint) -> CGFloat {
        var total: CGFloat = 0, offset: CGFloat = 0
        for warp in warps {
            let t = min(1, hypot(point.x - warp.center.x, point.y - warp.center.y) / warp.radius)
            let weight = 1 - t * t * (3 - 2 * t)
            total += weight
            offset += weight * warp.visibleOffset.dx
        }
        return offset / sqrt(1 + total * total)
    }

    private func configuration(_ strength: Double) -> BeautyConfiguration {
        // Isolate Slim from skin and every other face control, with production Auto = 50.
        BeautyConfiguration(enabled: true, faceOverallStrength: 0.5, faceSlimStrength: strength)
    }

    private func fixtureFace() -> DetectedFace {
        let box = CGRect(x: 0.2, y: 0.1, width: 0.6, height: 0.8)
        let points: [CGPoint] = [CGPoint(x: 0.08, y: 0.58), CGPoint(x: 0.10, y: 0.42),
            CGPoint(x: 0.18, y: 0.24), CGPoint(x: 0.34, y: 0.08), CGPoint(x: 0.50, y: 0.03),
            CGPoint(x: 0.66, y: 0.08), CGPoint(x: 0.82, y: 0.24), CGPoint(x: 0.90, y: 0.42),
            CGPoint(x: 0.92, y: 0.58)]
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: box.minX + x * box.width, y: box.minY + y * box.height)
        }
        return DetectedFace(boundingBox: box, confidence: 1, landmarks: [
            .faceContour: points.map { point($0.x, $0.y) },
            .leftEyebrow: [point(0.24, 0.70), point(0.36, 0.72)],
            .rightEyebrow: [point(0.64, 0.72), point(0.76, 0.70)]
        ])
    }

    private func fixtureBuffer() throws -> CVPixelBuffer {
        var result: CVPixelBuffer?
        let width = Int(extent.width), height = Int(extent.height)
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, width, height,
            kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
            &result), kCVReturnSuccess)
        let buffer = try XCTUnwrap(result)
        XCTAssertEqual(CVPixelBufferLockBaseAddress(buffer, []), kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            for x in 0..<width {
                let i = y * stride + x * 4
                base[i] = UInt8(40 + (x * 7 + y * 3) % 160)
                base[i + 1] = y % 16 < 3 ? 230 : 55
                base[i + 2] = x % 16 < 3 ? 235 : 65
                base[i + 3] = 255
            }
        }
        return buffer
    }

    private func coordinateRamp() throws -> CIImage {
        // Analytic CI coordinates avoid any bitmap row-order assumptions in the
        // X/Y sampling oracle. Kernel values already use the linear working space.
        let kernel = try XCTUnwrap(CIColorKernel(source: """
            kernel vec4 coordinateRamp() {
                vec2 p = destCoord();
                return vec4(p.x / 256.0, p.y / 384.0, 0.0, 1.0);
            }
            """))
        return try XCTUnwrap(kernel.apply(extent: extent, arguments: []))
    }

    private func floatPixel(_ image: CIImage, at point: CGPoint) -> [Float] {
        // Same default linear working space as production; linear output preserves RG numbers.
        let context = CIContext(options: [.cacheIntermediates: false])
        var values = [Float](repeating: 0, count: 4)
        values.withUnsafeMutableBytes {
            context.render(image, toBitmap: $0.baseAddress!, rowBytes: 16,
                bounds: CGRect(x: floor(point.x), y: floor(point.y), width: 1, height: 1),
                format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        }
        return values
    }

    private func pixels(_ image: CIImage) throws -> (image: CGImage, bytes: [UInt8]) {
        let rendered = try XCTUnwrap(CoreImageRendering.createCGImage(image, colorSpace: colorSpace))
        let data = try XCTUnwrap(rendered.dataProvider?.data)
        let base = try XCTUnwrap(CFDataGetBytePtr(data))
        XCTAssertEqual(rendered.bitsPerPixel, 32)
        var bytes: [UInt8] = []
        for row in 0..<rendered.height {
            bytes.append(contentsOf: UnsafeBufferPointer(start: base + row * rendered.bytesPerRow,
                                                         count: rendered.width * 4))
        }
        return (rendered, bytes)
    }

    private struct Metrics {
        var count = 0, changed = 0, maximum = 0, sum = 0
        mutating func add(_ differences: [Int]) {
            count += 1
            let maxChannel = differences.max() ?? 0
            if maxChannel > 0 { changed += 1 }
            maximum = max(maximum, maxChannel)
            sum += differences.reduce(0, +)
        }
        var ratio: Double { count == 0 ? 0 : Double(changed) / Double(count) }
        var mean: Double { count == 0 ? 0 : Double(sum) / Double(count * 4) }
        var json: [String: Any] {
            ["pixelCount": count, "changedPixelCount": changed, "changedPixelRatio": ratio,
             "maxChannelDifference_0_255": maximum, "meanAbsoluteDifference_0_255": mean]
        }
    }

    private struct Diff {
        var all = Metrics(), inside = Metrics(), outside = Metrics()
        var absoluteRGBA: [UInt8] = []
        var json: [String: Any] {
            ["all": all.json, "insideDeformation": inside.json, "outsideDeformation": outside.json,
             "bitIdentical": all.changed == 0]
        }
    }

    private func rowsStartAtTop(_ ramp: [UInt8]) -> Bool {
        // G is Y / height, and remains byte 1 in both RGBA8 and BGRA8.
        let lastRow = (Int(extent.height) - 1) * Int(extent.width) * 4
        XCTAssertGreaterThan(abs(Int(ramp[1]) - Int(ramp[lastRow + 1])), 200,
                             "The coordinate calibration must span the target height")
        return ramp[1] > ramp[lastRow + 1]
    }

    private func difference(_ a: [UInt8], _ b: [UInt8], warps: [FaceCorrectionWarp],
                            topLeftRows: Bool) -> Diff {
        var diff = Diff()
        let width = Int(extent.width), height = Int(extent.height)
        for index in 0..<(width * height) {
            let x = Double(index % width) + 0.5
            let row = index / width
            let y = Double(topLeftRows ? height - 1 - row : row) + 0.5
            // Two pixels cover map/source interpolation at the support boundary.
            let inside = warps.contains { hypot(x - $0.center.x, y - $0.center.y) <= $0.radius + 2 }
            let channels = (0..<4).map { abs(Int(a[index * 4 + $0]) - Int(b[index * 4 + $0])) }
            diff.all.add(channels)
            if inside { diff.inside.add(channels) } else { diff.outside.add(channels) }
            diff.absoluteRGBA.append(contentsOf: [UInt8(channels[0]), UInt8(channels[1]), UInt8(channels[2]), 255])
        }
        return diff
    }

    private func assertLocalizedChange(_ diff: Diff, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThan(diff.all.ratio, 0.005, file: file, line: line)
        XCTAssertGreaterThan(diff.inside.ratio, 0.15, file: file, line: line)
        XCTAssertGreaterThan(diff.inside.maximum, 32, file: file, line: line)
        XCTAssertGreaterThan(diff.inside.mean, 2, file: file, line: line)
        XCTAssertLessThanOrEqual(diff.outside.maximum, 2, file: file, line: line)
        XCTAssertLessThanOrEqual(diff.outside.mean, 0.05, file: file, line: line)
    }

    private func saveArtifacts(original: CGImage, zero: CGImage, full: CGImage, diff: [UInt8],
                               map: CIImage, legacy: CGImage, report: [String: Any]) throws -> URL {
        // Bounded local development output. No PhotoKit, upload or XCTest image
        // attachments (the existing CI uploads xcresult bundles).
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FaceCorrectionPixels")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Match the rendered CGImage's byte and row order for an aligned diff PNG.
        let diffImage = try XCTUnwrap(CGImage(width: original.width, height: original.height,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: original.width * 4,
            space: colorSpace, bitmapInfo: original.bitmapInfo,
            provider: try XCTUnwrap(CGDataProvider(data: Data(diff) as CFData)),
            decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        for (name, image) in [("original", original), ("smallFace0", zero), ("smallFace100", full),
                              ("absolute-diff", diffImage),
                              ("displacement-map", try pixels(map).image), ("legacy-smallFace100", legacy)] {
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
                directory.appendingPathComponent(name + ".png") as CFURL, "public.png" as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
        }
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("metrics.json"), options: .atomic)
        return directory
    }
}
#endif
