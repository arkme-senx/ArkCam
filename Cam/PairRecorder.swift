import AVFoundation

// Accessed only on the camera's serial capture queue.
final class PairRecorder {
    private final class Side {
        let writer: AVAssetWriter
        let video: AVAssetWriterInput
        let audio: AVAssetWriterInput
        var frames = 0
        var lastTime: CMTime = .invalid
        var rateMeter = VideoFrameRateMeter()

        init(url: URL, dimensions: CMVideoDimensions, audioSettings: [String: Any], profile: VideoRecordingProfile?) throws {
            writer = try AVAssetWriter(outputURL: url, fileType: .mov)
            writer.movieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 600)
            video = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoScalingModeKey: AVVideoScalingModeResizeAspectFill,
                AVVideoWidthKey: Int(dimensions.width),
                AVVideoHeightKey: Int(dimensions.height),
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: profile.map { Int(Double($0.bitRate) * Double(dimensions.width * dimensions.height) / Double($0.resolution.shortEdge * $0.resolution.longEdge)) } ?? 8_000_000,
                    AVVideoExpectedSourceFrameRateKey: profile?.fps ?? 30,
                    AVVideoMaxKeyFrameIntervalKey: profile?.fps ?? 30
                ]
            ])
            audio = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            video.expectsMediaDataInRealTime = true
            audio.expectsMediaDataInRealTime = true
            guard writer.canAdd(video), writer.canAdd(audio) else {
                throw CamError.message("这台设备无法使用当前的录像格式。")
            }
            writer.add(video)
            writer.add(audio)
        }
    }

    let draft: CaptureDraft
    private let sourceSizes: [Bool: CMVideoDimensions]
    private let preservesSourceAspect: Bool
    private let audioSettings: [String: Any]
    private let onStart: () -> Void
    private let onFrameRate: (Bool, RecordedFrameRate) -> Void
    private var rear: Side?
    private var front: Side?
    private var firstRear: CMSampleBuffer?
    private var firstFront: CMSampleBuffer?
    private var origin: CMTime = .invalid
    private var latestTime: CMTime = .invalid
    private var reportedStart = false
    private var leadingAudio: [CMSampleBuffer] = []
    private(set) var moments: [LayoutMoment]
    var elapsed: Double { origin.isValid && latestTime.isValid ? max(0, (latestTime - origin).seconds) : 0 }

    init(draft: CaptureDraft, audioSettings: [String: Any], sourceSizes: [Bool: CMVideoDimensions] = [:], preservesSourceAspect: Bool = false,
         onFrameRate: @escaping (Bool, RecordedFrameRate) -> Void = { _, _ in }, onStart: @escaping () -> Void) {
        self.preservesSourceAspect = preservesSourceAspect
        self.sourceSizes = sourceSizes
        self.draft = draft
        self.audioSettings = audioSettings
        self.onStart = onStart
        self.onFrameRate = onFrameRate
        moments = [LayoutMoment(seconds: 0, layout: draft.item.capturedLayout)]
    }

    func prepare() throws {
        guard let profile = draft.item.videoProfile else { return }
        for frontSide in [false, true] where draft.item.capturedLayout.includes(front: frontSide) {
            var dimensions = draft.item.capturedLayout.orientation?.isLandscape == true
                ? CMVideoDimensions(width: Int32(profile.resolution.longEdge), height: Int32(profile.resolution.shortEdge))
                : CMVideoDimensions(width: Int32(profile.resolution.shortEdge), height: Int32(profile.resolution.longEdge))
            if preservesSourceAspect, let source = sourceSizes[frontSide] {
                // QuickTake retains the photo stream's field of view. Preserve
                // its aspect in the original; the normal export applies the
                // user's chosen main-frame crop exactly once.
                let scale = min(1, Double(profile.resolution.longEdge) / Double(max(source.width, source.height)))
                dimensions = CMVideoDimensions(width: Int32(Double(source.width) * scale / 2) * 2,
                    height: Int32(Double(source.height) * scale / 2) * 2)
            }
            let side = try Side(url: frontSide ? draft.frontURL : draft.rearURL,
                dimensions: dimensions, audioSettings: audioSettings, profile: profile)
            if frontSide { front = side } else { rear = side }
        }
    }

    private func side(url: URL, sample: CMSampleBuffer) throws -> Side {
        guard let description = CMSampleBufferGetFormatDescription(sample) else { throw CamError.message("无法读取相机画面格式。") }
        return try Side(url: url, dimensions: CMVideoFormatDescriptionGetDimensions(description), audioSettings: audioSettings, profile: draft.item.videoProfile)
    }

    func setLayout(_ layout: CameraLayout) {
        if moments.last?.layout != layout { moments.append(LayoutMoment(seconds: elapsed, layout: layout)) }
    }

    func consumeVideo(_ sample: CMSampleBuffer, isFront: Bool) throws {
        guard draft.item.capturedLayout.includes(front: isFront), CMSampleBufferDataIsReady(sample) else { return }
        if let profile = draft.item.videoProfile, let desc = CMSampleBufferGetFormatDescription(sample) {
            let size = CMVideoFormatDescriptionGetDimensions(desc)
            // Drop old frames already queued before a format transaction.
            let expected = sourceSizes[isFront] ?? CMVideoDimensions(width: Int32(profile.resolution.shortEdge), height: Int32(profile.resolution.longEdge))
            guard size.width == expected.width && size.height == expected.height else { return }
        }
        if !origin.isValid {
            if isFront { firstFront = sample } else { firstRear = sample }
            let layout = draft.item.capturedLayout
            guard layout.complete(rear: firstRear != nil, front: firstFront != nil) else { return }
            if let firstRear, rear == nil { rear = try side(url: draft.rearURL, sample: firstRear) }
            if let firstFront, front == nil { front = try side(url: draft.frontURL, sample: firstFront) }
            origin = [firstRear, firstFront].compactMap { $0 }.map { CMSampleBufferGetPresentationTimeStamp($0) }.max()!
            for side in [rear, front].compactMap({ $0 }) {
                guard side.writer.startWriting() else {
                    throw side.writer.error ?? CamError.message("无法开始写入录像。")
                }
                side.writer.startSession(atSourceTime: origin)
            }
            if let firstRear, let rear { try appendVideo(firstRear, to: rear) }
            if let firstFront, let front { try appendVideo(firstFront, to: front) }
            self.firstRear = nil
            self.firstFront = nil
            let audio = leadingAudio; leadingAudio.removeAll()
            for sample in audio { try consumeAudio(sample) }
            reportStartIfReady()
            return
        }
        if let side = isFront ? front : rear { try appendVideo(sample, to: side) }
        reportStartIfReady()
    }

    private func reportStartIfReady() {
        guard !reportedStart, draft.item.capturedLayout.complete(rear: (rear?.frames ?? 0) > 0, front: (front?.frames ?? 0) > 0) else { return }
        reportedStart = true
        onStart()
    }

    private func appendVideo(_ sample: CMSampleBuffer, to side: Side) throws {
        let time = CMSampleBufferGetPresentationTimeStamp(sample)
        guard time >= origin else { return }
        if side.writer.status == .failed { throw side.writer.error ?? CamError.message("录像写入失败。") }
        guard side.video.isReadyForMoreMediaData else { return }
        guard side.video.append(sample) else { throw side.writer.error ?? CamError.message("录像画面保存失败。") }
        side.frames += 1
        side.lastTime = time
        if let observation = side.rateMeter.consume(time.seconds) { onFrameRate(side === front, observation) }
        latestTime = latestTime.isValid ? CMTimeMaximum(latestTime, time) : time
    }

    func consumeAudio(_ sample: CMSampleBuffer) throws {
        guard origin.isValid else {
            leadingAudio.append(sample)
            let now = CMSampleBufferGetPresentationTimeStamp(sample)
            leadingAudio.removeAll { (now - CMSampleBufferGetPresentationTimeStamp($0)).seconds > 0.5 }
            if leadingAudio.count > 48 { leadingAudio.removeFirst(leadingAudio.count - 48) }
            return
        }
        guard CMSampleBufferGetPresentationTimeStamp(sample) >= origin else { return }
        for side in [rear, front].compactMap({ $0 }) {
            if side.writer.status == .failed { throw side.writer.error ?? CamError.message("录像声音保存失败。") }
            if side.audio.isReadyForMoreMediaData, !side.audio.append(sample) {
                throw side.writer.error ?? CamError.message("录像声音保存失败。")
            }
        }
    }

    func finish(on queue: DispatchQueue, completion: @escaping (Bool, Bool, Double, [LayoutMoment], String?) -> Void) {
        guard draft.item.capturedLayout.complete(rear: rear != nil, front: front != nil), origin.isValid else {
            self.rear?.writer.cancelWriting()
            self.front?.writer.cancelWriting()
            completion(false, false, 0, moments, "录像尚未获取到所需画面，请重新拍摄。")
            return
        }
        let sides = [rear, front].compactMap { $0 }
        let end = (sides.map(\.lastTime).filter(\.isValid).min() ?? origin) + CMTime(value: 1, timescale: Int32(draft.item.videoProfile?.fps ?? 30))
        let duration = max(0, (end - origin).seconds)
        let group = DispatchGroup()
        for side in sides {
            if side.writer.status == .writing, side.frames > 0, duration > 0 {
                side.writer.endSession(atSourceTime: end)
                side.video.markAsFinished()
                side.audio.markAsFinished()
                group.enter()
                side.writer.finishWriting { group.leave() }
            } else if side.writer.status == .writing {
                side.writer.cancelWriting()
            }
        }
        group.notify(queue: queue) { [self] in
            let rearOK = rear?.writer.status == .completed
            let frontOK = front?.writer.status == .completed
            let error = (rear?.writer.error ?? front?.writer.error).map { CaptureStorageFailure.message(for: $0) }
            completion(rearOK, frontOK, duration, moments, error)
        }
    }
}
