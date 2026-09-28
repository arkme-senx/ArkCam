import XCTest
import AVFoundation
import UIKit
import CoreLocation
@testable import Cam

final class ThermalOptimizationTests: XCTestCase {
    @MainActor
    func testLocationPauseRejectsLateUpdatesAndRetainsCaptureFallback() {
        let provider = CaptureMetadataProvider()
        let service = CaptureLocationService(provider: provider)
        let manager = CLLocationManager()
        let first = CLLocation(latitude: 31.2, longitude: 121.4)
        let later = CLLocation(latitude: 32.2, longitude: 122.4)
        service.start()
        service.locationManager(manager, didUpdateLocations: [first])
        service.stop()
        service.locationManager(manager, didUpdateLocations: [later])
        XCTAssertEqual(provider.snapshot(cameras: []).location?.latitude, first.coordinate.latitude)
        service.start()
        service.locationManager(manager, didUpdateLocations: [later])
        XCTAssertEqual(service.latestLocation?.latitude, later.coordinate.latitude)
        service.setEnabled(false)
        XCTAssertNil(provider.snapshot(cameras: []).location)
        service.stop()
    }

    func testLivePreferenceDoesNotStartVideoModeOrQuickTakeBuffer() {
        for requested in [false, true] {
            for running in [false, true] {
                XCTAssertFalse(CaptureWorkPolicy.liveBuffer(requested: requested, running: running,
                    videoMode: true, hasVideoFormat: false, recording: false))
                XCTAssertFalse(CaptureWorkPolicy.liveBuffer(requested: requested, running: running,
                    videoMode: false, hasVideoFormat: true, recording: false))
                XCTAssertFalse(CaptureWorkPolicy.liveBuffer(requested: requested, running: running,
                    videoMode: false, hasVideoFormat: false, recording: true))
            }
        }
        XCTAssertTrue(CaptureWorkPolicy.liveBuffer(requested: true, running: true,
            videoMode: false, hasVideoFormat: false, recording: false))
    }

    func testWarmIdleCadenceRestoresSelectedVideoRateAtStart() {
        XCTAssertEqual(CaptureWorkPolicy.frameRate(requested: 60, pressure: .normal, videoMode: true, recording: false), 24)
        XCTAssertEqual(CaptureWorkPolicy.frameRate(requested: 30, pressure: .normal, videoMode: false, recording: false), 24)
        XCTAssertEqual(CaptureWorkPolicy.frameRate(requested: 30, pressure: .fair, videoMode: false, recording: false), 22)
        XCTAssertEqual(CaptureWorkPolicy.frameRate(requested: 30, pressure: .serious, videoMode: false, recording: false), 20)
        XCTAssertEqual(CaptureWorkPolicy.frameRate(requested: 60, pressure: .fair, videoMode: true, recording: true), 60)
        XCTAssertEqual(CaptureWorkPolicy.frameRate(requested: 24, pressure: .normal, videoMode: true, recording: false), 24)
        XCTAssertEqual(CaptureWorkPolicy.frameRate(requested: 60, pressure: .critical, videoMode: true, recording: true), 15)
    }

    func testPreviewDisplayCadenceUsesAnAccumulatedDeadline() {
        func count(source: Int, target: Double) -> Int {
            var cadence = PreviewDisplayCadence()
            var result = 0
            for index in 0..<(source * 1) {
                let time = CMTime(value: CMTimeValue(index), timescale: CMTimeScale(source))
                if cadence.shouldAttempt(at: time, targetFrameRate: target) {
                    cadence.didEnqueue(at: time)
                    result += 1
                }
            }
            return result
        }

        XCTAssertEqual(count(source: 30, target: 24), 24)
        XCTAssertEqual(count(source: 60, target: 24), 24)
        XCTAssertEqual(count(source: 24, target: 24), 24)
    }

