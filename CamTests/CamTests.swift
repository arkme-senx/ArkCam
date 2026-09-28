import XCTest
import AVFoundation
import UIKit
import CoreLocation
import ImageIO
import Photos
@testable import Cam

final class CamTests: XCTestCase {
    private var root: URL!
    private var disk: LibraryDisk!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("CamTests-\(UUID().uuidString)")
        disk = LibraryDisk(root: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    func testSingleVideoFastExportPreservesCompressedVideoAudioAndOriginal() async throws {
        let draft = try disk.createDraft(kind: .video, layout: CameraLayout(singleCamera: true, aspect: .wide),
            metadata: DebugFixtures.metadata(), videoProfile: VideoRecordingProfile(resolution: .hd, fps: 30))
        let silent = root.appendingPathComponent("silent.mov")
        try await DebugFixtures.writeMovie(to: silent, front: false, seconds: 1, width: 720, height: 1280)
        try await addAudio(movie: silent, output: draft.rearURL)
        let original = try Data(contentsOf: draft.rearURL)
        let item = try disk.finish(draft, rear: true, front: false, duration: 1)
        let output = draft.folder.appendingPathComponent("fast.mov")
        try await MediaExporter.makeVideo(item: item, rearURL: draft.rearURL, frontURL: draft.rearURL, outputURL: output)
        func packets(_ url: URL, type: AVMediaType) async throws -> [Data] {
            let asset = AVURLAsset(url: url)
            let tracks = try await asset.loadTracks(withMediaType: type)
            let track = try XCTUnwrap(tracks.first)
            let reader = try AVAssetReader(asset: asset)
            let trackOutput = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            reader.add(trackOutput); XCTAssertTrue(reader.startReading())
            var values: [Data] = []
            while let sample = trackOutput.copyNextSampleBuffer() {
                // Reader output can include empty edit/priming samples. Only
                // payload-bearing samples are compressed media packets.
                guard CMSampleBufferGetTotalSampleSize(sample) > 0 else { continue }
                let block = try XCTUnwrap(CMSampleBufferGetDataBuffer(sample))
                var bytes = Data(count: CMBlockBufferGetDataLength(block))
                let length = bytes.count
                let result = bytes.withUnsafeMutableBytes { ptr in
                    CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: ptr.baseAddress!)
                }
                XCTAssertEqual(result, kCMBlockBufferNoErr)
                values.append(bytes)
            }
            XCTAssertEqual(reader.status, .completed)
            return values
        }
        for type in [AVMediaType.video, .audio] {
            let before = try await packets(draft.rearURL, type: type)
            let after = try await packets(output, type: type)
            XCTAssertFalse(before.isEmpty)
            // Exact compressed samples prove this path did not re-encode content.
            XCTAssertEqual(before, after)
        }
        XCTAssertEqual(try Data(contentsOf: draft.rearURL), original)
    }

