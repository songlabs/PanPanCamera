import XCTest
@testable import PanPanCamera

final class BeautyParametersTests: XCTestCase {
    func testEveryToolStartsAtFifty() {
        let values = BeautyParameters()
        for tool in SkinTool.allCases { XCTAssertEqual(values.value(for: tool), 50, tool.rawValue) }
        for tool in FaceTool.allCases { XCTAssertEqual(values.value(for: tool), 50, tool.rawValue) }
        XCTAssertEqual(values.selectedSkin, .auto)
        XCTAssertEqual(values.selectedFace, .auto)
        XCTAssertEqual(values.processingConfiguration, BeautyConfiguration(
            enabled: true, overallStrength: 0.5, smoothingStrength: 0.5,
            brighteningStrength: 0.5, toneStrength: 0.5,
            blemishStrength: 0.5, darkCirclesStrength: 0.5,
            faceOverallStrength: 0.5, faceSlimStrength: 0.5,
            faceWidthStrength: 0.5, chinStrength: 0.5,
            foreheadStrength: 0.5, cheekbonesStrength: 0.5,
            makeup: MakeupConfiguration(lip: 0.5, blush: 0.5, eye: 0.5, brow: 0.5)))
    }

    func testMakeupMappingAndToolSelectionPreserveIndependentValues() {
        var values = BeautyParameters()
        let controls: [(MakeupTool, KeyPath<MakeupConfiguration, Double>)] = [
            (.lip, \.lip), (.blush, \.blush), (.eye, \.eye), (.brow, \.brow)
        ]
        for (tool, key) in controls {
            XCTAssertEqual(values.value(for: tool), 50)
            values.select(tool)
            for strength in [0.0, 25, 50, 75, 100] {
                values.setValue(strength, for: values.selectedMakeup)
                XCTAssertEqual(values.processingConfiguration.makeup[keyPath: key], strength / 100)
                for (other, _) in controls where other != tool {
                    XCTAssertEqual(values.value(for: other), 50)
                }
            }
            values.setValue(50, for: tool)
        }
        values.setValue(23, for: MakeupTool.lip)
        values.select(MakeupTool.brow)
        values.setValue(81, for: values.selectedMakeup)
        values.select(MakeupTool.lip)
        XCTAssertEqual(values.value(for: values.selectedMakeup), 23)
        XCTAssertEqual(values.value(for: MakeupTool.brow), 81)
        XCTAssertEqual(values.value(for: SkinTool.auto), 50)
        XCTAssertEqual(values.value(for: FaceTool.auto), 50)
    }

    func testFilterPresetSelectionPreservesIntensityAndOriginalAlwaysBypasses() {
        var values = BeautyParameters()
        XCTAssertEqual(values.selectedFilter, .original)
        XCTAssertEqual(values.value(for: FilterPreset.original), 0)
        for preset in FilterPreset.allCases where preset != .original {
            values.select(preset)
            XCTAssertEqual(values.value(for: preset), 50)
            for strength in [0.0, 25, 50, 100] {
                values.setValue(strength, for: preset)
                XCTAssertEqual(values.processingConfiguration.filter.preset, preset)
                XCTAssertEqual(values.processingConfiguration.filter.intensity, strength / 100)
                XCTAssertEqual(values.processingConfiguration.filter.isBypassed, strength == 0)
            }
        }
        values.setValue(37, for: FilterPreset.warm)
        values.select(FilterPreset.original)
        values.setValue(100, for: FilterPreset.original)
        XCTAssertEqual(values.processingConfiguration.filter, .original)
        values.select(FilterPreset.warm)
        XCTAssertEqual(values.value(for: values.selectedFilter), 37)
        XCTAssertEqual(values.processingConfiguration.filter.intensity, 0.37)
    }

