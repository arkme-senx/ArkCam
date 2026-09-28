import XCTest

final class LocalizationUITests: XCTestCase {
    @MainActor
    private func launch(_ language: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["ARKCAM_TEST_LANGUAGE"] = language
        #if targetEnvironment(simulator)
        app.launchArguments = ["--ui-quicktake-fixture", "--single-gallery-fixture", "-cameraMode", "dualPhoto", "-livePhotoEnabled", "NO"]
        #endif
        app.launch()
        XCTAssertTrue(app.buttons["cameraControlsToggle"].waitForExistence(timeout: 15))
        return app
    }

    @MainActor
    private func settings(_ app: XCUIApplication) {
        app.buttons["cameraControlsToggle"].tap()
        XCTAssertTrue(app.buttons["optionSettings"].waitForExistence(timeout: 5))
        app.buttons["optionSettings"].tap()
        XCTAssertTrue(app.buttons["settingsLanguage"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func select(_ language: String, in app: XCUIApplication) {
        let button = app.buttons["language-" + language]
        for _ in 0..<8 {
            if button.isHittable { break }
            app.swipeUp()
        }
        if !button.isHittable {
            for _ in 0..<8 {
                if button.isHittable { break }
                app.swipeDown()
            }
        }
        XCTAssertTrue(button.isHittable, language)
        button.tap()
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testGlobalShutterSoundPersistsAcrossLaunchAndModes() {
        continueAfterFailure = false
        let app = launch("zh-Hans")
        defer { app.terminate() }
        settings(app)
        let sound = app.switches["settingsShutterSound"]
        XCTAssertTrue(sound.waitForExistence(timeout: 5))
        if sound.value as? String == "0" { sound.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap() }
        XCTAssertEqual(sound.value as? String, "1")
        sound.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(sound.value as? String, "0")
        attach(app, "Shutter-Sound-Off-Chinese")
        app.buttons["settingsDone"].tap()
        app.terminate()
        app.launchEnvironment["ARKCAM_TEST_LANGUAGE"] = "en"
        app.launchArguments = ["--ui-quicktake-fixture", "--single-gallery-fixture", "-cameraMode", "dualVideo", "-livePhotoEnabled", "NO"]
        app.launch()
        XCTAssertTrue(app.buttons["cameraControlsToggle"].waitForExistence(timeout: 15))
        settings(app)
        XCTAssertTrue(sound.waitForExistence(timeout: 5))
        XCTAssertEqual(sound.label, "Shutter sound")
        XCTAssertEqual(sound.value as? String, "0")
        attach(app, "Shutter-Sound-Off-English-Video")
        sound.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(sound.value as? String, "1")
        app.buttons["settingsDone"].tap()
    }

    @MainActor
    func testAllLanguageSelectionsRefreshSettingsImmediately() {
        continueAfterFailure = false
        let app = launch("en")
        defer { app.terminate() }
        XCTAssertEqual(app.buttons["shutter"].label, "Take dual camera photo")
        settings(app)
        XCTAssertTrue(app.navigationBars["Camera settings"].exists)
        attach(app, "Settings-English")
        app.buttons["settingsLanguage"].tap()
        for (language, title) in [("zh-Hans","语言"), ("zh-Hant","語言"), ("ja","言語"), ("ko","언어"),
            ("es","Idioma"), ("fr","Langue"), ("de","Sprache"), ("it","Lingua"), ("pt-BR","Idioma"),
            ("ru","Язык"), ("ar","اللغة"), ("hi","भाषा"), ("id","Bahasa"), ("th","ภาษา"), ("vi","Ngôn ngữ"), ("en","Language")] {
            select(language, in: app)
            XCTAssertTrue(app.navigationBars[language == "en" ? "Language" : title + " / Language"].waitForExistence(timeout: 4), language)
            attach(app, "Language-" + language)
        }
        select("de", in: app)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["Kameraeinstellungen"].waitForExistence(timeout: 4))
        attach(app, "Settings-German")
        app.buttons["settingsDone"].tap()
        XCTAssertEqual(app.buttons["shutter"].label, "Foto mit zwei Kameras")
        attach(app, "Camera-German")
        app.terminate()
        app.launchEnvironment.removeValue(forKey: "ARKCAM_TEST_LANGUAGE")
        app.launch()
        XCTAssertTrue(app.buttons["shutter"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons["shutter"].label, "Foto mit zwei Kameras", "Persisted preference must survive launch and lock-camera context")
    }

    @MainActor
    func testArabicCameraGeometryAndLocalizedGallery() {
        continueAfterFailure = false
        let app = launch("ar")
        defer { app.terminate() }
        let shutter = app.buttons["shutter"]
        XCTAssertEqual(shutter.label, "صورة بكاميرتين")
        XCTAssertLessThan(app.buttons["openLibrary"].frame.midX, shutter.frame.midX)
        XCTAssertGreaterThan(app.buttons["swapCameras"].frame.midX, shutter.frame.midX)
        attach(app, "Camera-Arabic")
        settings(app)
        XCTAssertTrue(app.navigationBars["إعدادات الكاميرا"].exists)
        XCTAssertLessThan(app.buttons["settingsDone"].frame.midX, app.frame.midX, "RTL navigation actions should appear on the left")
        attach(app, "Settings-Arabic")
        app.buttons["settingsDone"].tap()
        #if targetEnvironment(simulator)
        app.buttons["openLibrary"].tap()
        XCTAssertTrue(app.navigationBars["ذكرياتنا"].waitForExistence(timeout: 5))
        attach(app, "Gallery-Arabic")
        app.buttons["memory-video"].tap()
        XCTAssertTrue(app.scrollViews["detailZoom"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["播放"].exists)
        attach(app, "Detail-Arabic")
        #endif
    }
    #if !targetEnvironment(simulator)
    @MainActor
    func testPhysicalLanguageSettingsAndCamera() {
        continueAfterFailure = false
        let app = launch("en")
        defer {
            app.terminate()
            app.launchEnvironment["ARKCAM_TEST_LANGUAGE"] = "system"
            app.launch()
            app.terminate()
        }
        XCTAssertEqual(app.buttons["shutter"].label, "Take dual camera photo")
        attach(app, "Physical14-Camera-English")
        settings(app)
        app.buttons["settingsLanguage"].tap()
        select("ja", in: app)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["カメラ設定"].waitForExistence(timeout: 5))
        attach(app, "Physical14-Settings-Japanese")
        app.buttons["settingsLanguage"].tap()
        select("zh-Hans", in: app)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["相机设置"].waitForExistence(timeout: 5))
        app.buttons["settingsDone"].tap()
        XCTAssertEqual(app.buttons["shutter"].label, "拍摄双面照片")
        app.buttons["openLibrary"].tap()
        XCTAssertTrue(app.navigationBars["我们的回忆"].waitForExistence(timeout: 8))
        XCTAssertGreaterThan(app.buttons.matching(identifier: "memory-photo").count, 0)
        attach(app, "Physical14-Memories-Chinese")
    }
    #endif

}
