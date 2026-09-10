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
            brighteningStrength: 0.5, toneStrength: 0.5))
    }

    func testConfigurationClampsEveryNormalizedInputAndRejectsNonfiniteValues() {
        let values = BeautyConfiguration(enabled: true, overallStrength: 2,
            smoothingStrength: -1, brighteningStrength: .infinity, toneStrength: .nan)
        XCTAssertEqual(values.overallStrength, 1)
        XCTAssertEqual(values.smoothingStrength, 0)
        XCTAssertEqual(values.brighteningStrength, 0)
        XCTAssertEqual(values.toneStrength, 0)
    }

    func testDisabledAndZeroOverallConfigurationsBypass() {
        XCTAssertTrue(BeautyConfiguration.disabled.isBypassed)
        XCTAssertTrue(BeautyConfiguration(enabled: true, overallStrength: 0,
            smoothingStrength: 1, brighteningStrength: 1, toneStrength: 1).isBypassed)
        XCTAssertFalse(BeautyConfiguration(enabled: true, overallStrength: 1,
            smoothingStrength: 1).isBypassed)
    }

    func testOverallStrengthScalesEveryImplementedEffectWithSharedSemantics() {
        let values = BeautyConfiguration(enabled: true, overallStrength: 0.8,
            smoothingStrength: 0.5, brighteningStrength: 0.25, toneStrength: 1)
        XCTAssertEqual(values.effectiveSmoothing, 0.4, accuracy: 0.000_001)
        XCTAssertEqual(values.effectiveBrightening, 0.2, accuracy: 0.000_001)
        XCTAssertEqual(values.effectiveTone, 0.8, accuracy: 0.000_001)
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
}
