import AVFoundation
import Accelerate
import CoreImage

// Accessed only from DualCamera's serial capture queue. It keeps a small,
// downscaled rolling window so dual-camera Live Photos do not require hundreds
// of megabytes of uncompressed 1080p buffers.
final class LivePhotoBuffer {
    private struct Frame {
        let pixelBuffer: CVPixelBuffer
        let time: CMTime
    }

    private struct Pending {
        let id: UUID
        let draft: CaptureDraft
        var shutterTime: CMTime
        var targetEnd: CMTime
        let audioSettings: [String: Any]?
        var rear: [Frame]
        var front: [Frame]
        var audio: [CMSampleBuffer]
        let completion: (Bool, Bool, Double?, Double?, String?) -> Void
    }

    private let callbackQueue: DispatchQueue
    private let encodingQueue = DispatchQueue(label: "cam.live-photo-encode", qos: .utility)
    private var enabled = false
    private var rear: [Frame] = []
    private var front: [Frame] = []
    private var audio: [CMSampleBuffer] = []
    private var lastRearSample = CMTime.invalid
    private var lastFrontSample = CMTime.invalid
    private var latestRear: (format: OSType, planes: Int)?
    private var latestFront: (format: OSType, planes: Int)?
    private var pending: [UUID: Pending] = [:]
    private var maximumFramesPerSecond = 12.0
    private var maximumLongEdge = 720
    private var rearPool: CVPixelBufferPool?
    private var frontPool: CVPixelBufferPool?
    private var rearPoolDescription: (width: Int, height: Int, format: OSType)?
    private var frontPoolDescription: (width: Int, height: Int, format: OSType)?
    private static let imageContext = CIContext(options: [.cacheIntermediates: false])

    init(callbackQueue: DispatchQueue) { self.callbackQueue = callbackQueue }

    #if DEBUG
    var diagnostics: [String: Any] {
        ["enabled": enabled, "rearFrames": rear.count, "frontFrames": front.count,
         "rearPixelFormat": latestRear.map { $0.format } ?? 0,
         "frontPixelFormat": latestFront.map { $0.format } ?? 0,
         "rearPlanes": latestRear.map { $0.planes } ?? 0,
         "frontPlanes": latestFront.map { $0.planes } ?? 0]
    }
    #endif

    func configure(maxFramesPerSecond: Double, maxLongEdge: Int) {
        maximumFramesPerSecond = max(1, maxFramesPerSecond)
        let edge = max(320, maxLongEdge)
        guard maximumLongEdge != edge else { return }
        maximumLongEdge = edge
        rearPool = nil
        frontPool = nil
        rearPoolDescription = nil
        frontPoolDescription = nil
    }

    func setEnabled(_ enabled: Bool) {
        guard self.enabled != enabled else { return }
        self.enabled = enabled
        if !enabled {
            rear.removeAll()
            front.removeAll()
            audio.removeAll()
            lastRearSample = .invalid
            lastFrontSample = .invalid
            latestRear = nil
            latestFront = nil
            finishEarly(reason: "Live Photo 缓冲已停止，静态照片仍会保留。")
        }
    }

    func beginCapture(draft: CaptureDraft, audioSettings: [String: Any]?,
                      completion: @escaping (Bool, Bool, Double?, Double?, String?) -> Void) -> Bool {
        guard enabled, pending[draft.item.id] == nil,
              draft.item.capturedLayout.complete(rear: rear.last != nil, front: front.last != nil) else {
            return false
        }
        // Static originals are delivered independently by AVCapturePhotoOutput.
        let shutter = [rear.last?.time, front.last?.time].compactMap { $0 }.min()!
        let start = shutter - CMTime(seconds: 1.5, preferredTimescale: 600)
        let end = shutter + CMTime(seconds: 1.5, preferredTimescale: 600)
        let id = draft.item.id
        pending[id] = Pending(id: id, draft: draft, shutterTime: shutter, targetEnd: end,
                          audioSettings: audioSettings,
                          rear: rear.filter { $0.time >= start && $0.time <= shutter },
                          front: front.filter { $0.time >= start && $0.time <= shutter },
                          audio: audio.filter { CMSampleBufferGetPresentationTimeStamp($0) >= start },
                          completion: completion)
        callbackQueue.asyncAfter(deadline: .now() + 2.4) { [weak self] in
            guard let self, self.pending[id] != nil else { return }
            self.finish(id: id, reason: "Live Photo 已保存快门前后能够保留的动态画面。")
        }
        return true
    }

