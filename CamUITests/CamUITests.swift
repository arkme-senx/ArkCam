import XCTest
import UIKit

final class CamUITests: XCTestCase {
    #if targetEnvironment(simulator)
    @MainActor
    func testFreshDefaultsAndExplicitLiveChoiceSurviveRelaunch() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["ARKCAM_TEST_LANGUAGE"] = "zh-Hans"
        app.launchArguments = ["--ui-quicktake-fixture", "--ui-live-available", "--ui-reset-factory-preferences"]
        app.launch()
        let live = app.buttons["livePhotoToggle"]
        XCTAssertTrue(live.waitForExistence(timeout: 5))
        XCTAssertEqual(live.label, "开启 Live Photo")
        XCTAssertEqual(app.buttons["photoMode"].value as? String, "已选择")
        attach(app, name: "新用户默认_双拍实况关闭")
        live.tap()
        XCTAssertEqual(live.label, "关闭 Live Photo")
        app.terminate()
        app.launchArguments = ["--ui-quicktake-fixture", "--ui-live-available"]
        app.launch()
        XCTAssertTrue(live.waitForExistence(timeout: 5))
        XCTAssertEqual(live.label, "关闭 Live Photo")
        attach(app, name: "重启后保留用户开启实况")
        live.tap()
    }

    @MainActor
    func testCaptureLoadNoticeCollapsesAndCanBeReadWithoutStoppingVideo() {
        continueAfterFailure = false
        let app = shutterFixture(extra: ["--ui-load-notice", "-cameraRecordingPhotoTipSeen", "YES"])
        let status = app.buttons["cameraLoadStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 3))
        let banner = app.staticTexts["cameraLoadNotice"]
        // Launch/idling alone can exceed the three-second lifetime. The state
        // tests cover its initial appearance; here verify the lasting UI.
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: banner)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 5), .completed)
        XCTAssertTrue(status.exists)
        attach(app, name: "拍摄提示_收起后的取景")
        app.buttons["videoMode"].tap()
        app.buttons["shutter"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["recordingTimer"].firstMatch.waitForExistence(timeout: 3))
        status.tap()
        XCTAssertTrue(banner.waitForExistence(timeout: 2))
        XCTAssertTrue(app.descendants(matching: .any)["recordingTimer"].firstMatch.exists)
        XCTAssertFalse(app.staticTexts["shutterGuidance"].exists)
        attach(app, name: "拍摄提示_点图标查看原因")
        status.tap()
        XCTAssertFalse(banner.exists)
        app.buttons["shutter"].tap()
    }

    @MainActor
    func testRecordingTeachingDisappearsAndDoesNotRepeatOnNextRecording() {
        continueAfterFailure = false
        let app = shutterFixture(extra: ["--ui-reset-recording-tip"])
        app.buttons["videoMode"].tap()
        app.buttons["shutter"].tap()
        let hint = app.staticTexts["shutterGuidance"]
        XCTAssertTrue(hint.waitForExistence(timeout: 2))
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: hint)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 4), .completed)
        app.buttons["shutter"].tap()
        app.buttons["shutter"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["recordingTimer"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertFalse(hint.exists)
        attach(app, name: "录像_教学消失后保持干净")
        app.buttons["shutter"].tap()
    }

    @MainActor
    func testZoomCenteringWheelLimitsAndFrontFraming() {
        continueAfterFailure = false
        let app = shutterFixture()
        let shutter = app.buttons["shutter"]
        for identifier in ["zoom-2", "zoom-5", "zoom-0.5", "zoom-1×"] {
            let button = app.buttons[identifier]
            button.tap()
            let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == '已选择'"), object: button)
            XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 3), .completed)
            let centered = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in abs(button.frame.midX - shutter.frame.midX) < 2 }, object: button)
            XCTAssertEqual(XCTWaiter.wait(for: [centered], timeout: 3), .completed)
        }
        let one = app.buttons["zoom-1×"]
        let start = one.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.35, thenDragTo: start.withOffset(CGVector(dx: -25 * app.frame.width / 375, dy: 0)), withVelocity: .slow, thenHoldForDuration: 0.15)
        let dial = app.descendants(matching: .any)["zoomDial"].firstMatch
        XCTAssertTrue(dial.exists)
        XCTAssertTrue(dial.label.contains("25"))
        attach(app, name: "倍率轮盘_全范围")
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: dial)
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 4), .completed)
        XCTAssertEqual(one.value as? String, "已选择")
        let firstValue = Double(one.label.components(separatedBy: " ").first ?? "") ?? 0
        XCTAssertGreaterThan(firstValue, 1.5, "Dragging must change the actual zoom value")
        XCTAssertLessThan(firstValue, 1.8)
        attach(app, name: "小数倍率_下侧档位居中")
        // Cross the 2× anchor during a single hold: the moving button must not
        // reset the drag coordinate or produce a jump back to its old preset.
        let again = one.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        again.press(forDuration: 0.35, thenDragTo: again.withOffset(CGVector(dx: -35 * app.frame.width / 375, dy: 0)), withVelocity: .slow, thenHoldForDuration: 0.15)
        XCTAssertTrue(dial.exists)
        let readout = Double(dial.value as? String ?? "") ?? 0
        XCTAssertGreaterThan(readout, firstValue * 1.75)
        XCTAssertLessThan(readout, firstValue * 2.1)
        attach(app, name: "倍率轮盘_跨过2倍")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: dial)], timeout: 4), .completed)
        XCTAssertEqual(app.buttons["zoom-2"].value as? String, "已选择")
        app.buttons["videoMode"].tap()
        let videoZoom = app.buttons["zoom-2"]
        videoZoom.press(forDuration: 0.35)
        XCTAssertTrue(dial.exists)
        XCTAssertTrue(dial.label.contains("15"))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: dial)], timeout: 4), .completed)
        app.buttons["swapCameras"].tap()
        let front = app.buttons["frontFraming"]
        XCTAssertTrue(front.waitForExistence(timeout: 3))
        XCTAssertEqual(front.value as? String, "广角")
        front.tap()
        let near = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == '近景'"), object: front)
        XCTAssertEqual(XCTWaiter.wait(for: [near], timeout: 3), .completed)
        front.tap()
        XCTAssertEqual(front.value as? String, "广角")
        attach(app, name: "前置取景范围")
    }

    @MainActor
    func testZoomHoldImmediateSwipeMaximumAndRetouch() {
        continueAfterFailure = false
        let app = shutterFixture()
        let scale = app.frame.width / 375
        let one = app.buttons["zoom-1×"]
        let dial = app.descendants(matching: .any)["zoomDial"].firstMatch
        // A stationary hold alone must reveal the wheel, even 24 pt above the
        // label where the previous 38 pt strip missed the touch entirely.
        let above = one.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).withOffset(CGVector(dx: 0, dy: -24 * scale))
        above.press(forDuration: 0.25)
        XCTAssertTrue(dial.exists)
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: dial)
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 5), .completed)
        // No long press is needed before a horizontal swipe. A single gesture
        // from the center reaches the actual 25x value, not only its label.
        let fixedCenter = one.frame
        let start = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: fixedCenter.midX, dy: fixedCenter.midY))
        start.press(forDuration: 0.01, thenDragTo: start.withOffset(CGVector(dx: -172 * scale, dy: 0)), withVelocity: .slow, thenHoldForDuration: 0.1)
        XCTAssertTrue(dial.exists)
        XCTAssertEqual(Double(dial.value as? String ?? ""), 25)
        // Resume on the drawn arc, well above the original zoom strip.
        let arc = start.withOffset(CGVector(dx: -90 * scale, dy: -45 * scale))
        arc.press(forDuration: 0.01, thenDragTo: arc.withOffset(CGVector(dx: 90 * scale, dy: 0)), withVelocity: .slow, thenHoldForDuration: 0.1)
        XCTAssertTrue(dial.exists)
        let value = Double(dial.value as? String ?? "") ?? 0
        XCTAssertGreaterThan(value, 3)
        XCTAssertLessThan(value, 6)
        attach(app, name: "轮盘_直接横拖与弧面续拖")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: dial)], timeout: 5), .completed)
        // The overlay must leave the shutter and options reachable.
        app.buttons["cameraControlsToggle"].tap()
        XCTAssertTrue(app.buttons["optionAspect"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testWidePreviewBoundsAndSmallerSwapIcon() {
        continueAfterFailure = false
        let app = shutterFixture()
        app.buttons["cameraControlsToggle"].tap()
        XCTAssertTrue(app.buttons["optionAspect"].waitForExistence(timeout: 3))
        app.buttons["optionAspect"].tap()
        XCTAssertTrue(app.buttons["aspect-16:9"].waitForExistence(timeout: 3))
        app.buttons["aspect-16:9"].tap()
        app.buttons["cameraOptionsHandle"].tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.buttons["cameraOptionsHandle"])], timeout: 3), .completed)
        attach(app, name: "16比9_边界诊断")
        let aperture = app.descendants(matching: .any)["rearPrimary"].firstMatch.frame
        let top = app.buttons["topFlashOptions"].frame
        let gallery = app.buttons["openLibrary"].frame
        let scale = app.frame.width / 375
        XCTAssertEqual(aperture.width / aperture.height, 9.0 / 16, accuracy: 0.01)
        XCTAssertLessThan(aperture.minY, top.minY)
        XCTAssertEqual(gallery.minY - aperture.maxY, 20 * scale, accuracy: 2)
        XCTAssertEqual(app.buttons["swapCameras"].frame.width, 48 * scale, accuracy: 2)
        attach(app, name: "16比9_顶部图标与底栏间距")
        app.buttons["swapCameras"].tap()
        XCTAssertTrue(app.buttons["frontFraming"].exists)
        app.buttons["cameraControlsToggle"].tap()
        XCTAssertTrue(app.buttons["optionAspect"].waitForExistence(timeout: 3))
        app.buttons["optionAspect"].tap()
        XCTAssertTrue(app.buttons["aspect-16:9"].waitForExistence(timeout: 3))
        app.buttons["aspect-4:3"].tap()
        app.buttons["cameraOptionsHandle"].tap()
    }

    @MainActor
    func testSingleMemoryVideoAndLiveShowWithoutMissingPairOrLayoutEditor() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["ARKCAM_TEST_LANGUAGE"] = "zh-Hans"
        app.launchArguments = ["--ui-quicktake-fixture", "--single-gallery-fixture", "-cameraMode", "dualPhoto"]
        app.launch()
        XCTAssertTrue(app.buttons["openLibrary"].waitForExistence(timeout: 10))
        app.buttons["openLibrary"].tap()
        XCTAssertTrue(app.buttons["memory-video"].waitForExistence(timeout: 15))
        app.buttons["memory-video"].tap()
        let play = app.buttons["播放"]
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: play)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed)
        XCTAssertEqual(app.otherElements["videoSurface"].value as? String, "画面已就绪")
        XCTAssertFalse(app.buttons["editMemoryLayout"].exists)
        XCTAssertTrue(app.buttons["saveToPhotos"].isEnabled)
        play.tap()
        XCTAssertTrue(app.buttons["暂停"].waitForExistence(timeout: 5))
        let advancing = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label MATCHES '00:0[1-3] / 00:03'"), object: app.staticTexts["playbackTime"])
        XCTAssertEqual(XCTWaiter.wait(for: [advancing], timeout: 5), .completed)
        app.buttons["暂停"].tap()
        attach(app, name: "单摄视频_详情首帧与时间")
        app.buttons["detailBack"].tap()
        app.buttons["memory-photo"].tap()
        XCTAssertTrue(app.otherElements["livePhotoSurface"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["editMemoryLayout"].exists)
        let media = app.scrollViews["detailZoom"]
        XCTAssertFalse(media.descendants(matching: .any)["inactivePipWindow"].exists)
        XCTAssertTrue(app.buttons["saveToPhotos"].isEnabled)
        app.buttons["saveToPhotos"].tap()
        XCTAssertTrue(app.buttons["export-rear"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["export-front"].exists)
        XCTAssertFalse(app.buttons["export-combined"].exists)
        attach(app, name: "单摄下载_仅真实镜头")
        dismissExportOptions(app)
        attach(app, name: "单摄实况_详情无小窗")
    }

    @MainActor
    func testColdLaunchDefaultsToDualPhotoAfterSavedVideoMode() {
        let app = XCUIApplication()
        app.launchEnvironment["ARKCAM_TEST_LANGUAGE"] = "zh-Hans"
        app.launchArguments = ["--ui-quicktake-fixture", "-cameraMode", "singleVideo", "-cameraRemember", "YES"]
        app.launch()
        XCTAssertTrue(app.buttons["photoMode"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons["photoMode"].value as? String, "已选择")
        XCTAssertTrue(app.descendants(matching: .any)["pipWindow"].exists)
        let selector = app.descendants(matching: .any)["captureModeSelector"].firstMatch
        XCTAssertEqual(app.buttons["photoMode"].frame.midX, selector.frame.midX, accuracy: 2)
        attach(app, name: "模式新顺序_默认双拍居中")
    }

    @MainActor
    func testFourCaptureModesDragSwapAndSingleQuickTake() {
        continueAfterFailure = false
        let app = shutterFixture()
        let selector = app.descendants(matching: .any)["captureModeSelector"].firstMatch
        let shutter = app.buttons["shutter"]
        func drag(_ points: CGFloat) {
            let center = selector.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            center.press(forDuration: 0.3, thenDragTo: center.withOffset(CGVector(dx: points * app.frame.width / 375, dy: 0)),
                         withVelocity: .slow, thenHoldForDuration: 0.3)
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: shutter)
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
        }
        XCTAssertEqual(app.buttons["photoMode"].value as? String, "已选择")
        XCTAssertTrue(app.descendants(matching: .any)["pipWindow"].exists)
        let originalHeight = selector.frame.height
        app.buttons["swapCameras"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["frontPrimary"].exists)
        drag(64)
        XCTAssertEqual(app.buttons["videoMode"].value as? String, "已选择")
        XCTAssertTrue(app.descendants(matching: .any)["pipWindow"].exists)
        drag(64)
        XCTAssertEqual(app.buttons["singleVideoMode"].value as? String, "已选择")
        XCTAssertFalse(app.descendants(matching: .any)["pipWindow"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["frontPrimary"].exists)
        XCTAssertEqual(shutter.label, "开始单摄录像")
        drag(-192)
        XCTAssertEqual(app.buttons["singlePhotoMode"].value as? String, "已选择")
        XCTAssertEqual(shutter.label, "拍摄单摄照片")
        app.buttons["swapCameras"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["rearPrimary"].exists)
        attach(app, name: "四模式_单拍_无小窗")
        let center = shutter.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        center.press(forDuration: 0.4, thenDragTo: center.withOffset(CGVector(dx: 133.5 * app.frame.width / 375, dy: 0)),
                     withVelocity: .slow, thenHoldForDuration: 0.3)
        XCTAssertTrue(app.buttons["recordingPhotoShutter"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["swapCameras"].isEnabled)
        XCTAssertFalse(app.buttons["singlePhotoMode"].isEnabled)
        shutter.tap()
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: shutter)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
        drag(64)
        XCTAssertEqual(app.buttons["photoMode"].value as? String, "已选择")
        XCTAssertTrue(app.descendants(matching: .any)["pipWindow"].exists)
        XCTAssertEqual(selector.frame.height, originalHeight)
        app.buttons["videoMode"].tap()
        XCTAssertEqual(shutter.label, "开始双面录像")
        XCTAssertTrue(app.descendants(matching: .any)["pipWindow"].waitForExistence(timeout: 5))
        attach(app, name: "四模式_双录_保留小窗")
    }

    @MainActor
    func testRecordingCaptionFollowsMeasuredFrameRate() {
        continueAfterFailure = false
        let app = shutterFixture(extra: ["--ui-video-readout", "-cameraDualVideoProfile", "1080p-30"])
        defer { app.terminate() }
        app.buttons["videoMode"].tap()
        app.buttons["shutter"].tap()
        let readout = app.staticTexts["recordingFormat"]
        XCTAssertTrue(readout.waitForExistence(timeout: 5))
        for fps in [24, 15, 30] {
            let updated = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "1080p · \(fps) fps"), object: readout)
            XCTAssertEqual(XCTWaiter.wait(for: [updated], timeout: 15), .completed)
            attach(app, name: "录制中帧率_\(fps)")
        }
        app.buttons["shutter"].tap()
        XCTAssertFalse(readout.exists)
    }

    @MainActor
    func testVideoFormatReadoutsFollowReductionAndRecovery() {
        continueAfterFailure = false
        let app = shutterFixture(extra: ["--ui-video-readout", "-cameraDualVideoProfile", "1080p-30"])
        defer { app.terminate() }
        app.buttons["videoMode"].tap()
        app.buttons["cameraControlsToggle"].tap()
        let top = app.buttons["topVideoFormat"], tile = app.buttons["optionFormat"]
        XCTAssertTrue(tile.waitForExistence(timeout: 5))
        for fps in [24, 15, 30] {
            let title = "1080p · \(fps) fps"
            let updated = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                top.label == title && tile.value as? String == title
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [updated], timeout: 15), .completed)
            attach(app, name: "帧率同步_\(fps)")
        }
        app.buttons["optionFormat"].tap()
        XCTAssertEqual(app.buttons["videoFPS-30"].value as? String, "已选择")
    }

    @MainActor
    func testModeSpecificOptionsFormatsAndCountdownCancellation() {
        continueAfterFailure = false
        let app = shutterFixture()
        let shutter = app.buttons["shutter"]
        app.buttons["cameraControlsToggle"].tap()
        XCTAssertTrue(app.buttons["optionLive"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["optionGrid"].exists)
        app.buttons["optionFormat"].tap()
        XCTAssertTrue(app.buttons["photoFormat-heif"].waitForExistence(timeout: 3))
        app.buttons["photoFormat-heif"].tap()
        app.buttons["photoMP-12"].tap()
        XCTAssertEqual(app.buttons["photoFormat-heif"].value as? String, "已选择")
        XCTAssertTrue(shutter.isHittable)
        app.buttons["optionsBack"].tap()
        XCTAssertEqual(app.buttons["optionFormat"].value as? String, "HEIF · 12 MP")
        Thread.sleep(forTimeInterval: 0.5)
        attach(app, name: "照片格式入口_HEIF_12MP")
        app.buttons["optionTimer"].tap()
        app.buttons["timer-3"].tap()
        XCTAssertTrue(app.staticTexts["photoTimerIndicator"].exists)
        XCTAssertLessThan(app.buttons["zoom-2"].frame.maxY, shutter.frame.minY)
        attach(app, name: "计时器_三秒_快门保留")
        shutter.tap()
        XCTAssertTrue(app.staticTexts["photoCountdown"].waitForExistence(timeout: 2))
        shutter.tap()
        XCTAssertFalse(app.staticTexts["photoCountdown"].exists)
        // A cancelled task must not shoot later.
        let noCapture = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !shutter.isEnabled }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [noCapture], timeout: 3.3), .timedOut)
        shutter.tap()
        XCTAssertTrue(app.staticTexts["photoCountdown"].waitForExistence(timeout: 2))
        let captured = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !shutter.isEnabled }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [captured], timeout: 5), .completed)
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in shutter.isEnabled }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 4), .completed)
        app.buttons["videoMode"].tap()
        XCTAssertTrue(app.buttons["topVideoFormat"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["livePhotoToggle"].exists)
        XCTAssertFalse(app.staticTexts["photoTimerIndicator"].exists)
        app.buttons["topVideoFormat"].tap()
        XCTAssertTrue(app.buttons["videoResolution-1080p"].waitForExistence(timeout: 3))
        app.buttons["videoResolution-1080p"].tap()
        app.buttons["videoFPS-60"].tap()
        XCTAssertEqual(app.buttons["videoFPS-60"].value as? String, "已选择")
        attach(app, name: "视频格式_分辨率与帧率")
        app.buttons["optionsBack"].tap()
        XCTAssertFalse(app.buttons["optionLive"].exists)
        XCTAssertFalse(app.buttons["optionAspect"].exists)
        XCTAssertFalse(app.buttons["optionTimer"].exists)
        XCTAssertTrue(app.buttons["optionStabilization"].exists)
        XCTAssertEqual(app.buttons["optionFormat"].value as? String, "1080p · 60 fps")
        XCTAssertEqual(app.buttons["optionFormat"].value as? String, app.buttons["topVideoFormat"].label)
        Thread.sleep(forTimeInterval: 0.5)
        attach(app, name: "录像格式入口_1080p_60")
        app.buttons["cameraOptionsHandle"].tap()
        app.buttons["singleVideoMode"].tap()
        app.buttons["cameraControlsToggle"].tap()
        app.buttons["optionFormat"].tap()
        app.buttons["videoResolution-4K"].tap()
        app.buttons["videoFPS-30"].tap()
        app.buttons["optionsBack"].tap()
        XCTAssertEqual(app.buttons["optionFormat"].value as? String, "4K · 30 fps")
        XCTAssertEqual(app.buttons["optionFormat"].value as? String, app.buttons["topVideoFormat"].label)
        Thread.sleep(forTimeInterval: 0.5)
        attach(app, name: "录像格式入口_4K_30")
        app.buttons["cameraOptionsHandle"].tap()
        app.buttons["videoMode"].tap()
        app.buttons["cameraControlsToggle"].tap()
        XCTAssertEqual(app.buttons["optionFormat"].value as? String, "1080p · 60 fps", "Single and dual modes retain their own recording format")
        XCTAssertEqual(app.buttons["optionFormat"].value as? String, app.buttons["topVideoFormat"].label)
        app.terminate()
    }

    @MainActor
    func testCountdownCancelsOnModeAndBackgroundAndQuickTakeBypassesTimer() {
        continueAfterFailure = false
        let app = shutterFixture()
        let shutter = app.buttons["shutter"], gallery = app.buttons["openLibrary"]
        let initialSave = gallery.value as? String
        app.buttons["cameraControlsToggle"].tap(); app.buttons["optionTimer"].tap()
        for value in ["5", "10", "0", "3"] {
            app.buttons["timer-" + value].tap()
            XCTAssertEqual(app.buttons["timer-" + value].value as? String, "已选择")
        }
        shutter.tap()
        XCTAssertTrue(app.staticTexts["photoCountdown"].waitForExistence(timeout: 2))
        app.buttons["videoMode"].tap()
        XCTAssertFalse(app.staticTexts["photoCountdown"].exists)
        sleep(4)
        XCTAssertEqual(gallery.value as? String, initialSave)
        app.buttons["photoMode"].tap(); shutter.tap()
        XCTAssertTrue(app.staticTexts["photoCountdown"].waitForExistence(timeout: 2))
        XCUIDevice.shared.press(.home); sleep(4); app.activate()
        XCTAssertTrue(shutter.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["photoCountdown"].exists)
        XCTAssertEqual(gallery.value as? String, initialSave)
        shutter.press(forDuration: 0.55)
        XCTAssertFalse(app.staticTexts["photoCountdown"].exists)
        // Hold-and-drag locks QuickTake even when a photo timer is configured.
        let start = shutter.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.45, thenDragTo: start.withOffset(CGVector(dx: 130, dy: 0)), withVelocity: .slow, thenHoldForDuration: 0.1)
        XCTAssertTrue(app.buttons["recordingPhotoShutter"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["photoCountdown"].exists)
        shutter.tap()
    }

    @MainActor
    func testModeFastSwipesMoveOneStepAndHeldDragCanSelectSeveral() {
        continueAfterFailure = false
        let app = shutterFixture()
        let selector = app.descendants(matching: .any)["captureModeSelector"].firstMatch
        func selected(_ id: String) {
            let check = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "已选择"), object: app.buttons[id])
            XCTAssertEqual(XCTWaiter.wait(for: [check], timeout: 5), .completed)
            XCTAssertEqual(app.buttons[id].frame.midX, selector.frame.midX, accuracy: 2)
        }
        func swipe(_ direction: CGFloat, hold: TimeInterval, velocity: XCUIGestureVelocity) {
            let start = selector.coordinate(withNormalizedOffset: CGVector(dx: direction > 0 ? 0.1 : 0.9, dy: 0.5))
            let end = selector.coordinate(withNormalizedOffset: CGVector(dx: direction > 0 ? 0.95 : 0.05, dy: 0.5))
            start.press(forDuration: hold, thenDragTo: end, withVelocity: velocity, thenHoldForDuration: 0)
        }
        selected("photoMode")
        swipe(1, hold: 0.01, velocity: .fast)
        selected("videoMode")
        swipe(-1, hold: 0.01, velocity: .fast)
        selected("photoMode")
        swipe(-1, hold: 0.01, velocity: .fast)
        selected("singlePhotoMode")
        swipe(-1, hold: 0.01, velocity: .fast)
        selected("singlePhotoMode")
        swipe(1, hold: 0.4, velocity: .slow)
        selected("singleVideoMode")
        swipe(-1, hold: 0.4, velocity: .slow)
        selected("singlePhotoMode")
        attach(app, name: "模式栏_短划单档_按住连续选择")
    }

    @MainActor
    func testLevelHorizonAndCrosshairAppearanceAndAlignment() {
        continueAfterFailure = false
        for (fixture, mode, aligned) in [("horizon", "horizon", false), ("aligned", "horizon", true),
                                         ("flat", "flat", false), ("flat-aligned", "flat", true)] {
            let app = XCUIApplication()
        app.launchEnvironment["ARKCAM_TEST_LANGUAGE"] = "zh-Hans"
            app.launchArguments = ["--ui-quicktake-fixture", "--level-fixture=" + fixture,
                                   "-cameraLevel", "YES", "-cameraMode", "photo", "-livePhotoEnabled", "NO"]
            app.launch()
            let level = app.descendants(matching: .any)["cameraLevel-" + mode].firstMatch
            XCTAssertTrue(level.waitForExistence(timeout: 10))
            XCTAssertEqual(level.value as? String, aligned ? "已对齐" : "未对齐")
            let aperture = app.descendants(matching: .any)["captureAperture"].firstMatch
            // Accessibility bounds enclose the union of both crosses, so an
            // offset yellow cross shifts that union's center by half its offset.
            let dx = fixture == "flat" ? 0.08 * 96 / 2 * aperture.frame.width / 375 : 0
            let dy = fixture == "flat" ? 0.12 * 96 / 2 * aperture.frame.width / 375 : 0
            XCTAssertEqual(level.frame.midX, aperture.frame.midX + dx, accuracy: 1)
            XCTAssertEqual(level.frame.midY, aperture.frame.midY + dy, accuracy: 1)
            attach(app, name: "Level_" + fixture)
            // Sensor overlay must not take the tap intended to focus the main camera.
            aperture.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            XCTAssertTrue(app.descendants(matching: .any)["focusIndicator"].waitForExistence(timeout: 3))
            app.terminate()
        }
    }

    @MainActor
    func testVideoSpecificationsAndCompositionSettings() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["ARKCAM_TEST_LANGUAGE"] = "zh-Hans"
        app.launchArguments = ["--ui-quicktake-fixture", "-cameraMode", "dualPhoto"]
        app.launch()
        app.buttons["cameraControlsToggle"].tap()
        XCTAssertTrue(app.buttons["optionSettings"].waitForExistence(timeout: 5))
        app.buttons["optionSettings"].tap()
        XCTAssertTrue(app.buttons["settingsSingleVideo"].waitForExistence(timeout: 5))
        let priorDual = app.buttons["settingsDualVideo"].label + String(describing: app.buttons["settingsDualVideo"].value)
        attach(app, name: "视频与构图设置")
        app.buttons["settingsSingleVideo"].tap()
        app.buttons["videoResolution-4K"].tap()
        app.buttons["videoFPS-60"].tap()
        attach(app, name: "单摄4K60选择")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue((app.buttons["settingsSingleVideo"].label + String(describing: app.buttons["settingsSingleVideo"].value)).contains("4K · 60 fps"))
        XCTAssertEqual(app.buttons["settingsDualVideo"].label + String(describing: app.buttons["settingsDualVideo"].value), priorDual)
        app.buttons["settingsDualVideo"].tap()
        XCTAssertFalse(app.buttons["videoResolution-4K"].isEnabled)
        app.buttons["videoResolution-720p"].tap()
        app.buttons["videoFPS-24"].tap()
        attach(app, name: "双摄规格独立选择")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue((app.buttons["settingsDualVideo"].label + String(describing: app.buttons["settingsDualVideo"].value)).contains("720p · 24 fps"))
        let mirror = app.switches["settingsMirrorFront"]
        if !mirror.isHittable { app.swipeUp() }
        if mirror.value as? String == "0" { mirror.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap() }
        XCTAssertEqual(mirror.value as? String, "1")
        mirror.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(mirror.value as? String, "0")
        // List creates off-screen rows lazily. Newer settings above this
        // section can leave the level row below the viewport.
        for _ in 0..<3 {
            if app.switches["settingsLevel"].isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(app.switches["settingsGrid"].exists)
        XCTAssertTrue(app.switches["settingsLevel"].exists)
        attach(app, name: "前置镜像关闭")
        app.buttons["settingsDone"].tap()
        XCTAssertTrue(app.buttons["shutter"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testLevelSettingDisablesAndRestoresTheOverlay() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["ARKCAM_TEST_LANGUAGE"] = "zh-Hans"
        app.launchArguments = ["--ui-quicktake-fixture", "--level-fixture=aligned", "-cameraMode", "photo"]
        app.launch()
        func openSettings() {
            XCTAssertTrue(app.buttons["cameraControlsToggle"].waitForExistence(timeout: 5))
            app.buttons["cameraControlsToggle"].tap()
            XCTAssertTrue(app.buttons["optionSettings"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.descendants(matching: .any)["cameraLevel-horizon"].exists)
            app.buttons["optionSettings"].tap()
            XCTAssertTrue(app.switches["settingsLevel"].waitForExistence(timeout: 5))
        }
        openSettings()
        let toggle = app.switches["settingsLevel"]
        if toggle.value as? String == "1" {
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        }
        XCTAssertEqual(toggle.value as? String, "0")
        app.buttons["settingsDone"].tap()
        XCTAssertTrue(app.buttons["shutter"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["cameraLevel-horizon"].exists)
        openSettings()
        XCTAssertEqual(toggle.value as? String, "0")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(toggle.value as? String, "1")
        app.buttons["settingsDone"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["cameraLevel-horizon"].waitForExistence(timeout: 5))
        app.buttons["videoMode"].tap()
        app.buttons["shutter"].tap()
        XCTAssertTrue(app.buttons["recordingPhotoShutter"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["cameraLevel-horizon"].exists)
        app.buttons["shutter"].tap()
    }

    @MainActor
    private func shutterFixture(delayed: Bool = false, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["ARKCAM_TEST_LANGUAGE"] = "zh-Hans"
        app.launchArguments = ["--ui-quicktake-fixture", "-cameraMode", "photo", "-livePhotoEnabled", "NO"]
        app.launchArguments += extra
        if delayed { app.launchArguments.append("--ui-delayed-start") }
        app.launch()
        XCTAssertTrue(app.buttons["shutter"].waitForExistence(timeout: 10))
        return app
    }

    @MainActor
    func testShutterRemainsUsableWhileGalleryShowsPendingSaves() {
        continueAfterFailure = false
        let app = shutterFixture()
        let shutter = app.buttons["shutter"]
        shutter.tap()
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: shutter)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 4), .completed)
        let gallery = app.buttons["openLibrary"]
        XCTAssertTrue(gallery.isEnabled)
        XCTAssertTrue((gallery.value as? String ?? "").contains("正在保存"))
        XCTAssertEqual(shutter.descendants(matching: .activityIndicator).count, 0)
        shutter.tap()
        XCTAssertTrue((gallery.value as? String ?? "").contains("2"))
        let readyAgain = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: shutter)
        XCTAssertEqual(XCTWaiter.wait(for: [readyAgain], timeout: 4), .completed)
        XCTAssertTrue((gallery.value as? String ?? "").contains("正在保存"))
        attach(app, name: "连续拍摄_左下角保存中")
    }

    @MainActor
    func testVideoStartCanBeCancelledAndImmediatelyRetriedWithoutSpinner() {
        continueAfterFailure = false
        let app = shutterFixture(delayed: true)
        app.buttons["videoMode"].tap()
        let shutter = app.buttons["shutter"]
        shutter.tap()
        XCTAssertTrue(shutter.isEnabled)
        XCTAssertEqual(shutter.label, "停止录像")
        XCTAssertEqual(shutter.descendants(matching: .activityIndicator).count, 0)
        XCTAssertFalse(app.descendants(matching: .any)["recordingTimer"].exists)
        shutter.tap()
        XCTAssertEqual(shutter.label, "开始双面录像")
        shutter.tap()
        XCTAssertTrue(app.buttons["recordingPhotoShutter"].waitForExistence(timeout: 5))
        XCTAssertEqual(shutter.label, "停止录像")
        shutter.tap()
        XCTAssertFalse(app.descendants(matching: .any)["recordingTimer"].exists)
    }

    @MainActor
    func testQuickTakeRightLockPhotoAndStopWhilePhotoBusy() {
        continueAfterFailure = false
        let app = shutterFixture()
        let shutter = app.buttons["shutter"]
        let originalFrame = shutter.frame
        let center = shutter.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        center.press(forDuration: 0.4,
                     thenDragTo: center.withOffset(CGVector(dx: 133.5 * app.frame.width / 375, dy: 0)),
                     withVelocity: .slow, thenHoldForDuration: 0.3)
        let photo = app.buttons["recordingPhotoShutter"]
        XCTAssertTrue(photo.waitForExistence(timeout: 5))
        XCTAssertEqual(shutter.label, "停止录像")
        XCTAssertEqual(shutter.frame, originalFrame, "The shutter hit target must stay in place during the morph")
        attach(app, name: "QuickTake_右滑锁定后")
        photo.tap()
        XCTAssertFalse(photo.isEnabled)
        XCTAssertTrue(shutter.isEnabled, "Taking a still must not disable stopping")
        XCTAssertEqual(shutter.label, "停止录像")
        shutter.tap()
        XCTAssertFalse(app.descendants(matching: .any)["recordingTimer"].exists)
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: shutter)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
        XCTAssertEqual(shutter.label, "拍摄双面照片")
        XCTAssertFalse(photo.exists)
        attach(app, name: "QuickTake_拍照过程中停止后")
    }

    @MainActor
    func testQuickTakeReleaseBeforeAsyncStartDoesNotLeaveRecording() {
        continueAfterFailure = false
        let app = shutterFixture(delayed: true)
        let shutter = app.buttons["shutter"]
        let center = shutter.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        center.press(forDuration: 0.3, thenDragTo: center.withOffset(CGVector(dx: -30, dy: 0)),
                     withVelocity: .fast, thenHoldForDuration: 0)
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: shutter)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
        XCTAssertEqual(shutter.label, "拍摄双面照片")
        XCTAssertFalse(app.descendants(matching: .any)["recordingTimer"].exists)
        XCTAssertFalse(app.buttons["recordingPhotoShutter"].exists)
    }

    @MainActor
    func testQuickTakeUpwardDragReleasesInsteadOfLocking() {
        continueAfterFailure = false
        let app = shutterFixture()
        let shutter = app.buttons["shutter"]
        let center = shutter.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        center.press(forDuration: 0.4, thenDragTo: center.withOffset(CGVector(dx: 0, dy: -130)),
                     withVelocity: .slow, thenHoldForDuration: 0.3)
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: shutter)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
        XCTAssertEqual(shutter.label, "拍摄双面照片")
        XCTAssertFalse(app.buttons["recordingPhotoShutter"].exists)
    }

    @MainActor
    func testQuickTakeBackgroundCancelsPendingLockedStart() {
        continueAfterFailure = false
        let app = shutterFixture(delayed: true)
        let shutter = app.buttons["shutter"]
        let center = shutter.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        center.press(forDuration: 0.24,
                     thenDragTo: center.withOffset(CGVector(dx: 133.5 * app.frame.width / 375, dy: 0)),
                     withVelocity: .fast, thenHoldForDuration: 0)
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(shutter.waitForExistence(timeout: 5))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: shutter)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
        XCTAssertEqual(shutter.label, "拍摄双面照片")
        XCTAssertFalse(app.buttons["recordingPhotoShutter"].exists)
    }

    @MainActor
    func testVideoModeAlsoOffersPhotoAndReturnsToVideo() {
        continueAfterFailure = false
        let app = shutterFixture()
        app.buttons["videoMode"].tap()
        let shutter = app.buttons["shutter"]
        XCTAssertEqual(shutter.label, "开始双面录像")
        shutter.tap()
        XCTAssertTrue(app.buttons["recordingPhotoShutter"].waitForExistence(timeout: 5))
        XCTAssertEqual(shutter.label, "停止录像")
        shutter.tap()
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: shutter)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
        XCTAssertEqual(shutter.label, "开始双面录像")
    }

    @MainActor
    func testLockedSessionLibraryRequiresAuthenticationForFullLibrary() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["ARKCAM_TEST_LANGUAGE"] = "zh-Hans"
        app.launchArguments = ["--ui-fixtures", "--ui-locked"]
        app.launch()
        let library = app.buttons["openLibrary"]
        XCTAssertTrue(library.waitForExistence(timeout: 10))
        library.tap()
        XCTAssertTrue(app.navigationBars["本次拍摄"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.navigationBars["我们的回忆"].exists)
        app.buttons["unlockAllMemories"].tap()
        XCTAssertTrue(app.alerts["解锁未完成"].waitForExistence(timeout: 5))
        app.alerts.buttons["知道了"].tap()
        XCTAssertTrue(app.navigationBars["本次拍摄"].exists)
        let photo = app.buttons["memory-photo"].firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 5))
        photo.tap()
        XCTAssertTrue(app.buttons["saveToPhotos"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["saveToPhotos"].label, "解锁后保存到相册")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "LockedSessionDetail"
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor
    func testControlGalleryAddsAndOpensCamera() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["ARKCAM_TEST_LANGUAGE"] = "zh-Hans"
        app.launch()
        XCTAssertTrue(app.buttons["shutter"].waitForExistence(timeout: 20))
        app.buttons["openLibrary"].tap()
        XCTAssertTrue(app.navigationBars["我们的回忆"].waitForExistence(timeout: 5))
        let screen = app.windows.firstMatch
        screen.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.015))
            .press(forDuration: 0.1, thenDragTo: screen.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.6)))
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        XCTAssertTrue(springboard.buttons["添加控制"].waitForExistence(timeout: 5))
        springboard.buttons["添加控制"].tap()
        sleep(1)
        springboard.buttons["添加控制"].tap()
        let search = springboard.searchFields["搜索控制"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        if search.buttons["清除文本"].exists { search.buttons["清除文本"].tap() }
        search.typeText("双面")
        let control = springboard.buttons.matching(identifier: "com.tison.dualcam.capture").firstMatch
        XCTAssertTrue(control.waitForExistence(timeout: 8))
        sleep(1)
        let tree = XCTAttachment(string: springboard.debugDescription)
        tree.name = "ControlCenterAccessibility"
        tree.lifetime = .keepAlways
        add(tree)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "ControlCenter"
        shot.lifetime = .keepAlways
        add(shot)
        control.tap()
        let added = XCTAttachment(string: springboard.debugDescription)
        added.name = "AddedControlAccessibility"
        added.lifetime = .keepAlways
        add(added)
        XCUIDevice.shared.press(.home)
        let systemScreen = springboard.windows.firstMatch
        systemScreen.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.015))
            .press(forDuration: 0.1, thenDragTo: systemScreen.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.6)))
        let installed = springboard.buttons.matching(identifier: "com.tison.dualcam.capture").firstMatch
        XCTAssertTrue(installed.waitForExistence(timeout: 5))
        installed.tap()
        XCTAssertTrue(app.buttons["openLibrary"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["openLibrary"].isHittable)
        XCTAssertFalse(app.navigationBars["我们的回忆"].exists)
    }

    #endif
    @MainActor
    func testDeviceSinglePhotoFormatCapabilities() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires camera format capabilities")
        #else
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchEnvironment["ARKCAM_TEST_LANGUAGE"] = "zh-Hans"
        app.launch(); defer { app.terminate() }
        let shutter = app.buttons["shutter"]
        XCTAssertTrue(shutter.waitForExistence(timeout: 20))
        app.buttons["singlePhotoMode"].tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: shutter)], timeout: 15), .completed)
        let options = app.buttons["cameraControlsToggle"]
        options.tap(); app.buttons["optionTimer"].tap(); app.buttons["timer-0"].tap()
        app.buttons["optionsBack"].tap(); app.buttons["optionFormat"].tap()
        attach(app, name: "v39_single_photo_capabilities")
        if app.buttons["photoFormat-raw"].exists {
            app.buttons["photoFormat-raw"].tap()
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == '已选择'"), object: app.buttons["photoFormat-raw"])], timeout: 5), .completed)
            shutter.tap(); sleep(5)
            XCTAssertTrue(shutter.isEnabled); XCTAssertFalse(app.alerts.firstMatch.exists)
        }
        app.buttons["photoFormat-heif"].tap()
        if app.buttons["photoMP-3"].exists {
            app.buttons["photoMP-3"].tap(); shutter.tap(); sleep(4)
            XCTAssertTrue(shutter.isEnabled); XCTAssertFalse(app.alerts.firstMatch.exists)
        }
        if app.buttons["photoMP-12"].exists { app.buttons["photoMP-12"].tap() }
        app.buttons["photoFormat-jpeg"].tap()
        app.buttons["cameraOptionsHandle"].tap(); app.buttons["photoMode"].tap()
        #endif
    }

    @MainActor
    func testDeviceModeOptionsAndPhotoFormats() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires real photo output")
        #else
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["ARKCAM_TEST_LANGUAGE"] = "zh-Hans"
        app.launch()
        defer { app.terminate() }
        let shutter = app.buttons["shutter"]
        XCTAssertTrue(shutter.waitForExistence(timeout: 20))
        app.buttons["photoMode"].tap()
        let ready = { XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: shutter)], timeout: 15), .completed) }
        ready()
        let options = app.buttons["cameraControlsToggle"]
        options.tap()
        XCTAssertTrue(app.buttons["optionTimer"].waitForExistence(timeout: 5))
        app.buttons["optionTimer"].tap(); app.buttons["timer-0"].tap()
        app.buttons["optionsBack"].tap(); app.buttons["optionFormat"].tap()
        for format in ["heif", "jpeg"] {
            let choice = app.buttons["photoFormat-" + format]
            XCTAssertTrue(choice.waitForExistence(timeout: 5))
            choice.tap()
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == '已选择'"), object: choice)], timeout: 5), .completed)
            attach(app, name: "v39_device_photo_" + format)
            shutter.tap()
            sleep(4)
            ready()
            XCTAssertFalse(app.alerts.firstMatch.exists)
        }
        app.buttons["optionsBack"].tap(); app.buttons["optionTimer"].tap()
        app.buttons["timer-3"].tap(); shutter.tap()
        XCTAssertTrue(app.staticTexts["photoCountdown"].waitForExistence(timeout: 2))
        shutter.tap()
        XCTAssertFalse(app.staticTexts["photoCountdown"].exists)
        options.tap(); app.buttons["optionTimer"].tap(); app.buttons["timer-0"].tap()
        app.buttons["cameraOptionsHandle"].tap()
        app.buttons["videoMode"].tap(); ready()
        XCTAssertTrue(app.buttons["topVideoFormat"].waitForExistence(timeout: 5))
        app.buttons["topVideoFormat"].tap()
        attach(app, name: "v39_device_video_format")
        app.buttons["optionsBack"].tap()
        XCTAssertFalse(app.buttons["optionTimer"].exists)
        XCTAssertFalse(app.buttons["optionLive"].exists)
        app.buttons["optionStabilization"].tap()
        let enhanced = app.buttons["enhanced-on"]
        if enhanced.isEnabled { enhanced.tap() }
        app.buttons["cameraOptionsHandle"].tap()
        shutter.tap(); XCTAssertTrue(app.buttons["recordingPhotoShutter"].waitForExistence(timeout: 10))
        sleep(3); shutter.tap(); sleep(4); ready()
        options.tap(); app.buttons["optionStabilization"].tap(); app.buttons["enhanced-off"].tap()
        app.buttons["cameraOptionsHandle"].tap(); app.buttons["photoMode"].tap()
        #endif
    }

    @MainActor
    func testPipCanReachEveryViewfinderEdge() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["ARKCAM_TEST_LANGUAGE"] = "zh-Hans"
        #if targetEnvironment(simulator)
        app.launchArguments = ["--ui-quicktake-fixture"]
        #endif
        app.launch()
        defer { app.terminate() }
        let options = app.buttons["cameraControlsToggle"]
        XCTAssertTrue(options.waitForExistence(timeout: 20))
        app.buttons["photoMode"].tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: options)], timeout: 20), .completed)
        options.tap()
        XCTAssertTrue(app.buttons["optionAspect"].waitForExistence(timeout: 4))
        let oldAspect = app.buttons["optionAspect"].value as? String ?? "4:3"
        app.buttons["cameraOptionsHandle"].tap()
        let pip = app.descendants(matching: .any)["pipWindow"].firstMatch
        let aperture = app.descendants(matching: .any)["rearPrimary"].firstMatch
        func checkCorners(_ name: String) {
            XCTAssertTrue(pip.waitForExistence(timeout: 10))
            let bounds = XCTAttachment(string: "Viewfinder: \(aperture.frame); PiP: \(pip.frame)")
            bounds.name = "拖动边界_" + name; bounds.lifetime = .keepAlways; add(bounds)
            for (right, bottom) in [(false, false), (true, false), (true, true), (false, true)] {
                let area = aperture.frame
                // Start away from zoom buttons that may overlay the inset in 16:9.
                let start = pip.coordinate(withNormalizedOffset: CGVector(dx: right ? 0.75 : 0.25, dy: 0.35))
                let target = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(
                    dx: right ? area.maxX - 3 : area.minX + 3,
                    dy: bottom ? area.maxY - 3 : area.minY + 3))
                start.press(forDuration: 0.1, thenDragTo: target, withVelocity: .slow, thenHoldForDuration: 0.1)
                let frame = pip.frame
                XCTAssertEqual(right ? frame.maxX : frame.minX, right ? area.maxX : area.minX, accuracy: 2)
                XCTAssertEqual(bottom ? frame.maxY : frame.minY, bottom ? area.maxY : area.minY, accuracy: 2)
            }
            attach(app, name: "小窗贴边_" + name)
        }
        for aspect in ["4:3", "1:1", "16:9"] {
            options.tap(); app.buttons["optionAspect"].tap()
            app.buttons["aspect-" + aspect].tap(); app.buttons["cameraOptionsHandle"].tap()
            checkCorners(aspect)
        }
        // Return the user's photo aspect before switching modes.
        options.tap(); app.buttons["optionAspect"].tap()
        app.buttons["aspect-" + oldAspect].tap(); app.buttons["cameraOptionsHandle"].tap()
        app.buttons["videoMode"].tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: options)], timeout: 20), .completed)
        checkCorners("双录")
        let beforeSwap = pip.frame
        pip.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.35)).tap()
        XCTAssertTrue(app.descendants(matching: .any)["frontPrimary"].waitForExistence(timeout: 10))
        XCTAssertEqual(pip.frame.minX, beforeSwap.minX, accuracy: 2)
        XCTAssertEqual(pip.frame.minY, beforeSwap.minY, accuracy: 2)
        app.buttons["photoMode"].tap()
    }

    @MainActor
    func testTimerReadoutAndLiveOptionsRequireExplicitSelection() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["ARKCAM_TEST_LANGUAGE"] = "zh-Hans"
        #if targetEnvironment(simulator)
        app.launchArguments = ["--ui-quicktake-fixture", "--ui-live-available"]
        #endif
        app.launch()
        defer { app.terminate() }
        let options = app.buttons["cameraControlsToggle"]
        XCTAssertTrue(options.waitForExistence(timeout: 20))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            options.isEnabled
        }, object: nil)], timeout: 15), .completed)
        options.tap()
        let panel = app.descendants(matching: .any)["cameraOptionsPanel"].firstMatch
        XCTAssertTrue(app.buttons["optionTimer"].waitForExistence(timeout: 4))
        let overviewHeight = panel.frame.height
        let originalLive = app.buttons["optionLive"].value as? String == "已开启"
        app.buttons["optionTimer"].tap()
        let originalTimer = ["0", "3", "5", "10"].first { app.buttons["timer-" + $0].value as? String == "已选择" } ?? "0"
        for value in ["3", "5", "10"] {
            app.buttons["timer-" + value].tap()
            let readout = app.staticTexts["photoTimerIndicator"]
            XCTAssertEqual(readout.value as? String, value)
            // The readout deliberately passes taps through to focus; validate
            // its visible bounds, not whether it accepts an input event.
            XCTAssertTrue(app.frame.contains(readout.frame))
            if value != "5" { attach(app, name: "计时器圆盘与大号预设_" + value) }
        }
        app.buttons["timer-0"].tap()
        XCTAssertFalse(app.staticTexts["photoTimerIndicator"].exists)
        app.buttons["timer-" + originalTimer].tap()
        app.buttons["optionsBack"].tap()
        app.buttons["optionLive"].tap()
        let off = app.buttons["live-off"], on = app.buttons["live-on"]
        XCTAssertTrue(on.waitForExistence(timeout: 4))
        XCTAssertEqual((originalLive ? on : off).value as? String, "已选择", "Opening the page must not toggle Live")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            panel.frame.height < overviewHeight - 25
        }, object: nil)], timeout: 4), .completed)
        off.tap()
        XCTAssertEqual(off.value as? String, "已选择")
        XCTAssertEqual(app.buttons["livePhotoToggle"].label, "开启 Live Photo")
        on.tap()
        XCTAssertEqual(on.value as? String, "已选择")
        XCTAssertEqual(app.buttons["livePhotoToggle"].label, "关闭 Live Photo")
        attach(app, name: "实况二级设置_开启")
        app.buttons["optionsBack"].tap()
        XCTAssertEqual(app.buttons["optionLive"].value as? String, "已开启")
        app.buttons["optionLive"].tap()
        XCTAssertEqual(on.value as? String, "已选择", "Reopening the page must preserve the setting")
        (originalLive ? on : off).tap()
        app.buttons["cameraOptionsHandle"].tap()
        app.buttons["videoMode"].tap()
        options.tap()
        XCTAssertTrue(app.buttons["optionFormat"].waitForExistence(timeout: 4))
        XCTAssertFalse(app.buttons["optionLive"].exists)
        XCTAssertFalse(app.buttons["optionTimer"].exists)
    }

    @MainActor
    func testOptionsResizeDragAndTopControls() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["ARKCAM_TEST_LANGUAGE"] = "zh-Hans"
        #if targetEnvironment(simulator)
        app.launchArguments = ["--ui-quicktake-fixture"]
        #endif
        app.launch()
        defer { app.terminate() }
        let options = app.buttons["cameraControlsToggle"]
        XCTAssertTrue(options.waitForExistence(timeout: 20))
        app.buttons["photoMode"].tap()
        options.tap()
        let panel = app.descendants(matching: .any)["cameraOptionsPanel"].firstMatch
        let handle = app.buttons["cameraOptionsHandle"]
        XCTAssertTrue(handle.waitForExistence(timeout: 5))
        let overview = panel.frame
        attach(app, name: "v36_Overview")
        app.buttons["optionAspect"].tap()
        let compact = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in panel.frame.height < overview.height - 25 }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [compact], timeout: 4), .completed)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            abs(panel.frame.maxY - overview.maxY) < 1
        }, object: nil)], timeout: 3), .completed)
        XCTAssertTrue(app.buttons["aspect-16:9"].isHittable)
        attach(app, name: "v36_CompactAspect")
        app.buttons["optionsBack"].tap()
        app.buttons["optionExposure"].tap()
        XCTAssertLessThan(panel.frame.height, overview.height - 10)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            abs(panel.frame.maxY - overview.maxY) < 1
        }, object: nil)], timeout: 3), .completed)
        XCTAssertTrue(app.sliders["cameraExposure"].isHittable)
        attach(app, name: "v36_CompactExposure")
        app.buttons["optionsBack"].tap()
        // A short, slow pull returns to the same position, then a long pull dismisses.
        let start = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 24)), withVelocity: .slow, thenHoldForDuration: 0.2)
        XCTAssertTrue(handle.exists)
        let returned = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in abs(panel.frame.minY - overview.minY) < 1 }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [returned], timeout: 3), .completed)
        let closeStart = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        closeStart.press(forDuration: 0.1, thenDragTo: closeStart.withOffset(CGVector(dx: 0, dy: 170)), withVelocity: .slow, thenHoldForDuration: 0.1)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: handle)], timeout: 4), .completed)
        for _ in 0..<3 { options.tap(); XCTAssertTrue(handle.waitForExistence(timeout: 3)); handle.tap() }
        XCTAssertTrue(app.buttons["livePhotoToggle"].exists)
        let livePreference = app.buttons["livePhotoToggle"].label
        app.buttons["videoMode"].tap()
        XCTAssertFalse(app.buttons["livePhotoToggle"].exists)
        XCTAssertTrue(app.buttons["topFlashOptions"].exists)
        attach(app, name: "v36_VideoTopControls")
        app.buttons["photoMode"].tap()
        XCTAssertTrue(app.buttons["livePhotoToggle"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["livePhotoToggle"].label, livePreference)
        #if !targetEnvironment(simulator)
        let flash = app.buttons["topFlashOptions"]
        XCTAssertTrue(flash.isEnabled)
        let initial = flash.value as? String
        var values = Set<String>()
        for _ in 0..<3 {
            flash.tap()
            XCTAssertFalse(handle.exists)
            values.insert(flash.value as? String ?? "")
        }
        XCTAssertEqual(values, Set(["关闭", "自动", "开启"]))
        XCTAssertEqual(flash.value as? String, initial)
        #endif
    }

    @MainActor
    func testCameraOptionsPanelRatiosAndSettings() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["ARKCAM_TEST_LANGUAGE"] = "zh-Hans"
        #if targetEnvironment(simulator)
        app.launchArguments = ["--ui-fixtures"]
        #endif
        app.launch()
        let options = app.buttons["cameraControlsToggle"]
        XCTAssertTrue(options.waitForExistence(timeout: 20))
        app.buttons["photoMode"].tap()
        options.tap()
        XCTAssertTrue(app.buttons["optionAspect"].waitForExistence(timeout: 5))
        attach(app, name: "底部玻璃拍摄面板")
        app.buttons["optionAspect"].tap()
        app.buttons["aspect-1:1"].tap()
        attach(app, name: "宽高比选项")
        app.buttons["cameraOptionsHandle"].tap()
        let aperture = app.descendants(matching: .any)["captureAperture"].firstMatch
        XCTAssertEqual(aperture.frame.width / aperture.frame.height, 1, accuracy: 0.01)
        options.tap(); app.buttons["optionSettings"].tap()
        XCTAssertTrue(app.navigationBars["相机设置"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.switches["settingsGrid"].exists)
        XCTAssertTrue(app.switches["settingsLocation"].exists)
        attach(app, name: "相机底层设置")
        app.buttons["settingsDone"].tap()
        XCTAssertTrue(options.waitForExistence(timeout: 8))
        options.tap(); app.buttons["optionAspect"].tap(); app.buttons["aspect-4:3"].tap()
        app.buttons["cameraOptionsHandle"].tap()
        XCTAssertEqual(aperture.frame.width / aperture.frame.height, 0.75, accuracy: 0.01)
    }

    #if !targetEnvironment(simulator)
    @MainActor
    func testPhysicalZoomGestureAndWideBounds() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["ARKCAM_TEST_LANGUAGE"] = "zh-Hans"
        app.launch()
        defer { app.terminate() }
        let shutter = app.buttons["shutter"]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: shutter)], timeout: 25), .completed)
        let maximum = app.buttons["zoom-5"].exists ? 25.0 : 15.0
        let one = app.buttons["zoom-1×"]
        one.tap()
        let scale = app.frame.width / 375
        let center = one.frame
        let start = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: center.midX, dy: center.midY))
        let dial = app.descendants(matching: .any)["zoomDial"].firstMatch
        start.press(forDuration: 0.25)
        XCTAssertTrue(dial.exists)
        let arc = start.withOffset(CGVector(dx: 0, dy: -42 * scale))
        arc.press(forDuration: 0.01, thenDragTo: arc.withOffset(CGVector(dx: -172 * scale, dy: 0)), withVelocity: .slow, thenHoldForDuration: 0.85)
        XCTAssertEqual(Double(dial.value as? String ?? ""), maximum)
        attach(app, name: "真机轮盘_单次滑到最大倍率")
        let regrip = start.withOffset(CGVector(dx: -90 * scale, dy: -42 * scale))
        regrip.press(forDuration: 0.01, thenDragTo: regrip.withOffset(CGVector(dx: 90 * scale, dy: 0)), withVelocity: .slow, thenHoldForDuration: 0.1)
        XCTAssertTrue(dial.exists)
        let value = Double(dial.value as? String ?? "") ?? 0
        XCTAssertGreaterThan(value, 1)
        XCTAssertLessThan(value, maximum / 2)
        attach(app, name: "真机轮盘_弧面续拖")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: dial)], timeout: 5), .completed)
        one.tap()
        app.buttons["cameraControlsToggle"].tap()
        XCTAssertTrue(app.buttons["optionAspect"].waitForExistence(timeout: 3))
        let oldAspect = app.buttons["optionAspect"].value as? String ?? "4:3"
        app.buttons["optionAspect"].tap()
        XCTAssertTrue(app.buttons["aspect-16:9"].waitForExistence(timeout: 3))
        app.buttons["aspect-16:9"].tap()
        app.buttons["cameraOptionsHandle"].tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.buttons["cameraOptionsHandle"])], timeout: 3), .completed)
        let aperture = app.descendants(matching: .any)["rearPrimary"].firstMatch.frame
        XCTAssertEqual(aperture.width / aperture.height, 9.0 / 16, accuracy: 0.01)
        XCTAssertLessThan(aperture.minY, app.buttons["topFlashOptions"].frame.minY)
        XCTAssertEqual(app.buttons["openLibrary"].frame.minY - aperture.maxY, 20 * scale, accuracy: 2)
        attach(app, name: "真机16比9_构图边界")
        app.buttons["cameraControlsToggle"].tap()
        XCTAssertTrue(app.buttons["optionAspect"].waitForExistence(timeout: 3))
        app.buttons["optionAspect"].tap()
        XCTAssertTrue(app.buttons["aspect-" + oldAspect].waitForExistence(timeout: 3))
        app.buttons["aspect-" + oldAspect].tap()
        app.buttons["cameraOptionsHandle"].tap()
    }

    @MainActor
    func testPhysicalFlashAspectsLiveAndVideo() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["ARKCAM_TEST_LANGUAGE"] = "zh-Hans"; app.launch()
        let shutter = app.buttons["shutter"]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: shutter)], timeout: 25), .completed)
        app.buttons["photoMode"].tap()
        let live = app.buttons["livePhotoToggle"]
        if live.label == "关闭 Live Photo" { live.tap() }
        func chooseAspect(_ value: String) {
            app.buttons["cameraControlsToggle"].tap()
            app.buttons["optionAspect"].tap()
            app.buttons["aspect-" + value].tap()
            app.buttons["cameraOptionsHandle"].tap()
        }
        func capture() {
            sleep(2)
            shutter.tap()
            XCTAssertTrue(app.staticTexts["已保存到回忆"].waitForExistence(timeout: 25))
            XCTAssertFalse(app.alerts["拍摄提示"].exists)
            sleep(3)
        }
        for aspect in ["4:3", "16:9", "1:1"] {
            chooseAspect(aspect)
            let aperture = app.descendants(matching: .any)["captureAperture"].firstMatch.frame
            let pip = app.descendants(matching: .any)["pipWindow"].firstMatch.frame
            XCTAssertEqual(pip.width / pip.height, 0.75, accuracy: 0.02)
            let expected = aspect == "4:3" ? 0.75 : aspect == "16:9" ? 0.5625 : 1.0
            XCTAssertEqual(aperture.width / aperture.height, expected, accuracy: 0.01)
            attach(app, name: "真机主画幅-" + aspect)
            if aspect == "4:3" {
                app.buttons["cameraControlsToggle"].tap(); app.buttons["optionFlash"].tap()
                XCTAssertTrue(app.buttons["flash-on"].isEnabled)
                app.buttons["flash-on"].tap(); attach(app, name: "真实闪光灯选项")
                app.buttons["cameraOptionsHandle"].tap()
            }
            capture()
            if aspect == "4:3" {
                app.buttons["cameraControlsToggle"].tap(); app.buttons["optionFlash"].tap()
                app.buttons["flash-off"].tap(); app.buttons["cameraOptionsHandle"].tap()
            }
        }
        live.tap(); sleep(3); capture()
        app.buttons["videoMode"].tap(); chooseAspect("1:1")
        app.buttons["cameraControlsToggle"].tap(); app.buttons["optionFlash"].tap()
        XCTAssertTrue(app.buttons["torch-on"].isEnabled)
        app.buttons["torch-on"].tap(); app.buttons["cameraOptionsHandle"].tap()
        shutter.tap(); sleep(3)
        XCTAssertEqual(shutter.label, "停止录像")
        XCTAssertFalse(app.buttons["cameraControlsToggle"].isEnabled)
        shutter.tap()
        XCTAssertTrue(app.staticTexts["已保存到回忆"].waitForExistence(timeout: 20))
        app.buttons["cameraControlsToggle"].tap(); app.buttons["optionFlash"].tap()
        app.buttons["torch-off"].tap(); app.buttons["cameraOptionsHandle"].tap()
        chooseAspect("16:9"); app.buttons["photoMode"].tap(); chooseAspect("4:3")
    }

    @MainActor
    func testPhysicalOpticalZoomAndHighResolutionLive() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["ARKCAM_TEST_LANGUAGE"] = "zh-Hans"
        app.launch()
        let shutter = app.buttons["shutter"]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: shutter)], timeout: 25), .completed)
        let tele = app.buttons["zoom-3"].exists ? app.buttons["zoom-3"] : app.buttons["zoom-5"]
        XCTAssertTrue(tele.exists)
        XCTAssertTrue(app.buttons["zoom-2"].exists)
        let live = app.buttons["livePhotoToggle"]
        if live.label == "关闭 Live Photo" { live.tap() }
        tele.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "已选择"), object: tele)], timeout: 8), .completed)
        sleep(2)
        attach(app, name: "真实长焦取景")
        shutter.tap()
        XCTAssertTrue(app.staticTexts["已保存到回忆"].waitForExistence(timeout: 25))
        if app.alerts["拍摄提示"].exists { app.alerts["拍摄提示"].buttons["知道了"].tap() }
        live.tap()
        sleep(3)
        shutter.tap()
        XCTAssertTrue(app.staticTexts["已保存到回忆"].waitForExistence(timeout: 25))
        if app.alerts["拍摄提示"].exists { app.alerts["拍摄提示"].buttons["知道了"].tap() }
        app.buttons["openLibrary"].tap()
        app.buttons["memory-photo"].firstMatch.tap()
        app.buttons["showCaptureInfo"].tap()
        XCTAssertTrue(app.staticTexts["相册保存 1 张合成 Live Photo · App 保留 2 路动态原片"].waitForExistence(timeout: 8))
    }

    @MainActor
    func testPhysicalZoomDialAndRecordingLensChange() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["ARKCAM_TEST_LANGUAGE"] = "zh-Hans"
        app.launch()
        let shutter = app.buttons["shutter"]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: shutter)], timeout: 25), .completed)
        app.buttons["zoom-2"].press(forDuration: 0.6)
        XCTAssertTrue(app.descendants(matching: .any)["zoomDial"].exists)
        attach(app, name: "原生风格连续变焦盘")
        sleep(2)
        let zoom = app.buttons["zoom-1×"]
        let start = zoom.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.3, thenDragTo: start.withOffset(CGVector(dx: -75, dy: 0)))
        attach(app, name: "拖动后的连续倍率")
        sleep(2)
        zoom.tap()
        let hold = shutter.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        hold.press(forDuration: 0.3, thenDragTo: hold.withOffset(CGVector(dx: 133.5 * app.frame.width / 375, dy: 0)),
                   withVelocity: .slow, thenHoldForDuration: 0.6)
        XCTAssertEqual(shutter.label, "停止录像")
        sleep(1)
        let tele = app.buttons["zoom-3"].exists ? app.buttons["zoom-3"] : app.buttons["zoom-5"]
        let tree = XCTAttachment(string: "tele=\(tele.frame) shutter=\(shutter.frame)\n" + app.debugDescription)
        tree.name = "RecordingZoomHitTargets"; tree.lifetime = .keepAlways; add(tree)
        attach(app, name: "录像中切换镜头前")
        tele.tap()
        sleep(2)
        attach(app, name: "录像中切换镜头后")
        XCTAssertEqual(shutter.label, "停止录像")
        XCTAssertEqual(tele.value as? String, "已选择")
        zoom.tap()
        sleep(2)
        XCTAssertEqual(shutter.label, "停止录像")
        shutter.tap()
        XCTAssertTrue(app.staticTexts["已保存到回忆"].waitForExistence(timeout: 25))
        XCTAssertFalse(app.alerts["拍摄提示"].exists)
    }

    @MainActor
    func testPhysicalLiveCaptureFinishesWithoutLeavingBusyState() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["ARKCAM_TEST_LANGUAGE"] = "zh-Hans"
        app.launch()
        let live = app.buttons["livePhotoToggle"]
        XCTAssertTrue(live.waitForExistence(timeout: 20))
        let liveReady = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: live)
        XCTAssertEqual(XCTWaiter.wait(for: [liveReady], timeout: 20), .completed)
        if live.label == "开启 Live Photo" { live.tap() }
        // Fill the pre-shutter rolling window before taking the device sample.
        sleep(2)
        let shutter = app.buttons["shutter"]
        XCTAssertTrue(shutter.isEnabled)
        shutter.tap()
        XCTAssertTrue(app.staticTexts["已保存到回忆"].waitForExistence(timeout: 25))
        XCTAssertTrue(shutter.isEnabled, "The capture must leave the busy state after saving")
        if app.alerts["拍摄提示"].exists { app.alerts["拍摄提示"].buttons["知道了"].tap() }
        app.buttons["openLibrary"].tap()
        let photo = app.buttons["memory-photo"].firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 5))
        photo.tap()
        app.buttons["showCaptureInfo"].tap()
        XCTAssertTrue(app.staticTexts["相册保存 1 张合成 Live Photo · App 保留 2 路动态原片"].waitForExistence(timeout: 8),
                      "A saved still photo is not a successful Live Photo capture")
    }

    @MainActor
    func testPhysicalTapFocusAndLockFollowDisplayedLens() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["ARKCAM_TEST_LANGUAGE"] = "zh-Hans"
        app.launch()
        let shutter = app.buttons["shutter"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: shutter)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 25), .completed)

        // The chosen rear input must keep both capture streams available while zooming.
        let zoomIdentifiers = ["zoom-0.5", "zoom-2", "zoom-5", "zoom-1×"]
            .filter { app.buttons[$0].exists }
        for identifier in zoomIdentifiers {
            let zoom = app.buttons[identifier]
            XCTAssertTrue(zoom.isEnabled)
            zoom.tap()
            let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "已选择"), object: zoom)
            XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 3), .completed)
            XCTAssertTrue(shutter.isEnabled)
        }
        let main = app.descendants(matching: .any)["rearPrimary"]
        XCTAssertTrue(main.waitForExistence(timeout: 5))
        main.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.42)).tap()
        let indicator = app.descendants(matching: .any)["focusIndicator"]
        XCTAssertTrue(indicator.waitForExistence(timeout: 2))
        XCTAssertEqual(indicator.value as? String, "后摄")

        main.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.45)).press(forDuration: 0.8)
        XCTAssertTrue(app.staticTexts["focusLockLabel"].waitForExistence(timeout: 2))

        let pip = app.descendants(matching: .any)["pipWindow"]
        pip.tap()
        let frontMain = app.descendants(matching: .any)["frontPrimary"]
        XCTAssertTrue(frontMain.waitForExistence(timeout: 2))
        frontMain.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.38)).tap()
        XCTAssertTrue(indicator.waitForExistence(timeout: 2))
        XCTAssertEqual(indicator.value as? String, "前摄")
        pip.tap()
        let start = pip.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.82, dy: 0.82)))
        XCTAssertLessThan(pip.frame.maxY, app.buttons["zoom-1×"].frame.minY - 5)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "真机倍率与小窗切换后主界面"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testPhysicalQuickTakeAndRecordingLayout() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["ARKCAM_TEST_LANGUAGE"] = "zh-Hans"
        app.launch()
        let shutter = app.buttons["shutter"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: shutter)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 25), .completed)
        let start = shutter.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.3, thenDragTo: start.withOffset(CGVector(dx: 133.5 * app.frame.width / 375, dy: 0)),
                    withVelocity: .slow, thenHoldForDuration: 0.6)
        XCTAssertTrue(app.descendants(matching: .any)["recordingTimer"].waitForExistence(timeout: 10))
        XCTAssertEqual(shutter.label, "停止录像")
        XCTAssertFalse(app.buttons["openLibrary"].isEnabled)
        let pip = app.descendants(matching: .any)["pipWindow"]
        pip.tap()
        XCTAssertTrue(app.descendants(matching: .any)["frontPrimary"].waitForExistence(timeout: 3))
        attach(app, name: "真机快捷录像_前摄主画面")
        XCTAssertEqual(shutter.label, "停止录像", "Swapping the inset must not stop recording")
        shutter.tap()
        XCTAssertTrue(app.staticTexts["已保存到回忆"].waitForExistence(timeout: 25))
        XCTAssertTrue(shutter.isEnabled)
    }

    @MainActor
    func testPhysicalForegroundRecoveryDoesNotFlashFailure() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["ARKCAM_TEST_LANGUAGE"] = "zh-Hans"
        app.launch()
        let shutter = app.buttons["shutter"]
        let initiallyReady = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: shutter)
        XCTAssertEqual(XCTWaiter.wait(for: [initiallyReady], timeout: 25), .completed)

        XCUIDevice.shared.press(.home)
        sleep(1)
        app.activate()
        let failure = app.staticTexts["暂时无法拍摄"]
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            XCTAssertFalse(failure.exists, "Returning to the app must not present a transient camera failure")
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        let readyAgain = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: shutter)
        XCTAssertEqual(XCTWaiter.wait(for: [readyAgain], timeout: 10), .completed)
    }
    #endif

    @MainActor
    func testAutomaticAlbumSaveModeSettingsPersist() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["ARKCAM_TEST_LANGUAGE"] = "zh-Hans"
        app.launchArguments = ["--ui-fixtures", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        func openSetting() {
            XCTAssertTrue(app.buttons["cameraControlsToggle"].waitForExistence(timeout: 10))
            app.buttons["cameraControlsToggle"].tap()
            let options = app.buttons["optionSettings"]
            let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                options.isHittable && options.frame.maxY < app.frame.maxY - 20
            }, object: options)
            XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 5), .completed)
            options.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            let setting = app.buttons["settingsAlbumSaveMode"]
            XCTAssertTrue(setting.waitForExistence(timeout: 5))
            setting.tap()
        }
        app.launch(); openSetting()
        let primary = app.buttons["albumSaveMode-primary"]
        let dual = app.buttons["albumSaveMode-dual"]
        XCTAssertTrue(primary.waitForExistence(timeout: 5))
        primary.tap()
        XCTAssertEqual(primary.value as? String, "已选择")
        XCTAssertEqual(dual.value as? String, "未选择")
        attach(app, name: "自动保存_仅主画面设置")
        app.terminate(); app.launch(); openSetting()
        XCTAssertTrue(primary.waitForExistence(timeout: 5))
        XCTAssertEqual(primary.value as? String, "已选择")
        let separate = app.buttons["albumSaveMode-separate"]
        XCTAssertTrue(separate.exists)
        separate.tap()
        XCTAssertEqual(separate.value as? String, "已选择")
        XCTAssertEqual(primary.value as? String, "未选择")
        attach(app, name: "自动保存_双摄同时保存设置")
        app.terminate(); app.launch(); openSetting()
        XCTAssertEqual(separate.value as? String, "已选择")
        dual.tap()
        XCTAssertEqual(dual.value as? String, "已选择")
        XCTAssertEqual(separate.value as? String, "未选择")
        attach(app, name: "自动保存_双摄合成默认设置")
        app.terminate()
    }

    @MainActor
    func testModeSelectorDragTapReboundAndVerticalRejection() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["ARKCAM_TEST_LANGUAGE"] = "zh-Hans"
        app.launchArguments = ["--ui-fixtures", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        let photo = app.buttons["photoMode"]
        let video = app.buttons["videoMode"]
        XCTAssertTrue(photo.waitForExistence(timeout: 10))
        photo.tap()
        let center = app.frame.midX
        let scale = min(app.frame.width / 375, app.frame.height / 812)
        func expect(_ mode: XCUIElement) {
            let selected = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                mode.value as? String == "已选择" && abs(mode.frame.midX - center) < 1
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 4), .completed)
        }
        func drag(_ mode: XCUIElement, dx: CGFloat, dy: CGFloat = 0) {
            let start = mode.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            start.press(forDuration: 0.25, thenDragTo: start.withOffset(CGVector(dx: dx * scale, dy: dy * scale)),
                        withVelocity: .slow, thenHoldForDuration: 0.65)
        }
        expect(photo)
        let shutterFrame = app.buttons["shutter"].frame
        drag(photo, dx: 14)
        expect(photo)
        drag(photo, dx: 0, dy: -42)
        expect(photo)
        drag(photo, dx: -45)
        expect(photo)
        drag(photo, dx: 48)
        expect(video)
        XCTAssertEqual(app.buttons["shutter"].label, "开始双面录像")
        XCTAssertEqual(app.buttons["shutter"].frame, shutterFrame)
        attach(app, name: "模式栏_右拖吸附视频")
        drag(video, dx: 48)
        expect(video)
        drag(video, dx: -48)
        expect(photo)
        XCTAssertEqual(app.buttons["shutter"].label, "拍摄双面照片")
        XCTAssertEqual(app.buttons["shutter"].frame, shutterFrame)
        attach(app, name: "模式栏_左拖吸附照片")
        video.tap(); expect(video)
        photo.tap(); expect(photo)
        // Dragging can start directly over the unselected label, too.
        drag(video, dx: 48)
        expect(video)
        photo.tap(); expect(photo)
    }

    @MainActor
    func testCameraChromeUsesNativeControlHierarchy() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["ARKCAM_TEST_LANGUAGE"] = "zh-Hans"
        app.launchArguments = ["--ui-quicktake-fixture", "-cameraPhotoAspect", "4:3", "-cameraVideoAspect", "16:9"]
        app.launch()
        app.buttons["photoMode"].tap()
        let controls = app.buttons["cameraControlsToggle"]
        let live = app.buttons["livePhotoToggle"]
        let photo = app.buttons["photoMode"]
        let video = app.buttons["videoMode"]
        let shutter = app.buttons["shutter"]
        let library = app.buttons["openLibrary"]
        let swap = app.buttons["swapCameras"]
        let zoom = app.descendants(matching: .any)["rearZoomSelector"]
        let modes = app.descendants(matching: .any)["captureModeSelector"]
        XCTAssertTrue(controls.waitForExistence(timeout: 10))
        XCTAssertTrue(live.exists)
        XCTAssertTrue(photo.exists)
        XCTAssertTrue(video.exists)
        XCTAssertTrue(shutter.exists)
        XCTAssertTrue(library.exists)
        XCTAssertTrue(swap.exists)
        XCTAssertTrue(zoom.exists)
        XCTAssertTrue(modes.exists)
        #if targetEnvironment(simulator)
        XCTAssertTrue(app.buttons["zoom-0.5"].exists)
        #endif
        XCTAssertTrue(app.buttons["zoom-1×"].exists)
        XCTAssertTrue(app.buttons["zoom-2"].exists)
        XCTAssertTrue(app.buttons["zoom-5"].exists)
        for control in [controls, live, shutter, library, swap, photo, video] {
            XCTAssertGreaterThanOrEqual(control.frame.minX, app.frame.minX)
            XCTAssertLessThanOrEqual(control.frame.maxX, app.frame.maxX)
        }
        let scale = min(app.frame.width / 375, app.frame.height / 812)
        let aperture = app.descendants(matching: .any)["rearPrimary"]
        XCTAssertTrue(aperture.exists)
        // Independent measured reference in display points (1125 × 2436 / 3).
        XCTAssertEqual(aperture.frame.minY, 106 * scale, accuracy: 2)
        XCTAssertEqual(aperture.frame.maxY, 606 * scale, accuracy: 2)
        XCTAssertEqual(aperture.frame.height / aperture.frame.width, 4 / 3, accuracy: 0.01)
        XCTAssertEqual(shutter.frame.midY, 661.67 * scale, accuracy: 2)
        XCTAssertEqual(shutter.frame.width, 80.67 * scale, accuracy: 2)
        XCTAssertGreaterThan(shutter.frame.minY, aperture.frame.maxY)
        XCTAssertEqual(library.frame.midY, app.frame.height - 54 * scale, accuracy: 2)
        XCTAssertEqual(library.frame.height, 48 * scale, accuracy: 2)
        XCTAssertEqual(swap.frame.height, 48 * scale, accuracy: 2)
        XCTAssertEqual(library.frame.midY, swap.frame.midY, accuracy: 1)
        XCTAssertEqual(photo.frame.midY, library.frame.midY, accuracy: 1)
        XCTAssertEqual(photo.frame.midX, app.frame.midX, accuracy: 1)
        XCTAssertEqual(shutter.frame.midX, app.frame.midX, accuracy: 1)
        let one = app.buttons["zoom-1×"]
        XCTAssertEqual(one.frame.midX, app.frame.midX, accuracy: 1)
        XCTAssertEqual(one.frame.midY, 570 * scale, accuracy: 2)
        XCTAssertEqual(one.frame.height, 38 * scale, accuracy: 2)
        XCTAssertLessThan(one.frame.maxY, aperture.frame.maxY)
        attach(app, name: "照片首页_参考尺寸验收")

        let originalShutter = shutter.frame
        controls.tap()
        XCTAssertTrue(app.buttons["optionFlash"].waitForExistence(timeout: 2))
        attach(app, name: "拍摄选项展开")
        app.buttons["cameraOptionsHandle"].tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.buttons["cameraOptionsHandle"])], timeout: 3), .completed)
        XCTAssertEqual(shutter.frame, originalShutter, "Closing options must restore the same shutter position")

        video.tap()
        let videoCentered = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            abs(video.frame.midX - app.frame.midX) < 1
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [videoCentered], timeout: 3), .completed)
        XCTAssertEqual(video.frame.midX, app.frame.midX, accuracy: 1)
        XCTAssertEqual(shutter.frame, originalShutter)
        XCTAssertEqual(aperture.frame.height / aperture.frame.width, 16 / 9, accuracy: 0.01)
        attach(app, name: "视频模式_底栏不移动")
        photo.tap()
        let photoCentered = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            abs(photo.frame.midX - app.frame.midX) < 1
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [photoCentered], timeout: 3), .completed)
        XCTAssertEqual(photo.frame.midX, app.frame.midX, accuracy: 1)
    }

    @MainActor
    func testGalleryZoomFullscreenFilmstripAndLive() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["ARKCAM_TEST_LANGUAGE"] = "zh-Hans"
        app.launchArguments = ["--ui-fixtures", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        app.buttons["openLibrary"].tap()
        XCTAssertTrue(app.buttons.matching(identifier: "memory-photo").firstMatch.waitForExistence(timeout: 15))
        app.buttons.matching(identifier: "memory-photo").firstMatch.tap()
        let zoom = app.scrollViews["detailZoom"]
        XCTAssertTrue(zoom.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["showCaptureInfo"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["captureInfo"].exists)
        XCTAssertFalse(app.buttons["detailSwap"].exists)
        attach(app, name: "相册浏览_照片与底部缩略图")
        XCTAssertTrue(app.staticTexts["按住播放"].waitForExistence(timeout: 15))
        zoom.pinch(withScale: 2, velocity: 2)
        let zoomed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value != '1×'"), object: zoom)
        XCTAssertEqual(XCTWaiter.wait(for: [zoomed], timeout: 5), .completed)
        // A drag while magnified pans the image and must not navigate to the video.
        zoom.swipeLeft()
        XCTAssertTrue(app.otherElements["livePhotoSurface"].exists)
        zoom.doubleTap()
        let reset = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == '1×'"), object: zoom)
        XCTAssertEqual(XCTWaiter.wait(for: [reset], timeout: 5), .completed)
        zoom.tap()
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.buttons["showCaptureInfo"])
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 5), .completed)
        XCTAssertFalse(app.collectionViews["memoryFilmstrip"].exists)
        attach(app, name: "相册浏览_单击全屏")
        zoom.tap()
        XCTAssertTrue(app.buttons["showCaptureInfo"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["按住播放"].waitForExistence(timeout: 15))
        zoom.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.5, thenDragTo: zoom.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)), withVelocity: .slow, thenHoldForDuration: 0.4)
        app.buttons["showCaptureInfo"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["captureInfo"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["captureDevice"].exists)
        app.buttons["closeCaptureInfo"].tap()
        let video = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'filmstrip-video-'" )).firstMatch
        XCTAssertTrue(video.exists)
        video.tap()
        XCTAssertTrue(app.buttons["播放"].waitForExistence(timeout: 10))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: app.buttons["播放"])
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed)
        app.buttons["播放"].tap()
        zoom.pinch(withScale: 2, velocity: 1)
        XCTAssertTrue(app.buttons["暂停"].exists)
        XCTAssertNotEqual(zoom.value as? String, "1×")
        attach(app, name: "相册浏览_视频播放中缩放")
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'filmstrip-photo-'" )).firstMatch.tap()
        XCTAssertFalse(app.buttons["暂停"].exists)
        XCTAssertTrue(app.otherElements["livePhotoSurface"].waitForExistence(timeout: 5))
        XCTAssertEqual(zoom.value as? String, "1×")
        // Browsing never opens the inset editor implicitly.
        XCTAssertFalse(app.buttons["detailSwap"].exists)
        zoom.swipeRight()
        XCTAssertTrue(app.buttons["播放"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testTabletGalleryDoubleTapFullscreenFilmstripAndLive() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["ARKCAM_TEST_LANGUAGE"] = "zh-Hans"
        app.launchArguments = ["--ui-fixtures", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        app.buttons["openLibrary"].tap()
        XCTAssertTrue(app.buttons.matching(identifier: "memory-photo").firstMatch.waitForExistence(timeout: 15))
        app.buttons.matching(identifier: "memory-photo").firstMatch.tap()
        let zoom = app.scrollViews["detailZoom"]
        XCTAssertTrue(zoom.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["showCaptureInfo"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["captureInfo"].exists)
        XCTAssertFalse(app.buttons["detailSwap"].exists)
        attach(app, name: "相册浏览_照片与底部缩略图")
        XCTAssertTrue(app.staticTexts["按住播放"].waitForExistence(timeout: 15))
        zoom.doubleTap()
        let zoomed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value != '1×'"), object: zoom)
        XCTAssertEqual(XCTWaiter.wait(for: [zoomed], timeout: 5), .completed)
        // A drag while magnified pans the image and must not navigate to the video.
        zoom.swipeLeft()
        XCTAssertTrue(app.otherElements["livePhotoSurface"].exists)
        zoom.doubleTap()
        let reset = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == '1×'"), object: zoom)
        XCTAssertEqual(XCTWaiter.wait(for: [reset], timeout: 5), .completed)
        zoom.tap()
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.buttons["showCaptureInfo"])
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 5), .completed)
        XCTAssertFalse(app.collectionViews["memoryFilmstrip"].exists)
        attach(app, name: "相册浏览_单击全屏")
        zoom.tap()
        XCTAssertTrue(app.buttons["showCaptureInfo"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["按住播放"].waitForExistence(timeout: 15))
        zoom.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.5, thenDragTo: zoom.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)), withVelocity: .slow, thenHoldForDuration: 0.4)
        app.buttons["showCaptureInfo"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["captureInfo"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["captureDevice"].exists)
        app.buttons["closeCaptureInfo"].tap()
        let video = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'filmstrip-video-'" )).firstMatch
        XCTAssertTrue(video.exists)
        video.tap()
        XCTAssertTrue(app.buttons["播放"].waitForExistence(timeout: 10))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: app.buttons["播放"])
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed)
        app.buttons["播放"].tap()
        zoom.doubleTap()
        XCTAssertTrue(app.buttons["暂停"].exists)
        XCTAssertNotEqual(zoom.value as? String, "1×")
        attach(app, name: "相册浏览_视频播放中缩放")
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'filmstrip-photo-'" )).firstMatch.tap()
        XCTAssertFalse(app.buttons["暂停"].exists)
        XCTAssertTrue(app.otherElements["livePhotoSurface"].waitForExistence(timeout: 5))
        XCTAssertEqual(zoom.value as? String, "1×")
        // Browsing never opens the inset editor implicitly.
        XCTAssertFalse(app.buttons["detailSwap"].exists)
        zoom.swipeRight()
        XCTAssertTrue(app.buttons["播放"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testGalleryFilmstripScrubbingKeepsSelectionCenteredAndZoomResets() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["ARKCAM_TEST_LANGUAGE"] = "zh-Hans"
        app.launchArguments = ["--ui-fixtures", "--gallery-fixtures", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        app.buttons["openLibrary"].tap()
        XCTAssertTrue(app.buttons["memory-photo"].firstMatch.waitForExistence(timeout: 15))
        app.buttons["memory-photo"].firstMatch.tap()
        let strip = app.collectionViews["memoryFilmstrip"]
        XCTAssertTrue(strip.waitForExistence(timeout: 5))
        let selected = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'filmstrip-' AND value == '当前'" )).firstMatch
        print("Gallery initial hierarchy: \(app.debugDescription)")
        attach(app, name: "底部初始定位")
        let centered = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            selected.exists && abs(selected.frame.midX - app.frame.midX) < 3
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [centered], timeout: 5), .completed)
        let firstID = selected.identifier
        let zoom = app.scrollViews["detailZoom"]
        zoom.pinch(withScale: 2, velocity: 1)
        strip.swipeLeft()
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            selected.exists && selected.identifier != firstID && abs(selected.frame.midX - app.frame.midX) < 3
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 8), .completed)
        XCTAssertEqual(zoom.value as? String, "1×")
        XCTAssertFalse(app.otherElements["livePhotoSurface"].exists)
        let plainID = selected.identifier
        attach(app, name: "相册浏览_连续滑动缩略图与普通照片")
        zoom.doubleTap()
        XCTAssertNotEqual(zoom.value as? String, "1×")
        zoom.tap()
        XCTAssertFalse(app.buttons["showCaptureInfo"].waitForExistence(timeout: 1))
        XCTAssertNotEqual(zoom.value as? String, "1×")
        zoom.tap()
        XCTAssertTrue(app.buttons["showCaptureInfo"].waitForExistence(timeout: 5))
        XCTAssertEqual(selected.identifier, plainID)
        XCTAssertNotEqual(zoom.value as? String, "1×")
        zoom.doubleTap()
        let reset = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == '1×'"), object: zoom)
        XCTAssertEqual(XCTWaiter.wait(for: [reset], timeout: 5), .completed)
        zoom.swipeRight()
        XCTAssertNotEqual(selected.identifier, plainID)
    }

    @MainActor
    private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testPausedVideoPIPFollowsFingerAndRedrawsAtNewPosition() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["ARKCAM_TEST_LANGUAGE"] = "zh-Hans"
        app.launchArguments = ["--ui-fixtures", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        app.buttons["openLibrary"].tap()
        XCTAssertTrue(app.buttons["memory-video"].waitForExistence(timeout: 15))
        app.buttons["memory-video"].tap()
        app.buttons["showCaptureInfo"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["captureInfo"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["iPhone 15 Pro Max"].exists)
        app.buttons["closeCaptureInfo"].tap()
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: app.buttons["播放"])
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed)
        app.buttons["editMemoryLayout"].tap()
        let restore = app.buttons["恢复拍摄布局"]
        if restore.isEnabled { restore.tap() }
        let pip = app.descendants(matching: .any).matching(identifier: "pipWindow").firstMatch
        let before = pip.frame
        let start = pip.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: -100, dy: -150)),
                    withVelocity: .slow, thenHoldForDuration: 0.2)
        let after = pip.frame
        XCTAssertEqual(after.minX, before.minX - 100, accuracy: 8)
        XCTAssertEqual(after.minY, before.minY - 150, accuracy: 8)
        let screenshot = app.screenshot()
        let image = try XCTUnwrap(screenshot.image.cgImage)
        let scale = CGFloat(image.width) / app.frame.width
        let movedPip = pixel(image, point: CGPoint(x: (after.minX + after.width * 0.2) * scale,
                                                  y: (after.minY + after.height * 0.2) * scale))
        let oldPip = pixel(image, point: CGPoint(x: before.midX * scale, y: before.midY * scale))
        XCTAssertGreaterThan(movedPip.r, movedPip.g + 15, "Paused video must actually redraw the inset at its new position")
        XCTAssertGreaterThan(oldPip.g, oldPip.r + 15, "The old inset position must show the main picture")
        XCTAssertEqual(app.staticTexts["playbackTime"].label, "00:00 / 00:03")
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "视频暂停时拖动小窗"; attachment.lifetime = .keepAlways; add(attachment)
        app.buttons["detailBack"].tap()
        app.buttons["memory-video"].tap()
        app.buttons["editMemoryLayout"].tap()
        XCTAssertEqual(pip.frame.minX, after.minX, accuracy: 2)
        XCTAssertEqual(pip.frame.minY, after.minY, accuracy: 2)

        let play = app.buttons["播放"]
        let reopened = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: play)
        XCTAssertEqual(XCTWaiter.wait(for: [reopened], timeout: 15), .completed)
        play.tap()
        XCTAssertTrue(app.buttons["暂停"].waitForExistence(timeout: 5))
        let playingStart = pip.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        playingStart.press(forDuration: 0.1,
                           thenDragTo: playingStart.withOffset(CGVector(dx: 55, dy: 70)),
                           withVelocity: .slow, thenHoldForDuration: 0.1)
        XCTAssertTrue(app.buttons["暂停"].exists, "Playback should resume after a layout drag")
        let resumed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label MATCHES '00:0[1-3] / 00:03'"),
            object: app.staticTexts["playbackTime"])
        XCTAssertEqual(XCTWaiter.wait(for: [resumed], timeout: 3), .completed)
    }

    @MainActor
    func testPhotoPIPFollowsFingerAndPersistsAfterReopening() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["ARKCAM_TEST_LANGUAGE"] = "zh-Hans"
        app.launchArguments = ["--ui-fixtures", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        app.buttons["openLibrary"].tap()
        XCTAssertTrue(app.buttons["memory-photo"].waitForExistence(timeout: 15))
        app.buttons["memory-photo"].tap()
        app.buttons["showCaptureInfo"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["captureInfo"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["captureLocation"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["captureDevice"].exists)
        XCTAssertTrue(app.staticTexts["iPhone 15 Pro Max"].exists)
        app.buttons["closeCaptureInfo"].tap()
        app.buttons["editMemoryLayout"].tap()
        let restore = app.buttons["恢复布局"]
        if restore.isEnabled { restore.tap() }
        let pip = app.descendants(matching: .any).matching(identifier: "pipWindow").firstMatch
        XCTAssertTrue(pip.waitForExistence(timeout: 5))
        let before = pip.frame
        let start = pip.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = start.withOffset(CGVector(dx: -100, dy: -150))
        start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
        let after = pip.frame
        XCTAssertEqual(after.minX, before.minX - 100, accuracy: 8)
        XCTAssertEqual(after.minY, before.minY - 150, accuracy: 8)
        app.buttons["detailBack"].tap()
        app.buttons["memory-photo"].tap()
        app.buttons["editMemoryLayout"].tap()
        XCTAssertEqual(pip.frame.minX, after.minX, accuracy: 2)
        XCTAssertEqual(pip.frame.minY, after.minY, accuracy: 2)
    }

    @MainActor
    func testPlaySwapAndSaveMergedVideo() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["ARKCAM_TEST_LANGUAGE"] = "zh-Hans"
        app.resetAuthorizationStatus(for: .photos)
        app.launchArguments = ["--ui-fixtures", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.buttons["openLibrary"].waitForExistence(timeout: 15))
        app.buttons["openLibrary"].tap()
        XCTAssertTrue(app.buttons["memory-video"].waitForExistence(timeout: 15))
        app.buttons["memory-video"].tap()
        let play = app.buttons["播放"]
        XCTAssertTrue(play.waitForExistence(timeout: 15))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: play)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed)
        let surface = app.otherElements["videoSurface"]
        XCTAssertEqual(surface.value as? String, "画面已就绪")
        let playbackTime = app.staticTexts["playbackTime"]
        XCTAssertEqual(playbackTime.label, "00:00 / 00:03")
        play.tap()
        XCTAssertTrue(app.buttons["暂停"].waitForExistence(timeout: 5))
        let advancing = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label MATCHES '00:0[1-3] / 00:03'"), object: playbackTime)
        XCTAssertEqual(XCTWaiter.wait(for: [advancing], timeout: 5), .completed)
        app.buttons["暂停"].tap()
        app.buttons["editMemoryLayout"].tap()
        app.buttons["detailSwap"].tap()
        let preview = XCTAttachment(screenshot: app.screenshot())
        preview.name = "视频回看"; preview.lifetime = .keepAlways; add(preview)
        app.buttons["saveToPhotos"].tap()
        app.buttons["export-combined"].firstMatch.tap()
        allowAddingToPhotosIfNeeded()
        XCTAssertTrue(app.alerts["保存到相册"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.alerts.staticTexts.containing(NSPredicate(format: "label CONTAINS '已保存到相册（双摄合成）'" )).firstMatch.exists)
        app.alerts.buttons["完成"].tap()
        app.buttons["detailBack"].tap()
        app.buttons["memory-video"].tap()
        let reopened = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: app.buttons["播放"])
        XCTAssertEqual(XCTWaiter.wait(for: [reopened], timeout: 15), .completed)
        XCTAssertEqual(app.otherElements["videoSurface"].value as? String, "画面已就绪")
        XCTAssertEqual(app.staticTexts["playbackTime"].label, "00:00 / 00:03")
    }

    @MainActor
    func testDownloadChoicesCancelAndSaveEachPhysicalCamera() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["ARKCAM_TEST_LANGUAGE"] = "zh-Hans"
        app.launchArguments = ["--ui-fixtures"]
        app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.buttons["openLibrary"].waitForExistence(timeout: 15)); app.buttons["openLibrary"].tap()
        XCTAssertTrue(app.buttons["memory-photo"].waitForExistence(timeout: 15)); app.buttons["memory-photo"].tap()
        app.buttons["editMemoryLayout"].tap(); app.buttons["detailSwap"].tap()
        app.buttons["saveToPhotos"].tap()
        for mode in ["front", "rear", "combined"] { XCTAssertTrue(app.buttons["export-" + mode].waitForExistence(timeout: 3)) }
        attach(app, name: "详情下载_三种方式")
        dismissExportOptions(app)
        XCTAssertFalse(app.alerts["保存到相册"].exists)
        for mode in ["front", "rear"] {
            app.buttons["saveToPhotos"].tap(); app.buttons["export-" + mode].firstMatch.tap()
            allowAddingToPhotosIfNeeded()
            let result = app.alerts["保存到相册"]
            XCTAssertTrue(result.waitForExistence(timeout: 30))
            XCTAssertTrue(result.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "已保存到相册（" + (mode == "front" ? "仅前置" : "仅后置") + "）")).firstMatch.exists)
            result.buttons["完成"].tap()
        }
    }

    @MainActor
    func testBrowseSwapAndSaveMergedPhoto() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["ARKCAM_TEST_LANGUAGE"] = "zh-Hans"
        app.resetAuthorizationStatus(for: .photos)
        app.launchArguments = ["--ui-fixtures", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.buttons["openLibrary"].waitForExistence(timeout: 15))
        app.buttons["openLibrary"].tap()
        XCTAssertTrue(app.buttons["memory-photo"].waitForExistence(timeout: 15))
        let libraryImage = XCTAttachment(screenshot: app.screenshot())
        libraryImage.name = "回忆列表"; libraryImage.lifetime = .keepAlways; add(libraryImage)
        app.buttons["memory-photo"].tap()
        XCTAssertTrue(app.buttons["editMemoryLayout"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["按住播放"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.otherElements["livePhotoSurface"].exists)
        app.buttons["editMemoryLayout"].tap()
        app.buttons["detailSwap"].tap()
        app.buttons["showCaptureInfo"].tap()
        let captureInfo = app.descendants(matching: .any)["captureInfo"]
        XCTAssertTrue(captureInfo.isHittable)
        let detail = XCTAttachment(screenshot: app.screenshot())
        detail.name = "照片回看与交换"; detail.lifetime = .keepAlways; add(detail)
        app.buttons["closeCaptureInfo"].tap()
        app.buttons["saveToPhotos"].tap()
        app.buttons["export-combined"].firstMatch.tap()
        allowAddingToPhotosIfNeeded()
        XCTAssertTrue(app.alerts["保存到相册"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.alerts.staticTexts.containing(NSPredicate(format: "label CONTAINS '已保存到相册（双摄合成）'" )).firstMatch.exists)
        app.alerts.buttons["完成"].tap()
    }

    @MainActor
    private func dismissExportOptions(_ app: XCUIApplication) {
        // iOS 26 presents a popover dismissed outside its bounds; older action
        // sheets expose the cancel action. Neither route should start a save.
        if app.buttons["取消"].firstMatch.exists {
            app.buttons["取消"].firstMatch.tap()
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.15)).tap()
        }
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"),
                                             object: app.buttons["export-rear"].firstMatch)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 3), .completed)
    }

    @MainActor
    private func allowAddingToPhotosIfNeeded() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        guard springboard.alerts.firstMatch.waitForExistence(timeout: 3) else { return }
        let allow = springboard.alerts.buttons.allElementsBoundByIndex.first {
            !$0.label.localizedCaseInsensitiveContains("don’t") &&
            !$0.label.localizedCaseInsensitiveContains("don't") &&
            !$0.label.contains("不允许")
        }
        XCTAssertNotNil(allow, "没有找到照片添加授权按钮")
        allow?.tap()
    }

    private func pixel(_ image: CGImage, point: CGPoint) -> (r: Int, g: Int, b: Int) {
        guard let crop = image.cropping(to: CGRect(x: point.x, y: point.y, width: 1, height: 1)) else {
            XCTFail("Sample point falls outside screenshot"); return (0, 0, 0)
        }
        var rgba = [UInt8](repeating: 0, count: 4)
        rgba.withUnsafeMutableBytes { data in
            let context = CGContext(data: data.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
            context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return (Int(rgba[0]), Int(rgba[1]), Int(rgba[2]))
    }
}

extension CamUITests {
    @MainActor
    func testGalleryShowsSaveStatusAndPhotosEntryWithoutClaimingLegacyItemsWereSaved() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["ARKCAM_TEST_LANGUAGE"] = "zh-Hans"
        app.launchArguments = ["--ui-fixtures", "--album-status-fixture"]
        app.launch()
        XCTAssertTrue(app.buttons["openLibrary"].waitForExistence(timeout: 10))
        app.buttons["openLibrary"].tap()
        XCTAssertTrue(app.buttons["openSystemPhotos"].waitForExistence(timeout: 5))
        let badge = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'albumStatus-'")).firstMatch
        XCTAssertTrue(badge.waitForExistence(timeout: 5))
        XCTAssertTrue(badge.label.contains("待确认"))
        badge.tap()
        XCTAssertTrue(app.navigationBars["相册保存状态"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["没有可靠的保存记录，请在系统相册核对。"].exists)
        attach(app, name: "相册保存状态_历史待确认")
        app.buttons["完成"].tap()
        app.buttons["memory-photo"].firstMatch.tap()
        XCTAssertTrue(app.buttons["detailAlbumStatus"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["openSystemPhotos"].exists)
        attach(app, name: "详情_保存状态及相册入口")
        #if targetEnvironment(simulator)
        app.buttons["openSystemPhotos"].tap()
        let photos = XCUIApplication(bundleIdentifier: "com.apple.mobileslideshow")
        XCTAssertTrue(photos.wait(for: .runningForeground, timeout: 8))
        app.activate()
        #endif
    }

    @MainActor
    func testAdaptiveCameraLayoutPortraitAndLandscape() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        app.launchEnvironment["ARKCAM_TEST_LANGUAGE"] = "zh-Hans"
        app.launchArguments = ["--ui-quicktake-fixture", "-cameraPhotoAspect", "4:3", "-cameraVideoAspect", "16:9"]
        app.launch()
        XCTAssertTrue(app.buttons["shutter"].waitForExistence(timeout: 10))
        func check(landscape: Bool) {
            let aperture = app.descendants(matching: .any)["captureAperture"].firstMatch.frame
            let shutter = app.buttons["shutter"].frame
            XCTAssertFalse(aperture.intersects(shutter))
            XCTAssertEqual(aperture.width / aperture.height, landscape ? 4.0 / 3 : 3.0 / 4, accuracy: 0.02)
            for id in ["openLibrary", "swapCameras", "shutter", "cameraControlsToggle"] {
                let frame = app.buttons[id].frame
                XCTAssertGreaterThanOrEqual(frame.minX, app.frame.minX - 1)
                XCTAssertLessThanOrEqual(frame.maxX, app.frame.maxX + 1)
                XCTAssertGreaterThanOrEqual(frame.minY, app.frame.minY - 1)
                XCTAssertLessThanOrEqual(frame.maxY, app.frame.maxY + 1)
                XCTAssertGreaterThanOrEqual(frame.height, 43.5)
                XCTAssertTrue(app.buttons[id].isHittable)
            }
        }
        check(landscape: false)
        attach(app, name: "适配_竖屏")
        if app.frame.width > 600 {
            XCUIDevice.shared.orientation = .landscapeLeft
            let horizontal = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in app.frame.width > app.frame.height }, object: app)
            XCTAssertEqual(XCTWaiter.wait(for: [horizontal], timeout: 5), .completed)
            sleep(1)
            check(landscape: true)
            let fullScreen = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            fullScreen.name = "适配_iPad横屏_完整屏幕"; fullScreen.lifetime = .keepAlways; add(fullScreen)
            let bounds = XCTAttachment(string: app.debugDescription)
            bounds.name = "横屏控件坐标"; bounds.lifetime = .keepAlways; add(bounds)
        }
        app.buttons["cameraControlsToggle"].tap()
        XCTAssertTrue(app.buttons["optionSettings"].waitForExistence(timeout: 3))
        app.buttons["optionSettings"].tap()
        XCTAssertTrue(app.buttons["settingsMainCamera"].waitForExistence(timeout: 3))
        app.buttons["settingsMainCamera"].tap()
        XCTAssertTrue(app.buttons["defaultMainLens-native"].waitForExistence(timeout: 3))
        attach(app, name: "适配_主相机设置")
    }

    @MainActor
    func testSingleOnlyDeviceHasUsablePhotoAndVideoModes() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["ARKCAM_TEST_LANGUAGE"] = "zh-Hans"
        app.launchArguments = ["--ui-quicktake-fixture", "--single-camera-only", "-cameraExplainedSingleOnly", "YES"]
        app.launch()
        let photo = app.buttons["singlePhotoMode"]
        XCTAssertTrue(photo.waitForExistence(timeout: 10))
        XCTAssertEqual(photo.value as? String, "已选择")
        XCTAssertFalse(app.buttons["photoMode"].exists)
        XCTAssertFalse(app.buttons["videoMode"].exists)
        app.buttons["singleVideoMode"].tap()
        XCTAssertEqual(app.buttons["singleVideoMode"].value as? String, "已选择")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: app.buttons["shutter"])], timeout: 5), .completed)
        app.buttons["shutter"].tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == '停止录像'"), object: app.buttons["shutter"])], timeout: 5), .completed)
        app.buttons["shutter"].tap()
        attach(app, name: "仅单摄能力_可录像")
    }
}
