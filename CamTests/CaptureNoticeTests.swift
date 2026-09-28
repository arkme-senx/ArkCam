import XCTest
@testable import Cam

@MainActor
final class CaptureNoticeTests: XCTestCase {
    private let notice = "相机温度较高，已自动降低拍摄负载"

    func testSameConditionAndFPSChangesDoNotRepeatButEscalationDoes() async throws {
        let state = CaptureNoticePresentation(duration: .milliseconds(80))
        state.update(message: notice + "（当前 24 fps）", level: .serious, active: true)
        XCTAssertTrue(state.expanded)
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertFalse(state.expanded)
        state.update(message: notice + "（当前 15 fps）", level: .serious, active: true)
        XCTAssertFalse(state.expanded)
        state.update(message: nil, level: .normal, active: true)
        state.update(message: notice, level: .serious, active: true)
        XCTAssertFalse(state.expanded, "A brief recovery must not replay the same message")
        state.update(message: notice, level: .critical, active: true)
        XCTAssertTrue(state.expanded, "A more severe condition must still be communicated")
    }

    func testLeavingCaptureDismissesAndCancelsOldTimer() async throws {
        let state = CaptureNoticePresentation(duration: .milliseconds(180))
        state.update(message: notice, level: .serious, active: true)
        try await Task.sleep(for: .milliseconds(100))
        state.update(message: notice, level: .serious, active: false)
        XCTAssertFalse(state.expanded)
        state.update(message: notice, level: .serious, active: true)
        XCTAssertFalse(state.expanded)
        state.toggle()
        try await Task.sleep(for: .milliseconds(110))
        XCTAssertTrue(state.expanded, "The previous timer must not dismiss a manually reopened notice")
        try await Task.sleep(for: .milliseconds(160))
        XCTAssertFalse(state.expanded)
        state.update(message: nil, level: .normal, active: true)
        state.toggle()
        XCTAssertFalse(state.expanded, "Resolved conditions cannot be reopened")
    }
}