    func testPreviewDisplayCadenceHandlesBackpressureRewindsAndRateChanges() {
        var cadence = PreviewDisplayCadence()
        let first = CMTime(value: 0, timescale: 600)
        let next = CMTime(value: 30, timescale: 600)
        XCTAssertTrue(cadence.shouldAttempt(at: first, targetFrameRate: 24))
        // A rejected enqueue must not consume the first display deadline.
        XCTAssertTrue(cadence.shouldAttempt(at: next, targetFrameRate: 24))
        cadence.didEnqueue(at: next)
        XCTAssertFalse(cadence.shouldAttempt(at: next, targetFrameRate: 24))

        let rewound = CMTime(value: 10, timescale: 600)
        XCTAssertTrue(cadence.shouldAttempt(at: rewound, targetFrameRate: 24))
        cadence.didEnqueue(at: rewound)
        let changedRate = CMTime(value: 20, timescale: 600)
        XCTAssertTrue(cadence.shouldAttempt(at: changedRate, targetFrameRate: 20))
        cadence.didEnqueue(at: changedRate)
        XCTAssertFalse(cadence.shouldAttempt(at: changedRate, targetFrameRate: 20))
    }

    func testExportSchedulingProtectsCaptureAndResumesOutsideCamera() {
        func allowed(_ thermal: ProcessInfo.ThermalState, _ pressure: CameraPressureLevel,
                     visible: Bool = true, capturing: Bool = false, heavy: Bool = true) -> Bool {
            CaptureWorkPolicy.albumExport(energy: .init(thermal: thermal), pressure: pressure,
                cameraVisible: visible, capturing: capturing, heavy: heavy)
        }
        XCTAssertFalse(allowed(.nominal, .normal, capturing: true))
        XCTAssertFalse(allowed(.serious, .normal, visible: false))
        XCTAssertFalse(allowed(.fair, .normal))
        XCTAssertFalse(allowed(.nominal, .serious))
        XCTAssertTrue(allowed(.fair, .normal, heavy: false))
        XCTAssertTrue(allowed(.nominal, .serious, visible: false))
        XCTAssertTrue(allowed(.nominal, .normal))
    }

    func testPrimaryExportKeepsBothSourcesWhenPrimaryChanges() throws {
        var item = MemoryItem(id: UUID(), createdAt: Date(), kind: .video,
                              capturedLayout: CameraLayout())
        XCTAssertEqual(MediaExporter.requiredCameras(item, mode: .primary), [false])
        item.layoutMoments = [.init(seconds: 1, layout: CameraLayout(frontIsPrimary: true))]
        XCTAssertEqual(MediaExporter.requiredCameras(item, mode: .primary), [false, true])
        item.layoutOverride = CameraLayout(frontIsPrimary: true)
        XCTAssertEqual(MediaExporter.requiredCameras(item, mode: .primary), [true])
        XCTAssertEqual(MediaExporter.requiredCameras(item, mode: .dual), [false, true])
    }