    func testManualPhotoExportsUsePhysicalCamerasAndKeepOriginals() async throws {
        let draft = try photoPair(metadata: DebugFixtures.metadata())
        var item = try disk.finish(draft, rear: true, front: true)
        item.layoutOverride = CameraLayout(frontIsPrimary: true, x: 1, y: 0)
        let rearBytes = try Data(contentsOf: draft.rearURL), frontBytes = try Data(contentsOf: draft.frontURL)
        XCTAssertEqual(ManualAlbumExport.availableModes(for: item, disk: disk), [.front, .rear, .combined])
        for mode in MemoryExportMode.allCases {
            let folder = root.appendingPathComponent(mode.rawValue); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let media = try await ManualAlbumExport.prepare(item, mode: mode, disk: disk, folder: folder)
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(media.file as CFURL, nil))
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            let center = pixel(image, x: 0.5, y: 0.5)
            if mode == .rear { XCTAssertGreaterThan(center.r, 220); XCTAssertLessThan(center.b, 30) }
            else { XCTAssertGreaterThan(center.b, 220); XCTAssertLessThan(center.r, 30) }
            if mode != .combined { XCTAssertEqual(image.width, 400); XCTAssertEqual(image.height, 600) }
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
            let gps = try XCTUnwrap(properties[kCGImagePropertyGPSDictionary] as? [String: Any])
            XCTAssertEqual(gps[kCGImagePropertyGPSLatitude as String] as? Double ?? 0, 31.2304, accuracy: 0.00001)
        }
        XCTAssertEqual(try Data(contentsOf: draft.rearURL), rearBytes)
        XCTAssertEqual(try Data(contentsOf: draft.frontURL), frontBytes)
        XCTAssertNil(item.albumSaveMode)
        try FileManager.default.removeItem(at: draft.frontURL)
        XCTAssertEqual(ManualAlbumExport.availableModes(for: item, disk: disk), [.rear])
        let rescue = root.appendingPathComponent("rescue"); try FileManager.default.createDirectory(at: rescue, withIntermediateDirectories: true)
        _ = try await ManualAlbumExport.prepare(item, mode: .rear, disk: disk, folder: rescue)
        let single = try disk.createDraft(kind: .photo, layout: CameraLayout(frontIsPrimary: true, singleCamera: true))
        try frontBytes.write(to: single.frontURL)
        let singleItem = try disk.finish(single, rear: false, front: true)
        XCTAssertEqual(ManualAlbumExport.availableModes(for: singleItem, disk: disk), [.front])
    }

    func testManualVideoExportsKeepTheSelectedFullFileAndAudioAfterLayoutSwaps() async throws {
        let draft = try disk.createDraft(kind: .video, layout: CameraLayout())
        for front in [false, true] {
            let silent = root.appendingPathComponent("silent-\(front).mov")
            try await DebugFixtures.writeMovie(to: silent, front: front, seconds: 2)
            try await addAudio(movie: silent, output: front ? draft.frontURL : draft.rearURL)
        }
        var item = try disk.finish(draft, rear: true, front: true, duration: 2,
            moments: [LayoutMoment(seconds: 0.5, layout: CameraLayout(frontIsPrimary: true))])
        item.layoutOverride = CameraLayout(frontIsPrimary: false)
        for mode in [MemoryExportMode.front, .rear] {
            let folder = root.appendingPathComponent(mode.rawValue); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let media = try await ManualAlbumExport.prepare(item, mode: mode, disk: disk, folder: folder)
            XCTAssertEqual(try Data(contentsOf: media.file), try Data(contentsOf: mode == .front ? draft.frontURL : draft.rearURL))
            let audio = try await AVURLAsset(url: media.file).loadTracks(withMediaType: .audio)
            XCTAssertEqual(audio.count, 1)
            XCTAssertNil(media.pairedMovie)
        }
    }

    func testManualHEIFPhotoAndLiveKeepDimensionsOrientationPairingAndSound() async throws {
        let draft = try disk.createDraft(kind: .photo, layout: CameraLayout(frontIsPrimary: true), metadata: DebugFixtures.metadata(),
            photoProfile: PhotoCaptureProfile(format: .heif, processedFormat: .heif))
        for front in [false, true] {
            let file = front ? draft.frontURL : draft.rearURL
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(file as CFURL, "public.heic" as CFString, 1, nil))
            CGImageDestinationAddImage(destination, solid(front ? .blue : .red).cgImage!, [kCGImagePropertyOrientation: 6] as CFDictionary)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            let silent = root.appendingPathComponent("silent-\(front).mov")
            try await DebugFixtures.writeMovie(to: silent, front: front, seconds: 2)
            try await addAudio(movie: silent, output: front ? draft.frontLiveURL : draft.rearLiveURL)
        }
        let still = try disk.finish(draft, rear: true, front: true)
        let live = try disk.finish(draft, rear: true, front: true, rearLive: true, frontLive: true, livePhotoDuration: 2, livePhotoDisplayTime: 1)
        for item in [still, live] {
            for mode in [MemoryExportMode.front, .rear] {
                let folder = root.appendingPathComponent(UUID().uuidString); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let media = try await ManualAlbumExport.prepare(item, mode: mode, disk: disk, folder: folder)
                let source = try XCTUnwrap(CGImageSourceCreateWithURL(media.file as CFURL, nil))
                XCTAssertEqual(CGImageSourceGetType(source) as String?, "public.heic")
                let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
                XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 400)
                XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, 600)
                XCTAssertEqual(properties[kCGImagePropertyOrientation] as? Int, 6)
                if item.isLivePhoto {
                    let maker = try XCTUnwrap(properties[kCGImagePropertyMakerAppleDictionary] as? [String: Any])
                    let identifier = try XCTUnwrap(maker["17"] as? String)
                    let asset = AVURLAsset(url: try XCTUnwrap(media.pairedMovie))
                    var metadata: [AVMetadataItem] = []
                    for format in try await asset.load(.availableMetadataFormats) { metadata += try await asset.loadMetadata(for: format) }
                    XCTAssertEqual(metadata.first { $0.identifier == .quickTimeMetadataContentIdentifier }?.stringValue, identifier)
                    let audio = try await asset.loadTracks(withMediaType: .audio)
                    XCTAssertEqual(audio.count, 1)
                    let decoder = try AVAssetReader(asset: asset)
                    let output = AVAssetReaderTrackOutput(track: audio[0], outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
                    decoder.add(output); XCTAssertTrue(decoder.startReading())
                    var samples = 0
                    while let sample = output.copyNextSampleBuffer() { samples += CMSampleBufferGetNumSamples(sample) }
                    XCTAssertEqual(decoder.status, .completed); XCTAssertGreaterThan(samples, 70_000)
                } else { XCTAssertNil(media.pairedMovie) }
            }
        }
    }

    func testPhotoProfilesFilterDeferredDimensionsAndRespectLiveCapabilities() {
        let dimensions = [CMVideoDimensions(width: 4032, height: 3024), CMVideoDimensions(width: 5712, height: 4284), CMVideoDimensions(width: 8064, height: 6048)]
        let allowed = PhotoCaptureCapabilities.dimensions(dimensions, maximum: dimensions[2])
        XCTAssertEqual(allowed.map(PhotoCaptureCapabilities.pixels), [12, 48])
        let cap = PhotoCaptureCapabilities(formats: [.jpeg, .heif, .raw], megapixels: [12, 48])
        XCTAssertEqual(cap.resolve(PhotoCaptureProfile(format: .raw, megapixels: 48), live: true).format, .heif)
        XCTAssertEqual(cap.resolve(PhotoCaptureProfile(format: .raw, megapixels: 48), live: false).format, .raw)
        let limited = PhotoCaptureCapabilities(formats: [.jpeg], megapixels: [8])
        let resolved = limited.resolve(PhotoCaptureProfile(format: .heif, megapixels: 48), live: false)
        XCTAssertEqual(resolved.format, .jpeg)
        XCTAssertEqual(resolved.processedFormat, .jpeg)
        XCTAssertEqual(resolved.megapixels, 8)
    }

    func testHEIFExportRetainsSelectedEncodingAndDoesNotUseLegacySizeCap() throws {
        let size = CGSize(width: 3040, height: 4054)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.red.setFill(); context.fill(CGRect(origin: .zero, size: size))
        }
        let profile = PhotoCaptureProfile(format: .heif, megapixels: 12, processedFormat: .heif)
        let draft = try disk.createDraft(kind: .photo, layout: CameraLayout(singleCamera: true, aspect: .standard), photoProfile: profile)
        XCTAssertEqual(draft.rearURL.pathExtension, "heic")
        let data = NSMutableData()
        let encoder = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.heic" as CFString, 1, nil))
        CGImageDestinationAddImage(encoder, try XCTUnwrap(image.cgImage), nil)
        XCTAssertTrue(CGImageDestinationFinalize(encoder))
        try (data as Data).write(to: draft.rearURL)
        let item = try disk.finish(draft, rear: true, front: false)
        XCTAssertEqual(try disk.load().first?.photoProfile, profile)
        let output = root.appendingPathComponent("heif-export.heic")
        try MediaExporter.makePhoto(item: item, rearURL: draft.rearURL, frontURL: draft.frontURL, outputURL: output)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, "public.heic")
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth as String] as? Int, 3040)
        XCTAssertLessThanOrEqual(properties[kCGImagePropertyPixelHeight as String] as? Int ?? Int.max, 4054)
        var old = item; old.photoProfile = nil
        let legacy = root.appendingPathComponent("legacy.jpg")
        try MediaExporter.makePhoto(item: old, rearURL: draft.rearURL, frontURL: draft.frontURL, outputURL: legacy)
        let legacySource = try XCTUnwrap(CGImageSourceCreateWithURL(legacy as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(legacySource) as String?, "public.jpeg")
    }

    func testRAWCompanionAndPhotoPreferencesSurviveDraftFinalization() throws {
        let draft = try disk.createDraft(kind: .photo, layout: CameraLayout(singleCamera: true),
            photoProfile: PhotoCaptureProfile(format: .raw, megapixels: 12, processedFormat: .jpeg))
        try Data([1,2,3]).write(to: draft.rawURL(front: false))
        let item = try disk.finish(draft, rear: true, front: false)
        XCTAssertEqual(item.rearRawFile, "rear.dng")
        XCTAssertNil(item.frontRawFile)
        XCTAssertEqual(item.rearFile, "rear.jpg")
        let suite = "Options-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("heif", forKey: "cameraPhotoFormat"); defaults.set("5", forKey: "cameraPhotoTimer")
        let preferences = CameraPreferenceStore.snapshot(defaults)
        XCTAssertEqual(preferences["cameraPhotoFormat"], "heif")
        XCTAssertEqual(preferences["cameraPhotoTimer"], "5")
        XCTAssertEqual(preferences["cameraEnhancedStabilization"], "false")
    }

    func testRAWAndProcessedCompanionsFailIndependentlyWithoutDiscardingGoodData() async throws {
        for rawFails in [false, true] {
            let draft = try disk.createDraft(kind: .photo, layout: CameraLayout(singleCamera: true),
                photoProfile: PhotoCaptureProfile(format: .raw, processedFormat: .jpeg))
            let done = expectation(description: "Independent companion write")
            let capture = PhotoPairCapture(draft: draft, queue: DispatchQueue(label: "test-photo-pair"),
                saveQueue: DispatchQueue(label: "test-photo-save"), live: false, onAcquired: {}) { rear, _, _, _, _, _, error in
                    XCTAssertEqual(rear, rawFails)
                    XCTAssertNotNil(error)
                    done.fulfill()
                }
            let bytes = Data([4, 5, 6]), failure = CamError.message("照片采集未完成。")
            capture.rear.completion(PhotoCaptureResult(photo: rawFails ? .success(bytes) : .failure(failure),
                captureTime: .invalid, liveMovieSucceeded: false, liveDuration: nil, displayTime: nil, liveError: nil,
                raw: rawFails ? .failure(failure) : .success(bytes)))
            await fulfillment(of: [done], timeout: 3)
            XCTAssertEqual(try Data(contentsOf: rawFails ? draft.rearURL : draft.rawURL(front: false)), bytes)
        }
    }

    func testFlashCycleSkipsUnavailableModesAndRecoversFromOldPreference() {
        XCTAssertEqual(CameraFlashMode.off.next(supported: [.off, .auto, .on]), .auto)
        XCTAssertEqual(CameraFlashMode.auto.next(supported: [.off, .auto, .on]), .on)
        XCTAssertEqual(CameraFlashMode.on.next(supported: [.off, .auto, .on]), .off)
        XCTAssertEqual(CameraFlashMode.off.next(supported: [.off, .on]), .on)
        XCTAssertEqual(CameraFlashMode.auto.next(supported: [.off]), .off)
        XCTAssertEqual(CameraFlashMode.on.next(supported: []), .off)
    }

    func testSeparateAutoPhotosSaveBothPhysicalCamerasOnceAndKeepAllReceipts() async throws {
        let draft = try photoPair(metadata: DebugFixtures.metadata())
        var item = try disk.finish(draft, rear: true, front: true)
        item.albumSaveMode = .separate
        item.capturedLayout.frontIsPrimary = true
        item.layoutOverride = CameraLayout(frontIsPrimary: false)
        try disk.save(item)
        let original = try Data(contentsOf: draft.rearURL)
        let store = AlbumSaveStore(disk: disk)
        var calls = 0
        let writer: AutomaticAlbumExport.Writer = { media, snapshot in
            calls += 1
            XCTAssertEqual(media.count, 2)
            XCTAssertNil(snapshot.layoutOverride)
            XCTAssertEqual(try store.receipt(item.id)?.phase, .writing)
            for (index, resource) in media.enumerated() {
                let image = try XCTUnwrap(UIImage(contentsOfFile: resource.file.path)?.cgImage)
                XCTAssertEqual(image.width, 400); XCTAssertEqual(image.height, 600)
                let color = self.pixel(image, x: 0.82, y: 0.82)
                XCTAssertGreaterThan(index == 0 ? color.b : color.r, 230)
                XCTAssertLessThan(index == 0 ? color.r : color.b, 20)
            }
            return ["front-asset", "rear-asset"]
        }
        try await AutomaticAlbumExport.save(item, disk: disk, writer: writer)
        try await AutomaticAlbumExport.save(item, disk: disk, writer: writer)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(try store.receipt(item.id)?.assetIdentifiers, ["front-asset", "rear-asset"])
        XCTAssertEqual(try store.receipt(item.id)?.assetIdentifier, "front-asset")
        XCTAssertEqual(try disk.load().first?.albumSaveMode, .separate)
        XCTAssertEqual(try Data(contentsOf: draft.rearURL), original)
        let legacy = try JSONDecoder().decode(AlbumSaveReceipt.self, from: Data(#"{"phase":"saved","assetIdentifier":"old-asset"}"#.utf8))
        XCTAssertEqual(legacy.phase, .saved); XCTAssertNil(legacy.assetIdentifiers)
        XCTAssertEqual(legacy.assetIdentifier, "old-asset")
    }

    func testSeparateAutoExportDoesNotCommitHalfAndCanRetryWholeBatch() async throws {
        let draft = try photoPair()
        var item = try disk.finish(draft, rear: true, front: true)
        item.albumSaveMode = .separate
        let rear = try Data(contentsOf: draft.rearURL)
        try FileManager.default.removeItem(at: draft.rearURL)
        let store = AlbumSaveStore(disk: disk)
        do {
            try await AutomaticAlbumExport.save(item, disk: disk) { _, _ in
                XCTFail("Do not submit even the prepared front camera when the rear is missing"); return []
            }
            XCTFail("Expected missing source")
        } catch { XCTAssertNil(try store.receipt(item.id)) }
        try rear.write(to: draft.rearURL)
        do {
            try await AutomaticAlbumExport.save(item, disk: disk) { media, _ in
                XCTAssertEqual(media.count, 2); throw CamError.message("Rejected batch")
            }
            XCTFail("Expected rejected Photos transaction")
        } catch { XCTAssertEqual(try store.receipt(item.id)?.phase, .failed) }
        try await AutomaticAlbumExport.save(item, disk: disk) { media, _ in
            XCTAssertEqual(media.count, 2); return ["front-retry", "rear-retry"]
        }
        XCTAssertEqual(try store.receipt(item.id)?.assetIdentifiers?.count, 2)
        try store.write(AlbumSaveReceipt(phase: .writing), for: item.id)
        do {
            try await AutomaticAlbumExport.save(item, disk: disk) { _, _ in
                XCTFail("Do not blindly retry either camera after an uncertain commit"); return []
            }
            XCTFail("Expected uncertain receipt")
        } catch { XCTAssertEqual(try store.receipt(item.id)?.phase, .writing) }
        XCTAssertEqual(try Data(contentsOf: draft.rearURL), rear)
    }

    func testAlbumSaveDefaultsAndCaptureSnapshotSurviveSettingsAndLibraryChanges() throws {
        let name = "AlbumPreferences-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(AlbumSaveMode.current(defaults), .dual)
        defaults.set("primary", forKey: "cameraAlbumSaveMode")
        XCTAssertEqual(CameraPreferenceStore.snapshot(defaults)["cameraAlbumSaveMode"], "primary")
        let draft = try disk.createDraft(kind: .photo, layout: CameraLayout(), albumSaveMode: AlbumSaveMode.current(defaults))
        defaults.set("separate", forKey: "cameraAlbumSaveMode")
        XCTAssertEqual(AlbumSaveMode.current(defaults), .separate)
        XCTAssertEqual(CameraPreferenceStore.snapshot(defaults)["cameraAlbumSaveMode"], "separate")
        try solid(.red).jpegData(compressionQuality: 1)!.write(to: draft.rearURL)
        try solid(.blue).jpegData(compressionQuality: 1)!.write(to: draft.frontURL)
        _ = try disk.finish(draft, rear: true, front: true)
        XCTAssertEqual(try disk.load().first?.albumSaveMode, .primary)
        let old = try photoPair()
        let legacy = try disk.finish(old, rear: true, front: true)
        XCTAssertNil(legacy.albumSaveMode)
        XCTAssertFalse(AlbumSaveStore(disk: disk).needsSave(legacy))
    }

    func testPrimaryPhotosRespectEveryAspectWithoutInsetOrOriginalMutation() throws {
        let draft = try photoPair(metadata: DebugFixtures.metadata())
        let original = try Data(contentsOf: draft.rearURL)
        var item = try disk.finish(draft, rear: true, front: true)
        for aspect in CaptureAspect.allCases {
            for front in [false, true] {
                item.capturedLayout = CameraLayout(frontIsPrimary: front, aspect: aspect, insetAspectRatio: 0.75)
                let file = root.appendingPathComponent("primary-\(aspect.rawValue)-\(front).jpg")
                try MediaExporter.makePhoto(item: item, rearURL: draft.rearURL, frontURL: draft.frontURL,
                                            outputURL: file, mode: .primary)
                let image = try XCTUnwrap(UIImage(contentsOfFile: file.path)?.cgImage)
                XCTAssertEqual(Double(image.width) / Double(image.height), Double(aspect.ratio), accuracy: 0.006)
                for point in [0.2, 0.82] {
                    let sample = pixel(image, x: point, y: point)
                    XCTAssertGreaterThan(front ? sample.b : sample.r, 230)
                    XCTAssertLessThan(front ? sample.r : sample.b, 20)
                }
            }
        }
        XCTAssertEqual(try Data(contentsOf: draft.rearURL), original)
    }

    func testAutomaticSaveReceiptPreventsDuplicatesAndUsesCapturedLayout() async throws {
        let draft = try photoPair()
        var item = try disk.finish(draft, rear: true, front: true)
        item.albumSaveMode = .primary
        item.layoutOverride = CameraLayout(frontIsPrimary: true)
        try disk.save(item)
        let before = try Data(contentsOf: draft.folder.appendingPathComponent("memory.json"))
        var calls = 0
        let writer: AutomaticAlbumExport.Writer = { batch, snapshot in
            XCTAssertEqual(batch.count, 1)
            let media = try XCTUnwrap(batch.first)
            calls += 1
            XCTAssertNil(snapshot.layoutOverride)
            XCTAssertEqual(try AlbumSaveStore(disk: self.disk).receipt(item.id)?.phase, .writing)
            let image = try XCTUnwrap(UIImage(contentsOfFile: media.file.path)?.cgImage)
            XCTAssertGreaterThan(self.pixel(image, x: 0.82, y: 0.82).r, 230)
            return ["test-asset"]
        }
        try await AutomaticAlbumExport.save(item, disk: disk, writer: writer)
        try await AutomaticAlbumExport.save(item, disk: disk, writer: writer)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(try AlbumSaveStore(disk: disk).receipt(item.id)?.assetIdentifier, "test-asset")
        let timing = try XCTUnwrap(AlbumSaveStore(disk: disk).receipt(item.id)?.timing)
        XCTAssertGreaterThanOrEqual(timing.prepareSeconds, 0)
        XCTAssertGreaterThanOrEqual(timing.writeSeconds, 0)
        XCTAssertNotNil(try AlbumSaveStore(disk: disk).receipt(item.id)?.savedAt)
        XCTAssertEqual(try Data(contentsOf: draft.folder.appendingPathComponent("memory.json")), before)
    }

    func testAutomaticSaveFailureCanRetryButUncertainCommitCannotDuplicate() async throws {
        let draft = try photoPair()
        var item = try disk.finish(draft, rear: true, front: true)
        item.albumSaveMode = .dual
        let store = AlbumSaveStore(disk: disk)
        do {
            try await AutomaticAlbumExport.save(item, disk: disk) { _, _ in throw CamError.message("Photos rejected write") }
            XCTFail("Expected failure")
        } catch { XCTAssertEqual(try store.receipt(item.id)?.phase, .failed) }
        try await AutomaticAlbumExport.save(item, disk: disk) { _, _ in ["retried-asset"] }
        XCTAssertEqual(try store.receipt(item.id)?.phase, .saved)
        try store.write(AlbumSaveReceipt(phase: .writing), for: item.id)
        do {
            try await AutomaticAlbumExport.save(item, disk: disk) { _, _ in XCTFail("Must not duplicate an uncertain commit"); return ["duplicate"] }
            XCTFail("Should require reconciliation")
        } catch { XCTAssertEqual(try store.receipt(item.id)?.phase, .writing) }
        // Unknown/corrupt receipt is also fail-closed: never overwrite its evidence.
        try Data("corrupt receipt".utf8).write(to: store.url(item.id))
        do {
            try await AutomaticAlbumExport.save(item, disk: disk) { _, _ in XCTFail("Must not overwrite unknown receipt"); return ["duplicate"] }
            XCTFail("Expected receipt failure")
        } catch { XCTAssertEqual(try Data(contentsOf: store.url(item.id)), Data("corrupt receipt".utf8)) }
    }

    func testPrimaryVideoFollowsMainCameraSwitchAndKeepsOneAudioTrack() async throws {
        let draft = try disk.createDraft(kind: .video, layout: CameraLayout(), metadata: DebugFixtures.metadata(), albumSaveMode: .primary)
        let rear = root.appendingPathComponent("rear-silent.mov"), front = root.appendingPathComponent("front-silent.mov")
        try await DebugFixtures.writeMovie(to: rear, front: false)
        try await DebugFixtures.writeMovie(to: front, front: true)
        try await addAudio(movie: rear, output: draft.rearURL)
        try await addAudio(movie: front, output: draft.frontURL)
        let item = try disk.finish(draft, rear: true, front: true, duration: 2, moments: [
            LayoutMoment(seconds: 0, layout: CameraLayout()),
            LayoutMoment(seconds: 1, layout: CameraLayout(frontIsPrimary: true))])
        try await AutomaticAlbumExport.save(item, disk: disk) { batch, _ in
            XCTAssertEqual(batch.count, 1)
            let media = try XCTUnwrap(batch.first)
            let asset = AVURLAsset(url: media.file)
            let videos = try await asset.loadTracks(withMediaType: .video)
            let audios = try await asset.loadTracks(withMediaType: .audio)
            XCTAssertEqual(videos.count, 1); XCTAssertEqual(audios.count, 1)
            let generator = AVAssetImageGenerator(asset: asset)
            for (time, isFront) in [(0.3, false), (1.3, true)] {
                let image = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
                for point in [0.2, 0.82] {
                    let color = self.pixel(image, x: point, y: point)
                    XCTAssertGreaterThan(isFront ? color.r - color.g : color.g - color.r, 20)
                }
            }
            return ["video-asset"]
        }
    }

    func testCancelledAutoExportKeepsOriginalsAndCanResumeBeforePhotosCommit() async throws {
        let draft = try photoPair()
        var item = try disk.finish(draft, rear: true, front: true)
        item.albumSaveMode = .primary
        let snapshot = item
        let disk = self.disk!
        let task = Task {
            try await AutomaticAlbumExport.save(snapshot, disk: disk) { _, _ in XCTFail("Cancelled before commit"); return ["unexpected"] }
        }
        task.cancel()
        do { try await task.value; XCTFail("Expected cancellation") } catch { }
        XCTAssertNil(try AlbumSaveStore(disk: disk).receipt(item.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: draft.rearURL.path))
        try await AutomaticAlbumExport.save(item, disk: disk) { _, _ in ["resumed"] }
        XCTAssertEqual(try AlbumSaveStore(disk: disk).receipt(item.id)?.assetIdentifier, "resumed")
    }

    func testLockedImportCarriesSavedReceiptWithoutExportingAgain() async throws {
        let session = root.appendingPathComponent("Session")
        let locked = LibraryDisk(root: session.appendingPathComponent("Memories"))
        let draft = try locked.createDraft(kind: .photo, layout: CameraLayout(), albumSaveMode: .separate)
        try solid(.red).jpegData(compressionQuality: 1)!.write(to: draft.rearURL)
        try solid(.blue).jpegData(compressionQuality: 1)!.write(to: draft.frontURL)
        let item = try locked.finish(draft, rear: true, front: true)
        try await AutomaticAlbumExport.save(item, disk: locked) { media, _ in XCTAssertEqual(media.count, 2); return ["locked-front", "locked-rear"] }
        let unlocked = LibraryDisk(root: root.appendingPathComponent("Unlocked/Memories"))
        XCTAssertEqual(try LockedCaptureImport.receive(session: session, into: unlocked), 1)
        let imported = try XCTUnwrap(unlocked.load().first)
        try await AutomaticAlbumExport.save(imported, disk: unlocked) { _, _ in XCTFail("Already saved from lock screen"); return ["duplicate"] }
        XCTAssertEqual(try AlbumSaveStore(disk: unlocked).receipt(item.id)?.assetIdentifiers, ["locked-front", "locked-rear"])
    }

    #if targetEnvironment(simulator)
    func testPhotosBatchRejectsBothWhenSecondResourceIsInvalid() async throws {
        // Only the dedicated simulator QA host supplies the read usage string.
        // The shipped app continues to request add-only access.
        if PHPhotoLibrary.authorizationStatus(for: .readWrite) != .authorized,
           Bundle.main.object(forInfoDictionaryKey: "NSPhotoLibraryUsageDescription") != nil {
            _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized,
              PHPhotoLibrary.authorizationStatus(for: .addOnly) == .authorized else {
            throw XCTSkip("Photos authorization read=\(PHPhotoLibrary.authorizationStatus(for: .readWrite).rawValue), add=\(PHPhotoLibrary.authorizationStatus(for: .addOnly).rawValue). Requires permissions on the dedicated Cam simulator.")
        }
        let draft = try photoPair()
        let item = try disk.finish(draft, rear: true, front: true)
        let invalid = root.appendingPathComponent("invalid.jpg")
        try Data("invalid image".utf8).write(to: invalid)
        let count = PHAsset.fetchAssets(with: nil).count
        do {
            _ = try await PhotosAlbumWriter.writeAll([
                PreparedAlbumMedia(file: draft.frontURL, pairedMovie: nil),
                PreparedAlbumMedia(file: invalid, pairedMovie: nil)
            ], item)
            XCTFail("Photos should reject invalid second photo")
        } catch { XCTAssertEqual(PHAsset.fetchAssets(with: nil).count, count) }
    }

    func testAutomaticPhotoLiveAndVideoReachSystemPhotosInAllModes() async throws {
        // Only the dedicated simulator QA host supplies the read usage string.
        // The shipped app continues to request add-only access.
        if PHPhotoLibrary.authorizationStatus(for: .readWrite) != .authorized,
           Bundle.main.object(forInfoDictionaryKey: "NSPhotoLibraryUsageDescription") != nil {
            _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized,
              PHPhotoLibrary.authorizationStatus(for: .addOnly) == .authorized else {
            throw XCTSkip("Photos authorization read=\(PHPhotoLibrary.authorizationStatus(for: .readWrite).rawValue), add=\(PHPhotoLibrary.authorizationStatus(for: .addOnly).rawValue). Requires permissions on the dedicated Cam simulator.")
        }
        for mode in AlbumSaveMode.allCases {
            for kind in ["photo", "live", "video"] {
                let draft = try disk.createDraft(kind: kind == "video" ? .video : .photo,
                    layout: CameraLayout(aspect: .square, insetAspectRatio: 0.75),
                    metadata: DebugFixtures.metadata(), albumSaveMode: mode)
                if kind == "video" {
                    try await DebugFixtures.writeMovie(to: draft.rearURL, front: false, seconds: 1)
                    try await DebugFixtures.writeMovie(to: draft.frontURL, front: true, seconds: 1)
                } else {
                    try solid(.red).jpegData(compressionQuality: 1)!.write(to: draft.rearURL)
                    try solid(.blue).jpegData(compressionQuality: 1)!.write(to: draft.frontURL)
                    if kind == "live" {
                        let rear = root.appendingPathComponent("r-\(UUID()).mov"), front = root.appendingPathComponent("f-\(UUID()).mov")
                        try await DebugFixtures.writeMovie(to: rear, front: false)
                        try await DebugFixtures.writeMovie(to: front, front: true)
                        try await addAudio(movie: rear, output: draft.rearLiveURL)
                        try await addAudio(movie: front, output: draft.frontLiveURL)
                    }
                }
                let item = try disk.finish(draft, rear: true, front: true, duration: kind == "video" ? 1 : nil,
                    rearLive: kind == "live", frontLive: kind == "live", livePhotoDuration: 2, livePhotoDisplayTime: 1)
                try await AutomaticAlbumExport.save(item, disk: disk)
                let identifiers = try XCTUnwrap(AlbumSaveStore(disk: disk).receipt(item.id)?.assetIdentifiers)
                XCTAssertEqual(identifiers.count, mode == .separate ? 2 : 1)
                XCTAssertEqual(Set(identifiers).count, identifiers.count)
                for id in identifiers {
                    let asset = try XCTUnwrap(PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject)
                    XCTAssertEqual(asset.mediaType, kind == "video" ? .video : .image)
                    XCTAssertEqual(asset.mediaSubtypes.contains(.photoLive), kind == "live")
                    if mode != .separate { XCTAssertEqual(asset.pixelWidth, asset.pixelHeight) }
                    else if kind != "video" { XCTAssertEqual(asset.pixelWidth, 400); XCTAssertEqual(asset.pixelHeight, 600) }
                    XCTAssertEqual(asset.creationDate!.timeIntervalSince1970, item.createdAt.timeIntervalSince1970, accuracy: 1)
                    XCTAssertEqual(asset.location!.coordinate.latitude, 31.2304, accuracy: 0.00001)
                }
                try await AutomaticAlbumExport.save(item, disk: disk) { _, _ in XCTFail("Already saved"); return ["duplicate"] }
            }
        }
    }
    #endif

    func testStorageMessagesRequireRealFilesystemErrors() {
        for underlying in [
            NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)),
            NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileWriteOutOfSpace.rawValue),
            NSError(domain: AVFoundationErrorDomain, code: AVError.diskFull.rawValue)
        ] {
            let wrapped = NSError(domain: AVFoundationErrorDomain, code: AVError.unknown.rawValue,
                                  userInfo: [NSUnderlyingErrorKey: underlying])
            XCTAssertEqual(CaptureStorageFailure.classify(wrapped), .outOfSpace)
            XCTAssertTrue(CaptureStorageFailure.message(for: wrapped).contains("系统报告存储空间不足"))
        }
        for underlying in [
            NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)),
            NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM)),
            NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileWriteNoPermission.rawValue)
        ] {
            let wrapped = NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileWriteUnknown.rawValue,
                                  userInfo: [NSUnderlyingErrorKey: underlying])
            XCTAssertEqual(CaptureStorageFailure.classify(wrapped), .accessDenied)
            XCTAssertFalse(CaptureStorageFailure.message(for: wrapped).contains("空间不足"))
        }
        let unknown = CamError.message("无法读取容量估算")
        XCTAssertNil(CaptureStorageFailure.classify(unknown))
        XCTAssertEqual(CaptureStorageFailure.message(for: unknown), unknown.localizedDescription)
    }

    func testNoSavedMediaNeverBecomesASuccessfulMemory() throws {
        for kind in [CaptureKind.photo, .video] {
            let draft = try disk.createDraft(kind: kind, layout: CameraLayout())
            let partial = Data("partial capture".utf8)
            try partial.write(to: draft.rearURL)
            XCTAssertThrowsError(try disk.finish(draft, rear: false, front: false, note: "保存失败"))
            XCTAssertTrue(try disk.load().isEmpty)
            XCTAssertTrue(disk.unfinishedDrafts().contains { $0.item.id == draft.item.id })
            XCTAssertEqual(try Data(contentsOf: draft.rearURL), partial)
        }
    }

    func testFailedMetadataWriteKeepsOriginalsAndRecoverableDraft() throws {
        let draft = try photoPair()
        let rear = try Data(contentsOf: draft.rearURL)
        let front = try Data(contentsOf: draft.frontURL)
        let blockedMetadata = draft.folder.appendingPathComponent("memory.json")
        try FileManager.default.createDirectory(at: blockedMetadata, withIntermediateDirectories: true)
        try Data("occupied".utf8).write(to: blockedMetadata.appendingPathComponent("keep"))
        XCTAssertThrowsError(try disk.finish(draft, rear: true, front: true))
        XCTAssertEqual(try Data(contentsOf: draft.rearURL), rear)
        XCTAssertEqual(try Data(contentsOf: draft.frontURL), front)
        XCTAssertTrue(disk.unfinishedDrafts().contains { $0.item.id == draft.item.id })
    }

    func testLiveWriterKeepsCompletedRearWhenFrontCannotBeWritten() async throws {
        let source = root.appendingPathComponent("source.mov")
        try await DebugFixtures.writeMovie(to: source, front: false, seconds: 1)
        let asset = AVURLAsset(url: source)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: try XCTUnwrap(tracks.first), outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ])
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var frames: [(CVPixelBuffer, CMTime)] = []
        while let sample = output.copyNextSampleBuffer(), let buffer = CMSampleBufferGetImageBuffer(sample) {
            frames.append((buffer, CMSampleBufferGetPresentationTimeStamp(sample)))
        }
        XCTAssertGreaterThan(frames.count, 10)
        let rear = root.appendingPathComponent("rear-live.mov")
        let front = root.appendingPathComponent("missing-parent/front-live.mov")
        XCTAssertThrowsError(try RawLivePhotoWriter.write(rearFrames: frames, frontFrames: frames,
            audio: [], audioSettings: nil, shutterTime: CMTime(seconds: 0.5, preferredTimescale: 600),
            rearURL: rear, frontURL: front)) { error in
                XCTAssertEqual((error as? RawLivePhotoWriter.PartialFailure)?.rearCompleted, true)
            }
        let readable = await MediaLibrary.isReadableMovie(rear)
        XCTAssertTrue(readable)
        XCTAssertFalse(FileManager.default.fileExists(atPath: front.path))
    }

    func testLockedCaptureImportPreservesOriginalsAndIsIdempotentAfterLayoutEdit() throws {
        let session = root.appendingPathComponent("Session")
        let source = LibraryDisk(root: session.appendingPathComponent("Memories"))
        let draft = try source.createDraft(kind: .photo, layout: CameraLayout(), metadata: DebugFixtures.metadata())
        let rear = solid(.red).jpegData(compressionQuality: 1)!
        let front = solid(.blue).jpegData(compressionQuality: 1)!
        try rear.write(to: draft.rearURL)
        try front.write(to: draft.frontURL)
        _ = try source.finish(draft, rear: true, front: true)
        let destination = LibraryDisk(root: root.appendingPathComponent("Destination"))
        XCTAssertEqual(try LockedCaptureImport.receive(session: session, into: destination), 1)
        var item = try XCTUnwrap(destination.load().first)
        item.layoutOverride = CameraLayout(frontIsPrimary: true)
        try destination.save(item)
        XCTAssertEqual(try LockedCaptureImport.receive(session: session, into: destination), 0)
        XCTAssertEqual(try destination.load().count, 1)
        XCTAssertEqual(try destination.load().first?.layoutOverride, item.layoutOverride)
        XCTAssertEqual(try Data(contentsOf: destination.folder(for: item.id).appendingPathComponent("rear.jpg")), rear)
        XCTAssertEqual(try Data(contentsOf: draft.rearURL), rear)
        XCTAssertEqual(try Data(contentsOf: draft.frontURL), front)
        XCTAssertEqual(try destination.load().first?.captureMetadata, DebugFixtures.metadata())
    }

    func testLockedCaptureConflictNeverOverwritesEitherOriginal() throws {
        let session = root.appendingPathComponent("Session")
        let source = LibraryDisk(root: session.appendingPathComponent("Memories"))
        let draft = try source.createDraft(kind: .photo, layout: CameraLayout())
        try Data("source".utf8).write(to: draft.rearURL)
        _ = try source.finish(draft, rear: true, front: false)
        let destination = LibraryDisk(root: root.appendingPathComponent("Destination"))
        try FileManager.default.createDirectory(at: destination.root, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: draft.folder, to: destination.folder(for: draft.item.id))
        let existing = destination.folder(for: draft.item.id).appendingPathComponent("rear.jpg")
        try Data("existing".utf8).write(to: existing)
        XCTAssertThrowsError(try LockedCaptureImport.receive(session: session, into: destination))
        XCTAssertEqual(try Data(contentsOf: existing), Data("existing".utf8))
        XCTAssertEqual(try Data(contentsOf: draft.rearURL), Data("source".utf8))
    }

    @MainActor
    func testLockedCaptureInterruptedDraftCanBeRecoveredAfterImport() async throws {
        let session = root.appendingPathComponent("Session")
        let source = LibraryDisk(root: session.appendingPathComponent("Memories"))
        let draft = try source.createDraft(kind: .photo, layout: CameraLayout())
        let original = solid(.red).jpegData(compressionQuality: 1)!
        try original.write(to: draft.rearURL)
        let destination = LibraryDisk(root: root.appendingPathComponent("Destination"))
        XCTAssertEqual(try LockedCaptureImport.receive(session: session, into: destination), 1)
        let library = MediaLibrary(disk: destination)
        library.work.setPhase(.browsing)
        await library.recoverInterruptedCaptures()
        XCTAssertEqual(library.items.count, 1)
        XCTAssertNotNil(library.items.first?.rearFile)
        XCTAssertNil(library.items.first?.frontFile)
        XCTAssertTrue(destination.unfinishedDrafts().isEmpty)
        XCTAssertEqual(try LockedCaptureImport.receive(session: session, into: destination), 0)
        XCTAssertEqual(try Data(contentsOf: draft.rearURL), original)
        XCTAssertTrue(FileManager.default.fileExists(atPath: draft.folder.appendingPathComponent("draft.json").path))
    }

    func testLockedCaptureRejectsSymlinkWithoutImportingExternalContent() throws {
        let session = root.appendingPathComponent("Session")
        let source = LibraryDisk(root: session.appendingPathComponent("Memories"))
        let draft = try source.createDraft(kind: .photo, layout: CameraLayout())
        let outside = root.appendingPathComponent("outside.jpg")
        try Data("private".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: draft.rearURL, withDestinationURL: outside)
        let destination = LibraryDisk(root: root.appendingPathComponent("Destination"))
        XCTAssertThrowsError(try LockedCaptureImport.receive(session: session, into: destination))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.folder(for: draft.item.id).path))
    }

    func testLayoutEditsSurviveReloadWithoutChangingOriginals() throws {
        let draft = try photoPair()
        let rearBefore = try Data(contentsOf: draft.rearURL)
        let frontBefore = try Data(contentsOf: draft.frontURL)
        var item = try disk.finish(draft, rear: true, front: true)
        item.layoutOverride = CameraLayout(frontIsPrimary: true, x: 0, y: 0.3)
        try disk.save(item)
        let reloaded = try XCTUnwrap(disk.load().first)
        XCTAssertEqual(reloaded.layout(), item.layoutOverride)
        XCTAssertEqual(try Data(contentsOf: draft.rearURL), rearBefore)
        XCTAssertEqual(try Data(contentsOf: draft.frontURL), frontBefore)
        XCTAssertTrue(disk.unfinishedDrafts().isEmpty)
    }

    func testCaptureMetadataRoundTripsAndOldMemoriesRemainReadable() throws {
        let metadata = DebugFixtures.metadata()
        let draft = try disk.createDraft(kind: .photo, layout: CameraLayout(), metadata: metadata)
        try solid(.red).jpegData(compressionQuality: 1)!.write(to: draft.rearURL)
        try solid(.blue).jpegData(compressionQuality: 1)!.write(to: draft.frontURL)
        _ = try disk.finish(draft, rear: true, front: true)
        let reloaded = try XCTUnwrap(disk.load().first)
        XCTAssertEqual(reloaded.captureMetadata, metadata)
        XCTAssertEqual(reloaded.captureMetadata?.device.modelName, "iPhone 15 Pro Max")
        XCTAssertEqual(reloaded.captureMetadata?.location?.latitude, 31.23040)

        let oldDraft = try disk.createDraft(kind: .photo, layout: CameraLayout())
        try solid(.red).jpegData(compressionQuality: 1)!.write(to: oldDraft.rearURL)
        try solid(.blue).jpegData(compressionQuality: 1)!.write(to: oldDraft.frontURL)
        _ = try disk.finish(oldDraft, rear: true, front: true)
        let old = try XCTUnwrap(disk.load().first(where: { $0.id == oldDraft.item.id }))
        XCTAssertNil(old.captureMetadata)
    }

    func testLocationSnapshotUsesBoundedFallbackAndLateVideoFix() {
        let provider = CaptureMetadataProvider(device: DebugFixtures.metadata().device)
        let current = Date()
        provider.update(location: CLLocation(coordinate: CLLocationCoordinate2D(latitude: 22.5431, longitude: 114.0579),
                                             altitude: 25, horizontalAccuracy: 6, verticalAccuracy: 4,
                                             timestamp: current.addingTimeInterval(-90)))
        XCTAssertNil(provider.snapshot(cameras: [], at: current).location)
        XCTAssertEqual(provider.snapshot(cameras: [], at: current,
                                         maximumPastLocationAge: 5 * 60).location?.horizontalAccuracy, 6)

        provider.update(location: CLLocation(coordinate: CLLocationCoordinate2D(latitude: 22.5432, longitude: 114.0580),
                                             altitude: 26, horizontalAccuracy: 4, verticalAccuracy: 3,
                                             timestamp: current.addingTimeInterval(2)))
        let finalizedVideo = provider.snapshot(cameras: [], at: current,
                                               maximumPastLocationAge: 5 * 60,
                                               maximumFutureLocationAge: 10)
        XCTAssertEqual(finalizedVideo.location?.horizontalAccuracy, 4)
        XCTAssertEqual(finalizedVideo.location?.measuredAt, current.addingTimeInterval(2))
        XCTAssertNil(provider.snapshot(cameras: [], at: current,
                                       maximumPastLocationAge: 0,
                                       maximumFutureLocationAge: 1).location)
    }

    func testBackgroundCameraInterruptionStaysSilentUntilRecoveryFails() {
        XCTAssertEqual(DualCamera.interruptionState(wantsRunning: false, reason: "中断"), .paused)
        XCTAssertEqual(DualCamera.interruptionState(wantsRunning: true, reason: "中断"), .unavailable("中断"))
        XCTAssertTrue(CameraTransitionPolicy.keepsPreview(for: .paused, statusVisible: false))
        XCTAssertTrue(CameraTransitionPolicy.keepsPreview(for: .resuming, statusVisible: false))
        XCTAssertFalse(CameraTransitionPolicy.showsRecoveryHint(for: .resuming, statusVisible: false))
        XCTAssertTrue(CameraTransitionPolicy.showsRecoveryHint(for: .resuming, statusVisible: true))
        XCTAssertTrue(CameraTransitionPolicy.keepsPreview(for: .unavailable("失败"), statusVisible: false))
        XCTAssertFalse(CameraTransitionPolicy.keepsPreview(for: .unavailable("失败"), statusVisible: true))
    }

    func testCameraPressurePolicyReducesWorkAndExplainsTheRealCause() {
        XCTAssertEqual(CameraLoadPolicy.plan(level: .normal, causes: []),
                       CameraLoadPlan(frameRate: 24, liveFrameRate: 10,
                                      liveLongEdge: 640, notice: nil))
        XCTAssertEqual(CameraLoadPolicy.plan(level: .serious, causes: .peakPower),
                       CameraLoadPlan(frameRate: 20, liveFrameRate: 6,
                                      liveLongEdge: 480,
                                      notice: "相机功耗较高，已自动降低拍摄负载"))
        XCTAssertEqual(CameraLoadPolicy.plan(level: .critical, causes: .thermal),
                       CameraLoadPlan(frameRate: 15, liveFrameRate: 4,
                                      liveLongEdge: 400,
                                      notice: "相机温度较高，已自动降低拍摄负载"))
    }

    func testPhotoChromeMatchesMeasuredReferenceOnBothDisplaySizes() {
        for size in [CGSize(width: 375, height: 812), CGSize(width: 430, height: 932)] {
            let chrome = CameraChromeGeometry(size: size, kind: .photo)
            let factor = size.width / 375
            XCTAssertEqual(chrome.preview.minY / factor, 106, accuracy: 0.1)
            XCTAssertEqual(chrome.preview.maxY / factor, 606, accuracy: 0.1)
            XCTAssertEqual(chrome.shutterY / factor, 661.67, accuracy: 0.1)
            XCTAssertEqual(chrome.zoomY / factor, 570, accuracy: 0.1)
            XCTAssertGreaterThan(chrome.shutterY - chrome.shutterDiameter / 2, chrome.preview.maxY)
            XCTAssertLessThan(chrome.bottomY + chrome.bottomDiameter / 2, size.height)
            let dragged = CameraLayout(x: 1, y: 0).moved(by: CGSize(width: 0, height: 2000), in: chrome.preview.size)
            let pip = dragged.pipRect(in: chrome.preview.size)
            XCTAssertEqual(pip.maxY, chrome.preview.height, accuracy: 0.001)
        }
    }

    func testWidePreviewContainsTopControlsAndEndsAboveBottomRow() {
        for size in [CGSize(width: 375, height: 812), CGSize(width: 393, height: 852), CGSize(width: 430, height: 932)] {
            for kind in [CaptureKind.photo, .video] {
                let chrome = CameraChromeGeometry(size: size, kind: kind, aspect: .wide)
                XCTAssertEqual(chrome.preview.width / chrome.preview.height, 9.0 / 16, accuracy: 0.00001)
                XCTAssertLessThan(chrome.preview.minY, chrome.topControlsY - 22 * chrome.scale)
                XCTAssertEqual(chrome.bottomY - chrome.bottomDiameter / 2 - chrome.preview.maxY, 20 * chrome.scale, accuracy: 0.01)
                XCTAssertGreaterThan(chrome.preview.maxY, chrome.shutterY + chrome.shutterDiameter / 2)
                XCTAssertGreaterThanOrEqual(chrome.preview.minY, 0)
            }
        }
    }

    func testCaptureAspectsKeepInsetIndependentAndLegacyLayoutReadable() throws {
        let old = try JSONDecoder().decode(CameraLayout.self, from: Data(#"{"frontIsPrimary":false,"x":1,"y":1}"#.utf8))
        XCTAssertNil(old.aspect)
        XCTAssertNil(old.insetAspectRatio)
        XCTAssertEqual(old.pipRect(in: CGSize(width: 400, height: 600)).height, 180)
        for aspect in CaptureAspect.allCases {
            let chrome = CameraChromeGeometry(size: CGSize(width: 393, height: 852), kind: .photo, aspect: aspect)
            var layout = CameraLayout(aspect: aspect, insetAspectRatio: 0.75, x: 1, y: 1)
            XCTAssertEqual(chrome.preview.width / chrome.preview.height, aspect.ratio, accuracy: 0.001)
            let inset = layout.pipRect(in: chrome.preview.size)
            XCTAssertEqual(inset.width / inset.height, 0.75, accuracy: 0.001)
            layout.frontIsPrimary = true
            XCTAssertEqual(layout.pipRect(in: chrome.preview.size), inset)
            let moved = layout.moved(by: CGSize(width: 2000, height: 2000), in: chrome.preview.size)
            XCTAssertEqual(moved.pipRect(in: chrome.preview.size).maxY, chrome.preview.height, accuracy: 0.001)
        }
    }

    func testPipReachesAllEdgesAcrossAspectsAndOrientations() {
        for aspect in CaptureAspect.allCases {
            for landscape in [false, true] {
                let ratio = landscape ? 1 / aspect.ratio : aspect.ratio
                let size = CGSize(width: 393, height: 393 / ratio)
                let layout = CameraLayout(aspect: aspect, insetAspectRatio: landscape ? 4.0 / 3 : 0.75,
                                          pipEdgeToEdge: true, x: 0.5, y: 0.5)
                for x in [-1.0, 1.0] {
                    for y in [-1.0, 1.0] {
                        let moved = layout.moved(by: CGSize(width: x * 2000, height: y * 2000), in: size)
                        let rect = moved.pipRect(in: size)
                        XCTAssertEqual(x < 0 ? rect.minX : rect.maxX, x < 0 ? 0 : size.width, accuracy: 0.001)
                        XCTAssertEqual(y < 0 ? rect.minY : rect.maxY, y < 0 ? 0 : size.height, accuracy: 0.001)
                        XCTAssertEqual(rect.size, layout.pipRect(in: size).size)
                        let exportSize = CGSize(width: size.width * 4, height: size.height * 4)
                        let exportRect = moved.pipRect(in: exportSize)
                        XCTAssertEqual(exportRect.minX, rect.minX * 4, accuracy: 0.001)
                        XCTAssertEqual(exportRect.minY, rect.minY * 4, accuracy: 0.001)
                    }
                }
                let before = layout.pipRect(in: size)
                let after = layout.moved(by: CGSize(width: 12, height: -18), in: size).pipRect(in: size)
                XCTAssertEqual(after.minX - before.minX, 12, accuracy: 0.001)
                XCTAssertEqual(after.minY - before.minY, -18, accuracy: 0.001)
            }
        }
        let narrowHeight = CGSize(width: 900, height: 100)
        let rect = CameraLayout(insetAspectRatio: 0.75, pipEdgeToEdge: true).pipRect(in: narrowHeight)
        XCTAssertLessThanOrEqual(rect.maxY, narrowHeight.height)
        XCTAssertEqual(rect.width / rect.height, 0.75, accuracy: 0.001)
    }

    func testLegacyPipKeepsSavedPositionAndMigratesWithoutJump() throws {
        let data = Data(#"{"frontIsPrimary":false,"x":1,"y":1}"#.utf8)
        let old = try JSONDecoder().decode(CameraLayout.self, from: data)
        let size = CGSize(width: 400, height: 600)
        XCTAssertNil(old.pipEdgeToEdge)
        let original = CGRect(x: 270, y: 410, width: 120, height: 180)
        XCTAssertEqual(old.pipRect(in: size), original)
        let decoded = try JSONDecoder().decode(CameraLayout.self, from: JSONEncoder().encode(old))
        XCTAssertEqual(decoded.pipRect(in: size), original)
        let zero = old.moved(by: .zero, in: size)
        XCTAssertEqual(zero.pipEdgeToEdge, true)
        XCTAssertEqual(zero.pipRect(in: size), original)
        let moved = old.moved(by: CGSize(width: -40, height: -30), in: size)
        XCTAssertEqual(moved.pipRect(in: size), original.offsetBy(dx: -40, dy: -30))
        XCTAssertEqual(try JSONDecoder().decode(CameraLayout.self, from: JSONEncoder().encode(moved)), moved)
        let corner = old.moved(by: CGSize(width: 2000, height: 2000), in: size).pipRect(in: size)
        XCTAssertEqual(corner.maxX, size.width)
        XCTAssertEqual(corner.maxY, size.height)
        XCTAssertEqual(old.pipRect(in: size), original)
    }

    func testEdgePipPhotoExportsMatchSavedCorners() throws {
        for aspect in CaptureAspect.allCases {
            for x in [0.0, 1.0] {
                for y in [0.0, 1.0] {
                    let layout = CameraLayout(aspect: aspect, insetAspectRatio: 0.75, pipEdgeToEdge: true, x: x, y: y)
                    let draft = try disk.createDraft(kind: .photo, layout: layout)
                    try XCTUnwrap(solid(.red).jpegData(compressionQuality: 1)).write(to: draft.rearURL)
                    try XCTUnwrap(solid(.blue).jpegData(compressionQuality: 1)).write(to: draft.frontURL)
                    let item = try disk.finish(draft, rear: true, front: true)
                    let output = root.appendingPathComponent("edge-\(draft.item.id).jpg")
                    try MediaExporter.makePhoto(item: item, rearURL: draft.rearURL, frontURL: draft.frontURL, outputURL: output)
                    let image = try XCTUnwrap(UIImage(contentsOfFile: output.path)?.cgImage)
                    let size = CGSize(width: image.width, height: image.height)
                    let pip = layout.pipRect(in: size)
                    // Probe just inside each flush edge, beyond the rounded corners and border.
                    let nearX = x == 0 ? 0.012 : 0.988
                    let nearY = y == 0 ? 0.012 : 0.988
                    XCTAssertGreaterThan(pixel(image, x: nearX, y: pip.midY / size.height).b, 220)
                    XCTAssertGreaterThan(pixel(image, x: pip.midX / size.width, y: nearY).b, 220)
                    XCTAssertGreaterThan(pixel(image, x: 0.5, y: 0.5).r, 220)
                }
            }
        }
    }

    func testEdgePipVideoExportUsesRecordedCornerChanges() async throws {
        let first = CameraLayout(aspect: .wide, insetAspectRatio: 0.75, pipEdgeToEdge: true, x: 0, y: 1)
        var last = first; last.x = 1; last.y = 0
        let draft = try disk.createDraft(kind: .video, layout: first)
        try await DebugFixtures.writeMovie(to: draft.rearURL, front: false, seconds: 2)
        try await DebugFixtures.writeMovie(to: draft.frontURL, front: true, seconds: 2)
        var item = try disk.finish(draft, rear: true, front: true, duration: 2,
                                  moments: [LayoutMoment(seconds: 0, layout: first), LayoutMoment(seconds: 1, layout: last)])
        item.videoProfile = .init(resolution: .hd)
        let output = root.appendingPathComponent("edge-video.mov")
        try await MediaExporter.makeVideo(item: item, rearURL: draft.rearURL, frontURL: draft.frontURL, outputURL: output)
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: output))
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        for (seconds, layout) in [(0.3, first), (1.3, last)] {
            let image = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
            let size = CGSize(width: image.width, height: image.height), rect = layout.pipRect(in: CGSize(width: image.width, height: image.height))
            let nearX = layout.x == 0 ? 0.012 : 0.988
            let nearY = layout.y == 0 ? 0.012 : 0.988
            for sample in [pixel(image, x: nearX, y: rect.midY / size.height), pixel(image, x: rect.midX / size.width, y: nearY)] {
                XCTAssertGreaterThan(sample.r, sample.g + 15)
            }
            let main = pixel(image, x: 0.5, y: 0.5)
            XCTAssertGreaterThan(main.g, main.r + 15)
        }
    }

    func testEveryPhotoAspectExportsBothViewsAndPreservesFullOriginals() throws {
        for aspect in CaptureAspect.allCases {
            let layout = CameraLayout(aspect: aspect, insetAspectRatio: 0.75)
            let draft = try disk.createDraft(kind: .photo, layout: layout)
            let rear = try XCTUnwrap(solid(.red).jpegData(compressionQuality: 1))
            let front = try XCTUnwrap(solid(.blue).jpegData(compressionQuality: 1))
            try rear.write(to: draft.rearURL); try front.write(to: draft.frontURL)
            var item = try disk.finish(draft, rear: true, front: true)
            XCTAssertEqual(try disk.load().first(where: { $0.id == item.id })?.capturedLayout.aspect, aspect)
            for swapped in [false, true] {
                var changed = layout; changed.frontIsPrimary = swapped; item.layoutOverride = changed
                let output = root.appendingPathComponent("aspect-\(aspect.rawValue)-\(swapped).jpg")
                try MediaExporter.makePhoto(item: item, rearURL: draft.rearURL, frontURL: draft.frontURL, outputURL: output)
                let image = try XCTUnwrap(UIImage(contentsOfFile: output.path)?.cgImage)
                XCTAssertEqual(CGFloat(image.width) / CGFloat(image.height), aspect.ratio, accuracy: 0.005)
                let main = pixel(image, x: 0.15, y: 0.15)
                let pip = changed.pipRect(in: CGSize(width: image.width, height: image.height))
                let inset = pixel(image, x: pip.midX / Double(image.width), y: pip.midY / Double(image.height))
                XCTAssertGreaterThan(swapped ? main.b : main.r, 230)
                XCTAssertGreaterThan(swapped ? inset.r : inset.b, 230)
            }
            XCTAssertEqual(try Data(contentsOf: draft.rearURL), rear)
            XCTAssertEqual(try Data(contentsOf: draft.frontURL), front)
        }
    }

    func testLandscapePhotoAndVideoExportKeepsOrientationAndBothViews() async throws {
        for orientation in [CameraOrientation.landscapeLeft, .landscapeRight] {
            let layout = CameraLayout(aspect: .standard, insetAspectRatio: 4.0 / 3, orientation: orientation)
            let draft = try disk.createDraft(kind: .photo, layout: layout)
            try XCTUnwrap(solid(.red).jpegData(compressionQuality: 1)).write(to: draft.rearURL)
            try XCTUnwrap(solid(.blue).jpegData(compressionQuality: 1)).write(to: draft.frontURL)
            let item = try disk.finish(draft, rear: true, front: true)
            let target = root.appendingPathComponent("landscape-\(orientation.rawValue).jpg")
            try MediaExporter.makePhoto(item: item, rearURL: draft.rearURL, frontURL: draft.frontURL, outputURL: target)
            let image = try XCTUnwrap(UIImage(contentsOfFile: target.path)?.cgImage)
            XCTAssertEqual(Double(image.width) / Double(image.height), 4.0 / 3, accuracy: 0.01)
            XCTAssertGreaterThan(pixel(image, x: 0.1, y: 0.1).r, 230)
            let pip = layout.pipRect(in: CGSize(width: image.width, height: image.height))
            XCTAssertGreaterThan(pixel(image, x: pip.midX / Double(image.width), y: pip.midY / Double(image.height)).b, 230)
        }
        let layout = CameraLayout(aspect: .wide, insetAspectRatio: 4.0 / 3, orientation: .landscapeLeft)
        let draft = try disk.createDraft(kind: .video, layout: layout)
        try await DebugFixtures.writeMovie(to: draft.rearURL, front: false, seconds: 1)
        try await DebugFixtures.writeMovie(to: draft.frontURL, front: true, seconds: 1)
        var item = try disk.finish(draft, rear: true, front: true, duration: 1)
        item.videoProfile = .init(resolution: .hd)
        let target = root.appendingPathComponent("landscape-video.mov")
        try await MediaExporter.makeVideo(item: item, rearURL: draft.rearURL, frontURL: draft.frontURL, outputURL: target)
        let asset = AVURLAsset(url: target)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let outputSize = try await track.load(.naturalSize)
        XCTAssertEqual(outputSize, CGSize(width: 1280, height: 720))
    }

    func testVideoAndLiveRenderSizesFollowStoredAspect() async throws {
        let draft = try disk.createDraft(kind: .video, layout: CameraLayout())
        try await DebugFixtures.writeMovie(to: draft.rearURL, front: false, seconds: 1)
        try await DebugFixtures.writeMovie(to: draft.frontURL, front: true, seconds: 1)
        let base = try disk.finish(draft, rear: true, front: true, duration: 1)
        for aspect in CaptureAspect.allCases {
            for kind in [CaptureKind.photo, .video] {
                var item = base; item.kind = kind
                item.capturedLayout.aspect = aspect; item.capturedLayout.insetAspectRatio = 0.75
                let recipe = try await MediaExporter.videoRecipe(item: item, rearURL: draft.rearURL, frontURL: draft.frontURL)
                XCTAssertEqual(recipe.videoComposition.renderSize.width / recipe.videoComposition.renderSize.height, aspect.ratio, accuracy: 0.001)
                let output = root.appendingPathComponent("aspect-\(kind.rawValue)-\(aspect.rawValue).mov")
                try await MediaExporter.makeVideo(item: item, rearURL: draft.rearURL, frontURL: draft.frontURL, outputURL: output)
                let asset = AVURLAsset(url: output)
                let tracks = try await asset.loadTracks(withMediaType: .video)
                let size = try await XCTUnwrap(tracks.first).load(.naturalSize)
                XCTAssertEqual(size.width / size.height, aspect.ratio, accuracy: 0.001)
                let generator = AVAssetImageGenerator(asset: asset)
                let frame = try await generator.image(at: CMTime(seconds: 0.3, preferredTimescale: 600)).image
                XCTAssertGreaterThan(frame.width, 0)
            }
        }
    }

    func testDisablingLocationClearsCachedFixAndIgnoresLateCallbacks() {
        let provider = CaptureMetadataProvider()
        let location = CLLocation(latitude: 31, longitude: 121)
        provider.update(location: location)
        XCTAssertNotNil(provider.snapshot(cameras: []).location)
        provider.setLocationEnabled(false)
        provider.update(location: location)
        XCTAssertNil(provider.snapshot(cameras: []).location)
        provider.setLocationEnabled(true)
        XCTAssertNil(provider.snapshot(cameras: []).location)
        provider.update(location: location)
        XCTAssertNotNil(provider.snapshot(cameras: []).location)
    }

    func testPhotoFormatComparisonIncludesTheSecondCrop() {
        XCTAssertTrue(CameraFormatGeometry.supportsLiveBuffer(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange))
        XCTAssertTrue(CameraFormatGeometry.supportsLiveBuffer(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange))
        XCTAssertFalse(CameraFormatGeometry.supportsLiveBuffer(kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange))
        // Measured rear dual-wide formats on iPhone 15 Pro Max. The wider
        // nominal FOV of the 16:9 format is misleading after the photo crop.
        let video = CameraFormatGeometry.photoSpan(width: 1920, height: 1080, fieldOfView: 106.2007)
        let photo = CameraFormatGeometry.photoSpan(width: 1920, height: 1440, fieldOfView: 103.6253)
        XCTAssertGreaterThan(photo / video, 1.25)
        XCTAssertEqual(CameraFormatGeometry.photoSpan(width: 0, height: 0, fieldOfView: 0), 0)
    }

    @MainActor
    func testCameraSwapKeepsVideoLayersInTheirOriginalContainers() {
        let rear = AVSampleBufferDisplayLayer(), front = AVSampleBufferDisplayLayer()
        let host = CameraVideoSurface.Host(frame: CGRect(x: 0, y: 0, width: 375, height: 812))
        let photo = CGRect(x: 0, y: 106, width: 375, height: 500)
        func surface(_ layout: CameraLayout, aperture: CGRect) -> CameraVideoSurface {
            CameraVideoSurface(rear: rear, front: front,
                               rearSize: CGSize(width: 1440, height: 1920),
                               frontSize: CGSize(width: 1440, height: 1920),
                               aperture: aperture, layout: layout)
        }
        host.update(surface(CameraLayout(), aperture: photo))
        let rearParent = rear.superlayer, frontParent = front.superlayer
        XCTAssertNotNil(rearParent)
        XCTAssertNotNil(frontParent)
        var swapped = CameraLayout(frontIsPrimary: true, x: 0, y: 0)
        for i in 0..<6 {
            swapped.frontIsPrimary.toggle()
            swapped.x = Double(i) / 5
            let aperture = i % 2 == 0 ? photo : CGRect(x: 0, y: 72, width: 375, height: 667)
            host.update(surface(swapped, aperture: aperture))
            XCTAssertTrue(rear.superlayer === rearParent)
            XCTAssertTrue(front.superlayer === frontParent)
            XCTAssertEqual(rearParent?.zPosition, swapped.frontIsPrimary ? 2 : 0)
            XCTAssertEqual(frontParent?.zPosition, swapped.frontIsPrimary ? 0 : 2)
            XCTAssertGreaterThan(rear.bounds.width, 0)
            XCTAssertGreaterThan(front.bounds.height, 0)
        }
    }

    func testPrimaryImageExtendsContinuouslyAcrossApertureEdges() {
        let aperture = CGRect(x: 0, y: 106, width: 375, height: 500)
        let image = CGSize(width: 1080, height: 1920)
        let frame = CameraImageGeometry.frame(imageSize: image, aperture: aperture)
        XCTAssertEqual(frame.midX, aperture.midX, accuracy: 0.001)
        XCTAssertEqual(frame.midY, aperture.midY, accuracy: 0.001)
        XCTAssertEqual(frame.height, 666.6667, accuracy: 0.001)
        // The sensor row at the dark/light seam is identical to the tap-focus
        // crop conversion. A separate screen-filling transform breaks this.
        for y in [CGFloat(0), 250, 500] {
            let sourceRow = (aperture.minY + y - frame.minY) / frame.height * image.height
            let focus = CameraFocusGeometry.imagePoint(CGPoint(x: 187.5, y: y),
                                                       viewSize: aperture.size, imageSize: image)
            XCTAssertEqual(sourceRow, focus.y, accuracy: 0.001)
        }
        // A full 4:3 source has no spare top/bottom pixels. It must not be
        // stretched or repeated to manufacture an outside-frame view.
        let fullPhoto = CameraImageGeometry.frame(imageSize: CGSize(width: 1440, height: 1920), aperture: aperture)
        XCTAssertEqual(fullPhoto.minY, aperture.minY, accuracy: 0.001)
        XCTAssertEqual(fullPhoto.width, aperture.width, accuracy: 0.001)
        XCTAssertEqual(fullPhoto.height, aperture.height, accuracy: 0.001)
    }

    func testStabilizedPreviewFocusAccountsForAspectFillCrop() {
        let view = CGSize(width: 375, height: 500)
        let image = CGSize(width: 1080, height: 1920)
        let center = CameraFocusGeometry.normalizedImagePoint(CGPoint(x: 187.5, y: 250), viewSize: view, imageSize: image)
        XCTAssertEqual(center.x, 0.5, accuracy: 0.00001)
        XCTAssertEqual(center.y, 0.5, accuracy: 0.00001)
        let corner = CameraFocusGeometry.normalizedImagePoint(.zero, viewSize: view, imageSize: image)
        XCTAssertEqual(corner.x, 0, accuracy: 0.00001)
        XCTAssertEqual(corner.y, 0.125, accuracy: 0.00001)
        let bottom = CameraFocusGeometry.normalizedImagePoint(CGPoint(x: 375, y: 500), viewSize: view, imageSize: image)
        XCTAssertEqual(bottom.x, 1, accuracy: 0.00001)
        XCTAssertEqual(bottom.y, 0.875, accuracy: 0.00001)
        // AVCaptureOutput's conversion API takes output pixels, not [0, 1].
        let pixels = CameraFocusGeometry.imagePoint(CGPoint(x: 187.5, y: 250), viewSize: view, imageSize: image)
        XCTAssertEqual(pixels.x, 540, accuracy: 0.00001)
        XCTAssertEqual(pixels.y, 960, accuracy: 0.00001)
        let croppedTop = CameraFocusGeometry.imagePoint(.zero, viewSize: view, imageSize: image)
        XCTAssertEqual(croppedTop.y, 240, accuracy: 0.00001)
        XCTAssertEqual(CameraFocusGeometry.normalizedImagePoint(.zero, viewSize: .zero, imageSize: image),
                       CGPoint(x: 0.5, y: 0.5))
    }

    func testStabilizationPolicyKeepsPreviewAndRecordingModesCompatible() {
        XCTAssertEqual(CameraStabilizationPolicy.preferred(for: .preview, connectionSupported: true,
                                                           formatSupports: { $0 == .previewOptimized }), .previewOptimized)
        XCTAssertEqual(CameraStabilizationPolicy.preferred(for: .preview, connectionSupported: true,
                                                           formatSupports: { $0 == .standard }), .off)
        XCTAssertEqual(CameraStabilizationPolicy.preferred(for: .recording, connectionSupported: true,
                                                           formatSupports: { $0 == .standard }), .standard)
        XCTAssertEqual(CameraStabilizationPolicy.preferred(for: .recording, connectionSupported: false,
                                                           formatSupports: { _ in true }), .off)
        XCTAssertEqual(CameraStabilizationPolicy.preferred(for: .recording, connectionSupported: true,
                                                           formatSupports: { _ in false }), .off)
        if #available(iOS 26.0, *) {
            XCTAssertEqual(CameraStabilizationPolicy.preferred(for: .recording, connectionSupported: true,
                                                               formatSupports: { _ in true }), .lowLatency)
        }
        XCTAssertFalse(CameraStabilizationPolicy.preferences(for: .recording).contains(.cinematicExtended))
        XCTAssertFalse(CameraStabilizationPolicy.preferences(for: .recording).contains(.previewOptimized))
    }

    func testZoomStopsFollowAvailableOpticsAndSensorCrop() {
        let pro14 = CameraZoomScale.stops(minimum: 0.5, telephoto: 3, sensorCrop: true,
                                          calibration: CameraFocalCalibration.known("iPhone15,2"))
        let max15 = CameraZoomScale.stops(minimum: 0.5, telephoto: 5, sensorCrop: true,
                                          calibration: CameraFocalCalibration.known("iPhone16,2"))
        XCTAssertEqual(pro14.map(\.factor), [0.5, 1, 2, 3])
        XCTAssertEqual(pro14.map(\.focalLength), [13, 24, 48, 77])
        XCTAssertEqual(max15.map(\.factor), [0.5, 1, 2, 5])
        XCTAssertEqual(max15.map(\.focalLength), [13, 24, 48, 120])
        XCTAssertEqual(CameraZoomScale.stops(minimum: 1, telephoto: nil, sensorCrop: false,
                                             calibration: nil).map(\.factor), [1])
        XCTAssertTrue(CameraZoomScale.stops(minimum: 0.5, telephoto: 4, sensorCrop: false,
                                            calibration: nil).allSatisfy { $0.focalLength == nil })
    }

    func testContinuousZoomIsSmoothBoundedAndReversible() {
        let range = 0.5...25.0
        let moved = CameraZoomScale.dragged(from: 2, points: 1, range: range)
        XCTAssertGreaterThan(moved, 2)
        XCTAssertLessThan(moved, 2.2)
        XCTAssertEqual(CameraZoomScale.dragged(from: moved, points: -1, range: range), 2, accuracy: 0.0001)
        XCTAssertEqual(CameraZoomScale.dragged(from: 2, points: 1000, range: range), 25)
        XCTAssertEqual(CameraZoomScale.dragged(from: 2, points: -1000, range: range), 0.5)
    }

    func testPhotoExportEmbedsDeviceAndGPSMetadata() throws {
        let draft = try photoPair(metadata: DebugFixtures.metadata())
        let item = try disk.finish(draft, rear: true, front: true)
        let output = root.appendingPathComponent("metadata.jpg")
        try MediaExporter.makePhoto(item: item, rearURL: draft.rearURL, frontURL: draft.frontURL, outputURL: output)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let tiff = try XCTUnwrap(properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any])
        let gps = try XCTUnwrap(properties[kCGImagePropertyGPSDictionary] as? [CFString: Any])
        XCTAssertEqual(tiff[kCGImagePropertyTIFFMake] as? String, "Apple")
        XCTAssertEqual(tiff[kCGImagePropertyTIFFModel] as? String, "iPhone 15 Pro Max")
        XCTAssertEqual(try XCTUnwrap(gps[kCGImagePropertyGPSLatitude] as? Double), 31.23040, accuracy: 0.00001)
        XCTAssertEqual(try XCTUnwrap(gps[kCGImagePropertyGPSLongitude] as? Double), 121.47370, accuracy: 0.00001)
    }

    func testLivePhotoExportPairsMergedPhotoAndMovie() async throws {
        let draft = try photoPair(metadata: DebugFixtures.metadata())
        try await DebugFixtures.writeMovie(to: draft.rearLiveURL, front: false, seconds: 3)
        try await DebugFixtures.writeMovie(to: draft.frontLiveURL, front: true, seconds: 3)
        let item = try disk.finish(draft, rear: true, front: true,
                                   rearLive: true, frontLive: true,
                                   livePhotoDuration: 3, livePhotoDisplayTime: 1.5)
        let photo = root.appendingPathComponent("merged-live.jpg")
        let movie = root.appendingPathComponent("merged-live.mov")
        try await MediaExporter.makeLivePhoto(item: item,
                                              rearPhotoURL: draft.rearURL, frontPhotoURL: draft.frontURL,
                                              rearMovieURL: draft.rearLiveURL, frontMovieURL: draft.frontLiveURL,
                                              photoOutputURL: photo, movieOutputURL: movie)

        let source = try XCTUnwrap(CGImageSourceCreateWithURL(photo as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let maker = try XCTUnwrap(properties[kCGImagePropertyMakerAppleDictionary] as? [String: Any])
        let photoIdentifier = try XCTUnwrap(maker["17"] as? String)

        let asset = AVURLAsset(url: movie)
        let formats = try await asset.load(.availableMetadataFormats)
        var metadata: [AVMetadataItem] = []
        for format in formats { metadata += try await asset.loadMetadata(for: format) }
        let movieIdentifier = metadata.first(where: { $0.identifier == .quickTimeMetadataContentIdentifier })?.stringValue
        XCTAssertEqual(movieIdentifier, photoIdentifier)
        let video = try await asset.loadTracks(withMediaType: .video)
        let timed = try await asset.loadTracks(withMediaType: .metadata)
        XCTAssertEqual(video.count, 1)
        XCTAssertEqual(timed.count, 1)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 3, accuracy: 0.12)
    }

    func testHEIFLivePhotoExportPairsMergedPhotoAndMovie() async throws {
        let draft = try photoPair(metadata: DebugFixtures.metadata())
        try await DebugFixtures.writeMovie(to: draft.rearLiveURL, front: false, seconds: 3)
        try await DebugFixtures.writeMovie(to: draft.frontLiveURL, front: true, seconds: 3)
        var item = try disk.finish(draft, rear: true, front: true,
                                   rearLive: true, frontLive: true,
                                   livePhotoDuration: 3, livePhotoDisplayTime: 1.5)
        item.photoProfile = PhotoCaptureProfile(format: .heif, processedFormat: .heif)
        let photo = root.appendingPathComponent("merged-live.heic")
        let movie = root.appendingPathComponent("merged-live.mov")
        try await MediaExporter.makeLivePhoto(item: item,
                                              rearPhotoURL: draft.rearURL, frontPhotoURL: draft.frontURL,
                                              rearMovieURL: draft.rearLiveURL, frontMovieURL: draft.frontLiveURL,
                                              photoOutputURL: photo, movieOutputURL: movie)

        let source = try XCTUnwrap(CGImageSourceCreateWithURL(photo as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let maker = try XCTUnwrap(properties[kCGImagePropertyMakerAppleDictionary] as? [String: Any])
        let photoIdentifier = try XCTUnwrap(maker["17"] as? String)

        let asset = AVURLAsset(url: movie)
        let formats = try await asset.load(.availableMetadataFormats)
        var metadata: [AVMetadataItem] = []
        for format in formats { metadata += try await asset.loadMetadata(for: format) }
        let movieIdentifier = metadata.first(where: { $0.identifier == .quickTimeMetadataContentIdentifier })?.stringValue
        XCTAssertEqual(movieIdentifier, photoIdentifier)
        let video = try await asset.loadTracks(withMediaType: .video)
        let timed = try await asset.loadTracks(withMediaType: .metadata)
        XCTAssertEqual(video.count, 1)
        XCTAssertEqual(timed.count, 1)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 3, accuracy: 0.12)
    }

    func testRollingLivePhotoBufferWritesSynchronizedDualMovies() async throws {
        let source = root.appendingPathComponent("live-buffer-source.mov")
        try await DebugFixtures.writeMovie(to: source, front: false, seconds: 4)
        let asset = AVURLAsset(url: source)
        let sourceTracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(sourceTracks.first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ])
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var samples: [CMSampleBuffer] = []
        // A physical camera uses the device host clock rather than a timeline
        // starting at zero. Keep that condition in the regression test.
        let hostClockOffset = CMTime(seconds: 43_210, preferredTimescale: 600)
        while let sample = output.copyNextSampleBuffer() {
            samples.append(try shifted(sample, by: hostClockOffset))
        }
        XCTAssertGreaterThan(samples.count, 100)

        let draft = try disk.createDraft(kind: .photo, layout: CameraLayout())
        let queue = DispatchQueue(label: "cam.tests.live-buffer")
        let result: (Bool, Bool, Double?, Double?, String?) = await withCheckedContinuation { continuation in
            queue.async {
                let buffer = LivePhotoBuffer(callbackQueue: queue)
                // At 8 fps the first frame after shutter + 1.5 s can exceed
                // the old 1/30 s cutoff. Both lanes must finish normally.
                buffer.configure(maxFramesPerSecond: 8, maxLongEdge: 640)
                buffer.setEnabled(true)
                for sample in samples.prefix(61) {
                    buffer.consumeVideo(sample, isFront: false)
                    buffer.consumeVideo(sample, isFront: true)
                }
                let started = buffer.beginCapture(draft: draft, audioSettings: nil) {
                    continuation.resume(returning: ($0, $1, $2, $3, $4))
                }
                XCTAssertTrue(started)
                for sample in samples.dropFirst(61) {
                    buffer.consumeVideo(sample, isFront: false)
                    buffer.consumeVideo(sample, isFront: true)
                }
            }
        }
        XCTAssertTrue(result.0)
        XCTAssertTrue(result.1)
        XCTAssertNil(result.4)
        XCTAssertFalse(FileManager.default.fileExists(atPath: draft.rearURL.path), "Live buffering must not substitute a video frame for the real still photo")
        XCTAssertFalse(FileManager.default.fileExists(atPath: draft.frontURL.path))
        XCTAssertEqual(try XCTUnwrap(result.2), 3, accuracy: 0.12)
        XCTAssertEqual(try XCTUnwrap(result.3), 1.5, accuracy: 0.12)
        for url in [draft.rearLiveURL, draft.frontLiveURL] {
            let movie = AVURLAsset(url: url)
            let tracks = try await movie.loadTracks(withMediaType: .video)
            let duration = try await movie.load(.duration).seconds
            XCTAssertEqual(tracks.count, 1)
            // The encoded track includes the final sampled frame's duration.
            XCTAssertEqual(duration, 3, accuracy: 0.17)
        }
    }
    func testSingleRollingLiveCompletesWithoutWaitingForTheOtherCamera() async throws {
        let source = root.appendingPathComponent("live-buffer-source.mov")
        try await DebugFixtures.writeMovie(to: source, front: false, seconds: 4)
        let asset = AVURLAsset(url: source)
        let sourceTracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(sourceTracks.first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ])
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var samples: [CMSampleBuffer] = []
        // A physical camera uses the device host clock rather than a timeline
        // starting at zero. Keep that condition in the regression test.
        let hostClockOffset = CMTime(seconds: 43_210, preferredTimescale: 600)
        while let sample = output.copyNextSampleBuffer() {
            samples.append(try shifted(sample, by: hostClockOffset))
        }
        XCTAssertGreaterThan(samples.count, 100)

        for selectedFront in [false, true] {
        let layout = CameraLayout(frontIsPrimary: selectedFront, singleCamera: true)
        let draft = try disk.createDraft(kind: .photo, layout: layout)
        let queue = DispatchQueue(label: "cam.tests.live-buffer")
        let result: (Bool, Bool, Double?, Double?, String?) = await withCheckedContinuation { continuation in
            queue.async {
                let buffer = LivePhotoBuffer(callbackQueue: queue)
                // At 8 fps the first frame after shutter + 1.5 s can exceed
                // the old 1/30 s cutoff. Both lanes must finish normally.
                buffer.configure(maxFramesPerSecond: 8, maxLongEdge: 640)
                buffer.setEnabled(true)
                for sample in samples.prefix(61) {
                    buffer.consumeVideo(sample, isFront: selectedFront)
                }
                let started = buffer.beginCapture(draft: draft, audioSettings: nil) {
                    continuation.resume(returning: ($0, $1, $2, $3, $4))
                }
                XCTAssertTrue(started)
                for sample in samples.dropFirst(61) {
                    buffer.consumeVideo(sample, isFront: selectedFront)
                }
            }
        }
        XCTAssertEqual(result.0, !selectedFront)
        XCTAssertEqual(result.1, selectedFront)
        XCTAssertNil(result.4)
        XCTAssertFalse(FileManager.default.fileExists(atPath: draft.rearURL.path), "Live buffering must not substitute a video frame for the real still photo")
        XCTAssertFalse(FileManager.default.fileExists(atPath: draft.frontURL.path))
        XCTAssertEqual(try XCTUnwrap(result.2), 3, accuracy: 0.12)
        XCTAssertEqual(try XCTUnwrap(result.3), 1.5, accuracy: 0.12)
        let selectedMovie = selectedFront ? draft.frontLiveURL : draft.rearLiveURL
        XCTAssertFalse(FileManager.default.fileExists(atPath: (selectedFront ? draft.rearLiveURL : draft.frontLiveURL).path))
        let selectedPhoto = selectedFront ? draft.frontURL : draft.rearURL
        try solid(.red).jpegData(compressionQuality: 1)!.write(to: selectedPhoto)
        let item = try disk.finish(draft, rear: !selectedFront, front: selectedFront,
            rearLive: result.0, frontLive: result.1, livePhotoDuration: result.2, livePhotoDisplayTime: result.3)
        XCTAssertTrue(item.isComplete); XCTAssertTrue(item.isLivePhoto)
        XCTAssertNotNil(item.livePhotoDisplayTime)
        try await MediaExporter.makeLivePhoto(item: item, rearPhotoURL: selectedPhoto, frontPhotoURL: selectedPhoto,
            rearMovieURL: selectedMovie, frontMovieURL: selectedMovie,
            photoOutputURL: draft.folder.appendingPathComponent("export.jpg"), movieOutputURL: draft.folder.appendingPathComponent("export-live.mov"))
        for url in [selectedMovie] {
            let movie = AVURLAsset(url: url)
            let tracks = try await movie.loadTracks(withMediaType: .video)
            let duration = try await movie.load(.duration).seconds
            XCTAssertEqual(tracks.count, 1)
            // The encoded track includes the final sampled frame's duration.
            XCTAssertEqual(duration, 3, accuracy: 0.17)
        }
        }
    }

    func testLiveWriterPreservesAudioWithHostClockTimestamps() async throws {
        let silent = root.appendingPathComponent("live-audio-source.mov")
        let source = root.appendingPathComponent("live-audio-source-with-tone.mov")
        try await DebugFixtures.writeMovie(to: silent, front: false, seconds: 2)
        try await addAudio(movie: silent, output: source)
        let asset = AVURLAsset(url: source)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let reader = try AVAssetReader(asset: asset)
        let video = AVAssetReaderTrackOutput(track: try XCTUnwrap(videoTracks.first), outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ])
        let audio = AVAssetReaderTrackOutput(track: try XCTUnwrap(audioTracks.first), outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM
        ])
        reader.add(video); reader.add(audio)
        XCTAssertTrue(reader.startReading())
        let offset = CMTime(seconds: 43_210, preferredTimescale: 600)
        var frames: [(CVPixelBuffer, CMTime)] = []
        var sound: [CMSampleBuffer] = []
        while let sample = video.copyNextSampleBuffer() {
            frames.append((try XCTUnwrap(CMSampleBufferGetImageBuffer(sample)),
                           CMSampleBufferGetPresentationTimeStamp(sample) + offset))
        }
        while let sample = audio.copyNextSampleBuffer() { sound.append(try shifted(sample, by: offset)) }
        XCTAssertEqual(reader.status, .completed)
        XCTAssertGreaterThan(sound.reduce(0) { $0 + CMSampleBufferGetNumSamples($1) }, 70_000)
        let draft = try disk.createDraft(kind: .photo, layout: CameraLayout())
        let timing = try RawLivePhotoWriter.write(rearFrames: frames, frontFrames: frames,
            audio: sound, audioSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
                                         AVSampleRateKey: 44100, AVNumberOfChannelsKey: 1,
                                         AVEncoderBitRateKey: 64000],
            shutterTime: offset + CMTime(seconds: 1, preferredTimescale: 600),
            rearURL: draft.rearLiveURL, frontURL: draft.frontLiveURL)
        XCTAssertNil(timing.note, "An encoder scheduling deadlock must not silently discard audio")
        for url in [draft.rearLiveURL, draft.frontLiveURL] {
            let movie = AVURLAsset(url: url)
            let tracks = try await movie.loadTracks(withMediaType: .audio)
            XCTAssertEqual(tracks.count, 1)
            let decoder = try AVAssetReader(asset: movie)
            let output = AVAssetReaderTrackOutput(track: try XCTUnwrap(tracks.first), outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM
            ])
            decoder.add(output)
            XCTAssertTrue(decoder.startReading())
            var decoded = 0
            while let sample = output.copyNextSampleBuffer() { decoded += CMSampleBufferGetNumSamples(sample) }
            XCTAssertEqual(decoder.status, .completed)
            XCTAssertGreaterThan(decoded, 70_000, "Both Live originals must contain decodable sound")
        }
    }

    func testModeDragTracksFingerAndResistsPastEndpoints() {
        for mode in CameraCaptureMode.allCases {
            let index = CameraModeDragPolicy.index(mode)
            XCTAssertEqual(CameraModeDragPolicy.offset(index * 64, from: mode), index * 64)
            XCTAssertEqual(CameraModeDragPolicy.offset(-(3 - index) * 64, from: mode), -(3 - index) * 64)
            XCTAssertLessThan(CameraModeDragPolicy.offset(500, from: mode), index * 64 + 18)
            XCTAssertGreaterThan(CameraModeDragPolicy.offset(-500, from: mode), -(3 - index) * 64 - 18)
            let samples = (-250...250).map { CameraModeDragPolicy.offset(CGFloat($0), from: mode) }
            XCTAssertTrue(zip(samples, samples.dropFirst()).allSatisfy { $0 <= $1 })
        }
    }

    func testModeShortSwipeNeverUsesMomentumOrSkipsAdjacentModes() {
        for mode in CameraCaptureMode.allCases {
            for distance in [CGFloat(-500), -130, -40, 40, 130, 500] {
                let result = CameraModeDragPolicy.destination(from: mode, translation: distance, predicted: distance * 50)
                XCTAssertLessThanOrEqual(abs(CameraModeDragPolicy.index(result) - CameraModeDragPolicy.index(mode)), 1)
                XCTAssertEqual(result, CameraModeDragPolicy.destination(from: mode, translation: distance, predicted: distance, idleTime: 2))
            }
        }
        XCTAssertEqual(CameraModeDragPolicy.destination(from: .dualPhoto, translation: 18, predicted: 1000), .dualPhoto)
        XCTAssertEqual(CameraModeDragPolicy.destination(from: .dualPhoto, translation: 40, predicted: 40), .dualVideo)
        XCTAssertEqual(CameraModeDragPolicy.destination(from: .dualVideo, translation: -40, predicted: -1000), .dualPhoto)
        XCTAssertEqual(CameraModeDragPolicy.destination(from: .dualPhoto, translation: 130, predicted: 130), .dualVideo)
        XCTAssertEqual(CameraModeDragPolicy.destination(from: .singleVideo, translation: -500, predicted: -500), .dualVideo)
        XCTAssertEqual(CameraModeDragPolicy.destination(from: .singlePhoto, translation: -50, predicted: -60), .singlePhoto)
        XCTAssertEqual(CameraModeDragPolicy.destination(from: .singleVideo, translation: 50, predicted: 60), .singleVideo)
        XCTAssertEqual(CameraModeDragPolicy.destination(from: .dualPhoto, translation: .nan, predicted: 60), .dualPhoto)
    }

    func testModeSwipeTracksOneDetentEvenDuringSlowUninterruptedMotion() {
        for secondsPerMove in [0.015, 0.1] {
            var session = CameraModeDragSession(origin: .singleVideo, time: 0)
            var detents: [CameraCaptureMode] = []
            for step in 1...25 {
                if let next = session.update(translation: CGSize(width: -step * 10, height: 0), time: Double(step) * secondsPerMove) { detents.append(next) }
            }
            XCTAssertFalse(session.continuous)
            XCTAssertEqual(session.selection, .dualVideo)
            XCTAssertEqual(detents, [.dualVideo])
            XCTAssertGreaterThan(session.offset, -82)
            XCTAssertNil(session.update(translation: CGSize(width: -250, height: 0), time: 3))
            XCTAssertFalse(session.continuous, "A stationary release must never turn the previous swipe into a scrub")
        }
    }

    func testModeHeldScrubReportsEveryDetentOnceAndNoEndpointFeedback() {
        var session = CameraModeDragSession(origin: .singleVideo, time: 0)
        XCTAssertNil(session.update(translation: CGSize(width: 2, height: 1), time: 0.2))
        var detents: [CameraCaptureMode] = []
        for step in 1...25 {
            if let next = session.update(translation: CGSize(width: -step * 10, height: 0), time: 0.35 + Double(step) * 0.015) { detents.append(next) }
        }
        XCTAssertTrue(session.continuous)
        XCTAssertEqual(detents, [.dualVideo, .dualPhoto, .singlePhoto])
        XCTAssertEqual(session.selection, .singlePhoto)
        XCTAssertNil(session.update(translation: CGSize(width: -500, height: 0), time: 0.9))
        for step in (0...24).reversed() {
            if let next = session.update(translation: CGSize(width: -step * 10, height: 0), time: 1 + Double(24 - step) * 0.02) { detents.append(next) }
        }
        XCTAssertEqual(Array(detents.suffix(3)), [.dualPhoto, .dualVideo, .singleVideo])
    }

    func testModePauseThenContinueDoesNotCatchUpEarlierOvershoot() {
        var session = CameraModeDragSession(origin: .singleVideo, time: 0)
        XCTAssertEqual(session.update(translation: CGSize(width: -200, height: 0), time: 0.08), .dualVideo)
        XCTAssertFalse(session.continuous)
        let before = session.offset
        XCTAssertNil(session.update(translation: CGSize(width: -205, height: 0), time: 0.5))
        XCTAssertTrue(session.continuous)
        XCTAssertEqual(session.offset, before - 5, accuracy: 0.001)
        XCTAssertEqual(session.selection, .dualVideo)
        XCTAssertEqual(session.update(translation: CGSize(width: -250, height: 0), time: 0.55), .dualPhoto)
    }

    func testModeDetentsIgnoreBoundaryJitterVerticalMotionAndMissingModes() {
        var session = CameraModeDragSession(origin: .dualPhoto, time: 0)
        XCTAssertEqual(session.update(translation: CGSize(width: 40, height: 0), time: 0.05), .dualVideo)
        for step in 0..<20 {
            XCTAssertNil(session.update(translation: CGSize(width: step.isMultiple(of: 2) ? 31 : 34, height: 0), time: 0.1 + Double(step) * 0.01))
        }
        XCTAssertEqual(session.update(translation: CGSize(width: 20, height: 0), time: 0.31), .dualPhoto)
        var vertical = CameraModeDragSession(origin: .dualPhoto, time: 0)
        XCTAssertNil(vertical.update(translation: CGSize(width: 4, height: 40), time: 0.4))
        XCTAssertNil(vertical.update(translation: CGSize(width: 150, height: 100), time: 0.5))
        XCTAssertEqual(vertical.selection, .dualPhoto)
        XCTAssertEqual(vertical.offset, 0)
        var single = CameraModeDragSession(origin: .singlePhoto, modes: [.singleVideo, .singlePhoto], time: 0)
        XCTAssertEqual(single.update(translation: CGSize(width: 130, height: 0), time: 0.1), .singleVideo)
        XCTAssertNil(single.update(translation: CGSize(width: 300, height: 0), time: 0.2))
        XCTAssertNil(single.update(translation: CGSize(width: CGFloat.infinity, height: 0), time: 0.3))
        XCTAssertEqual(single.selection, .singleVideo)
    }

    func testModeTapUsesVisibleLabelPositionsAfterEitherSelection() {
        XCTAssertEqual(CameraCaptureMode.allCases, [.singleVideo, .dualVideo, .dualPhoto, .singlePhoto])
        for mode in CameraCaptureMode.allCases {
            XCTAssertEqual(CameraModeDragPolicy.tapped(at: 101.5, from: mode), mode)
        }
        XCTAssertEqual(CameraModeDragPolicy.tapped(at: 37.5, from: .dualPhoto), .dualVideo)
        XCTAssertEqual(CameraModeDragPolicy.tapped(at: 165.5, from: .dualPhoto), .singlePhoto)
        XCTAssertEqual(CameraModeDragPolicy.tapped(at: 37.5, from: .dualVideo), .singleVideo)
        XCTAssertEqual(CameraCaptureMode.restored(""), .dualPhoto)
        XCTAssertEqual(CameraCaptureMode.restored("photo"), .dualPhoto)
        XCTAssertEqual(CameraCaptureMode.restored("video"), .dualVideo)
        for mode in CameraCaptureMode.allCases { XCTAssertEqual(CameraCaptureMode.restored(mode.rawValue), mode) }
    }

    func testSinglePhotoCompletenessExportAndAutomaticAlbumNeverDuplicateTheSource() async throws {
        for mode in AlbumSaveMode.allCases {
            for front in [false, true] {
                let layout = CameraLayout(frontIsPrimary: front, singleCamera: true, aspect: .square)
                let draft = try disk.createDraft(kind: .photo, layout: layout, albumSaveMode: mode)
                let url = front ? draft.frontURL : draft.rearURL
                let sourceData = try XCTUnwrap(solid(.red).jpegData(compressionQuality: 1))
                try sourceData.write(to: url)
                let item = try disk.finish(draft, rear: !front, front: front)
                XCTAssertTrue(item.isComplete)
                XCTAssertFalse(item.isLivePhoto)
                var calls = 0
                try await AutomaticAlbumExport.save(item, disk: disk) { batch, snapshot in
                    XCTAssertEqual(batch.count, 1)
                    let media = try XCTUnwrap(batch.first)
                    calls += 1
                    XCTAssertNil(media.pairedMovie)
                    let image = try XCTUnwrap(UIImage(contentsOfFile: media.file.path)?.cgImage)
                    XCTAssertEqual(image.width, image.height)
                    // The old PiP border location must also remain the original red.
                    let sample = self.pixel(image, x: 0.70, y: 0.82)
                    XCTAssertGreaterThan(sample.r, 230); XCTAssertLessThan(sample.g, 20)
                    return ["single-test-asset"]
                }
                XCTAssertEqual(calls, 1)
                XCTAssertEqual(try Data(contentsOf: url), sourceData)
                XCTAssertFalse(FileManager.default.fileExists(atPath: (front ? draft.rearURL : draft.frontURL).path))
                XCTAssertTrue(try disk.load().first(where: { $0.id == item.id })!.isComplete)
                var missingPair = item; missingPair.capturedLayout.singleCamera = nil
                XCTAssertFalse(missingPair.isComplete, "Legacy partial dual captures must never be treated as single")
                XCTAssertNil(missingPair.renderFile(front: !front))
            }
        }
        let legacy = try JSONDecoder().decode(CameraLayout.self, from: Data(#"{"frontIsPrimary":false,"x":1,"y":0}"#.utf8))
        XCTAssertTrue(legacy.isDual)
    }

    func testShutterGestureStartsInEveryDirectionAndLocksOnlyAtRightTarget() {
        XCTAssertFalse(ShutterGesturePolicy.shouldStartVideo(translation: CGSize(width: 8, height: 8)))
        XCTAssertTrue(ShutterGesturePolicy.shouldStartVideo(translation: CGSize(width: 13, height: 0)))
        XCTAssertTrue(ShutterGesturePolicy.shouldStartVideo(translation: CGSize(width: -13, height: 0)))
        XCTAssertTrue(ShutterGesturePolicy.shouldStartVideo(translation: CGSize(width: 0, height: 13)))
        XCTAssertTrue(ShutterGesturePolicy.shouldStartVideo(translation: CGSize(width: 0, height: -13)))
        XCTAssertFalse(ShutterGesturePolicy.shouldLock(translation: CGSize(width: 30, height: -80)))
        XCTAssertFalse(ShutterGesturePolicy.shouldLock(translation: CGSize(width: 100, height: 0)))
        XCTAssertTrue(ShutterGesturePolicy.shouldLock(translation: CGSize(width: 120, height: 10)))
        XCTAssertFalse(ShutterGesturePolicy.shouldLock(translation: CGSize(width: 140, height: 100)))
        XCTAssertFalse(ShutterGesturePolicy.shouldLock(translation: CGSize(width: -140, height: 0)))
        XCTAssertEqual(ShutterGesturePolicy.thumbOffset(translation: CGSize(width: -50, height: 0)), 0)
        XCTAssertEqual(ShutterGesturePolicy.thumbOffset(translation: CGSize(width: 500, height: 0)), 133.5)
    }

    func testPhotoCompletionCannotReleaseOverlappingVideoSave() {
        let recordingPhoto = CaptureActivity(recording: true, savingVideo: false, takingPhoto: true)
        XCTAssertTrue(recordingPhoto.isBusy)
        XCTAssertTrue(recordingPhoto.canUseShutter, "Stopping must remain available while a recording photo is processing")
        XCTAssertFalse(recordingPhoto.canEndBackgroundSave)
        for photoRemaining in [true, false] {
            let saving = CaptureActivity(recording: false, savingVideo: true, takingPhoto: photoRemaining)
            XCTAssertEqual(saving.isBusy, photoRemaining)
            XCTAssertEqual(saving.canUseShutter, !photoRemaining)
            XCTAssertFalse(saving.canEndBackgroundSave)
        }
        let photoLast = CaptureActivity(recording: false, savingVideo: false, takingPhoto: true)
        XCTAssertFalse(photoLast.canEndBackgroundSave)
        let done = CaptureActivity(recording: false, savingVideo: false, takingPhoto: false)
        XCTAssertTrue(done.canEndBackgroundSave)
        XCTAssertFalse(done.isBusy)
    }

    func testPairedShutterSoundRespectsDeviceRestrictionsAndPrimarySwap() {
        XCTAssertFalse(PhotoShutterSoundPolicy.suppress(isPrimary: true, supported: true))
        XCTAssertTrue(PhotoShutterSoundPolicy.suppress(isPrimary: false, supported: true))
        XCTAssertFalse(PhotoShutterSoundPolicy.suppress(isPrimary: true, supported: false))
        XCTAssertFalse(PhotoShutterSoundPolicy.suppress(isPrimary: false, supported: false))
        for frontPrimary in [true, false] {
            let rear = PhotoShutterSoundPolicy.suppress(isPrimary: !frontPrimary, supported: true)
            let front = PhotoShutterSoundPolicy.suppress(isPrimary: frontPrimary, supported: true)
            XCTAssertNotEqual(rear, front)
            for isPrimary in [frontPrimary, !frontPrimary] {
                XCTAssertTrue(PhotoShutterSoundPolicy.suppress(isPrimary: isPrimary, supported: true, soundEnabled: false))
                XCTAssertFalse(PhotoShutterSoundPolicy.suppress(isPrimary: isPrimary, supported: false, soundEnabled: false))
            }
        }
    }

    func testShutterSoundDefaultsOnPersistsAndSyncsToLockedCapture() {
        let sourceName = "shutter-source-\(UUID())", targetName = "shutter-target-\(UUID())"
        let source = UserDefaults(suiteName: sourceName)!, target = UserDefaults(suiteName: targetName)!
        defer { source.removePersistentDomain(forName: sourceName); target.removePersistentDomain(forName: targetName) }
        XCTAssertTrue(PhotoShutterSoundPolicy.isEnabled(source))
        XCTAssertEqual(CameraPreferenceStore.snapshot(source)["cameraShutterSound"], "true")
        // Launch arguments may be stored as strings by Foundation.
        source.set("NO", forKey: "cameraShutterSound")
        XCTAssertFalse(PhotoShutterSoundPolicy.isEnabled(source))
        XCTAssertEqual(CameraPreferenceStore.snapshot(source)["cameraShutterSound"], "false")
        for enabled in [false, true] {
            source.set(enabled, forKey: "cameraShutterSound")
            XCTAssertEqual(PhotoShutterSoundPolicy.isEnabled(UserDefaults(suiteName: sourceName)!), enabled)
            CameraPreferenceStore.apply(CameraPreferenceStore.snapshot(source), to: target)
            XCTAssertEqual(PhotoShutterSoundPolicy.isEnabled(target), enabled)
            // Older app contexts must not reset this new preference.
            CameraPreferenceStore.apply(["cameraPhotoAspect": "1:1"], to: target)
            XCTAssertEqual(PhotoShutterSoundPolicy.isEnabled(target), enabled)
        }
    }

    func testFocusGeometryRoutesMainAndInsetCoordinatesToTheirOwnLenses() {
        let size = CGSize(width: 430, height: 573)
        let layout = CameraLayout(frontIsPrimary: false, x: 1, y: 1)
        let main = CameraFocusRequest.main(at: CGPoint(x: 120, y: 180), size: size,
                                           front: layout.frontIsPrimary, locked: false)
        XCTAssertFalse(main.isFront)
        XCTAssertEqual(main.previewPoint, CGPoint(x: 120, y: 180))
        XCTAssertEqual(main.previewSize, size)

        let pip = layout.pipRect(in: size)
        let displayPoint = CGPoint(x: pip.midX + 12, y: pip.midY - 9)
        let inset = CameraFocusRequest.pip(at: displayPoint, rect: pip, containerSize: size,
                                          front: !layout.frontIsPrimary, locked: true)
        XCTAssertTrue(inset.isFront)
        XCTAssertTrue(inset.locked)
        XCTAssertEqual(inset.displayPoint, displayPoint)
        XCTAssertEqual(inset.previewPoint.x, pip.width / 2 + 12, accuracy: 0.001)
        XCTAssertEqual(inset.previewPoint.y, pip.height / 2 - 9, accuracy: 0.001)
        XCTAssertEqual(inset.previewSize, pip.size)

        let swapped = CameraFocusRequest.main(at: CGPoint(x: 10, y: 20), size: size,
                                              front: true, locked: false)
        XCTAssertTrue(swapped.isFront)
    }

    func testFocusExposureBiasFollowsVerticalDragAndClamps() {
        XCTAssertEqual(CameraFocusGeometry.exposureBias(current: 0, verticalDelta: -70), 1, accuracy: 0.001)
        XCTAssertEqual(CameraFocusGeometry.exposureBias(current: 0, verticalDelta: 70), -1, accuracy: 0.001)
        XCTAssertEqual(CameraFocusGeometry.exposureBias(current: 1.8, verticalDelta: -70), 2, accuracy: 0.001)
        XCTAssertEqual(CameraFocusGeometry.exposureBias(current: -1.8, verticalDelta: 70), -2, accuracy: 0.001)
    }

    func testPhotoExportPlacesBothViewsAndSwapsWithoutTouchingOriginals() throws {
        let draft = try photoPair()
        var item = try disk.finish(draft, rear: true, front: true)
        let output = root.appendingPathComponent("merged.jpg")
        try MediaExporter.makePhoto(item: item, rearURL: draft.rearURL, frontURL: draft.frontURL, outputURL: output)
        let image = try XCTUnwrap(UIImage(contentsOfFile: output.path)?.cgImage)
        let main = pixel(image, x: 0.2, y: 0.2)
        let pip = pixel(image, x: 0.82, y: 0.82)
        XCTAssertGreaterThan(main.r, 230)
        XCTAssertLessThan(main.b, 30)
        XCTAssertGreaterThan(pip.b, 230)
        XCTAssertLessThan(pip.r, 30)
        item.layoutOverride = CameraLayout(frontIsPrimary: true, x: 0, y: 0)
        let swapped = root.appendingPathComponent("swapped.jpg")
        try MediaExporter.makePhoto(item: item, rearURL: draft.rearURL, frontURL: draft.frontURL, outputURL: swapped)
        let swappedImage = try XCTUnwrap(UIImage(contentsOfFile: swapped.path)?.cgImage)
        XCTAssertGreaterThan(pixel(swappedImage, x: 0.8, y: 0.8).b, 230)
        XCTAssertGreaterThan(pixel(swappedImage, x: 0.17, y: 0.17).r, 230)
        XCTAssertEqual(CGFloat(image.width) / CGFloat(image.height), 0.75, accuracy: 0.005)
    }

    func testMissingOriginalIsReportedAndExportDoesNotCreateAnAsset() throws {
        let draft = try photoPair()
        let item = try disk.finish(draft, rear: true, front: true)
        try FileManager.default.removeItem(at: draft.frontURL)
        let loaded = try XCTUnwrap(disk.load().first)
        XCTAssertFalse(loaded.isComplete)
        XCTAssertNotNil(loaded.rearFile)
        XCTAssertNotNil(loaded.captureNote)
        let output = root.appendingPathComponent("must-not-exist.jpg")
        XCTAssertThrowsError(try MediaExporter.makePhoto(item: item, rearURL: draft.rearURL, frontURL: draft.frontURL, outputURL: output))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    @MainActor
    func testInterruptedPhotoRecoversOnlyReadableOriginal() async throws {
        let draft = try disk.createDraft(kind: .photo, layout: CameraLayout())
        try solid(.red).jpegData(compressionQuality: 1)!.write(to: draft.rearURL)
        let library = MediaLibrary(disk: disk)
        library.work.setPhase(.browsing)
        await library.recoverInterruptedCaptures()
        let item = try XCTUnwrap(library.items.first)
        XCTAssertNotNil(item.rearFile)
        XCTAssertNil(item.frontFile)
        XCTAssertFalse(item.isComplete)
        XCTAssertTrue(FileManager.default.fileExists(atPath: draft.rearURL.path))
    }

    func testVideoExportHasOnePictureOneAudioAndRecordedLayoutSwitch() async throws {
        let draft = try disk.createDraft(kind: .video, layout: CameraLayout(), metadata: DebugFixtures.metadata())
        let rearSilent = root.appendingPathComponent("rear-silent.mov")
        let frontSilent = root.appendingPathComponent("front-silent.mov")
        try await DebugFixtures.writeMovie(to: rearSilent, front: false)
        try await DebugFixtures.writeMovie(to: frontSilent, front: true)
        try await addAudio(movie: rearSilent, output: draft.rearURL)
        try await addAudio(movie: frontSilent, output: draft.frontURL)
        let item = try disk.finish(draft, rear: true, front: true, duration: 2, moments: [
            LayoutMoment(seconds: 0, layout: CameraLayout()),
            LayoutMoment(seconds: 1, layout: CameraLayout(frontIsPrimary: true, x: 1, y: 1))
        ])
        let output = root.appendingPathComponent("merged.mov")
        try await MediaExporter.makeVideo(item: item, rearURL: draft.rearURL, frontURL: draft.frontURL, outputURL: output)
        let asset = AVURLAsset(url: output)
        let video = try await asset.loadTracks(withMediaType: .video)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(video.count, 1)
        XCTAssertEqual(audio.count, 1)
        XCTAssertEqual(duration, 2, accuracy: 0.1)
        let dimensions = try await video[0].load(.naturalSize)
        XCTAssertEqual(dimensions, CGSize(width: 1080, height: 1920))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let early = try await generator.image(at: CMTime(seconds: 0.3, preferredTimescale: 600)).image
        let late = try await generator.image(at: CMTime(seconds: 1.3, preferredTimescale: 600)).image
        let first = pixel(early, x: 0.2, y: 0.2)
        let second = pixel(late, x: 0.2, y: 0.2)
        XCTAssertGreaterThan(first.g, first.r + 20, "Rear scene should initially be the main image")
        XCTAssertGreaterThan(second.r, second.g + 20, "Front scene should be the main image after the recorded swap")
        let earlyPip = pixel(early, x: 0.82, y: 0.82)
        XCTAssertGreaterThan(earlyPip.r, earlyPip.g + 15, "Front camera must exist in the inset")
        let formats = try await asset.load(.availableMetadataFormats)
        var fileMetadata: [AVMetadataItem] = []
        for format in formats { fileMetadata += try await asset.loadMetadata(for: format) }
        XCTAssertEqual(fileMetadata.first(where: { $0.commonKey == .commonKeyMake })?.stringValue, "Apple")
        XCTAssertEqual(fileMetadata.first(where: { $0.commonKey == .commonKeyModel })?.stringValue, "iPhone 15 Pro Max")
        let location = fileMetadata.first(where: { $0.commonKey == .commonKeyLocation })?.stringValue
        XCTAssertTrue(location?.contains("+31.23040+121.47370") == true)
    }

    func testRecorderWritesTwoPlayableMoviesOnOneTimeline() async throws {
        let source = root.appendingPathComponent("source.mov")
        try await DebugFixtures.writeMovie(to: source, front: false, seconds: 1)
        let asset = AVURLAsset(url: source)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var samples: [CMSampleBuffer] = []
        while let sample = output.copyNextSampleBuffer() { samples.append(sample) }
        XCTAssertGreaterThan(samples.count, 20)
        let draft = try disk.createDraft(kind: .video, layout: CameraLayout())
        let queue = DispatchQueue(label: "cam.tests.recording")
        let result: (Bool, Bool, Double) = try await withCheckedThrowingContinuation { continuation in
            queue.async {
                let recorder = PairRecorder(draft: draft, audioSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 1
                ], onStart: {})
                do {
                    for (index, sample) in samples.enumerated() {
                        try recorder.consumeVideo(sample, isFront: false)
                        try recorder.consumeVideo(sample, isFront: true)
                        if index == 12 { recorder.setLayout(CameraLayout(frontIsPrimary: true)) }
                        // Feed camera samples at camera cadence, rather than flooding
                        // a real-time encoder with a whole second in a single burst.
                        Thread.sleep(forTimeInterval: 1.0 / 30.0)
                    }
                    recorder.finish(on: queue) { rear, front, duration, moments, error in
                        XCTAssertNil(error)
                        XCTAssertEqual(moments.count, 2)
                        continuation.resume(returning: (rear, front, duration))
                    }
                } catch { continuation.resume(throwing: error) }
            }
        }
        XCTAssertTrue(result.0)
        XCTAssertTrue(result.1)
        XCTAssertEqual(result.2, 1, accuracy: 0.08)
        let rearDuration = try await AVURLAsset(url: draft.rearURL).load(.duration).seconds
        let frontDuration = try await AVURLAsset(url: draft.frontURL).load(.duration).seconds
        XCTAssertEqual(rearDuration, frontDuration, accuracy: 0.034)
    }

    func testSingleRecorderAndPlaybackUseOnlyTheSelectedCamera() async throws {
        let source = root.appendingPathComponent("source.mov")
        try await DebugFixtures.writeMovie(to: source, front: false, seconds: 1)
        let asset = AVURLAsset(url: source)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var samples: [CMSampleBuffer] = []
        while let sample = output.copyNextSampleBuffer() { samples.append(sample) }
        XCTAssertGreaterThan(samples.count, 20)
        for selectedFront in [false, true] {
        let layout = CameraLayout(frontIsPrimary: selectedFront, singleCamera: true, aspect: .wide)
        let draft = try disk.createDraft(kind: .video, layout: layout)
        let queue = DispatchQueue(label: "cam.tests.recording")
        let result: (Bool, Bool, Double) = try await withCheckedThrowingContinuation { continuation in
            queue.async {
                let recorder = PairRecorder(draft: draft, audioSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 1
                ], onStart: {})
                do {
                    for sample in samples {
                        try recorder.consumeVideo(sample, isFront: false)
                        try recorder.consumeVideo(sample, isFront: true)

                        // Feed camera samples at camera cadence, rather than flooding
                        // a real-time encoder with a whole second in a single burst.
                        Thread.sleep(forTimeInterval: 1.0 / 30.0)
                    }
                    recorder.finish(on: queue) { rear, front, duration, moments, error in
                        XCTAssertNil(error)
                        XCTAssertEqual(moments.count, 1)
                        continuation.resume(returning: (rear, front, duration))
                    }
                } catch { continuation.resume(throwing: error) }
            }
        }
        XCTAssertEqual(result.0, !selectedFront)
        XCTAssertEqual(result.1, selectedFront)
        XCTAssertEqual(result.2, 1, accuracy: 0.08)
        let selected = selectedFront ? draft.frontURL : draft.rearURL
        XCTAssertFalse(FileManager.default.fileExists(atPath: (selectedFront ? draft.rearURL : draft.frontURL).path))
        let item = try disk.finish(draft, rear: result.0, front: result.1, duration: result.2)
        let recipe = try await MediaExporter.videoRecipe(item: item, rearURL: selected, frontURL: selected)
        XCTAssertEqual(recipe.composition.tracks(withMediaType: .video).count, 1)
        XCTAssertEqual((recipe.videoComposition.instructions.first as? PairCompositionInstruction)?.requiredSourceTrackIDs?.count, 1)
        let exported = draft.folder.appendingPathComponent("export.mov")
        try await MediaExporter.makeVideo(item: item, rearURL: selected, frontURL: selected, outputURL: exported)
        let movie = AVURLAsset(url: exported)
        let duration = try await movie.load(.duration).seconds
        XCTAssertEqual(duration, 1, accuracy: 0.1)
        let generator = AVAssetImageGenerator(asset: movie)
        _ = try await generator.image(at: .zero)
        }
    }

    func testLeadingEmptyEditExportsBothPicturesFromFirstFrameWithoutChangingOriginals() async throws {
        let draft = try disk.createDraft(kind: .video, layout: CameraLayout())
        try await DebugFixtures.writeMovie(to: draft.rearURL, front: false, startOffset: 0.065)
        try await DebugFixtures.writeMovie(to: draft.frontURL, front: true)
        let rearBefore = try Data(contentsOf: draft.rearURL)
        let frontBefore = try Data(contentsOf: draft.frontURL)
        let tracks = try await AVURLAsset(url: draft.rearURL).loadTracks(withMediaType: .video)
        let segments = try await XCTUnwrap(tracks.first).load(.segments)
        XCTAssertTrue(segments.contains { $0.isEmpty && $0.timeMapping.target.duration.seconds > 0.06 },
                      "Fixture must reproduce the real camera's leading empty edit")
        let item = try disk.finish(draft, rear: true, front: true, duration: 2)
        let output = root.appendingPathComponent("leading-gap.mov")
        try await MediaExporter.makeVideo(item: item, rearURL: draft.rearURL, frontURL: draft.frontURL, outputURL: output)
        let asset = AVURLAsset(url: output)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 2 - 0.065, accuracy: 0.04)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let frame = try await generator.image(at: .zero).image
        let main = pixel(frame, x: 0.2, y: 0.2)
        let pip = pixel(frame, x: 0.82, y: 0.82)
        XCTAssertGreaterThan(main.g, main.r + 20)
        XCTAssertGreaterThan(pip.r, pip.g + 15)
        XCTAssertEqual(try Data(contentsOf: draft.rearURL), rearBefore)
        XCTAssertEqual(try Data(contentsOf: draft.frontURL), frontBefore)
    }

    @MainActor
    func testPlayerShowsFirstFrameAndAdvancesWithoutUserSeeking() async throws {
        let draft = try disk.createDraft(kind: .video, layout: CameraLayout())
        try await DebugFixtures.writeMovie(to: draft.rearURL, front: false, startOffset: 0.065)
        try await DebugFixtures.writeMovie(to: draft.frontURL, front: true)
        let item = try disk.finish(draft, rear: true, front: true, duration: 2)
        let model = MemoryPlayer()
        let host = PlayerSurface.Host(frame: CGRect(x: 0, y: 0, width: 270, height: 480))
        host.onReadyForDisplay = model.displayReadinessChanged
        host.playerLayer.player = model.player
        host.observeReadiness()
        await model.load(item, rear: draft.rearURL, front: draft.frontURL)
        for _ in 0..<150 where !model.isReady && model.error == nil {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertNil(model.error)
        XCTAssertTrue(model.isReady)
        XCTAssertTrue(host.playerLayer.isReadyForDisplay)
        XCTAssertTrue(model.hasFirstFrame)
        XCTAssertEqual(model.duration, 2 - 0.065, accuracy: 0.01)
        XCTAssertEqual(model.position, 0, accuracy: 0.01)
        model.toggle()
        for _ in 0..<100 where model.position < 0.3 && model.error == nil {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertGreaterThan(model.position, 0.25)
        XCTAssertTrue(model.isPlaying)
        let playerItem = try XCTUnwrap(model.player.currentItem)
        let playingComposition = playerItem.videoComposition
        for step in 0..<30 {
            model.updateLayout(CameraLayout(x: Double(step) / 30, y: 0.25), interactive: true)
        }
        model.finishLayoutInteraction()
        XCTAssertTrue(playerItem.videoComposition === playingComposition,
                      "Dragging while playing must not replace the video composition")
        let beforeEdit = model.position
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertGreaterThan(model.position, beforeEdit)
        model.pause()
        try await Task.sleep(for: .milliseconds(100))
        let pausedComposition = playerItem.videoComposition
        let pausedPosition = model.position
        for step in 0..<30 {
            model.updateLayout(CameraLayout(x: 0.25, y: Double(step) / 30), interactive: true)
        }
        XCTAssertTrue(playerItem.videoComposition === pausedComposition,
                      "Paused drag updates must coalesce instead of reconfiguring for every touch")
        model.finishLayoutInteraction()
        XCTAssertFalse(playerItem.videoComposition === pausedComposition)
        let instruction = try XCTUnwrap(playerItem.videoComposition?.instructions.first as? PairCompositionInstruction)
        XCTAssertEqual(instruction.layout(at: model.position), CameraLayout(x: 0.25, y: 29.0 / 30))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.position, pausedPosition, accuracy: 0.04)
        // AVFoundation can report compositor failure while item.status stays ready.
        NotificationCenter.default.post(name: .AVPlayerItemFailedToPlayToEndTime,
            object: model.player.currentItem,
            userInfo: [AVPlayerItemFailedToPlayToEndTimeErrorKey: CamError.message("测试合成失败")])
        XCTAssertEqual(model.error, "测试合成失败")
        XCTAssertFalse(model.isReady)
        XCTAssertFalse(model.isLoading)
        XCTAssertEqual(model.player.rate, 0)
        host.playerLayer.player = nil
    }

    @MainActor
    func testLeavingMediaCancelsPlaybackAndPendingLoad() async throws {
        let draft = try disk.createDraft(kind: .video, layout: CameraLayout())
        try await DebugFixtures.writeMovie(to: draft.rearURL, front: false, seconds: 1)
        try await DebugFixtures.writeMovie(to: draft.frontURL, front: true, seconds: 1)
        let item = try disk.finish(draft, rear: true, front: true, duration: 1)
        let player = MemoryPlayer()
        let load = Task { await player.load(item, rear: draft.rearURL, front: draft.frontURL) }
        await Task.yield()
        player.unload()
        await load.value
        XCTAssertNil(player.player.currentItem)
        XCTAssertFalse(player.isReady)
        XCTAssertFalse(player.isLoading)
        XCTAssertEqual(player.position, 0)
        // The same memory must be loadable again after leaving it.
        await player.load(item, rear: draft.rearURL, front: draft.frontURL)
        XCTAssertNotNil(player.player.currentItem)
        player.displayReadinessChanged(true)
        for _ in 0..<50 where !player.isReady { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(player.isReady)
        player.playFromBeginning()
        player.unload()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertNil(player.player.currentItem)
        XCTAssertEqual(player.player.rate, 0)
        XCTAssertFalse(player.isPlaying)
        XCTAssertFalse(player.isWaiting)
    }

    func testDetailImageLoadsMoreThanGridThumbnailWithoutChangingFile() async throws {
        let url = root.appendingPathComponent("large-photo.jpg")
        let image = DebugFixtures.image(front: false, size: CGSize(width: 1800, height: 2400))
        let bytes = try XCTUnwrap(image.jpegData(compressionQuality: 0.9))
        try bytes.write(to: url)
        let small = await ThumbnailLoader.image(url: url, kind: .photo, maximumPixelSize: 160)
        let detail = await ThumbnailLoader.image(url: url, kind: .photo, maximumPixelSize: 4096)
        XCTAssertEqual(small?.cgImage?.height, 160)
        XCTAssertEqual(detail?.cgImage?.height, 2400)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    private func photoPair(metadata: CaptureMetadata? = nil) throws -> CaptureDraft {
        let draft = try disk.createDraft(kind: .photo, layout: CameraLayout(), metadata: metadata)
        try solid(.red).jpegData(compressionQuality: 1)!.write(to: draft.rearURL)
        try solid(.blue).jpegData(compressionQuality: 1)!.write(to: draft.frontURL)
        return draft
    }

    private func shifted(_ sample: CMSampleBuffer, by offset: CMTime) throws -> CMSampleBuffer {
        var count = 0
        XCTAssertEqual(CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: 0,
                                                               arrayToFill: nil,
                                                               entriesNeededOut: &count), noErr)
        var timing = Array(repeating: CMSampleTimingInfo(), count: count)
        let status = timing.withUnsafeMutableBufferPointer { buffer in
            CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: count,
                                                   arrayToFill: buffer.baseAddress,
                                                   entriesNeededOut: &count)
        }
        XCTAssertEqual(status, noErr)
        for index in timing.indices {
            timing[index].presentationTimeStamp = timing[index].presentationTimeStamp + offset
            if timing[index].decodeTimeStamp.isValid {
                timing[index].decodeTimeStamp = timing[index].decodeTimeStamp + offset
            }
        }
        var copy: CMSampleBuffer?
        let copyStatus = timing.withUnsafeMutableBufferPointer { buffer in
            CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault,
                                                   sampleBuffer: sample,
                                                   sampleTimingEntryCount: count,
                                                   sampleTimingArray: buffer.baseAddress!,
                                                   sampleBufferOut: &copy)
        }
        XCTAssertEqual(copyStatus, noErr)
        return try XCTUnwrap(copy)
    }

    private func solid(_ color: UIColor) -> UIImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 400, height: 600), format: format).image { context in
            color.setFill(); context.fill(CGRect(x: 0, y: 0, width: 400, height: 600))
        }
    }

    private func pixel(_ image: CGImage, x: Double, y: Double) -> (r: Int, g: Int, b: Int) {
        let cropped = image.cropping(to: CGRect(x: Int(Double(image.width) * x), y: Int(Double(image.height) * y), width: 1, height: 1))!
        var rgba = [UInt8](repeating: 0, count: 4)
        rgba.withUnsafeMutableBytes { data in
            let context = CGContext(data: data.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                    space: FrameRenderer.colorSpace,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return (Int(rgba[0]), Int(rgba[1]), Int(rgba[2]))
    }

    private func addAudio(movie: URL, output: URL) async throws {
        let audioURL = root.appendingPathComponent("tone-\(UUID().uuidString).caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        do {
            let file = try AVAudioFile(forWriting: audioURL, settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 88200)!
            buffer.frameLength = 88200
            for index in 0..<88200 { buffer.floatChannelData![0][index] = Float(sin(Double(index) * 440 * 2 * .pi / 44100)) * 0.1 }
            try file.write(from: buffer)
        }
        let videoAsset = AVURLAsset(url: movie)
        let audioAsset = AVURLAsset(url: audioURL)
        let videoTracks = try await videoAsset.loadTracks(withMediaType: .video)
        let audioTracks = try await audioAsset.loadTracks(withMediaType: .audio)
        let videoSource = try XCTUnwrap(videoTracks.first)
        let audioSource = try XCTUnwrap(audioTracks.first)
        let duration = try await videoAsset.load(.duration)
        let composition = AVMutableComposition()
        let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
        let audio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
        try video.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: videoSource, at: .zero)
        try audio.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: audioSource, at: .zero)
        let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality)!
        export.outputURL = output; export.outputFileType = .mov
        await export.export()
        XCTAssertEqual(export.status, .completed, export.error?.localizedDescription ?? "")
    }
}

