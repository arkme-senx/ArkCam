import XCTest
import AVFoundation
@testable import Cam

final class RecordingStartTests: XCTestCase {
    func testSampleBudgetBoundsSlowWriterAndReleasesCapacity() {
        let budget = VideoSampleBudget(maximumBytes: 100, maximumSamples: 2)
        XCTAssertTrue(budget.reserve(60)); XCTAssertFalse(budget.reserve(41))
        XCTAssertTrue(budget.reserve(40)); XCTAssertFalse(budget.reserve(0))
        budget.release(60)
        XCTAssertTrue(budget.reserve(60)); XCTAssertEqual(budget.peakBytes, 100)
        budget.release(40); budget.release(60)
        XCTAssertTrue(budget.reserve(100))
    }

    func testBlockedPreparationKeepsFirstPictureAudioAndRequestedDimensions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = LibraryDisk(root: root)
        let draft = disk.reserveDraft(kind: .video, layout: CameraLayout(), videoProfile: .init(resolution: .hd, fps: 30), inFlight: true)
        defer { CaptureDraftActivity.end(draft.item.id) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: draft.folder.path))
        let gate = DispatchSemaphore(value: 0)
        let entered = expectation(description: "writer is held before disk I/O")
        let started = expectation(description: "both first frames really appended")
        let finished = expectation(description: "bounded samples drained and both movies finished")
        let callbacks = DispatchQueue(label: "test.start-callback")
        let source = CMVideoDimensions(width: 960, height: 1280)
        let recorder = BufferedVideoRecorder(draft: draft, audioSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1], sourceSizes: [false: source, true: source],
            callbackQueue: callbacks, prepare: { entered.fulfill(); gate.wait(); try disk.writeDraft(draft) },
            onStart: { started.fulfill() }, onFailure: { XCTFail($0.localizedDescription) })
        await fulfillment(of: [entered], timeout: 3)
        // First samples arrive while disk is deliberately unavailable. The second
        // frame is blue, so decoding red at time zero proves the opening survives.
        for index in 0..<2 {
            recorder.consume(try audio(index), front: nil, notBefore: .zero)
            let sample = try video(index, red: index == 0)
            recorder.consume(sample, front: false, notBefore: .zero)
            recorder.consume(sample, front: true, notBefore: .zero)
        }
        XCTAssertFalse(recorder.hasStarted)
        gate.signal()
        await fulfillment(of: [started], timeout: 5)
        for index in 2..<15 {
            recorder.consume(try audio(index), front: nil, notBefore: .zero)
            let sample = try video(index, red: false)
            recorder.consume(sample, front: false, notBefore: .zero)
            recorder.consume(sample, front: true, notBefore: .zero)
            try await Task.sleep(for: .milliseconds(34))
        }
        recorder.finish(on: callbacks) { rear, front, duration, _, error in
            XCTAssertTrue(rear); XCTAssertTrue(front); XCTAssertNil(error)
            XCTAssertEqual(duration, 0.5, accuracy: 0.04); finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 8)
        for url in [draft.rearURL, draft.frontURL] {
            let asset = AVURLAsset(url: url)
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            let track = try XCTUnwrap(videoTracks.first)
            let size = try await track.load(.naturalSize)
            XCTAssertEqual(size, CGSize(width: 720, height: 1280))
            let audios = try await asset.loadTracks(withMediaType: .audio)
            let sound = try XCTUnwrap(audios.first)
            let range = try await sound.load(.timeRange)
            XCTAssertLessThan(range.start.seconds, 0.04, "Audio at the opening must not be discarded while waiting for pictures")
            let image = try await AVAssetImageGenerator(asset: asset).image(at: .zero).image
            var pixel = [UInt8](repeating: 0, count: 4)
            let ctx = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            XCTAssertGreaterThan(pixel[0], 180); XCTAssertLessThan(pixel[2], 70)
        }
    }

    func testStopDuringBlockedPreparationCompletesWithoutStarting() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = LibraryDisk(root: root)
        let draft = disk.reserveDraft(kind: .video, layout: CameraLayout())
        let gate = DispatchSemaphore(value: 0)
        let done = expectation(description: "pending stop completes")
        let recorder = BufferedVideoRecorder(draft: draft, audioSettings: [:], callbackQueue: .global(),
            prepare: { gate.wait(); try disk.writeDraft(draft) }, onStart: { XCTFail("Must not report a recording without frames") },
            onFailure: { XCTFail($0.localizedDescription) })
        recorder.finish(on: .global()) { rear, front, _, _, reason in
            XCTAssertFalse(rear); XCTAssertFalse(front); XCTAssertNotNil(reason); done.fulfill()
        }
        gate.signal()
        await fulfillment(of: [done], timeout: 3)
    }

    func testQuickTakeKeepsSourceAspectAndFinishesFramesQueuedBeforeEarlyStop() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = LibraryDisk(root: root)
        let draft = disk.reserveDraft(kind: .video, layout: CameraLayout(singleCamera: true),
            videoProfile: .init(resolution: .hd, fps: 30))
        let gate = DispatchSemaphore(value: 0)
        let done = expectation(description: "early stop drains accepted frames")
        let callbacks = DispatchQueue(label: "test.early-stop")
        let recorder = BufferedVideoRecorder(draft: draft,
            audioSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1],
            sourceSizes: [false: CMVideoDimensions(width: 960, height: 1280)], preservesSourceAspect: true,
            callbackQueue: callbacks, prepare: { gate.wait(); try disk.writeDraft(draft) },
            onStart: {}, onFailure: { XCTFail($0.localizedDescription) })
        for index in 0..<3 {
            recorder.consume(try audio(index), front: nil, notBefore: .zero)
            recorder.consume(try video(index, red: true), front: false, notBefore: .zero)
        }
        recorder.finish(on: callbacks) { rear, front, duration, _, error in
            XCTAssertTrue(rear); XCTAssertFalse(front); XCTAssertNil(error)
            XCTAssertGreaterThan(duration, 0); done.fulfill()
        }
        gate.signal()
        await fulfillment(of: [done], timeout: 5)
        let asset = AVURLAsset(url: draft.rearURL)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let size = try await XCTUnwrap(tracks.first).load(.naturalSize)
        XCTAssertEqual(size, CGSize(width: 960, height: 1280), "Keep the source field of view for the later aspect crop")
    }

    func testPreparationFailureReturnsBothErrorAndCompletionWithoutHanging() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let draft = LibraryDisk(root: root).reserveDraft(kind: .video, layout: CameraLayout())
        let failed = expectation(description: "failure delivered")
        let done = expectation(description: "finish still delivered")
        let recorder = BufferedVideoRecorder(draft: draft, audioSettings: [:], callbackQueue: .global(),
            prepare: { throw CocoaError(.fileWriteNoPermission) }, onStart: { XCTFail("Cannot start after failure") },
            onFailure: { _ in failed.fulfill() })
        await fulfillment(of: [failed], timeout: 3)
        recorder.finish(on: .global()) { rear, front, _, _, error in
            XCTAssertFalse(rear); XCTAssertFalse(front); XCTAssertNotNil(error); done.fulfill()
        }
        await fulfillment(of: [done], timeout: 3)
    }

    func testBackpressureDropsPicturesWithoutStoppingAndKeepsAudioTimeline() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = LibraryDisk(root: root)
        let draft = try disk.createDraft(kind: .video, layout: CameraLayout(),
            videoProfile: .init(resolution: .hd, fps: 30))
        let callbacks = DispatchQueue(label: "test.overflow-callbacks")
        let started = expectation(description: "recording started before congestion")
        let blocked = expectation(description: "writer blocked during recording")
        let finished = expectation(description: "recording survives and finishes normally")
        let gate = DispatchSemaphore(value: 0)
        let source = CMVideoDimensions(width: 960, height: 1280)
        let recorder = BufferedVideoRecorder(draft: draft,
            audioSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1],
            sourceSizes: [false: source, true: source], callbackQueue: callbacks,
            prepare: {}, onStart: { started.fulfill() },
            onFailure: { XCTFail("Transient congestion must not stop recording: \($0)") })
        for index in 0..<3 {
            recorder.consume(try audio(index), front: nil, notBefore: .zero)
            let sample = try video(index, red: true)
            recorder.consume(sample, front: false, notBefore: .zero)
            recorder.consume(sample, front: true, notBefore: .zero)
            try await Task.sleep(for: .milliseconds(34))
        }
        await fulfillment(of: [started], timeout: 5)
        recorder.performOnWriterForTesting { blocked.fulfill(); gate.wait() }
        await fulfillment(of: [blocked], timeout: 3)
        // More data than the former 48 MiB shared queue. Both cameras retain
        // capacity, while sound must survive the video queue being full.
        for index in 3..<24 {
            recorder.consume(try audio(index), front: nil, notBefore: .zero)
            let sample = try video(index, red: true)
            recorder.consume(sample, front: false, notBefore: .zero)
            recorder.consume(sample, front: true, notBefore: .zero)
        }
        let stats = recorder.bufferStatistics
        XCTAssertGreaterThan(stats.rearFramesDiscarded, 0)
        XCTAssertGreaterThan(stats.frontFramesDiscarded, 0)
        XCTAssertEqual(stats.audioSamplesDiscarded, 0)
        XCTAssertLessThanOrEqual(stats.peakQueuedBytesUpperBound, 49 * 1024 * 1024)
        gate.signal()
        // Drain explicitly, then supply blue pictures after the interruption.
        let drained = expectation(description: "backlog drained")
        recorder.performOnWriterForTesting { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 5)
        for index in 24..<42 {
            recorder.consume(try audio(index), front: nil, notBefore: .zero)
            let sample = try video(index, red: false)
            recorder.consume(sample, front: false, notBefore: .zero)
            recorder.consume(sample, front: true, notBefore: .zero)
            try await Task.sleep(for: .milliseconds(34))
        }
        recorder.finish(on: callbacks) { rear, front, duration, _, error in
            XCTAssertTrue(rear); XCTAssertTrue(front); XCTAssertNil(error)
            XCTAssertEqual(duration, 1.4, accuracy: 0.04)
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 8)
        for url in [draft.rearURL, draft.frontURL] {
            let asset = AVURLAsset(url: url)
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            let sound = try XCTUnwrap(tracks.first)
            let range = try await sound.load(.timeRange)
            XCTAssertLessThan(range.start.seconds, 0.04)
            XCTAssertGreaterThan(range.end.seconds, 1.35)
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: sound, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
            reader.add(output); XCTAssertTrue(reader.startReading())
            var decodedSamples = 0
            while let sample = output.copyNextSampleBuffer() { decodedSamples += CMSampleBufferGetNumSamples(sample) }
            XCTAssertEqual(reader.status, .completed)
            XCTAssertGreaterThanOrEqual(decodedSamples, 42 * 1600 - 1024, "No missing audio block during video backlog")
            let generator = AVAssetImageGenerator(asset: asset)
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            let image = try await generator.image(at: CMTime(value: 36, timescale: 30)).image
            var pixel = [UInt8](repeating: 0, count: 4)
            let ctx = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            XCTAssertGreaterThan(pixel[2], 180, "Blue frames after congestion must be recorded")
            XCTAssertLessThan(pixel[0], 70)
        }
    }

    func testStopDiagnosticsRoundTripAndLegacyMemoryCompatibility() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = LibraryDisk(root: root)
        let original = try disk.createDraft(kind: .video, layout: CameraLayout())
        let legacy = try JSONEncoder().encode(original.item)
        XCTAssertNil(try JSONDecoder().decode(MemoryItem.self, from: legacy).recordingDiagnostics)
        var item = original.item
        item.recordingDiagnostics = RecordingDiagnostics(reason: .systemInterruption, stoppedAt: Date(), build: "test",
            pressureLevel: 3, thermalState: 2, interruptionReason: 5,
            buffer: .init(rearFramesDiscarded: 8, frontFramesDiscarded: 9,
                audioSamplesDiscarded: 0, peakQueuedBytesUpperBound: 48 * 1024 * 1024))
        let draft = CaptureDraft(item: item, folder: original.folder)
        // Even failed finalization must leave the machine-readable stop reason.
        XCTAssertThrowsError(try disk.finish(draft, rear: false, front: false))
        XCTAssertTrue(FileManager.default.fileExists(atPath: draft.folder.appendingPathComponent("recording-stop.json").path))
        let saved = try disk.finish(draft, rear: true, front: true, duration: 1)
        let roundTrip = try JSONDecoder().decode(MemoryItem.self, from: JSONEncoder().encode(saved))
        XCTAssertEqual(roundTrip.recordingDiagnostics, item.recordingDiagnostics)
    }

    private func video(_ index: Int, red: Bool) throws -> CMSampleBuffer {
        var pixel: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 960, 1280, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixel)
        CVPixelBufferLockBaseAddress(buffer, [])
        let ptr = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt32.self)
        let count = CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer) / 4
        ptr.update(repeating: red ? 0xFFFF0000 : 0xFF0000FF, count: count)
        CVPixelBufferUnlockBaseAddress(buffer, [])
        var description: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescriptionOut: &description)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: CMTime(value: Int64(index), timescale: 30), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescription: description!, sampleTiming: &timing, sampleBufferOut: &sample)
        return try XCTUnwrap(sample)
    }
    private func audio(_ index: Int) throws -> CMSampleBuffer {
        var asbd = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 4,
            mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        var description: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0,
            layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &description)
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: 6400,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: 6400, flags: 0, blockBufferOut: &block)
        CMBlockBufferFillDataBytes(with: 0, blockBuffer: block!, offsetIntoDestination: 0, dataLength: 6400)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48000), presentationTimeStamp: CMTime(value: Int64(index), timescale: 30), decodeTimeStamp: .invalid)
        var size = 4
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: description,
            sampleCount: 1600, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
        return try XCTUnwrap(sample)
    }
}
