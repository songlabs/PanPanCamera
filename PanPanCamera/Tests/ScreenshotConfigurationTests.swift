import XCTest
@testable import PanPanCamera

final class ScreenshotConfigurationTests: XCTestCase {
    func testNormalLaunchDoesNotEnableScreenshotMode() {
        XCTAssertFalse(ScreenshotConfiguration(arguments: ["PanPanCamera"]).isEnabled)
    }

    func testScreenArgumentAloneDoesNotEnableScreenshotMode() {
        XCTAssertFalse(ScreenshotConfiguration(arguments: ["--screenshot-screen", "beauty"]).isEnabled)
        XCTAssertFalse(ScreenshotConfiguration(arguments: ["--screenshot-mode=true"]).isEnabled)
    }

    func testExplicitModeDefaultsToCameraOnlyInDebug() {
        let configuration = ScreenshotConfiguration(arguments: ["--screenshot-mode"])
        #if DEBUG
        XCTAssertTrue(configuration.isEnabled)
        XCTAssertEqual(configuration.screen, .camera)
        #else
        XCTAssertFalse(configuration.isEnabled)
        XCTAssertNil(configuration.screen)
        #endif
    }

    func testEveryScreenArgumentRespectsBuildConfiguration() {
        for screen in ScreenshotConfiguration.Screen.allCases {
            let configuration = ScreenshotConfiguration(arguments: [
                "--screenshot-mode", "--screenshot-screen", screen.rawValue
            ])
            #if DEBUG
            XCTAssertEqual(configuration.screen, screen)
            #else
            XCTAssertFalse(configuration.isEnabled)
            XCTAssertNil(configuration.screen)
            #endif
        }
    }

    func testInvalidOrMissingScreenFailsClosed() {
        for suffix in [[], ["unknown"], ["--another-argument"]] {
            let configuration = ScreenshotConfiguration(arguments: [
                "--screenshot-mode", "--screenshot-screen"
            ] + suffix)
            XCTAssertFalse(configuration.isEnabled)
            XCTAssertNil(configuration.screen)
        }
    }
}