@available(iOS 18.0, *)
@MainActor
final class LockedCaptureReceiverTests: XCTestCase {
    private let first = URL(fileURLWithPath: "/sessions/first")
    private let second = URL(fileURLWithPath: "/sessions/second")

    func testPendingSnapshotImportsWithoutAnyInitialStreamEvent() async {
        let (signals, continuation) = AsyncStream<LockedCaptureReceiver.Signal>.makeStream()
        continuation.finish()
        var received: [URL] = []
        await LockedCaptureReceiver.consume(signals, snapshot: { [self.first] }, receive: {
            received.append($0)
        }, onFailure: { XCTFail("Unexpected import failure: \($0)") })
        XCTAssertEqual(received, [first])
    }

    func testForegroundRechecksSnapshotEvenWithoutAddedEvent() async {
        let (signals, continuation) = AsyncStream<LockedCaptureReceiver.Signal>.makeStream()
        continuation.yield(.reconcile)
        continuation.finish()
        var reads = 0
        var received: [URL] = []
        await LockedCaptureReceiver.consume(signals, snapshot: {
            reads += 1
            return reads == 1 ? [] : [self.first]
        }, receive: { received.append($0) }, onFailure: { XCTFail("\($0)") })
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(received, [first])
    }

    func testEventsQueuedDuringImportAreSerializedAndDeduplicated() async {
        let (signals, continuation) = AsyncStream<LockedCaptureReceiver.Signal>.makeStream()
        var received: [URL] = []
        var active = 0
        await LockedCaptureReceiver.consume(signals, snapshot: { [self.first] }, receive: { url in
            active += 1
            XCTAssertEqual(active, 1)
            defer { active -= 1 }
            received.append(url)
            if url == self.first {
                continuation.yield(.sessions([self.first, self.second, self.first]))
                continuation.yield(.reconcile)
                continuation.finish()
                await Task.yield()
            }
        }, onFailure: { XCTFail("\($0)") })
        XCTAssertEqual(received, [first, second])
    }

