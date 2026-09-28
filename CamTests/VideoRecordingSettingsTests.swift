import XCTest
import AVFoundation
@testable import Cam

final class VideoRecordingSettingsTests: XCTestCase {
    func testMeasuredFrameRateTracksThrottleAndRecovery() {
        var meter = VideoFrameRateMeter(), time = 100.0
        var observations: [Int] = []
        for fps in [30, 24, 15, 30] {
            for _ in 0..<(fps * 4) {
                time += 1 / Double(fps)
                if let observation = meter.consume(time) { observations.append(observation.fps) }
            }
            XCTAssertEqual(observations.last, fps)
        }
        XCTAssertTrue(observations.contains(15))
        XCTAssertEqual(observations.last, 30)
    }

    func testFrameRateMeterRejectsInvalidDuplicateAndDiscontinuousTimes() {
        var meter = VideoFrameRateMeter()
        XCTAssertNil(meter.consume(.nan)); XCTAssertNil(meter.consume(.infinity))
        for i in 0...30 {
            let t = 100 + Double(i) / 30
            _ = meter.consume(t)
            XCTAssertNil(meter.consume(t), "Duplicate timestamps must not count twice")
        }
        XCTAssertNil(meter.consume(50), "A new timebase starts a new window")
        XCTAssertNil(meter.consume(1000), "Do not average across interruptions")
        var result: RecordedFrameRate?
        for i in 1...31 { if let sample = meter.consume(1000 + Double(i) / 30) { result = sample } }
        XCTAssertEqual(result?.fps, 30)
    }

    func testFrameRateReadoutSeparatesPreviewTargetAndActualRecording() {
        let requested = VideoRecordingProfile(resolution: .uhd, fps: 60)
        XCTAssertEqual(VideoFrameRateReadout.fps(requested: requested.fps, device: 30, measured: nil, recording: false, constrained: false), 60)
        XCTAssertEqual(VideoFrameRateReadout.fps(requested: 60, device: 24, measured: nil, recording: false, constrained: true), 24)
        XCTAssertEqual(VideoFrameRateReadout.fps(requested: 60, device: 24, measured: 60, recording: true, constrained: true), 24)
        XCTAssertEqual(VideoFrameRateReadout.fps(requested: 60, device: 24, measured: 21, recording: true, constrained: true), 21)
        XCTAssertEqual(VideoFrameRateReadout.fps(requested: 60, device: 60, measured: 60, recording: true, constrained: false), 60)
        XCTAssertEqual(requested.rawValue, "4K-60", "Throttling must not overwrite the user's saved setting")
    }

    func testPreferencesRoundTripIntoLockedCapture() {
        let a = UserDefaults(suiteName: "video-settings-source-\(UUID())")!
        let b = UserDefaults(suiteName: "video-settings-target-\(UUID())")!
        a.set("4K-60", forKey: "cameraSingleVideoProfile")
        a.set("720p-24", forKey: "cameraDualVideoProfile")
        a.set(false, forKey: "cameraMirrorFront")
        a.set(false, forKey: "cameraGrid")
        a.set(true, forKey: "cameraLevel")
        CameraPreferenceStore.apply(CameraPreferenceStore.snapshot(a), to: b)
        XCTAssertEqual(VideoRecordingProfile.current(dual: false, defaults: b), .init(resolution: .uhd, fps: 60))
        XCTAssertEqual(VideoRecordingProfile.current(dual: true, defaults: b), .init(resolution: .hd, fps: 24))
        XCTAssertFalse(b.bool(forKey: "cameraMirrorFront"))
        XCTAssertFalse(b.bool(forKey: "cameraGrid"))
        XCTAssertTrue(b.bool(forKey: "cameraLevel"))
        XCTAssertEqual(VideoRecordingProfile(rawValue: "unknown-120"), .standard)
    }

    @MainActor
    func testUnmirroredSavedFramesStillHaveMirroredSelfiePreview() {
        let rear = AVSampleBufferDisplayLayer(), front = AVSampleBufferDisplayLayer()
        let host = CameraVideoSurface.Host(frame: CGRect(x: 0, y: 0, width: 375, height: 812))
        for primary in [false, true] {
            for mirrorSaved in [false, true] {
                let surface = CameraVideoSurface(rear: rear, front: front,
                    rearSize: CGSize(width: 1080, height: 1920), frontSize: CGSize(width: 1080, height: 1920),
                    frontNeedsMirror: !mirrorSaved, aperture: CGRect(x: 0, y: 106, width: 375, height: 500),
                    layout: CameraLayout(frontIsPrimary: primary))
                host.update(surface)
                XCTAssertEqual(front.affineTransform().a, mirrorSaved ? 1 : -1)
                XCTAssertEqual(rear.affineTransform(), .identity)
                XCTAssertEqual(front.position.x, front.superlayer!.bounds.midX, accuracy: 0.01)
            }
        }
    }

