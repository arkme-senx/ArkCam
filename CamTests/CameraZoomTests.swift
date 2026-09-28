import XCTest
@testable import Cam

final class CameraZoomTests: XCTestCase {
    func testProductCapsDifferByCaptureModeAndRespectHardware() {
        for (model, photo, video) in [("iPhone15,2", 15.0, 9.0), ("iPhone15,3", 15, 9), ("iPhone16,2", 25, 15)] {
            XCTAssertEqual(CameraZoomPolicy.maximum(hardware: model, video: false, available: 100, hasTelephoto: true, sensorCrop: true), photo)
            XCTAssertEqual(CameraZoomPolicy.maximum(hardware: model, video: true, available: 100, hasTelephoto: true, sensorCrop: true), video)
            XCTAssertEqual(CameraZoomPolicy.maximum(hardware: model, video: false, available: 7, hasTelephoto: true, sensorCrop: true), 7)
        }
        XCTAssertEqual(CameraZoomPolicy.maximum(hardware: "unknown", video: false, available: 2, hasTelephoto: false, sensorCrop: false), 2)
    }

    func testFractionStaysWithLowerAnchorUntilBoundaryIsCrossed() {
        let stops = CameraZoomScale.stops(minimum: 0.5, telephoto: 5, sensorCrop: true, calibration: nil)
        for (value, anchor) in [(0.7, 0.5), (1.7, 1.0), (1.999, 1), (2.0, 2), (3.3, 2), (4.99, 2), (5.0, 5), (25.0, 5)] {
            XCTAssertEqual(CameraZoomScale.selectedStop(for: value, stops: stops), anchor)
        }
    }

    func testDialRotatesBothEndpointsWithoutStretchingItsScale() {
        for maximum in [15.0, 25.0] {
            let range = 0.5...maximum
            let startLeft = CameraZoomDialGeometry.angle(0.5, value: 1, range: range)
            let startRight = CameraZoomDialGeometry.angle(maximum, value: 1, range: range)
            let endLeft = CameraZoomDialGeometry.angle(0.5, value: 5, range: range)
            let endRight = CameraZoomDialGeometry.angle(maximum, value: 5, range: range)
            XCTAssertLessThan(endLeft, startLeft)
            XCTAssertLessThan(endRight, startRight)
            XCTAssertEqual(endLeft - startLeft, endRight - startRight, accuracy: 0.000001)
            XCTAssertEqual(startRight - startLeft, endRight - endLeft, accuracy: 0.000001)
            XCTAssertEqual(CameraZoomDialGeometry.angle(maximum, value: maximum, range: range), 0)
        }
    }

    func testMaximumCanBeReachedFromCenterInOneComfortableSweep() {
        for maximum in [9.0, 15.0, 25.0] {
            let range = 0.5...maximum
            XCTAssertEqual(CameraZoomScale.dragged(from: 1, points: 170, range: range), maximum)
            XCTAssertEqual(CameraZoomScale.dragged(from: maximum, points: -200, range: range), 0.5, accuracy: 0.00001)
            let fine = CameraZoomScale.dragged(from: 1, points: 1, range: range)
            XCTAssertGreaterThan(fine, 1)
            XCTAssertLessThan(fine, 1.025)
        }
    }

    func testVisibleLabelsFollowTheirOwnTickInsteadOfBeingRepositioned() {
        let stops = CameraZoomScale.stops(minimum: 0.5, telephoto: 5, sensorCrop: true, calibration: nil)
        for value in [0.5, 1, 2, 3.3, 5, 15, 25] {
            let labels = CameraZoomDialGeometry.labels(value: value, stops: stops, range: 0.5...25)
            for (stop, angle) in labels {
                XCTAssertEqual(angle, CameraZoomDialGeometry.angle(stop.factor, value: value, range: 0.5...25), accuracy: 0.000001)
                XCTAssertLessThan(abs(angle), CameraZoomDialGeometry.visibleAngle)
            }
        }
    }

    func testFrontFramingNeverExceedsActualSensorOrHardwareRange() {
        XCTAssertEqual(CameraZoomPolicy.frontRange(minimum: 1, maximum: 8), 1...1.3)
        XCTAssertEqual(CameraZoomPolicy.frontRange(minimum: 1, maximum: 1.1), 1...1.1)
        XCTAssertEqual(CameraZoomPolicy.frontRange(minimum: 1, maximum: 1), 1...1)
        XCTAssertEqual(CameraZoomPolicy.frontRange(minimum: 1.2, maximum: 2), 1.2...1.56)
    }
}