    func testColorControlsClampAndRejectInvalidUIValues() {
        var values = BeautyParameters()
        for input in [-10.0, 0, 50, 100, 150] {
            for tool in MakeupTool.allCases { values.setValue(input, for: tool) }
            for preset in FilterPreset.allCases { values.setValue(input, for: preset) }
            for tool in MakeupTool.allCases { XCTAssertEqual(values.value(for: tool), min(100, max(0, input))) }
            for preset in FilterPreset.allCases where preset != .original {
                XCTAssertEqual(values.value(for: preset), min(100, max(0, input)))
            }
        }
        let before = values
        for invalid in [Double.nan, .infinity, -.infinity] {
            for tool in MakeupTool.allCases { values.setValue(invalid, for: tool) }
            for preset in FilterPreset.allCases { values.setValue(invalid, for: preset) }
        }
        XCTAssertEqual(values, before)
        for input in [-1.0, 0, 0.5, 1, 2, .nan, .infinity] {
            let expected = input.isFinite ? min(1, max(0, input)) : 0
            let makeup = MakeupConfiguration(lip: input, blush: input, eye: input, brow: input)
            XCTAssertEqual([makeup.lip, makeup.blush, makeup.eye, makeup.brow], Array(repeating: expected, count: 4))
            XCTAssertEqual(makeup.isBypassed, expected == 0)
            XCTAssertEqual(FilterConfiguration(preset: .warm, intensity: input).intensity, expected)
            XCTAssertTrue(FilterConfiguration(preset: .original, intensity: input).isBypassed)
        }
    }

    func testSkinFaceMakeupAndFilterRemainIndependentInOneSnapshot() {
        var values = BeautyParameters()
        values.setValue(80, for: SkinTool.auto)
        values.setValue(40, for: FaceTool.auto)
        values.setValue(70, for: MakeupTool.lip)
        values.select(FilterPreset.cool)
        values.setValue(30, for: FilterPreset.cool)
        let snapshot = values.processingConfiguration
        values.setValue(0, for: SkinTool.auto)
        values.setValue(0, for: FaceTool.auto)
        XCTAssertEqual(values.processingConfiguration.makeup, snapshot.makeup)
        XCTAssertEqual(values.processingConfiguration.filter, snapshot.filter)
        XCTAssertFalse(values.processingConfiguration.isPhotoBypassed)
        for tool in MakeupTool.allCases { values.setValue(0, for: tool) }
        XCTAssertFalse(values.processingConfiguration.requiresFaceDetection)
        XCTAssertFalse(values.processingConfiguration.isBypassed)
        values.select(FilterPreset.original)
        XCTAssertTrue(values.processingConfiguration.isBypassed)
        XCTAssertEqual(snapshot.makeup.lip, 0.7)
        XCTAssertEqual(snapshot.filter.intensity, 0.3)
        XCTAssertEqual(snapshot.effectiveSmoothing, 0.64, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.effectiveFaceSlim, 0.16, accuracy: 0.000_001)
        XCTAssertTrue(BeautyConfiguration(enabled: false, makeup: snapshot.makeup,
                                         filter: snapshot.filter).isBypassed)
    }

    func testConfigurationClampsEveryNormalizedInputAndRejectsNonfiniteValues() {
        let values = BeautyConfiguration(enabled: true, overallStrength: 2,
            smoothingStrength: -1, brighteningStrength: .infinity, toneStrength: .nan,
            faceOverallStrength: 2, faceSlimStrength: -1, faceWidthStrength: .infinity,
            chinStrength: .nan, foreheadStrength: 4, cheekbonesStrength: -4)
        XCTAssertEqual(values.overallStrength, 1)
        XCTAssertEqual(values.smoothingStrength, 0)
        XCTAssertEqual(values.brighteningStrength, 0)
        XCTAssertEqual(values.toneStrength, 0)
        XCTAssertEqual(values.faceOverallStrength, 1)
        XCTAssertEqual(values.faceSlimStrength, 0)
        XCTAssertEqual(values.faceWidthStrength, 0)
        XCTAssertEqual(values.chinStrength, 0)
        XCTAssertEqual(values.foreheadStrength, 1)
        XCTAssertEqual(values.cheekbonesStrength, 0)
    }