    func alignShutter(id: UUID, to time: CMTime) {
        guard time.isValid, time.seconds.isFinite, var active = pending[id],
              abs((time - active.shutterTime).seconds) < 1 else { return }
        active.shutterTime = CMTimeMaximum(active.shutterTime, time)
        active.targetEnd = active.shutterTime + CMTime(seconds: 1.5, preferredTimescale: 600)
        pending[id] = active
    }

    func consumeVideo(_ sample: CMSampleBuffer, isFront: Bool) {
        guard enabled, CMSampleBufferDataIsReady(sample),
              let source = CMSampleBufferGetImageBuffer(sample) else { return }
        let description = (CVPixelBufferGetPixelFormatType(source), CVPixelBufferGetPlaneCount(source))
        if isFront { latestFront = description } else { latestRear = description }
        let time = CMSampleBufferGetPresentationTimeStamp(sample)
        let previous = isFront ? lastFrontSample : lastRearSample
        guard !previous.isValid || (time - previous).seconds >= (1.0 / maximumFramesPerSecond) else { return }
        let scaled: CVPixelBuffer?
        if isFront {
            scaled = downscale(source, pool: &frontPool, description: &frontPoolDescription)
        } else {
            scaled = downscale(source, pool: &rearPool, description: &rearPoolDescription)
        }
        guard let scaled else { return }
        let frame = Frame(pixelBuffer: scaled, time: time)
        if isFront { lastFrontSample = time; front.append(frame) }
        else { lastRearSample = time; rear.append(frame) }

        for id in Array(pending.keys) {
            guard var active = pending[id] else { continue }
            // The rolling buffer samples at 5–12 fps, not the camera's 30 fps.
            // Keep the first sample reaching the target on each side; a fixed
            // 1/30 s upper cutoff can discard it and force a false timeout.
            let lastTime = isFront ? active.front.last?.time : active.rear.last?.time
            if lastTime == nil || lastTime! < active.targetEnd {
                if isFront { active.front.append(frame) } else { active.rear.append(frame) }
            }
            pending[id] = active
        }
        trimRolling(at: time)
        finishIfReady()
    }

    func consumeAudio(_ sample: CMSampleBuffer) {
        guard enabled, CMSampleBufferDataIsReady(sample) else { return }
        audio.append(sample)
        for id in Array(pending.keys) {
            guard var active = pending[id],
                  CMSampleBufferGetPresentationTimeStamp(sample) <= active.targetEnd + CMTime(value: 1, timescale: 10) else { continue }
            active.audio.append(sample)
            pending[id] = active
        }
        let time = CMSampleBufferGetPresentationTimeStamp(sample)
        let cutoff = time - CMTime(seconds: 1.7, preferredTimescale: 600)
        audio.removeAll { CMSampleBufferGetPresentationTimeStamp($0) < cutoff }
    }

    func finishEarly(reason: String? = nil) {
        for id in Array(pending.keys) { finish(id: id, reason: reason) }
    }

    private func finish(id: UUID, reason: String?) {
        guard var active = pending.removeValue(forKey: id) else { return }
        encode(&active, earlyReason: reason)
    }

    private func finishIfReady() {
        for id in Array(pending.keys) {
            guard let active = pending[id], active.draft.item.capturedLayout.complete(
                rear: (active.rear.last?.time ?? .invalid) >= active.targetEnd,
                front: (active.front.last?.time ?? .invalid) >= active.targetEnd) else { continue }
            finish(id: id, reason: nil)
        }
    }

    private func encode(_ active: inout Pending, earlyReason: String?) {
        let value = active
        encodingQueue.async { [callbackQueue] in
            do {
                let timing = try RawLivePhotoWriter.write(rearFrames: value.rear.map { ($0.pixelBuffer, $0.time) },
                                                          frontFrames: value.front.map { ($0.pixelBuffer, $0.time) },
                                                          audio: value.audio,
                                                          audioSettings: value.audioSettings,
                                                          shutterTime: value.shutterTime,
                                                          rearURL: value.draft.rearLiveURL,
                                                          frontURL: value.draft.frontLiveURL, layout: value.draft.item.capturedLayout)
                callbackQueue.async {
                    value.completion(value.draft.item.capturedLayout.includes(front: false),
                                     value.draft.item.capturedLayout.includes(front: true), timing.duration, timing.displayTime,
                                     earlyReason ?? timing.note)
                }
            } catch {
                // One side may have completed before the other failed. Preserve
                // it and report its actual readability instead of deleting both.
                let partial = error as? RawLivePhotoWriter.PartialFailure
                callbackQueue.async {
                    value.completion(partial?.rearCompleted ?? false, false, nil, nil,
                                     "Live Photo 动态原片保存失败：\(CaptureStorageFailure.message(for: partial?.underlying ?? error))")
                }
            }
        }
    }

