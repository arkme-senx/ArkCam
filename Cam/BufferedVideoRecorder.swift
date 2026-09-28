import AVFoundation

/// Memory is bounded even if the filesystem or encoder stalls. Calls from the
/// capture queue never wait for disk I/O, writer setup, or another camera frame.
final class VideoSampleBudget: @unchecked Sendable {
    private let lock = NSLock()
    let maximumBytes: Int
    let maximumSamples: Int
    private var storedPeakBytes = 0
    private var rejectedSamples = 0
    var peakBytes: Int { lock.lock(); defer { lock.unlock() }; return storedPeakBytes }
    var discardedSamples: Int { lock.lock(); defer { lock.unlock() }; return rejectedSamples }
    private var bytes = 0
    private var samples = 0
    init(maximumBytes: Int = 48 * 1024 * 1024, maximumSamples: Int = 96) {
        self.maximumBytes = maximumBytes; self.maximumSamples = maximumSamples
    }
    func reserve(_ size: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard size >= 0, size <= maximumBytes - bytes, samples < maximumSamples else {
            rejectedSamples += 1
            return false
        }
        bytes += size; samples += 1; storedPeakBytes = max(storedPeakBytes, bytes)
        return true
    }
    func release(_ size: Int) {
        lock.lock(); defer { lock.unlock() }
        bytes -= size; samples -= 1
    }
}

final class BufferedVideoRecorder: @unchecked Sendable {
    let draft: CaptureDraft
    private let sourceSizes: [Bool: CMVideoDimensions]
    private let preservesSourceAspect: Bool
    private let worker = DispatchQueue(label: "cam.video-writer", qos: .userInitiated)
    private let callbackQueue: DispatchQueue
    // Each camera has a share so one stream cannot starve the other's opening.
    // Audio cannot be displaced by large video buffers. Total retained payload
    // remains bounded at 49 MiB; rejected samples never enqueue more work.
    private let rearBudget: VideoSampleBudget
    private let frontBudget: VideoSampleBudget
    private let audioBudget = VideoSampleBudget(maximumBytes: 1024 * 1024, maximumSamples: 96)
    var bufferStatistics: RecordingBufferStatistics {
        RecordingBufferStatistics(rearFramesDiscarded: rearBudget.discardedSamples,
            frontFramesDiscarded: frontBudget.discardedSamples, audioSamplesDiscarded: audioBudget.discardedSamples,
            peakQueuedBytesUpperBound: rearBudget.peakBytes + frontBudget.peakBytes + audioBudget.peakBytes)
    }

    #if DEBUG
    // Deterministic backpressure injection for tests; absent from delivery builds.
    func performOnWriterForTesting(_ action: @escaping () -> Void) { worker.async(execute: action) }
    #endif
    private let lock = NSLock()
    private var accepting = true
    private var started = false
    private var duration = 0.0
    private var failure: Error?
    private var recorder: PairRecorder?
    private let onFailure: (Error) -> Void
    var hasStarted: Bool { lock.lock(); defer { lock.unlock() }; return started }
    var elapsed: Double { lock.lock(); defer { lock.unlock() }; return duration }

    init(draft: CaptureDraft, audioSettings: [String: Any], sourceSizes: [Bool: CMVideoDimensions] = [:], preservesSourceAspect: Bool = false, callbackQueue: DispatchQueue,
         prepare: @escaping () throws -> Void, onFrameRate: @escaping (Bool, RecordedFrameRate) -> Void = { _, _ in }, onStart: @escaping () -> Void,
         onFailure: @escaping (Error) -> Void) {
        let cameraBytes = (draft.item.capturedLayout.isDual ? 24 : 48) * 1024 * 1024
        self.rearBudget = VideoSampleBudget(maximumBytes: cameraBytes)
        self.frontBudget = VideoSampleBudget(maximumBytes: cameraBytes)
        self.preservesSourceAspect = preservesSourceAspect
        self.sourceSizes = sourceSizes
        self.draft = draft; self.callbackQueue = callbackQueue; self.onFailure = onFailure
        worker.async { [self] in
            do {
                try prepare()
                let recorder = PairRecorder(draft: draft, audioSettings: audioSettings, sourceSizes: sourceSizes, preservesSourceAspect: preservesSourceAspect,
                    onFrameRate: { front, observation in
                        callbackQueue.async { onFrameRate(front, observation) }
                    }) { [weak self] in
                    guard let self else { return }
                    self.lock.lock(); self.started = true; self.lock.unlock()
                    self.callbackQueue.async(execute: onStart)
                }
                self.recorder = recorder
                try recorder.prepare()
            } catch { fail(error) }
        }
    }

    func consume(_ sample: CMSampleBuffer, front: Bool?, notBefore: CMTime) {
        guard CMSampleBufferDataIsReady(sample), CMSampleBufferGetPresentationTimeStamp(sample) >= notBefore else { return }
        if let front {
            guard draft.item.capturedLayout.includes(front: front) else { return }
            if let profile = draft.item.videoProfile, let description = CMSampleBufferGetFormatDescription(sample) {
                let size = CMVideoFormatDescriptionGetDimensions(description)
                let expected = sourceSizes[front] ?? CMVideoDimensions(width: Int32(profile.resolution.shortEdge), height: Int32(profile.resolution.longEdge))
                guard size.width == expected.width, size.height == expected.height else { return }
            }
        }
        lock.lock(); defer { lock.unlock() }
        guard accepting else { return }
        let budget = front.map { $0 ? frontBudget : rearBudget } ?? audioBudget
        let size = CMSampleBufferGetImageBuffer(sample).map { CVPixelBufferGetDataSize($0) }
            ?? CMSampleBufferGetTotalSampleSize(sample)
        // A full queue is transient backpressure, not a failed AVAssetWriter.
        // Keep source timestamps: skipped pictures become a brief held frame,
        // rather than shortening the movie or shifting subsequent audio.
        guard budget.reserve(size) else { return }
        worker.async { [self] in
            defer { budget.release(size) }
            guard failure == nil, let recorder else { return }
            do {
                if let front { try recorder.consumeVideo(sample, isFront: front) }
                else { try recorder.consumeAudio(sample) }
                lock.lock(); duration = recorder.elapsed; lock.unlock()
            } catch { fail(error) }
        }
    }

    func setLayout(_ layout: CameraLayout) {
        worker.async { [self] in recorder?.setLayout(layout) }
    }

    private func fail(_ error: Error) {
        guard failure == nil else { return }
        failure = error
        lock.lock(); accepting = false; lock.unlock()
        callbackQueue.async { [onFailure] in onFailure(error) }
    }

    func finish(on queue: DispatchQueue, completion: @escaping (Bool, Bool, Double, [LayoutMoment], String?) -> Void) {
        lock.lock(); defer { lock.unlock() }
        accepting = false
        worker.async { [self] in
            guard let recorder else {
                let reason = failure?.localizedDescription ?? "录像尚未获取到所需画面，请重新拍摄。"
                queue.async { completion(false, false, 0, [], reason) }
                return
            }
            recorder.finish(on: worker) { [self] rear, front, duration, moments, error in
                let error = failure?.localizedDescription ?? error
                queue.async { completion(rear, front, duration, moments, error) }
            }
        }
    }
}

final class VideoStartRequest: @unchecked Sendable {
    let id: UUID
    init(id: UUID = UUID()) { self.id = id }
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}
