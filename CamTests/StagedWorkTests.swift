import XCTest
@testable import Cam

final class StagedWorkTests: XCTestCase {
    private func item(_ seconds: TimeInterval = 0) -> MemoryItem {
        MemoryItem(id: UUID(), createdAt: Date(timeIntervalSince1970: seconds), kind: .photo, capturedLayout: CameraLayout())
    }

    @MainActor
    func testStartupCaptureAndBackgroundBlockOptionalWork() async throws {
        let work = CaptureWorkScheduler(quietInterval: 0.03)
        XCTAssertFalse(work.allowsBackgroundWork)
        work.setPhase(.preview)
        XCTAssertFalse(work.allowsBackgroundWork)
        let allowed = await work.waitUntilAvailable()
        XCTAssertTrue(allowed)
        work.setPhase(.capturing)
        XCTAssertFalse(work.allowsBackgroundWork)
        work.setPhase(.suspended)
        let waiter = Task { await work.waitUntilAvailable() }
        waiter.cancel()
        let cancelled = await waiter.value
        XCTAssertFalse(cancelled)
        work.setPhase(.browsing)
        XCTAssertTrue(work.allowsBackgroundWork)
    }

    @MainActor
    func testContinuedInteractionExtendsQuietPeriodAndCaptureCancelsIt() async throws {
        let work = CaptureWorkScheduler(quietInterval: 0.07)
        work.setPhase(.preview)
        try await Task.sleep(for: .milliseconds(45))
        work.userInteracted()
        try await Task.sleep(for: .milliseconds(45))
        XCTAssertFalse(work.allowsBackgroundWork)
        work.setPhase(.capturing)
        try await Task.sleep(for: .milliseconds(90))
        XCTAssertFalse(work.allowsBackgroundWork)
        work.setPhase(.preview)
        let allowed = await work.waitUntilAvailable()
        XCTAssertTrue(allowed)
    }

    @MainActor
    func testReloadRunsOffMainAndPreservesCaptureAndEditDuringScan() async {
        let original = item(1), newer = item(2)
        var edited = original; edited.captureNote = "edit while scanning"
        let started = expectation(description: "background reader started")
        let release = DispatchSemaphore(value: 0)
        let library = MediaLibrary(readItems: { _ in
            XCTAssertFalse(Thread.isMainThread)
            started.fulfill()
            _ = release.wait(timeout: .now() + 3)
            return [original]
        })
        library.work.setPhase(.browsing)
        library.reload()
        await fulfillment(of: [started], timeout: 2)
        library.insert(newer); library.insert(edited)
        release.signal()
        await library.reloadAndWait()
        XCTAssertEqual(library.items.map(\.id), [newer.id, original.id])
        XCTAssertEqual(library.items.last?.captureNote, edited.captureNote)
        XCTAssertFalse(library.isLoading)
    }

    @MainActor
    func testReloadRequestsDuringStartupAreCoalesced() async {
        let read = expectation(description: "one scan")
        read.assertForOverFulfill = true
        let library = MediaLibrary(readItems: { _ in read.fulfill(); return [] })
        for _ in 0..<100 { library.reload() }
        XCTAssertTrue(library.isLoading)
        library.work.setPhase(.browsing)
        await library.reloadAndWait()
        await fulfillment(of: [read], timeout: 2)
    }

    func testLevelWaitsForValidSamplesAndCoalescesBacklog() {
        let processor = CameraLevelSampleProcessor()
        let gravity = CameraGravity(x: 0, y: -1, z: 0)
        XCTAssertTrue(processor.consume(gravity, timestamp: 1, uptime: 1))
        XCTAssertEqual(processor.takeLatest()?.reading.mode, .hidden)
        _ = processor.consume(gravity, timestamp: 1.04, uptime: 1.04)
        _ = processor.consume(gravity, timestamp: 1.12, uptime: 1.12)
        // Pending UI update is replaced with the newest reading, not queued 30 times.
        for i in 1...30 {
            XCTAssertFalse(processor.consume(CameraGravity(x: 0.02 * Double(i) / 30, y: -1, z: 0),
                timestamp: 1.12 + Double(i) / 30, uptime: 1.12 + Double(i) / 30))
        }
        XCTAssertEqual(processor.takeLatest()?.reading.mode, .horizon)
        XCTAssertNil(processor.takeLatest())
        XCTAssertTrue(processor.consume(gravity, timestamp: 4, uptime: 4))
        XCTAssertEqual(processor.takeLatest()?.reading.mode, .hidden)
    }

    @MainActor
    func testSavedReceiptsReadAsynchronouslyWithoutDuplicateExport() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = LibraryDisk(root: root)
        let draft = try disk.createDraft(kind: .photo, layout: CameraLayout(), albumSaveMode: .dual)
        try AlbumSaveStore(disk: disk).write(.init(phase: .saved, assetIdentifier: "existing"), for: draft.item.id)
        let saver = AutoAlbumSaver()
        saver.update(items: [draft.item], disk: disk, canWork: true, locked: true, backgroundWorkAllowed: false)
        XCTAssertEqual(saver.state(for: draft.item), .unknown)
        XCTAssertFalse(saver.isActive(draft.item.id))
        saver.update(items: [draft.item], disk: disk, canWork: true, locked: true, backgroundWorkAllowed: true)
        for _ in 0..<100 where saver.state(for: draft.item) == .unknown { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(saver.state(for: draft.item), .saved)
        XCTAssertEqual(saver.pendingCount, 0)
        XCTAssertFalse(saver.isActive(draft.item.id))
        saver.retry()
        XCTAssertEqual(saver.state(for: draft.item), .saved)
        XCTAssertEqual(saver.savedReceipt(for: draft.item.id)?.assetIdentifier, "existing")
    }
}
