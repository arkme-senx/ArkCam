import XCTest
@testable import Cam

final class CameraDefaultsTests: XCTestCase {
    private func isolated(_ body: (UserDefaults, String) throws -> Void) rethrows {
        let name = "CameraDefaultsTests-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults, name)
    }

    func testFreshInstallUsesTheApprovedFactoryProfileWithoutPersistingChoices() {
        isolated { defaults, name in
            CameraDefaults.prepare(defaults, domainName: name)
            XCTAssertFalse(CameraDefaults.bool("livePhotoEnabled", in: defaults))
            XCTAssertFalse(CaptureWorkPolicy.liveBuffer(requested: defaults.bool(forKey: "livePhotoEnabled"),
                running: true, videoMode: false, hasVideoFormat: false, recording: false))
            XCTAssertEqual(defaults.string(forKey: "cameraMode"), CameraCaptureMode.dualPhoto.rawValue)
            XCTAssertEqual(VideoRecordingProfile.current(dual: true, defaults: defaults), .init(resolution: .fullHD, fps: 30))
            XCTAssertEqual(VideoRecordingProfile.current(dual: false, defaults: defaults), .standard)
            XCTAssertEqual(PhotoCaptureProfile.current(defaults), .init(format: .jpeg, megapixels: 12))
            XCTAssertEqual(AlbumSaveMode.current(defaults), .dual)
            for key in ["cameraStabilization", "cameraMirrorFront", "cameraGrid", "cameraLevel", "cameraLocation", "cameraShutterSound"] {
                XCTAssertTrue(defaults.bool(forKey: key), key)
            }
            XCTAssertFalse(defaults.bool(forKey: "cameraEnhancedStabilization"))
            XCTAssertEqual(defaults.string(forKey: "cameraFlash"), "off")
            XCTAssertEqual(defaults.string(forKey: "cameraPhotoTimer"), "0")
            XCTAssertEqual(defaults.string(forKey: "cameraPhotoAspect"), "4:3")
            XCTAssertEqual(defaults.string(forKey: "cameraVideoAspect"), "16:9")
            XCTAssertEqual(Set(defaults.persistentDomain(forName: name)!.keys), [CameraDefaults.versionKey])
        }
    }

    func testUpgradePreservesExplicitChoicesIncludingLiveOff() {
        for live in [false, true] {
            isolated { defaults, name in
                let choices: [String: Any] = ["livePhotoEnabled": live, "cameraSingleVideoProfile": "4K-60",
                    "cameraDualVideoProfile": "1080p-60", "cameraPhotoFormat": "heif", "cameraPhotoMP": "48",
                    "cameraAlbumSaveMode": "separate", "cameraMirrorFront": false, "cameraStabilization": false]
                choices.forEach { defaults.set($0.value, forKey: $0.key) }
                CameraDefaults.prepare(defaults, domainName: name, hasExistingMedia: true)
                CameraDefaults.prepare(defaults, domainName: name, hasExistingMedia: true)
                for (key, value) in choices {
                    XCTAssertEqual(defaults.object(forKey: key) as? NSObject, value as? NSObject, key)
                }
            }
        }
    }

    func testUpgradePreservesUnwrittenLegacyLiveDefault() {
        isolated { defaults, name in
            defaults.set("dualPhoto", forKey: "cameraMode")
            CameraDefaults.prepare(defaults, domainName: name)
            XCTAssertTrue(defaults.bool(forKey: "livePhotoEnabled"))
            defaults.set(false, forKey: "livePhotoEnabled")
            CameraDefaults.prepare(defaults, domainName: name)
            XCTAssertFalse(defaults.bool(forKey: "livePhotoEnabled"))
        }
        isolated { defaults, name in
            CameraDefaults.prepare(defaults, domainName: name, hasExistingMedia: true)
            XCTAssertTrue(defaults.bool(forKey: "livePhotoEnabled"))
        }
    }

    func testLaterLaunchDoesNotMistakeANewUserForALegacyUser() {
        isolated { defaults, name in
            // Other registered defaults are not evidence of an older install.
            defaults.register(defaults: ["cameraMode": "dualPhoto"])
            CameraDefaults.prepare(defaults, domainName: name)
            defaults.set("dualPhoto", forKey: "cameraMode")
            CameraDefaults.prepare(defaults, domainName: name, hasExistingMedia: true)
            XCTAssertFalse(defaults.bool(forKey: "livePhotoEnabled"))
            defaults.set(true, forKey: "livePhotoEnabled")
            CameraDefaults.prepare(defaults, domainName: name)
            XCTAssertTrue(defaults.bool(forKey: "livePhotoEnabled"))
        }
    }

    func testAllFactoryPreferencesTransferToLockedCapture() throws {
        try isolated { source, sourceName in
            CameraDefaults.prepare(source, domainName: sourceName)
            let context = CamCaptureContext(livePhotoEnabled: CameraDefaults.bool("livePhotoEnabled", in: source),
                options: CameraPreferenceStore.snapshot(source))
            let decoded = try JSONDecoder().decode(CamCaptureContext.self, from: JSONEncoder().encode(context))
            XCTAssertFalse(CamCaptureContext().livePhotoEnabled)
            XCTAssertFalse(decoded.livePhotoEnabled)
            isolated { target, targetName in
                // An extension with prior local selections receives the complete
                // app snapshot, including values the new user never touched.
                target.set("4K-60", forKey: "cameraDualVideoProfile")
                CameraDefaults.prepare(target, domainName: targetName)
                target.set(decoded.livePhotoEnabled, forKey: "livePhotoEnabled")
                CameraPreferenceStore.apply(decoded.options, to: target)
                XCTAssertFalse(target.bool(forKey: "livePhotoEnabled"))
                XCTAssertEqual(CameraPreferenceStore.snapshot(target), CameraPreferenceStore.snapshot(source))
            }
        }
        let legacy = try JSONDecoder().decode(CamCaptureContext.self, from: Data(#"{"livePhotoEnabled":true}"#.utf8))
        XCTAssertTrue(legacy.livePhotoEnabled)
        XCTAssertNil(legacy.options)
    }
}
