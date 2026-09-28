import XCTest
@testable import Cam

final class LocalizationTests: XCTestCase {
    func testLanguageResolutionUsesSystemPreferenceAndScript() {
        XCTAssertEqual(AppLanguage.resolved("de", preferred: ["ja"]), .german)
        XCTAssertEqual(AppLanguage.resolved("system", preferred: ["zh-TW"]), .traditionalChinese)
        XCTAssertEqual(AppLanguage.resolved("system", preferred: ["zh_Hant_HK"]), .traditionalChinese)
        XCTAssertEqual(AppLanguage.resolved("system", preferred: ["zh-CN"]), .simplifiedChinese)
        XCTAssertEqual(AppLanguage.resolved("system", preferred: ["pt-PT"]), .portuguese)
        XCTAssertEqual(AppLanguage.resolved("invalid", preferred: ["ko-KR"]), .korean)
        XCTAssertEqual(AppLanguage.resolved("system", preferred: ["nl-NL", "fr-FR"]), .french)
        XCTAssertEqual(AppLanguage.resolved("system", preferred: ["unknown"]), .english)
    }

    func testEveryLanguageShipsCompleteMainAndExtensionResources() throws {
        let languages = AppLanguage.allCases.filter { $0 != .system }
        XCTAssertEqual(languages.count, 16)
        let appURL = Bundle.main.bundleURL
        let bundles = [appURL, appURL.appendingPathComponent("Extensions/CamCapture.appex"), appURL.appendingPathComponent("PlugIns/CamControls.appex")]
        for bundle in bundles {
            var expected: Set<String>?
            for language in languages {
                let folder = bundle.appendingPathComponent(language.rawValue + ".lproj")
                let values = try XCTUnwrap(try PropertyListSerialization.propertyList(from: Data(contentsOf: folder.appendingPathComponent("Localizable.strings")), format: nil) as? [String: String])
                XCTAssertGreaterThan(values.count, 350)
                if let expected { XCTAssertEqual(Set(values.keys), expected, language.rawValue) }
                expected = Set(values.keys)
                XCTAssertFalse(values.values.contains(""))
                let privacy = try XCTUnwrap(try PropertyListSerialization.propertyList(from: Data(contentsOf: folder.appendingPathComponent("InfoPlist.strings")), format: nil) as? [String: String])
                XCTAssertEqual(privacy.count, 6)
                for key in ["NSCameraUsageDescription", "NSMotionUsageDescription", "NSMicrophoneUsageDescription", "NSLocationWhenInUseUsageDescription", "NSPhotoLibraryAddUsageDescription"] {
                    XCTAssertFalse(try XCTUnwrap(privacy[key]).isEmpty)
                }
            }
        }
    }

    func testDynamicCountsErrorsAndLegacyNotesTranslateAtPresentation() {
        XCTAssertEqual(L10n.text("正在保存 3 项", language: .english), "Saving: 3")
        XCTAssertEqual(L10n.text("已恢复 7 条中断的拍摄，请在回忆中查看。", language: .english), "Recovered 7 interrupted captures. Check Memories.")
        let source = "保存失败：保存失败：系统报告存储空间不足，请腾出空间后重试。\n原片仍保留在 App 中。"
        let translated = L10n.text(source, language: .english)
        XCTAssertTrue(translated.contains("insufficient storage"), translated)
        XCTAssertTrue(translated.contains("Originals remain"), translated)
        XCTAssertEqual(L10n.text(source, language: .simplifiedChinese), source)
        XCTAssertEqual(L10n.text("拍摄位置", language: .japanese), "撮影場所")
        XCTAssertEqual(L10n.text("语言", language: .arabic), "اللغة")
        XCTAssertEqual(L10n.text("相机设置", language: .german), "Kameraeinstellungen")
        for language in AppLanguage.allCases where language != .system && language != .simplifiedChinese {
            XCTAssertNotEqual(L10n.text("正在保存 12 项", language: language), "正在保存 12 项", language.rawValue)
        }
    }

    func testPreferenceSyncIncludesLanguageAndOldContextKeepsSelection() {
        let sourceName = "language-source-\(UUID())", targetName = "language-target-\(UUID())"
        let source = UserDefaults(suiteName: sourceName)!, target = UserDefaults(suiteName: targetName)!
        defer { source.removePersistentDomain(forName: sourceName); target.removePersistentDomain(forName: targetName) }
        source.set("ja", forKey: "cameraLanguage")
        source.set("4K-60", forKey: "cameraSingleVideoProfile")
        CameraPreferenceStore.apply(CameraPreferenceStore.snapshot(source), to: target)
        XCTAssertEqual(target.string(forKey: "cameraLanguage"), "ja")
        XCTAssertEqual(target.string(forKey: "cameraSingleVideoProfile"), "4K-60")
        CameraPreferenceStore.apply(["cameraPhotoAspect":"1:1"], to: target)
        XCTAssertEqual(target.string(forKey: "cameraLanguage"), "ja")
    }

    func testNumbersAndDirectionFollowLanguageWithoutChangingStoredData() {
        let defaults = UserDefaults.standard, old = UserDefaults.standard.object(forKey: "cameraLanguage")
        defer { if let old { defaults.set(old, forKey: "cameraLanguage") } else { defaults.removeObject(forKey: "cameraLanguage") } }
        defaults.set("de", forKey: "cameraLanguage")
        XCTAssertEqual(L10n.number(3.3), "3,3")
        XCTAssertEqual(L10n.direction, .leftToRight)
        defaults.set("ar", forKey: "cameraLanguage")
        XCTAssertEqual(L10n.direction, .rightToLeft)
        XCTAssertEqual(L10n.text("语言"), "اللغة")
        defaults.set("en", forKey: "cameraLanguage")
        XCTAssertEqual(L10n.number(3.3), "3.3")
        XCTAssertEqual(L10n.text("语言"), "Language")
    }
}
