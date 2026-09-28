import XCTest
@testable import Cam

final class CameraLevelTests: XCTestCase {
    private func gravity(roll: Double = 0, flatTilt: Double = 90, faceUp: Bool = true) -> CameraGravity {
        let r = roll * .pi / 180, p = flatTilt * .pi / 180
        return CameraGravity(x: sin(r) * sin(p), y: -cos(r) * sin(p), z: cos(p) * (faceUp ? -1 : 1))
    }

    private func settle(_ estimator: inout CameraLevelEstimator, _ gravity: CameraGravity,
                        at time: inout Double) -> CameraLevelReading {
        for _ in 0..<40 { time += 1.0 / 30; _ = estimator.update(gravity, timestamp: time) }
        return estimator.reading
    }

    func testHorizonOpposesDeviceRollAndSupportsFourHoldingOrientations() {
        for roll in [0.0, 90, -90, 180, -180] {
            var estimator = CameraLevelEstimator()
            let reading = estimator.update(gravity(roll: roll), timestamp: 1)
            XCTAssertEqual(reading.mode, .horizon)
            XCTAssertTrue(reading.aligned)
            XCTAssertEqual(reading.referenceDegrees, abs(roll) == 90 ? 90 : 0, accuracy: 0.001)
        }
        var estimator = CameraLevelEstimator()
        let tilted = estimator.update(gravity(roll: 6), timestamp: 1)
        XCTAssertEqual(tilted.tiltDegrees, -6, accuracy: 0.001)
        XCTAssertFalse(tilted.aligned)
    }

    func testLookingDownAndUpUsesSameDevicePlaneCrosshair() {
        for faceUp in [true, false] {
            var estimator = CameraLevelEstimator()
            let level = estimator.update(gravity(flatTilt: 0, faceUp: faceUp), timestamp: 1)
            XCTAssertEqual(level.mode, .flat)
            XCTAssertTrue(level.aligned)
            XCTAssertEqual(level.offset, .zero)
            estimator.reset()
            let tilted = estimator.update(CameraGravity(x: 0.1, y: -0.1, z: sqrt(0.98) * (faceUp ? -1 : 1)), timestamp: 2)
            XCTAssertEqual(tilted.mode, .flat)
            XCTAssertFalse(tilted.aligned)
            XCTAssertEqual(tilted.offset.x, 9.6, accuracy: 0.001)
            XCTAssertEqual(tilted.offset.y, 9.6, accuracy: 0.001)
        }
    }

    func testAlignmentHysteresisAvoidsYellowWhiteFlicker() {
        var estimator = CameraLevelEstimator(), time = 0.0
        XCTAssertTrue(settle(&estimator, gravity(roll: 0.5), at: &time).aligned)
        XCTAssertTrue(settle(&estimator, gravity(roll: 1.2), at: &time).aligned)
        XCTAssertFalse(settle(&estimator, gravity(roll: 2), at: &time).aligned)
        XCTAssertFalse(settle(&estimator, gravity(roll: 1.2), at: &time).aligned)
        XCTAssertTrue(settle(&estimator, gravity(roll: 0.5), at: &time).aligned)
        estimator.reset(); time = 0
        XCTAssertTrue(settle(&estimator, gravity(flatTilt: 0.5), at: &time).aligned)
        XCTAssertTrue(settle(&estimator, gravity(flatTilt: 1.2), at: &time).aligned)
        XCTAssertFalse(settle(&estimator, gravity(flatTilt: 2), at: &time).aligned)
    }