    func testResolutionAndRateAreIndependentAndNeverUpscaleCrop() {
        let available: [VideoRecordingProfile] = [.init(resolution: .hd, fps: 24), .init(resolution: .hd, fps: 30), .standard]
        XCTAssertEqual(VideoRecordingProfile.nearest(to: .init(resolution: .hd, fps: 60), in: available), .init(resolution: .hd, fps: 30))
        XCTAssertNil(VideoRecordingProfile.nearest(to: .standard, in: []))
        for r in VideoResolution.allCases {
            let p = VideoRecordingProfile(resolution: r, fps: 60)
            for aspect in CaptureAspect.allCases {
                let size = p.exportSize(aspect: aspect.ratio)
                XCTAssertEqual(size.width, CGFloat(r.shortEdge))
                XCTAssertLessThanOrEqual(size.height, CGFloat(r.longEdge))
                XCTAssertEqual(size.width / size.height, aspect.ratio, accuracy: 0.002)
            }
        }
    }

    func testRecorded60FPSAnd24FPSRemainInExport() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for fps in [24, 60] {
            let profile = VideoRecordingProfile(resolution: .hd, fps: fps)
            let disk = LibraryDisk(root: folder.appendingPathComponent("\(fps)"))
            let draft = try disk.createDraft(kind: .video, layout: CameraLayout(singleCamera: true, aspect: .wide), videoProfile: profile)
            let queue = DispatchQueue(label: "video.profile.test")
            let result: (Bool, Double) = try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    let recorder = PairRecorder(draft: draft, audioSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 1], onStart: {})
                    do {
                        // A stale photo-shaped frame must not initialize a wrong-size writer.
                        try recorder.consumeVideo(Self.sample(width: 1440, height: 1920, time: .zero), isFront: false)
                        for i in 0..<fps {
                            if i == fps / 2 { Thread.sleep(forTimeInterval: 1.0 / Double(fps)); continue }
                            let time = CMTime(value: Int64(i), timescale: Int32(fps))
                            try recorder.consumeVideo(Self.sample(width: 720, height: 1280, time: time), isFront: false)
                            Thread.sleep(forTimeInterval: 1.0 / Double(fps))
                        }
                        recorder.finish(on: queue) { rear, _, duration, _, error in
                            XCTAssertNil(error)
                            continuation.resume(returning: (rear, duration))
                        }
                    } catch { continuation.resume(throwing: error) }
                }
            }
            XCTAssertTrue(result.0)
            XCTAssertEqual(result.1, 1, accuracy: 0.01)
            let item = try disk.finish(draft, rear: true, front: false, duration: result.1)
            let recipe = try await MediaExporter.videoRecipe(item: item, rearURL: draft.rearURL, frontURL: draft.rearURL)
            XCTAssertEqual(recipe.videoComposition.frameDuration.seconds, 1 / Double(fps), accuracy: 0.0001)
            XCTAssertEqual(recipe.videoComposition.renderSize, CGSize(width: 720, height: 1280))
            let output = draft.folder.appendingPathComponent("export.mov")
            try await MediaExporter.makeVideo(item: item, rearURL: draft.rearURL, frontURL: draft.rearURL, outputURL: output)
            let tracks = try await AVURLAsset(url: output).loadTracks(withMediaType: .video)
            let track = try XCTUnwrap(tracks.first)
            let rate = try await track.load(.nominalFrameRate)
            let size = try await track.load(.naturalSize)
            XCTAssertEqual(rate, Float(fps), accuracy: 0.2)
            XCTAssertEqual(size, CGSize(width: 720, height: 1280))
        }
    }

    private static func sample(width: Int, height: Int, time: CMTime) throws -> CMSampleBuffer {
        var pixel: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel)
        let buffer = try XCTUnwrap(pixel)
        CVPixelBufferLockBaseAddress(buffer, [])
        memset(CVPixelBufferGetBaseAddress(buffer), 100, CVPixelBufferGetDataSize(buffer))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        var description: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescriptionOut: &description)
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescription: description!, sampleTiming: &timing, sampleBufferOut: &sample)
        return try XCTUnwrap(sample)
    }
}
