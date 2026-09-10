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
            faceOverallStrength: 0.5, faceSlimStrength: 0.5,
            faceWidthStrength: 0.5, chinStrength: 0.5,
            foreheadStrength: 0.5, cheekbonesStrength: 0.5))
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
        XCTAssertFalse(BeautyConfiguration(enabled: true, faceOverallStrength: 0,
            faceSlimStrength: 1).isFaceCorrectionBypassed)
        let faceOnly = BeautyConfiguration(enabled: true, faceOverallStrength: 1,
                                           faceSlimStrength: 1)
        XCTAssertFalse(faceOnly.isBypassed)
        XCTAssertTrue(faceOnly.isPhotoBypassed)
    }

    func testEffectiveStrengthUsesEachConcreteParameterWithoutOverallMultiplication() {
        let values = BeautyConfiguration(enabled: true, overallStrength: 0.8,
            smoothingStrength: 0.5, brighteningStrength: 0.25, toneStrength: 1,
            faceOverallStrength: 0.6, faceSlimStrength: 0.5, faceWidthStrength: 0.25,
            chinStrength: 1, foreheadStrength: 0.75, cheekbonesStrength: 0.1)
        XCTAssertEqual(values.effectiveSmoothing, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(values.effectiveBrightening, 0.25, accuracy: 0.000_001)
        XCTAssertEqual(values.effectiveTone, 1, accuracy: 0.000_001)
        XCTAssertEqual(values.effectiveFaceSlim, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(values.effectiveFaceWidth, 0.25, accuracy: 0.000_001)
        XCTAssertEqual(values.effectiveChin, 1, accuracy: 0.000_001)
        XCTAssertEqual(values.effectiveForehead, 0.75, accuracy: 0.000_001)
        XCTAssertEqual(values.effectiveCheekbones, 0.1, accuracy: 0.000_001)
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
        XCTAssertEqual(configuration.effectiveFaceSlim, 0.25, accuracy: 0.000_001)
        XCTAssertEqual(configuration.effectiveFaceWidth, 0.4, accuracy: 0.000_001)
        XCTAssertEqual(configuration.effectiveChin, 0.6, accuracy: 0.000_001)
        XCTAssertEqual(configuration.effectiveForehead, 0.75, accuracy: 0.000_001)
        XCTAssertEqual(configuration.effectiveCheekbones, 0.1, accuracy: 0.000_001)
    }

    func testProcessingConfigurationDoesNotMultiplyBatchAndConcreteStrengths() {
        var values = BeautyParameters()
        for auto in [0.5, 1.0] {
            values.setValue(auto * 100, for: FaceTool.auto)
            values.setValue(auto * 100, for: SkinTool.auto)
            for strength in [0.0, 0.25, 0.5, 0.75, 1.0] {
                for tool in [FaceTool.slim, .width, .chin, .forehead, .cheekbones] {
                    values.setValue(strength * 100, for: tool)
                }
                for tool in [SkinTool.smooth, .brighten, .tone] {
                    values.setValue(strength * 100, for: tool)
                }
                let config = values.processingConfiguration
                for actual in [config.faceSlimStrength, config.faceWidthStrength, config.chinStrength,
                               config.foreheadStrength, config.cheekbonesStrength,
                               config.smoothingStrength, config.brighteningStrength, config.toneStrength] {
                    XCTAssertEqual(actual, strength, accuracy: 0.000_001)
                }
                for actual in [config.effectiveFaceSlim, config.effectiveFaceWidth, config.effectiveChin,
                               config.effectiveForehead, config.effectiveCheekbones,
                               config.effectiveSmoothing, config.effectiveBrightening, config.effectiveTone] {
                    XCTAssertEqual(actual, strength, accuracy: 0.000_001)
                }
            }
        }
    }
}
