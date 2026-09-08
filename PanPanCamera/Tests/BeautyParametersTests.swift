import XCTest
@testable import PanPanCamera

final class BeautyParametersTests: XCTestCase {
    func testEveryToolStartsAtFifty() {
        let values = BeautyParameters()
        for tool in SkinTool.allCases { XCTAssertEqual(values.value(for: tool), 50, tool.rawValue) }
        for tool in FaceTool.allCases { XCTAssertEqual(values.value(for: tool), 50, tool.rawValue) }
        XCTAssertEqual(values.selectedSkin, .auto)
        XCTAssertEqual(values.selectedFace, .auto)
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