    func testDisabledAndZeroConcreteConfigurationsBypass() {
        XCTAssertTrue(BeautyConfiguration.disabled.isBypassed)
        XCTAssertTrue(BeautyConfiguration(enabled: true, overallStrength: 0,
            smoothingStrength: 0, brighteningStrength: 0, toneStrength: 0).isBypassed)
        XCTAssertFalse(BeautyConfiguration(enabled: true, overallStrength: 1,
            smoothingStrength: 1).isBypassed)
        XCTAssertTrue(BeautyConfiguration(enabled: true, faceOverallStrength: 0,
            faceSlimStrength: 1).isFaceCorrectionBypassed)
        XCTAssertTrue(BeautyConfiguration(enabled: true, overallStrength: 0,
            smoothingStrength: 1).isPhotoBypassed)
        let faceOnly = BeautyConfiguration(enabled: true, faceOverallStrength: 1,
                                           faceSlimStrength: 1)
        XCTAssertFalse(faceOnly.isBypassed)
        XCTAssertTrue(faceOnly.isPhotoBypassed)
    }

    func testEffectiveStrengthMultipliesOverallAndConcreteParameters() {
        let values = BeautyConfiguration(enabled: true, overallStrength: 0.8,
            smoothingStrength: 0.5, brighteningStrength: 0.25, toneStrength: 1,
            faceOverallStrength: 0.6, faceSlimStrength: 0.5, faceWidthStrength: 0.25,
            chinStrength: 1, foreheadStrength: 0.75, cheekbonesStrength: 0.1)
        XCTAssertEqual(values.effectiveSmoothing, 0.4, accuracy: 0.000_001)
        XCTAssertEqual(values.effectiveBrightening, 0.2, accuracy: 0.000_001)
        XCTAssertEqual(values.effectiveTone, 0.8, accuracy: 0.000_001)
        XCTAssertEqual(values.effectiveFaceSlim, 0.3, accuracy: 0.000_001)
        XCTAssertEqual(values.effectiveFaceWidth, 0.15, accuracy: 0.000_001)
        XCTAssertEqual(values.effectiveChin, 0.6, accuracy: 0.000_001)
        XCTAssertEqual(values.effectiveForehead, 0.45, accuracy: 0.000_001)
        XCTAssertEqual(values.effectiveCheekbones, 0.06, accuracy: 0.000_001)
    }

    func testFaceAutoBatchSetsEveryChildAtZeroFiftyAndOneHundred() {
        var values = BeautyParameters()
        for strength in [50.0, 100.0, 0.0] {
            values.setValue(strength, for: FaceTool.auto)
            XCTAssertEqual(values.value(for: FaceTool.auto), strength)
            for tool in FaceTool.allCases where tool != .auto {
                XCTAssertEqual(values.value(for: tool), strength, tool.rawValue)
            }
        }
    }

    func testSkinAutoBatchSetsEveryChildAtZeroFiftyAndOneHundred() {
        var values = BeautyParameters()
        for strength in [50.0, 100.0, 0.0] {
            values.setValue(strength, for: SkinTool.auto)
            XCTAssertEqual(values.value(for: SkinTool.auto), strength)
            for tool in SkinTool.allCases where tool != .auto {
                XCTAssertEqual(values.value(for: tool), strength, tool.rawValue)
            }
        }
    }

    func testIndividualAdjustmentAfterBatchChangesOnlyThatParameter() {
        var values = BeautyParameters()
        values.setValue(50, for: SkinTool.auto)
        values.setValue(80, for: SkinTool.brighten)
        XCTAssertEqual(values.value(for: SkinTool.auto), 50)
        XCTAssertEqual(values.value(for: SkinTool.smooth), 50)
        XCTAssertEqual(values.value(for: SkinTool.brighten), 80)
        XCTAssertEqual(values.value(for: SkinTool.tone), 50)

        values.setValue(50, for: FaceTool.auto)
        values.setValue(80, for: FaceTool.slim)
        XCTAssertEqual(values.value(for: FaceTool.auto), 50)
        XCTAssertEqual(values.value(for: FaceTool.slim), 80)
        for tool in FaceTool.allCases where tool != .auto && tool != .slim {
            XCTAssertEqual(values.value(for: tool), 50, tool.rawValue)
        }
        XCTAssertEqual(values.processingConfiguration.effectiveBrightening, 0.4, accuracy: 0.000_001)
        XCTAssertEqual(values.processingConfiguration.effectiveFaceSlim, 0.4, accuracy: 0.000_001)
    }

