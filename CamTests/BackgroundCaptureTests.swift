import XCTest
import AVFoundation
import UIKit
@testable import Cam

final class BackgroundCaptureTests: XCTestCase {
    func testAcquisitionReleasesBeforeBlockedDiskAndPairsRemainIndependent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = LibraryDisk(root: root)
        let drafts = try (0..<2).map { _ in try disk.createDraft(kind: .photo, layout: CameraLayout()) }
        let captureQueue = DispatchQueue(label: "test.capture")
        let ioQueue = DispatchQueue(label: "test.blocked-io")
        ioQueue.suspend()
        let acquired = expectation(description: "both photos released without disk writes")
        acquired.expectedFulfillmentCount = 2
        let finished = expectation(description: "both independent pairs persisted")
        finished.expectedFulfillmentCount = 2
        for (index, draft) in drafts.enumerated() {
            let capture = PhotoPairCapture(draft: draft, queue: captureQueue, saveQueue: ioQueue, live: false,
                onAcquired: { acquired.fulfill() }) { rear, front, _, _, _, _, error in
                    XCTAssertTrue(rear); XCTAssertTrue(front); XCTAssertNil(error); finished.fulfill()
                }
            func result(_ front: Bool) -> PhotoCaptureResult {
                PhotoCaptureResult(photo: .success(Data("\(index)-\(front)".utf8)), captureTime: .zero,
                    liveMovieSucceeded: false, liveDuration: nil, displayTime: nil, liveError: nil)
            }
            // Deliberately reverse callbacks on one job; there is no shared result slot.
            if index == 0 { capture.front.completion(result(true)); capture.rear.completion(result(false)) }
            else { capture.rear.completion(result(false)); capture.front.completion(result(true)) }
        }
        await fulfillment(of: [acquired], timeout: 3)
        XCTAssertTrue(drafts.allSatisfy { !FileManager.default.fileExists(atPath: $0.rearURL.path) })
        ioQueue.resume()
        await fulfillment(of: [finished], timeout: 3)
        for (index, draft) in drafts.enumerated() {
            XCTAssertEqual(try Data(contentsOf: draft.rearURL), Data("\(index)-false".utf8))
            XCTAssertEqual(try Data(contentsOf: draft.frontURL), Data("\(index)-true".utf8))
        }
    }

    func testRapidCaptureOrderSurvivesOutOfOrderCompletionAndActiveRecovery() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = LibraryDisk(root: root)
        let first = try disk.createDraft(kind: .photo, layout: CameraLayout(), inFlight: true)
        let second = try disk.createDraft(kind: .photo, layout: CameraLayout(), inFlight: true)
        defer { CaptureDraftActivity.end(first.item.id); CaptureDraftActivity.end(second.item.id) }
        XCTAssertTrue(disk.unfinishedDrafts().isEmpty)
        for draft in [second, first] {
            try Data([1]).write(to: draft.rearURL)
            _ = try disk.finish(draft, rear: true, front: false)
        }
        XCTAssertEqual(try disk.load().map(\.id), [second.item.id, first.item.id])
        XCTAssertEqual(try disk.load().first?.captureDate, second.item.captureDate)
    }

    func testSavingDoesNotLockShutterButKeepsBackgroundTimeAlive() {
        let saving = CaptureActivity(recording: false, savingVideo: true, takingPhoto: false, pendingPhotos: 3)
        XCTAssertTrue(saving.canUseShutter); XCTAssertFalse(saving.isBusy)
        XCTAssertFalse(saving.canEndBackgroundSave)
        let full = CaptureActivity(recording: false, savingVideo: false, takingPhoto: false, pendingPhotos: 6, capacityReached: true)
        XCTAssertFalse(full.canUseShutter)
        let recording = CaptureActivity(recording: true, savingVideo: true, takingPhoto: false, pendingPhotos: 6, capacityReached: true)
        XCTAssertTrue(recording.canUseShutter, "Stop is always available")
    }

    func testOverlappingLiveWindowsAlignTheirOwnShutters() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = LibraryDisk(root: root)
        let source = root.appendingPathComponent("source.mov")
        try await DebugFixtures.writeMovie(to: source, front: false, seconds: 5)
        let asset = AVURLAsset(url: source)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: try XCTUnwrap(tracks.first), outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange])
        reader.add(output); XCTAssertTrue(reader.startReading())
        var samples: [CMSampleBuffer] = []
        while let sample = output.copyNextSampleBuffer() { samples.append(sample) }
        let drafts = try (0..<2).map { _ in try disk.createDraft(kind: .photo, layout: CameraLayout()) }
        let queue = DispatchQueue(label: "test.overlapping-live")
        let done = expectation(description: "both Live windows")
        done.expectedFulfillmentCount = 2
        queue.async {
            let buffer = LivePhotoBuffer(callbackQueue: queue)
            buffer.configure(maxFramesPerSecond: 10, maxLongEdge: 320); buffer.setEnabled(true)
            for (index, sample) in samples.enumerated() {
                buffer.consumeVideo(sample, isFront: false); buffer.consumeVideo(sample, isFront: true)
                if index == 60 || index == 72 {
                    let draft = drafts[index == 60 ? 0 : 1]
                    XCTAssertTrue(buffer.beginCapture(draft: draft, audioSettings: nil) { rear, front, duration, display, error in
                        XCTAssertTrue(rear); XCTAssertTrue(front); XCTAssertNil(error)
                        XCTAssertEqual(duration ?? 0, 3, accuracy: 0.13)
                        XCTAssertEqual(display ?? 0, 1.5, accuracy: 0.13)
                        done.fulfill()
                    })
                    buffer.alignShutter(id: draft.item.id, to: CMSampleBufferGetPresentationTimeStamp(sample))
                }
            }
        }
        await fulfillment(of: [done], timeout: 15)
        for draft in drafts {
            for url in [draft.rearLiveURL, draft.frontLiveURL] {
                let duration = try await AVURLAsset(url: url).load(.duration).seconds
                XCTAssertEqual(duration, 3, accuracy: 0.2)
            }
        }
    }
}