    private func trimRolling(at time: CMTime) {
        let cutoff = time - CMTime(seconds: 1.7, preferredTimescale: 600)
        rear.removeAll { $0.time < cutoff }
        front.removeAll { $0.time < cutoff }
    }

    private func downscale(_ source: CVPixelBuffer, pool: inout CVPixelBufferPool?,
                           description: inout (width: Int, height: Int, format: OSType)?) -> CVPixelBuffer? {
        guard CVPixelBufferGetPlaneCount(source) == 2 else { return nil }
        let sourceWidth = CVPixelBufferGetWidth(source)
        let sourceHeight = CVPixelBufferGetHeight(source)
        let scale = min(1, Double(maximumLongEdge) / Double(max(sourceWidth, sourceHeight)))
        let width = max(2, Int((Double(sourceWidth) * scale / 2).rounded(.down)) * 2)
        let height = max(2, Int((Double(sourceHeight) * scale / 2).rounded(.down)) * 2)
        let format = CVPixelBufferGetPixelFormatType(source)
        guard format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ||
                format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange else { return nil }
        let nextDescription = (width: width, height: height, format: format)
        if description?.width != width || description?.height != height || description?.format != format {
            let attributes: [CFString: Any] = [
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferPixelFormatTypeKey: format,
                kCVPixelBufferIOSurfacePropertiesKey: [String: Int](),
                kCVPixelBufferMetalCompatibilityKey: true
            ]
            var newPool: CVPixelBufferPool?
            guard CVPixelBufferPoolCreate(kCFAllocatorDefault,
                                          [kCVPixelBufferPoolMinimumBufferCountKey: 8] as CFDictionary,
                                          attributes as CFDictionary,
                                          &newPool) == kCVReturnSuccess else { return nil }
            pool = newPool
            description = nextDescription
        }
        var destination: CVPixelBuffer?
        guard let pool,
              CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &destination) == kCVReturnSuccess,
              let destination else { return nil }

        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(destination, [])
        defer {
            CVPixelBufferUnlockBaseAddress(destination, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }
        guard let sourceY = CVPixelBufferGetBaseAddressOfPlane(source, 0),
              let sourceUV = CVPixelBufferGetBaseAddressOfPlane(source, 1),
              let destinationY = CVPixelBufferGetBaseAddressOfPlane(destination, 0),
              let destinationUV = CVPixelBufferGetBaseAddressOfPlane(destination, 1) else { return nil }
        var ySource = vImage_Buffer(data: sourceY,
                                   height: vImagePixelCount(CVPixelBufferGetHeightOfPlane(source, 0)),
                                   width: vImagePixelCount(CVPixelBufferGetWidthOfPlane(source, 0)),
                                   rowBytes: CVPixelBufferGetBytesPerRowOfPlane(source, 0))
        var yDestination = vImage_Buffer(data: destinationY,
                                        height: vImagePixelCount(CVPixelBufferGetHeightOfPlane(destination, 0)),
                                        width: vImagePixelCount(CVPixelBufferGetWidthOfPlane(destination, 0)),
                                        rowBytes: CVPixelBufferGetBytesPerRowOfPlane(destination, 0))
        var uvSource = vImage_Buffer(data: sourceUV,
                                    height: vImagePixelCount(CVPixelBufferGetHeightOfPlane(source, 1)),
                                    width: vImagePixelCount(CVPixelBufferGetWidthOfPlane(source, 1)),
                                    rowBytes: CVPixelBufferGetBytesPerRowOfPlane(source, 1))
        var uvDestination = vImage_Buffer(data: destinationUV,
                                         height: vImagePixelCount(CVPixelBufferGetHeightOfPlane(destination, 1)),
                                         width: vImagePixelCount(CVPixelBufferGetWidthOfPlane(destination, 1)),
                                         rowBytes: CVPixelBufferGetBytesPerRowOfPlane(destination, 1))
        guard vImageScale_Planar8(&ySource, &yDestination, nil, vImage_Flags(kvImageNoFlags)) == kvImageNoError,
              vImageScale_CbCr8(&uvSource, &uvDestination, nil, vImage_Flags(kvImageNoFlags)) == kvImageNoError else {
            return nil
        }
        return destination
    }