    func testModeAndVisibilityBoundariesDoNotFlicker() {
        var estimator = CameraLevelEstimator(), time = 0.0
        XCTAssertEqual(settle(&estimator, gravity(flatTilt: 18), at: &time).mode, .flat)
        XCTAssertEqual(settle(&estimator, gravity(flatTilt: 25), at: &time).mode, .flat)
        XCTAssertEqual(settle(&estimator, gravity(flatTilt: 30), at: &time).mode, .horizon)
        XCTAssertEqual(settle(&estimator, gravity(flatTilt: 25), at: &time).mode, .horizon)
        XCTAssertEqual(settle(&estimator, gravity(flatTilt: 18), at: &time).mode, .flat)
        XCTAssertEqual(settle(&estimator, gravity(roll: 10), at: &time).mode, .horizon)
        XCTAssertEqual(settle(&estimator, gravity(roll: 15), at: &time).mode, .horizon)
        XCTAssertEqual(settle(&estimator, gravity(roll: 20), at: &time).mode, .hidden)
        XCTAssertEqual(settle(&estimator, gravity(roll: 15), at: &time).mode, .hidden)
        XCTAssertEqual(settle(&estimator, gravity(roll: 10), at: &time).mode, .horizon)
    }

    func testFilterRespondsQuicklyAndIgnoresOutOfOrderSamples() {
        var estimator = CameraLevelEstimator()
        _ = estimator.update(gravity(roll: 6), timestamp: 1)
        let intermediate = estimator.update(gravity(roll: 10), timestamp: 1 + 1.0 / 30)
        XCTAssertLessThan(intermediate.tiltDegrees, -6)
        XCTAssertGreaterThan(intermediate.tiltDegrees, -10)
        XCTAssertEqual(estimator.update(gravity(roll: 0), timestamp: 1), intermediate)
        var last = intermediate
        for frame in 2...7 { last = estimator.update(gravity(roll: 10), timestamp: 1 + Double(frame) / 30) }
        XCTAssertEqual(last.tiltDegrees, -10, accuracy: 0.05)
        let fresh = estimator.update(gravity(flatTilt: 0), timestamp: 4)
        XCTAssertEqual(fresh.mode, .flat)
        XCTAssertTrue(fresh.aligned)
    }

    func testInvalidGravityHidesIndicatorInsteadOfShowingFalseLevel() {
        var estimator = CameraLevelEstimator()
        _ = estimator.update(gravity(), timestamp: 1)
        XCTAssertEqual(estimator.update(CameraGravity(x: .nan, y: 0, z: 0), timestamp: 2), .hidden)
        XCTAssertEqual(estimator.update(CameraGravity(x: 0, y: 0, z: 0), timestamp: 3), .hidden)
        XCTAssertEqual(estimator.update(CameraGravity(x: 5, y: 0, z: 0), timestamp: 4), .hidden)
        XCTAssertTrue(estimator.update(gravity(), timestamp: 5).aligned)
        estimator.reset()
        XCTAssertEqual(estimator.reading, .hidden)
    }

    func testUpsideDownBoundaryDoesNotRotateReferenceByFullTurn() {
        var estimator = CameraLevelEstimator(), time = 0.0
        let first = settle(&estimator, gravity(roll: 178), at: &time)
        let second = settle(&estimator, gravity(roll: -178), at: &time)
        XCTAssertEqual(first.referenceDegrees, second.referenceDegrees)
        XCTAssertEqual(first.tiltDegrees, 2, accuracy: 0.001)
        XCTAssertEqual(second.tiltDegrees, -2, accuracy: 0.001)
    }

    func testLevelSettingDefaultsOnAndTransfersIndependentlyOfGrid() {
        let name = "LevelSettings-\(UUID().uuidString)", other = "LevelLockedSettings-\(UUID().uuidString)"
        let source = UserDefaults(suiteName: name)!, target = UserDefaults(suiteName: other)!
        defer { source.removePersistentDomain(forName: name); target.removePersistentDomain(forName: other) }
        XCTAssertEqual(CameraPreferenceStore.snapshot(source)["cameraLevel"], "true")
        source.set(false, forKey: "cameraGrid")
        source.set(true, forKey: "cameraLevel")
        CameraPreferenceStore.apply(CameraPreferenceStore.snapshot(source), to: target)
        XCTAssertFalse(target.bool(forKey: "cameraGrid"))
        XCTAssertTrue(target.bool(forKey: "cameraLevel"))
        source.set(false, forKey: "cameraLevel")
        CameraPreferenceStore.apply(CameraPreferenceStore.snapshot(source), to: target)
        XCTAssertFalse(target.bool(forKey: "cameraLevel"))
    }
}