    func testThirtyPercentAutoBatchProducesNinePercentEffectiveStrength() {
        var values = BeautyParameters()
        values.setValue(30, for: SkinTool.auto)
        values.setValue(30, for: FaceTool.auto)

        for tool in SkinTool.allCases where tool != .auto {
            XCTAssertEqual(values.value(for: tool), 30, tool.rawValue)
        }
        for tool in FaceTool.allCases where tool != .auto {
            XCTAssertEqual(values.value(for: tool), 30, tool.rawValue)
        }
        let configuration = values.processingConfiguration
        XCTAssertEqual(configuration.effectiveSmoothing, 0.09, accuracy: 0.000_001)
        XCTAssertEqual(configuration.effectiveBrightening, 0.09, accuracy: 0.000_001)
        XCTAssertEqual(configuration.effectiveTone, 0.09, accuracy: 0.000_001)
        XCTAssertEqual(configuration.effectiveBlemish, 0.09, accuracy: 0.000_001)
        XCTAssertEqual(configuration.effectiveDarkCircles, 0.09, accuracy: 0.000_001)
        XCTAssertEqual(configuration.effectiveFaceSlim, 0.09, accuracy: 0.000_001)
        XCTAssertEqual(configuration.effectiveFaceWidth, 0.09, accuracy: 0.000_001)
        XCTAssertEqual(configuration.effectiveChin, 0.09, accuracy: 0.000_001)
        XCTAssertEqual(configuration.effectiveForehead, 0.09, accuracy: 0.000_001)
        XCTAssertEqual(configuration.effectiveCheekbones, 0.09, accuracy: 0.000_001)
    }

    func testBothParameterGroupsClampToSliderRange() {
        var values = BeautyParameters()
        for tool in SkinTool.allCases {
            values.setValue(-1, for: tool)
            XCTAssertEqual(values.value(for: tool), 0)
            values.setValue(101, for: tool)
            XCTAssertEqual(values.value(for: tool), 100)
        }
        for tool in FaceTool.allCases {
            values.setValue(-100, for: tool)
            XCTAssertEqual(values.value(for: tool), 0)
            values.setValue(200, for: tool)
            XCTAssertEqual(values.value(for: tool), 100)
        }
    }

    func testInvalidValuesCannotPoisonSliderState() {
        var values = BeautyParameters()
        values.setValue(27, for: SkinTool.smooth)
        values.setValue(63, for: FaceTool.chin)
        for invalid in [Double.nan, Double.infinity, -Double.infinity] {
            values.setValue(invalid, for: SkinTool.smooth)
            values.setValue(invalid, for: FaceTool.chin)
        }
        XCTAssertEqual(values.value(for: SkinTool.smooth), 27)
        XCTAssertEqual(values.value(for: FaceTool.chin), 63)
    }

    func testSwitchingSkinToolsPreservesIndependentValues() {
        var values = BeautyParameters()
        values.select(SkinTool.smooth)
        values.setValue(23, for: values.selectedSkin)
        values.select(SkinTool.brighten)
        values.setValue(81, for: values.selectedSkin)
        values.select(SkinTool.smooth)
        XCTAssertEqual(values.value(for: values.selectedSkin), 23)
        XCTAssertEqual(values.value(for: SkinTool.brighten), 81)
        XCTAssertEqual(values.value(for: SkinTool.auto), 50)
    }

    func testSwitchingFaceToolsAndCategoriesPreservesIndependentValues() {
        var values = BeautyParameters()
        values.select(FaceTool.eyes)
        values.setValue(72, for: values.selectedFace)
        values.select(FaceTool.slim)
        values.setValue(38, for: values.selectedFace)
        values.select(SkinTool.auto)
        values.setValue(10, for: values.selectedSkin)
        values.select(FaceTool.eyes)
        XCTAssertEqual(values.value(for: values.selectedFace), 72)
        XCTAssertEqual(values.value(for: FaceTool.slim), 38)
        XCTAssertEqual(values.value(for: FaceTool.auto), 50)
        XCTAssertEqual(values.value(for: SkinTool.auto), 10)
    }

