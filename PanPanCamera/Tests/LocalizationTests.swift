import XCTest
@testable import PanPanCamera

final class LocalizationTests: XCTestCase {
    func testEveryUIKeyResolvesInAllFiveCompiledLocalizations() throws {
        let appBundle = Bundle(for: CameraService.self)
        for locale in ["ja", "zh-Hans", "zh-Hant", "en", "ko"] {
            let path = try XCTUnwrap(appBundle.path(forResource: locale, ofType: "lproj"), locale)
            let bundle = try XCTUnwrap(Bundle(path: path), locale)
            for key in L10n.allCases {
                let value = bundle.localizedString(forKey: key.rawValue, value: "__MISSING__", table: "Localizable")
                XCTAssertNotEqual(value, "__MISSING__", "\(locale): \(key.rawValue)")
                XCTAssertNotEqual(value, key.rawValue, "\(locale): \(key.rawValue)")
                XCTAssertFalse(value.isEmpty, "\(locale): \(key.rawValue)")
            }
            XCTAssertEqual(bundle.localizedString(forKey: L10n.appName.rawValue, value: nil,
                                                  table: "Localizable"), "PanPan")
            let permission = bundle.localizedString(forKey: "NSCameraUsageDescription", value: "__MISSING__",
                                                    table: "InfoPlist")
            XCTAssertNotEqual(permission, "__MISSING__", locale)
            XCTAssertFalse(permission.isEmpty, locale)
        }
    }
}
