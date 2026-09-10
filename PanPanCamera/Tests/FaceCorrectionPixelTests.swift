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
            XCTAssertEqual(fullGeometry.warps.count, 2)
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
            XCTAssertEqual(preview100.geometryDebug?.smallFaceWarps, fullGeometry.smallFaceWarps)
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
                let warp = FaceCorrectionWarp(kind: .slimLeft, center: center,
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
        }.value
    }

    func testProductionMetalRenderTargetContainsLocalizedPixelChanges() async throws {
        try await Task.detached { [self] in
            guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
                throw XCTSkip("Metal unavailable; render-target pixel verification NOT EXECUTED")
            }
            let buffer = try fixtureBuffer()
            let source = CIImage(cvPixelBuffer: buffer)
            let processor = BeautyImageProcessor()
            let output = try XCTUnwrap(processor.previewImage(for: BeautyPreviewFrame(
                pixelBuffer: buffer, orientation: .up, mirrored: false,
                faces: [fixtureFace()], configuration: configuration(1)),
                displayRotationAngle: 0, targetSize: extent.size))
            func render(_ image: CIImage) throws -> [UInt8] {
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb,
                    width: Int(extent.width), height: Int(extent.height), mipmapped: false)
                descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
                descriptor.storageMode = .shared
                let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
                let command = try XCTUnwrap(queue.makeCommandBuffer())
                // Identical submission primitive, bounds and format to BeautyPreviewRenderer.
                CoreImageRendering.render(image, to: texture, commandBuffer: command,
                                          bounds: extent, colorSpace: colorSpace)
                command.commit()
                command.waitUntilCompleted()
                XCTAssertEqual(command.status, .completed, "\(String(describing: command.error))")
                var bytes = [UInt8](repeating: 0, count: Int(extent.width * extent.height) * 4)
                bytes.withUnsafeMutableBytes {
                    texture.getBytes($0.baseAddress!, bytesPerRow: Int(extent.width) * 4,
                        from: MTLRegionMake2D(0, 0, Int(extent.width), Int(extent.height)), mipmapLevel: 0)
                }
                return bytes
            }
            let original = try render(source)
            let full = try render(output)
            let warps = FaceCorrectionGeometry.warps(faces: [fixtureFace()],
                configuration: configuration(1), extent: extent)
            // Calibrate raw readback rows against known CI Y coordinates, using
            // the same render target; never infer locality from changed pixels.
            let topLeftRows = rowsStartAtTop(try render(coordinateRamp()))
            let diff = difference(original, full, warps: warps, topLeftRows: topLeftRows)
            print("FaceCorrection Metal texture pixel metrics: \(diff.json)")
            assertLocalizedChange(diff)
        }.value
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
        return DetectedFace(boundingBox: box, confidence: 1, landmarks: [.faceContour: points.map {
            CGPoint(x: box.minX + $0.x * box.width, y: box.minY + $0.y * box.height)
        }])
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