    func testFaceCorrectionStatePropagatesWithoutUsingUnimplementedControls() {
        var values = BeautyParameters()
        values.setValue(80, for: FaceTool.auto)
        values.setValue(25, for: FaceTool.slim)
        values.setValue(40, for: FaceTool.width)
        values.setValue(60, for: FaceTool.chin)
        values.setValue(75, for: FaceTool.forehead)
        values.setValue(10, for: FaceTool.cheekbones)
        values.setValue(100, for: FaceTool.eyes)

        let configuration = values.processingConfiguration
        XCTAssertEqual(configuration.faceOverallStrength, 0.8, accuracy: 0.000_001)
        XCTAssertEqual(configuration.effectiveFaceSlim, 0.2, accuracy: 0.000_001)
        XCTAssertEqual(configuration.effectiveFaceWidth, 0.32, accuracy: 0.000_001)
        XCTAssertEqual(configuration.effectiveChin, 0.48, accuracy: 0.000_001)
        XCTAssertEqual(configuration.effectiveForehead, 0.6, accuracy: 0.000_001)
        XCTAssertEqual(configuration.effectiveCheekbones, 0.08, accuracy: 0.000_001)
    }

    func testProcessingConfigurationMultipliesBatchAndConcreteStrengths() {
        var values = BeautyParameters()
        for auto in [0.5, 1.0] {
            values.setValue(auto * 100, for: FaceTool.auto)
            values.setValue(auto * 100, for: SkinTool.auto)
            for strength in [0.0, 0.25, 0.5, 0.75, 1.0] {
                for tool in [FaceTool.slim, .width, .chin, .forehead, .cheekbones] {
                    values.setValue(strength * 100, for: tool)
                }
                for tool in [SkinTool.smooth, .brighten, .tone, .blemish, .darkCircles] {
                    values.setValue(strength * 100, for: tool)
                }
                let config = values.processingConfiguration
                for actual in [config.faceSlimStrength, config.faceWidthStrength, config.chinStrength,
                               config.foreheadStrength, config.cheekbonesStrength,
                               config.smoothingStrength, config.brighteningStrength, config.toneStrength,
                               config.blemishStrength, config.darkCirclesStrength] {
                    XCTAssertEqual(actual, strength, accuracy: 0.000_001)
                }
                for actual in [config.effectiveFaceSlim, config.effectiveFaceWidth, config.effectiveChin,
                               config.effectiveForehead, config.effectiveCheekbones,
                               config.effectiveSmoothing, config.effectiveBrightening, config.effectiveTone,
                               config.effectiveBlemish, config.effectiveDarkCircles] {
                    XCTAssertEqual(actual, auto * strength, accuracy: 0.000_001)
                }
            }
        }
    }

    func testLocalSkinControlsClampAndIndividuallyPreventPhotoBypass() {
        for input in [-1.0, 0, 0.5, 1, 2, .nan, .infinity, -.infinity] {
            let expected = input.isFinite ? min(1, max(0, input)) : 0
            let blemish = BeautyConfiguration(enabled: true, overallStrength: 1, blemishStrength: input)
            let dark = BeautyConfiguration(enabled: true, overallStrength: 1, darkCirclesStrength: input)
            XCTAssertEqual(blemish.blemishStrength, expected)
            XCTAssertEqual(dark.darkCirclesStrength, expected)
            XCTAssertEqual(blemish.effectiveBlemish, expected)
            XCTAssertEqual(dark.effectiveDarkCircles, expected)
            XCTAssertEqual(blemish.isPhotoBypassed, expected == 0)
            XCTAssertEqual(dark.isPhotoBypassed, expected == 0)
            XCTAssertEqual(blemish.isBypassed, expected == 0)
            XCTAssertEqual(dark.isBypassed, expected == 0)
        }
        XCTAssertTrue(BeautyConfiguration(enabled: true, overallStrength: 0,
            blemishStrength: 1, darkCirclesStrength: 1).isPhotoBypassed)
        XCTAssertTrue(BeautyConfiguration(enabled: false, overallStrength: 1,
            blemishStrength: 1, darkCirclesStrength: 1).isPhotoBypassed)
    }
}
