import XCTest
import SwiftUI
@testable import Cam

final class CameraCompatibilityTests: XCTestCase {
    @MainActor
    func testMemoryZoomSurvivesContentRefreshAndWindowResize() {
        let controller = MemoryZoomController()
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 820, height: 966)
        controller.configure(content: AnyView(Color.red), aspectRatio: 0.75, editing: false, liveEnabled: true,
                             onTap: {}, onStep: { _ in }, onLivePress: { _ in })
        controller.view.layoutIfNeeded()
        controller.scroll.setZoomScale(2, animated: false)
        XCTAssertEqual(controller.scroll.zoomScale, 2, accuracy: 0.01)
        controller.configure(content: AnyView(Color.blue), aspectRatio: 0.75, editing: false, liveEnabled: true,
                             onTap: {}, onStep: { _ in }, onLivePress: { _ in })
        controller.view.layoutIfNeeded()
        XCTAssertEqual(controller.scroll.zoomScale, 2, accuracy: 0.01)
        controller.view.frame = CGRect(x: 0, y: 0, width: 400, height: 660)
        controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
        XCTAssertEqual(controller.scroll.zoomScale, 2, accuracy: 0.01)
    }
    func testUnavailableDualFallsBackWithoutOfferingDeadModes() {
        let modes = CameraDeviceCapabilities.modes(dual: false)
        XCTAssertEqual(modes, [.singleVideo, .singlePhoto])
        XCTAssertEqual(CameraDeviceCapabilities.resolved(.dualPhoto, dual: false), .singlePhoto)
        XCTAssertEqual(CameraDeviceCapabilities.resolved(.dualVideo, dual: false), .singleVideo)
        XCTAssertEqual(CameraModeDragPolicy.destination(from: .singlePhoto, translation: 64, predicted: 64, modes: modes), .singleVideo)
        XCTAssertEqual(CameraModeDragPolicy.destination(from: .singleVideo, translation: -64, predicted: -64, modes: modes), .singlePhoto)
        XCTAssertEqual(CameraModeDragPolicy.tapped(at: 165.5, from: .singlePhoto, modes: modes), .singlePhoto)
        XCTAssertEqual(CameraDeviceCapabilities.resolved(.dualPhoto, dual: true), .dualPhoto)
    }
    func testCompactAndTabletAperturesKeepAspectAndControlsSeparate() {
        for size in [CGSize(width: 320, height: 568), CGSize(width: 375, height: 667),
                     CGSize(width: 744, height: 1133), CGSize(width: 820, height: 1180), CGSize(width: 1024, height: 1366),
                     CGSize(width: 1133, height: 744), CGSize(width: 1366, height: 1024), CGSize(width: 400, height: 744), CGSize(width: 466, height: 678),
                     CGSize(width: 890, height: 626), CGSize(width: 626, height: 890), CGSize(width: 445, height: 626)] {
            for landscape in [false, true] { for aspect in CaptureAspect.allCases {
                let g = CameraChromeGeometry(size: size, kind: .photo, aspect: aspect, landscapeCapture: landscape)
                XCTAssertEqual(g.preview.width / g.preview.height, landscape ? 1 / aspect.ratio : aspect.ratio, accuracy: 0.001)
                XCTAssertTrue(CGRect(origin: .zero, size: size).contains(g.preview))
                let shutter = CGRect(x: g.centerX - g.shutterDiameter / 2, y: g.shutterY - g.shutterDiameter / 2,
                                     width: g.shutterDiameter, height: g.shutterDiameter)
                XCTAssertFalse(g.preview.intersects(shutter), "\(size), \(aspect), \(landscape)")
                XCTAssertGreaterThanOrEqual(g.bottomDiameter, 44)
                XCTAssertGreaterThan(g.zoomY, g.preview.minY)
            } }
        }
    }
    func testKnownCeilingsRespectActualRouteEvenOnNewModels() {
        for (model, photo, video) in [("iPhone13,4",12.0,7.0),("iPhone14,2",15,9),("iPhone16,2",25,15),("iPhone18,1",40,15),("iPhone18,4",10,6)] {
            XCTAssertEqual(CameraZoomPolicy.maximum(hardware: model, video: false, available: 100, hasTelephoto: true, sensorCrop: true), photo)
            XCTAssertEqual(CameraZoomPolicy.maximum(hardware: model, video: true, available: 100, hasTelephoto: true, sensorCrop: true), video)
            XCTAssertEqual(CameraZoomPolicy.maximum(hardware: model, video: false, available: 4, hasTelephoto: true, sensorCrop: true), 4)
        }
        for tele in [2.0, 2.5, 3, 4, 5] {
            let stops = CameraZoomScale.stops(minimum: 1, telephoto: tele, sensorCrop: false, calibration: nil)
            XCTAssertEqual(stops.map(\.factor), [1, tele])
        }
        XCTAssertNil(CameraFocalCalibration.known("unreleased-device"))
        XCTAssertEqual(CameraZoomScale.stops(minimum: 1, telephoto: nil, sensorCrop: false, calibration: nil).map(\.factor), [1])
        XCTAssertEqual(CameraFocalCalibration.known("iPhone17,1")?.telephoto, 120)
    }
    func testUnknownHardwareUsesDetectedOpticsAndNativeFrontCrop() {
        XCTAssertEqual(CameraZoomPolicy.maximum(hardware: "unknown", video: false, available: 30, hasTelephoto: true, sensorCrop: true, telephotoFactor: 5), 25)
        XCTAssertEqual(CameraZoomPolicy.maximum(hardware: "unknown", video: true, available: 30, hasTelephoto: true, sensorCrop: true, telephotoFactor: 3), 9)
        XCTAssertEqual(CameraZoomPolicy.maximum(hardware: "unknown", video: false, available: 50, hasTelephoto: true, sensorCrop: true, telephotoFactor: 4, nativeTelephotoCrop: 8), 40)
        XCTAssertEqual(CameraZoomPolicy.maximum(hardware: "unknown", video: false, available: 8, hasTelephoto: false, sensorCrop: true), 8)
        XCTAssertEqual(CameraZoomPolicy.frontRange(minimum: 1, maximum: 2, nativeCrop: 1.5), 1...1.5)
        XCTAssertEqual(CameraZoomPolicy.frontRange(minimum: 1, maximum: 1), 1...1)
        XCTAssertEqual(CameraZoomPolicy.frontRange(minimum: 1, maximum: 1.2, nativeCrop: 1.5), 1...1.2)
    }
    func testMainFramingPersistsIndependentlyAndClampsToCapability() throws {
        let name = "CamMainLensTests-" + UUID().uuidString
        let prefs = try XCTUnwrap(UserDefaults(suiteName: name)); defer { prefs.removePersistentDomain(forName: name) }
        XCTAssertEqual(MainCameraPreference.factors(main: nil, maximum: 25, defaults: prefs), [1])
        XCTAssertEqual(MainCameraPreference.initial(main: 24, maximum: 25, defaults: prefs), 1)
        prefs.set("35", forKey: "cameraDefaultMainLens")
        XCTAssertEqual(MainCameraPreference.initial(main: 24, maximum: 25, defaults: prefs), 35.0 / 24)
        prefs.set(false, forKey: "cameraMainLens35")
        XCTAssertEqual(MainCameraPreference.initial(main: 24, maximum: 25, defaults: prefs), 1)
        XCTAssertEqual(MainCameraPreference.initial(main: 24, maximum: 1.1, defaults: prefs), 1)
        XCTAssertEqual(MainCameraPreference.next(after: 1, main: 26, maximum: 10, defaults: prefs), 28.0 / 26)
        XCTAssertEqual(MainCameraPreference.next(after: 28.0 / 26, main: 26, maximum: 10, defaults: prefs), 1)
    }
    func testLandscapeMemoriesAndExportsKeepFullShortEdgeResolution() throws {
        let layout = CameraLayout(aspect: .wide, orientation: .landscapeLeft)
        XCTAssertEqual(layout.aspectRatio(for: .video), 16.0 / 9)
        let decoded = try JSONDecoder().decode(CameraLayout.self, from: JSONEncoder().encode(layout))
        XCTAssertEqual(decoded, layout)
        for resolution in VideoResolution.allCases {
            let profile = VideoRecordingProfile(resolution: resolution)
            let size = profile.exportSize(aspect: layout.aspectRatio(for: .video))
            XCTAssertEqual(size.width, CGFloat(resolution.longEdge))
            XCTAssertEqual(size.height, CGFloat(resolution.shortEdge))
        }
        let old = try JSONDecoder().decode(CameraLayout.self, from: Data(#"{"frontIsPrimary":false,"x":1,"y":1}"#.utf8))
        XCTAssertEqual(old.aspectRatio(for: .photo), 0.75)
        XCTAssertNil(old.orientation)
    }
}