    private static func writeJPEG(_ pixelBuffer: CVPixelBuffer, to url: URL) throws {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        try imageContext.writeJPEGRepresentation(of: image, to: url,
                                                  colorSpace: CGColorSpaceCreateDeviceRGB(),
                                                  options: [:])
    }
}

enum RawLivePhotoWriter {
    private enum AudioOutcome { case notRequested, included, videoOnlyFallback }

    struct PartialFailure: Error {
        let underlying: Error
        let rearCompleted: Bool
    }

    struct Timing {
        let duration: Double
        let displayTime: Double
        let note: String?
    }

    static func write(rearFrames: [(CVPixelBuffer, CMTime)], frontFrames: [(CVPixelBuffer, CMTime)],
                      audio: [CMSampleBuffer], audioSettings: [String: Any]?, shutterTime: CMTime,
                      rearURL: URL, frontURL: URL, layout: CameraLayout = CameraLayout()) throws -> Timing {
        guard layout.complete(rear: !rearFrames.isEmpty, front: !frontFrames.isEmpty) else {
            throw CamError.message("Live Photo 缓冲画面不足。")
        }
        let streams = [(false, rearFrames), (true, frontFrames)].filter { layout.includes(front: $0.0) }.map { $0.1 }
        let start = streams.compactMap { $0.first?.1 }.max()!
        let end = streams.compactMap { $0.last?.1 }.min()!
        guard (end - start).seconds > 0.4 else { throw CamError.message("Live Photo 动态画面太短。") }
        let rearAudio: AudioOutcome = layout.includes(front: false) ? try writeSide(label: "rear",
                                      frames: rearFrames.filter { $0.1 >= start && $0.1 <= end },
                                      audio: audio, audioSettings: audioSettings,
                                      start: start, end: end, outputURL: rearURL) : .notRequested
        let frontAudio: AudioOutcome
        do {
            frontAudio = layout.includes(front: true) ? try writeSide(label: "front",
                                       frames: frontFrames.filter { $0.1 >= start && $0.1 <= end },
                                       audio: audio, audioSettings: audioSettings,
                                       start: start, end: end, outputURL: frontURL) : .notRequested
        } catch {
            throw PartialFailure(underlying: error, rearCompleted: layout.includes(front: false))
        }
        return Timing(duration: (end - start).seconds,
                      displayTime: min(max(0, (shutterTime - start).seconds), (end - start).seconds),
                      note: rearAudio == .videoOnlyFallback || frontAudio == .videoOnlyFallback
                        ? "Live Photo 动态画面已保存；本次声音编码未完成。" : nil)
    }