    func testPrimaryVideoRecipeDoesNotReadAnUnusedOriginal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("front.mov")
        try await DebugFixtures.writeMovie(to: source, front: true, seconds: 1)
        let item = MemoryItem(id: UUID(), createdAt: Date(), kind: .video,
            rearFile: "missing.mov", frontFile: "front.mov", capturedLayout: CameraLayout(frontIsPrimary: true))
        let recipe = try await MediaExporter.videoRecipe(item: item,
            rearURL: root.appendingPathComponent("missing.mov"), frontURL: source, mode: .primary)
        let tracks = try await recipe.composition.loadTracks(withMediaType: .video)
        XCTAssertEqual(tracks.count, 1)
        let instruction = try XCTUnwrap(recipe.videoComposition.instructions.first as? PairCompositionInstruction)
        XCTAssertEqual(instruction.requiredSourceTrackIDs?.count, 1)
        let output = root.appendingPathComponent("export.mov")
        try await MediaExporter.makeVideo(item: item, rearURL: root.appendingPathComponent("missing.mov"),
            frontURL: source, outputURL: output, mode: .primary)
        let readable = await MediaLibrary.isReadableMovie(output)
        XCTAssertTrue(readable)
    }

    func testLiveRecipePreservesDynamicSourceSizeAndCadence() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("live.mov")
        try await DebugFixtures.writeMovie(to: source, front: false, seconds: 1)
        let item = MemoryItem(id: UUID(), createdAt: Date(), kind: .photo,
            capturedLayout: CameraLayout(singleCamera: true), rearLiveFile: "live.mov")
        let recipe = try await MediaExporter.videoRecipe(item: item, rearURL: source, frontURL: source)
        XCTAssertEqual(recipe.videoComposition.renderSize, CGSize(width: 270, height: 360))
        XCTAssertEqual(recipe.videoComposition.frameDuration.seconds, 1.0 / 30, accuracy: 0.001)
        XCTAssertEqual(MediaExporter.liveRenderSize(source: CGSize(width: 540, height: 720), aspect: 0.75),
                       CGSize(width: 540, height: 720))
    }

    func testLowCadenceLiveExportDoesNotInventFramesOrPixels() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.mov")
        try await DebugFixtures.writeMovie(to: source, front: false, seconds: 2)
        let asset = AVURLAsset(url: source)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: try XCTUnwrap(tracks.first), outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ])
        reader.add(output); XCTAssertTrue(reader.startReading())
        var frames: [(CVPixelBuffer, CMTime)] = [], index = 0
        while let sample = output.copyNextSampleBuffer() {
            if index % 3 == 0 {
                frames.append((try XCTUnwrap(CMSampleBufferGetImageBuffer(sample)),
                               CMSampleBufferGetPresentationTimeStamp(sample)))
            }
            index += 1
        }
        XCTAssertEqual(reader.status, .completed)
        let rear = root.appendingPathComponent("rear.mov"), front = root.appendingPathComponent("front.mov")
        _ = try RawLivePhotoWriter.write(rearFrames: frames, frontFrames: frames,
            audio: [], audioSettings: nil, shutterTime: CMTime(seconds: 1, preferredTimescale: 600),
            rearURL: rear, frontURL: front)
        let item = MemoryItem(id: UUID(), createdAt: Date(), kind: .photo,
            capturedLayout: CameraLayout(), rearLiveFile: "rear.mov", frontLiveFile: "front.mov")
        let merged = root.appendingPathComponent("merged.mov")
        try await MediaExporter.makeVideo(item: item, rearURL: rear, frontURL: front, outputURL: merged)
        let exported = AVURLAsset(url: merged)
        let exportedTracks = try await exported.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(exportedTracks.first)
        let fps = try await track.load(.nominalFrameRate), size = try await track.load(.naturalSize)
        XCTAssertEqual(fps, 10, accuracy: 0.5)
        XCTAssertEqual(size, CGSize(width: 270, height: 360))
        let decoder = try AVAssetReader(asset: exported)
        let decoded = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ])
        decoder.add(decoded); XCTAssertTrue(decoder.startReading())
        var count = 0
        while decoded.copyNextSampleBuffer() != nil { count += 1 }
        XCTAssertEqual(decoder.status, .completed)
        XCTAssertEqual(count, frames.count, accuracy: 1)
    }

    func testThumbnailCacheSharesResultsAndInvalidatesChangedFile() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        try DebugFixtures.image(front: false).jpegData(compressionQuality: 0.9)!.write(to: url)
        let cache = ThumbnailCache()
        let first = await cache.image(url: url, kind: .photo, maximumPixelSize: 160)
        let repeated = await cache.image(url: url, kind: .photo, maximumPixelSize: 160)
        XCTAssertNotNil(first); XCTAssertTrue(first === repeated)
        try DebugFixtures.image(front: true).jpegData(compressionQuality: 0.9)!.write(to: url)
        let changed = await cache.image(url: url, kind: .photo, maximumPixelSize: 160)
        XCTAssertNotNil(changed); XCTAssertFalse(first === changed)
        let detail = await cache.image(url: url, kind: .photo, maximumPixelSize: 4096)
        XCTAssertGreaterThan(detail?.size.width ?? 0, first?.size.width ?? 0)
    }
}