    func testFailedSessionRetriesOnReconciliationAndThenDeduplicates() async {
        let (signals, continuation) = AsyncStream<LockedCaptureReceiver.Signal>.makeStream()
        continuation.yield(.reconcile)
        continuation.yield(.sessions([first]))
        continuation.finish()
        var attempts = 0
        var failures = 0
        await LockedCaptureReceiver.consume(signals, snapshot: { [self.first] }, receive: { _ in
            attempts += 1
            if attempts == 1 { throw CocoaError(.fileReadNoPermission) }
        }, onFailure: { _ in failures += 1 })
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(failures, 1)
    }

    func testCancellationDoesNotAcknowledgeOrStartNextSession() async {
        let (signals, continuation) = AsyncStream<LockedCaptureReceiver.Signal>.makeStream()
        let started = expectation(description: "Import started")
        var attempted: [URL] = []
        var acknowledged: [URL] = []
        var failures = 0
        let task = Task {
            await LockedCaptureReceiver.consume(signals, snapshot: { [self.first, self.second] }, receive: { url in
                attempted.append(url)
                started.fulfill()
                try await Task.sleep(for: .seconds(60))
                acknowledged.append(url)
            }, onFailure: { _ in failures += 1 })
        }
        await fulfillment(of: [started], timeout: 3)
        task.cancel()
        await task.value
        continuation.finish()
        XCTAssertEqual(attempted, [first])
        XCTAssertTrue(acknowledged.isEmpty)
        XCTAssertEqual(failures, 0)
    }
}