    // Reports whether audio was written or omitted. A device may temporarily
    // run out of encoder capacity while MultiCam is active, so an audio attempt
    // is retried as video-only instead of leaving the photo draft unfinished.
    private static func writeSide(label: String, frames: [(CVPixelBuffer, CMTime)],
                                  audio: [CMSampleBuffer], audioSettings: [String: Any]?,
                                  start: CMTime, end: CMTime, outputURL: URL) throws -> AudioOutcome {
        let hasSourceAudio = audioSettings != nil && audio.contains {
            let time = CMSampleBufferGetPresentationTimeStamp($0)
            return time >= start && time <= end
        }
        do {
            try writeSideAttempt(label: label, frames: frames, audio: audio,
                                 audioSettings: audioSettings, includeAudio: hasSourceAudio,
                                 start: start, end: end, outputURL: outputURL)
            return hasSourceAudio ? .included : .notRequested
        } catch {
            guard hasSourceAudio, CaptureStorageFailure.classify(error) == nil else { throw error }
            #if DEBUG
            print("Cam Live writer \(label): audio attempt failed, retrying video-only: \(error.localizedDescription)")
            let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("CamDiagnostics")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("live-errors.json")
            var errors = (try? Data(contentsOf: file)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] } ?? []
            let nsError = error as NSError
            errors.append(["time": Date().timeIntervalSince1970, "side": label, "domain": nsError.domain,
                           "code": nsError.code, "message": nsError.localizedDescription])
            try? JSONSerialization.data(withJSONObject: Array(errors.suffix(20)), options: [.prettyPrinted, .sortedKeys])
                .write(to: file, options: .atomic)
            #endif
            try? FileManager.default.removeItem(at: outputURL)
            try writeSideAttempt(label: label, frames: frames, audio: [],
                                 audioSettings: nil, includeAudio: false,
                                 start: start, end: end, outputURL: outputURL)
            return .videoOnlyFallback
        }
    }

    private static func writeSideAttempt(label: String, frames: [(CVPixelBuffer, CMTime)],
                                         audio: [CMSampleBuffer], audioSettings: [String: Any]?,
                                         includeAudio: Bool, start: CMTime, end: CMTime,
                                         outputURL: URL) throws {
        guard let first = frames.first else { throw CamError.message("Live Photo 一路画面为空。") }
        try? FileManager.default.removeItem(at: outputURL)
        let width = CVPixelBufferGetWidth(first.0)
        let height = CVPixelBufferGetHeight(first.0)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        writer.movieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 600)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 3_000_000,
                AVVideoExpectedSourceFrameRateKey: 15,
                AVVideoMaxKeyFrameIntervalKey: 15
            ]
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: nil)
        guard writer.canAdd(video) else { throw CamError.message("无法建立 Live Photo 画面写入器。") }
        writer.add(video)

        var audioInput: AVAssetWriterInput?
        if includeAudio, let audioSettings {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            guard writer.canAdd(input) else { throw CamError.message("无法建立 Live Photo 声音写入器。") }
            writer.add(input); audioInput = input
        }
        #if DEBUG
        print("Cam Live writer \(label): begin frames=\(frames.count) audio=\(audioInput != nil)")
        #endif
        do {
            guard writer.startWriting() else { throw writer.error ?? CamError.message("Live Photo 写入无法开始。") }
            // Camera timestamps use the device host clock. Rebasing the short
            // clip to zero avoids a real-device writer stall on large values.
            writer.startSession(atSourceTime: .zero)
            let sound = audioInput == nil ? [] : audio.filter {
                let time = CMSampleBufferGetPresentationTimeStamp($0)
                return time >= start && time <= end
            }
            var videoFramesWritten = 0
            var audioIndex = 0
            var lanes = [MediaWriterDrain.Lane(input: video) {
                guard videoFramesWritten < frames.count else { return false }
                let frame = frames[videoFramesWritten]
                guard adaptor.append(frame.0, withPresentationTime: CMTimeMaximum(.zero, frame.1 - start)) else {
                    throw writer.error ?? CamError.message("Live Photo 画面写入失败。")
                }
                videoFramesWritten += 1
                return videoFramesWritten < frames.count
            }]
            if let audioInput {
                lanes.append(MediaWriterDrain.Lane(input: audioInput) {
                    guard audioIndex < sound.count else { return false }
                    guard audioInput.append(try rebase(sound[audioIndex], by: start)) else {
                        throw writer.error ?? CamError.message("Live Photo 声音写入失败。")
                    }
                    audioIndex += 1
                    return audioIndex < sound.count
                })
            }
            try MediaWriterDrain.run(writer: writer, lanes: lanes,
                                     end: end - start + CMTime(value: 1, timescale: 15))
            guard writer.status == .completed else {
                throw writer.error ?? CamError.message("Live Photo 动态原片保存失败。")
            }
            #if DEBUG
            print("Cam Live writer \(label): completed frames=\(videoFramesWritten) audio=\(audioInput != nil)")
            #endif
        } catch {
            if writer.status == .writing { writer.cancelWriting() }
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
    }

    private static func rebase(_ sample: CMSampleBuffer, by start: CMTime) throws -> CMSampleBuffer {
        var count = 0
        let firstStatus = CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: 0,
                                                                  arrayToFill: nil,
                                                                  entriesNeededOut: &count)
        guard firstStatus == noErr, count > 0 else { throw CamError.message("Live Photo 声音时间信息无效。") }
        var timing = Array(repeating: CMSampleTimingInfo(), count: count)
        let secondStatus = timing.withUnsafeMutableBufferPointer { buffer in
            CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: count,
                                                   arrayToFill: buffer.baseAddress,
                                                   entriesNeededOut: &count)
        }
        guard secondStatus == noErr else { throw CamError.message("Live Photo 声音时间信息无法读取。") }
        for index in timing.indices {
            if timing[index].presentationTimeStamp.isValid {
                timing[index].presentationTimeStamp = timing[index].presentationTimeStamp - start
            }
            if timing[index].decodeTimeStamp.isValid {
                timing[index].decodeTimeStamp = timing[index].decodeTimeStamp - start
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
        guard copyStatus == noErr, let copy else { throw CamError.message("Live Photo 声音时间无法同步。") }
        return copy
    }
}
