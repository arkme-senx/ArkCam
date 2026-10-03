@preconcurrency import AVFoundation
import Photos
import CoreImage
import ImageIO
import UIKit

struct VideoRecipe {
    let composition: AVMutableComposition
    let videoComposition: AVMutableVideoComposition
    let sourceStart: CMTime
}

enum MediaExporter {
    // CIContext is thread-safe and expensive to recreate for every photograph.
    private static let photoContext = CIContext(options: [.cacheIntermediates: false])

    static func requiredCameras(_ item: MemoryItem, mode: AlbumSaveMode) -> Set<Bool> {
        if !item.capturedLayout.isDual { return [item.capturedLayout.frontIsPrimary] }
        if mode == .dual { return [false, true] }
        if let override = item.layoutOverride { return [override.frontIsPrimary] }
        return Set([item.capturedLayout.frontIsPrimary] + item.layoutMoments.map { $0.layout.frontIsPrimary })
    }

    static func liveRenderSize(source: CGSize, aspect: CGFloat) -> CGSize {
        let width = max(2, floor(min(abs(source.width), abs(source.height) * aspect, 1080) / 2) * 2)
        return CGSize(width: width, height: max(2, floor(width / aspect / 2) * 2))
    }

    static func makePhoto(item: MemoryItem, rearURL: URL, frontURL: URL, outputURL: URL,
                          liveAssetIdentifier: String? = nil, mode: AlbumSaveMode = .dual) throws {
        let layout = item.layout()
        let both = mode == .dual && layout.isDual
        let mainURL = layout.frontIsPrimary ? frontURL : rearURL
        guard let rear = CIImage(contentsOf: both ? rearURL : mainURL, options: [.applyOrientationProperty: true]),
              let front = both ? CIImage(contentsOf: frontURL, options: [.applyOrientationProperty: true]) : rear else {
            throw CamError.message("有一路原片无法读取，暂时无法合成。")
        }
        let primary = layout.frontIsPrimary ? front : rear
        // Crop to the requested aspect without upscaling the original.
        let width = floor(min(primary.extent.width, primary.extent.height * item.aspectRatio, item.photoProfile == nil ? 3024 : .greatestFiniteMagnitude) / 2) * 2
        let size = CGSize(width: width, height: floor(width / item.aspectRatio / 2) * 2)
        let image = FrameRenderer.compose(rear: rear, front: front, layout: layout, size: size, mode: mode)
        guard let cgImage = photoContext.createCGImage(image, from: image.extent, format: .RGBA8,
                                                   colorSpace: FrameRenderer.colorSpace),
              let destination = CGImageDestinationCreateWithURL(outputURL as CFURL, (item.photoProfile?.processedFormat == .heif ? "public.heic" : "public.jpeg") as CFString, 1, nil) else {
            throw CamError.message("无法建立照片文件。")
        }
        var properties = photoProperties(item)
        if let liveAssetIdentifier {
            properties[kCGImagePropertyMakerAppleDictionary] = ["17": liveAssetIdentifier]
        }
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CamError.message("照片元数据写入失败。") }
    }

    // Keep the physical camera's original pixel dimensions and orientation.
    static func copyOriginalPhoto(item: MemoryItem, sourceURL: URL, outputURL: URL,
                                  liveIdentifier: String? = nil) throws {
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
              let type = CGImageSourceGetType(source),
              let destination = CGImageDestinationCreateWithURL(outputURL as CFURL, type, 1, nil) else {
            throw CamError.message("照片原片无法读取。")
        }
        if let liveIdentifier {
            var properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
            for (key, value) in photoProperties(item) {
                if var existing = properties[key] as? [CFString: Any], let additions = value as? [CFString: Any] {
                    existing.merge(additions) { _, new in new }; properties[key] = existing
                } else { properties[key] = value }
            }
            var maker = properties[kCGImagePropertyMakerAppleDictionary] as? [String: Any] ?? [:]
            maker["17"] = liveIdentifier; properties[kCGImagePropertyMakerAppleDictionary] = maker
            CGImageDestinationAddImageFromSource(destination, source, 0, properties as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw CamError.message("照片元数据写入失败。") }
        } else {
            let metadata = CGImageMetadataCreateMutable()
            for (dictionary, value) in photoProperties(item) {
                guard let tags = value as? [CFString: Any] else { continue }
                for (key, value) in tags { CGImageMetadataSetValueMatchingImageProperty(metadata, dictionary, key, value as CFTypeRef) }
            }
            var error: Unmanaged<CFError>?
            guard CGImageDestinationCopyImageSource(destination, source,
                [kCGImageDestinationMetadata: metadata, kCGImageDestinationMergeMetadata: true] as CFDictionary, &error) else {
                throw error?.takeRetainedValue() as Error? ?? CamError.message("照片元数据写入失败。")
            }
        }
    }

    static func videoRecipe(item: MemoryItem, rearURL: URL, frontURL: URL, mode: AlbumSaveMode = .dual) async throws -> VideoRecipe {
        let directions = requiredCameras(item, mode: mode)
        let both = directions.count > 1
        let rear = AVURLAsset(url: directions.contains(false) ? rearURL : frontURL)
        let front = both ? AVURLAsset(url: frontURL) : rear
        guard let rearSource = try await rear.loadTracks(withMediaType: .video).first else {
            throw CamError.message("有一路录像无法读取，暂时无法合成。")
        }
        let frontSource: AVAssetTrack
        if both {
            guard let track = try await front.loadTracks(withMediaType: .video).first else {
                throw CamError.message("有一路录像无法读取，暂时无法合成。")
            }
            frontSource = track
        } else { frontSource = rearSource }
        let rearRange = try await playableRange(of: rearSource)
        let frontRange = both ? try await playableRange(of: frontSource) : rearRange
        // Keep the common timeline; never silently stretch one camera to fit the other.
        let start = CMTimeMaximum(rearRange.start, frontRange.start)
        let end = CMTimeMinimum(rearRange.end, frontRange.end)
        let duration = end - start
        guard duration.seconds.isFinite, duration.seconds > 0 else { throw CamError.message("两路录像没有可合成的共同片段。") }
        let sourceRange = CMTimeRange(start: start, duration: duration)
        let composition = AVMutableComposition()
        guard let rearTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw CamError.message("无法建立视频合成。")
        }
        try rearTrack.insertTimeRange(sourceRange, of: rearSource, at: .zero)
        let frontTrack: AVMutableCompositionTrack
        if both {
            guard let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw CamError.message("无法建立视频合成。")
            }
            frontTrack = track
            try frontTrack.insertTimeRange(sourceRange, of: frontSource, at: .zero)
        } else { frontTrack = rearTrack }
        let rearAudio = try await rear.loadTracks(withMediaType: .audio).first
        let frontAudio = both && rearAudio == nil ? try await front.loadTracks(withMediaType: .audio).first : nil
        // Both originals carry the same microphone; export it once to avoid doubled sound.
        if let source = rearAudio ?? frontAudio,
           let audio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            let available = try await source.load(.timeRange)
            let overlap = CMTimeRangeGetIntersection(sourceRange, otherRange: available)
            if overlap.duration.seconds > 0 {
                try audio.insertTimeRange(overlap, of: source, at: overlap.start - start)
            }
        }
        let rearTransform = try await rearSource.load(.preferredTransform)
        let frontTransform = try await frontSource.load(.preferredTransform)
        var adjustedItem = item
        adjustedItem.layoutMoments = item.layoutMoments.map { LayoutMoment(seconds: max(0, $0.seconds - start.seconds), layout: $0.layout) }
        let instruction = PairCompositionInstruction(timeRange: CMTimeRange(start: .zero, duration: duration),
                                                     rearID: rearTrack.trackID, frontID: frontTrack.trackID,
                                                     rearTransform: rearTransform, frontTransform: frontTransform,
                                                     memory: adjustedItem, mode: mode)
        let video = AVMutableVideoComposition()
        video.customVideoCompositorClass = PairVideoCompositor.self
        if item.isLivePhoto {
            let primary = item.layout().frontIsPrimary ? frontSource : rearSource
            let naturalSize = try await primary.load(.naturalSize)
            let transform = try await primary.load(.preferredTransform)
            video.renderSize = liveRenderSize(source: naturalSize.applying(transform), aspect: item.aspectRatio)
            let rearRate = try await rearSource.load(.nominalFrameRate)
            let frontRate = both ? try await frontSource.load(.nominalFrameRate) : rearRate
            let measured = [rearRate, frontRate].filter { $0.isFinite && $0 > 0 }.max() ?? 12
            // Keep the faster source cadence, rounding up fractional averages
            // caused by a dropped frame. A 5–12 fps ring does not need 30 fps output.
            let fps = min(30, max(1, Int(ceil(measured))))
            video.frameDuration = CMTime(value: 1, timescale: Int32(fps))
        } else if let profile = item.videoProfile {
            video.renderSize = profile.exportSize(aspect: item.aspectRatio)
            // Preserve the requested output cadence. A dropped source frame or
            // fractional final frame must not turn 60 fps into a 59 fps export.
            video.frameDuration = CMTime(value: 1, timescale: Int32(profile.fps))
        } else {
            video.renderSize = CGSize(width: 1080, height: floor(1080 / item.aspectRatio / 2) * 2)
            video.frameDuration = CMTime(value: 1, timescale: 30)
        }
        video.instructions = [instruction]
        video.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        video.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        video.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        return VideoRecipe(composition: composition, videoComposition: video, sourceStart: start)
    }

    static func playableRange(of track: AVAssetTrack) async throws -> CMTimeRange {
        let trackRange = try await track.load(.timeRange)
        let segments = try await track.load(.segments)
        // timeRange also includes empty edits before a camera's first frame.
        // Trim those edges in the composition, keeping the originals intact.
        let mediaRanges = segments.filter { !$0.isEmpty }.map(\.timeMapping.target).filter {
            $0.start.isNumeric && $0.duration.isNumeric && $0.duration > .zero
        }
        guard let first = mediaRanges.map(\.start).min(), let last = mediaRanges.map(\.end).max() else {
            throw CamError.message("这一路录像没有可播放的画面。")
        }
        let range = CMTimeRangeGetIntersection(trackRange, otherRange: CMTimeRange(start: first, end: last))
        guard range.duration.isNumeric, range.duration > .zero else {
            throw CamError.message("这一路录像没有有效的播放时间段。")
        }
        return range
    }

    static func makeVideo(item: MemoryItem, rearURL: URL, frontURL: URL, outputURL: URL,
                          mode: AlbumSaveMode = .dual) async throws {
        let recipe = try await videoRecipe(item: item, rearURL: rearURL, frontURL: frontURL, mode: mode)
        var passthrough = false
        let cameras = requiredCameras(item, mode: mode)
        if item.kind == .video, cameras.count == 1, let front = cameras.first {
            let source = AVURLAsset(url: front ? frontURL : rearURL)
            if let track = try await source.loadTracks(withMediaType: .video).first {
                let transform = try await track.load(.preferredTransform)
                let naturalSize = try await track.load(.naturalSize)
                let rate = try await track.load(.nominalFrameRate)
                passthrough = canPassthrough(sourceSize: naturalSize.applying(transform),
                    targetSize: recipe.videoComposition.renderSize, sourceFPS: Double(rate),
                    targetFPS: 1 / recipe.videoComposition.frameDuration.seconds)
                if passthrough,
                   let target = try await recipe.composition.loadTracks(withMediaType: .video).first {
                    target.preferredTransform = transform
                } else { passthrough = false }
            }
        }
        guard let export = AVAssetExportSession(asset: recipe.composition,
            presetName: passthrough ? AVAssetExportPresetPassthrough : AVAssetExportPresetHighestQuality) else {
            throw CamError.message("无法创建视频导出任务。")
        }
        if !passthrough { export.videoComposition = recipe.videoComposition }
        export.outputURL = outputURL
        // QuickTime preserves camera, device and ISO 6709 location metadata;
        // Photos accepts it as a normal video asset.
        export.outputFileType = .mov
        export.shouldOptimizeForNetworkUse = false
        export.metadata = videoMetadata(item)
        if #available(iOS 18.0, *) {
            do {
                try await withTaskCancellationHandler {
                    try await export.export(to: outputURL, as: .mov)
                } onCancel: {
                    export.cancelExport()
                }
            } catch is CancellationError {
                throw CamError.message("导出已取消，原片仍在 App 中。")
            } catch {
                throw error
            }
        } else {
            await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    export.exportAsynchronously { continuation.resume() }
                }
            } onCancel: { export.cancelExport() }
            guard export.status == .completed else {
                throw export.error ?? CamError.message(export.status == .cancelled ? "导出已取消，原片仍在 App 中。" : "视频导出失败，原片仍在 App 中。")
            }
        }
    }

    static func canPassthrough(sourceSize: CGSize, targetSize: CGSize, sourceFPS: Double, targetFPS: Double) -> Bool {
        abs(abs(sourceSize.width) - targetSize.width) < 1 &&
        abs(abs(sourceSize.height) - targetSize.height) < 1 &&
        sourceFPS.isFinite && sourceFPS > 0 && abs(sourceFPS - targetFPS) < 0.1
    }

    static func makeLivePhoto(item: MemoryItem, rearPhotoURL: URL, frontPhotoURL: URL,
                              rearMovieURL: URL, frontMovieURL: URL,
                              photoOutputURL: URL, movieOutputURL: URL, mode: AlbumSaveMode = .dual) async throws {
        let identifier = UUID().uuidString
        try makePhoto(item: item, rearURL: rearPhotoURL, frontURL: frontPhotoURL,
                      outputURL: photoOutputURL, liveAssetIdentifier: identifier, mode: mode)
        let contentMovie = movieOutputURL.deletingLastPathComponent()
            .appendingPathComponent("live-content-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: contentMovie) }
        try await makeVideo(item: item, rearURL: rearMovieURL, frontURL: frontMovieURL,
                            outputURL: contentMovie, mode: mode)
        try await pairLivePhotoMovie(sourceURL: contentMovie, outputURL: movieOutputURL,
                                     identifier: identifier,
                                     displayTime: item.livePhotoDisplayTime,
                                     metadata: videoMetadata(item))
    }

    static func pairLivePhotoMovie(sourceURL: URL, outputURL: URL, identifier: String,
                                           displayTime: Double?, metadata: [AVMetadataItem]) async throws {
        let asset = AVURLAsset(url: sourceURL)
        let duration = try await asset.load(.duration)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let tracks = videoTracks + audioTracks
        guard tracks.contains(where: { $0.mediaType == .video }) else {
            throw CamError.message("Live Photo 动态画面无法读取。")
        }
        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        writer.shouldOptimizeForNetworkUse = true
        writer.metadata = metadata + videoMetadataItemForLivePhoto(identifier)

        var transfers: [(AVAssetReaderTrackOutput, AVAssetWriterInput)] = []
        for track in tracks {
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { throw CamError.message("无法读取 Live Photo 媒体轨道。") }
            reader.add(output)
            let descriptions = try await track.load(.formatDescriptions)
            let input = AVAssetWriterInput(mediaType: track.mediaType, outputSettings: nil,
                                           sourceFormatHint: descriptions.first)
            if track.mediaType == .video { input.transform = try await track.load(.preferredTransform) }
            guard writer.canAdd(input) else { throw CamError.message("无法写入 Live Photo 媒体轨道。") }
            writer.add(input)
            transfers.append((output, input))
        }

        var metadataDescription: CMFormatDescription?
        let specifications: [[String: Any]] = [[
            kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as String:
                "mdta/com.apple.quicktime.still-image-time",
            kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as String:
                kCMMetadataBaseDataType_SInt8 as String
        ]]
        let metadataStatus = CMMetadataFormatDescriptionCreateWithMetadataSpecifications(
            allocator: kCFAllocatorDefault, metadataType: kCMMetadataFormatType_Boxed,
            metadataSpecifications: specifications as CFArray, formatDescriptionOut: &metadataDescription)
        guard metadataStatus == noErr, let metadataDescription else {
            throw CamError.message("无法建立 Live Photo 配对信息。")
        }
        let metadataInput = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil,
                                               sourceFormatHint: metadataDescription)
        guard writer.canAdd(metadataInput) else { throw CamError.message("无法写入 Live Photo 配对信息。") }
        writer.add(metadataInput)
        let adaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: metadataInput)

        let seconds = duration.seconds
        let requested = displayTime ?? seconds / 2
        let stillSeconds = min(max(0, requested), max(0, seconds - 0.01))
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                guard writer.startWriting(), reader.startReading() else {
                    continuation.resume(throwing: writer.error ?? reader.error ?? CamError.message("Live Photo 写入无法开始。"))
                    return
                }
                writer.startSession(atSourceTime: .zero)
                let still = AVMutableMetadataItem()
                still.identifier = AVMetadataIdentifier(rawValue: "mdta/com.apple.quicktime.still-image-time")
                still.value = NSNumber(value: Int8(0))
                still.dataType = kCMMetadataBaseDataType_SInt8 as String
                let group = AVTimedMetadataGroup(items: [still], timeRange: CMTimeRange(
                    start: CMTime(seconds: stillSeconds, preferredTimescale: 600),
                    duration: CMTime(value: 1, timescale: 600)))
                guard adaptor.append(group) else {
                    writer.cancelWriting()
                    reader.cancelReading()
                    continuation.resume(throwing: writer.error ?? CamError.message("Live Photo 关键帧信息写入失败。"))
                    return
                }
                metadataInput.markAsFinished()

                do {
                    let lanes = transfers.map { output, input in
                        var next: CMSampleBuffer?
                        var loaded = false
                        return MediaWriterDrain.Lane(input: input) {
                            if !loaded { next = output.copyNextSampleBuffer(); loaded = true }
                            guard let sample = next else {
                                if reader.status == .failed || reader.status == .cancelled {
                                    throw reader.error ?? CamError.message("Live Photo 媒体读取失败。")
                                }
                                return false
                            }
                            guard input.append(sample) else {
                                throw writer.error ?? CamError.message("Live Photo 媒体写入失败。")
                            }
                            next = output.copyNextSampleBuffer()
                            if reader.status == .failed || reader.status == .cancelled {
                                throw reader.error ?? CamError.message("Live Photo 媒体读取失败。")
                            }
                            return next != nil
                        }
                    }
                    try MediaWriterDrain.run(writer: writer, lanes: lanes, end: duration)
                    continuation.resume()
                } catch {
                    reader.cancelReading()
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func videoMetadataItemForLivePhoto(_ identifier: String) -> [AVMetadataItem] {
        [metadataItem(.quickTimeMetadataContentIdentifier, identifier)]
    }

    static func photoProperties(_ item: MemoryItem) -> [CFString: Any] {
        var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.95]
        guard let metadata = item.captureMetadata else { return properties }
        let tiffDate = DateFormatter()
        tiffDate.locale = Locale(identifier: "en_US_POSIX")
        tiffDate.dateFormat = "yyyy:MM:dd HH:mm:ss"
        properties[kCGImagePropertyTIFFDictionary] = [
            kCGImagePropertyTIFFMake: metadata.device.manufacturer,
            kCGImagePropertyTIFFModel: metadata.device.modelName,
            kCGImagePropertyTIFFSoftware: "ArkCam \(metadata.device.appVersion) (\(metadata.device.appBuild))",
            kCGImagePropertyTIFFDateTime: tiffDate.string(from: metadata.recordedAt)
        ]
        properties[kCGImagePropertyExifDictionary] = [
            kCGImagePropertyExifDateTimeOriginal: tiffDate.string(from: metadata.recordedAt),
            kCGImagePropertyExifDateTimeDigitized: tiffDate.string(from: metadata.recordedAt)
        ]
        if let location = metadata.location {
            let date = DateFormatter(); date.locale = Locale(identifier: "en_US_POSIX"); date.timeZone = .gmt
            date.dateFormat = "yyyy:MM:dd"
            let time = DateFormatter(); time.locale = Locale(identifier: "en_US_POSIX"); time.timeZone = .gmt
            time.dateFormat = "HH:mm:ss.SS"
            var gps: [CFString: Any] = [
                kCGImagePropertyGPSVersion: "2.3.0.0",
                kCGImagePropertyGPSLatitudeRef: location.latitude >= 0 ? "N" : "S",
                kCGImagePropertyGPSLatitude: abs(location.latitude),
                kCGImagePropertyGPSLongitudeRef: location.longitude >= 0 ? "E" : "W",
                kCGImagePropertyGPSLongitude: abs(location.longitude),
                kCGImagePropertyGPSDateStamp: date.string(from: location.measuredAt),
                kCGImagePropertyGPSTimeStamp: time.string(from: location.measuredAt),
                kCGImagePropertyGPSHPositioningError: location.horizontalAccuracy
            ]
            if let altitude = location.altitude {
                gps[kCGImagePropertyGPSAltitudeRef] = altitude >= 0 ? 0 : 1
                gps[kCGImagePropertyGPSAltitude] = abs(altitude)
            }
            properties[kCGImagePropertyGPSDictionary] = gps
        }
        return properties
    }

    static func videoMetadata(_ item: MemoryItem) -> [AVMetadataItem] {
        guard let metadata = item.captureMetadata else { return [] }
        var result = [metadataItem(.commonIdentifierMake, metadata.device.manufacturer),
                      metadataItem(.commonIdentifierModel, metadata.device.modelName),
                      metadataItem(.commonIdentifierSoftware,
                                   "ArkCam \(metadata.device.appVersion) (\(metadata.device.appBuild))")]
        if let location = metadata.location {
            let altitude = location.altitude ?? 0
            let iso6709 = String(format: "%+09.5f%+010.5f%+07.1f/", location.latitude, location.longitude, altitude)
            result.append(metadataItem(.commonIdentifierLocation, iso6709))
        }
        return result
    }

    private static func metadataItem(_ identifier: AVMetadataIdentifier, _ value: String) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = identifier
        item.value = value as NSString
        item.dataType = kCMMetadataBaseDataType_UTF8 as String
        return item
    }
}

enum MemoryExportMode: String, Codable, CaseIterable, Identifiable {
    case front, rear, combined
    var id: String { rawValue }
    var title: String { switch self { case .front: "仅前置"; case .rear: "仅后置"; case .combined: "双摄合成" } }
}

// Manual downloads deliberately do not read or write the automatic save preference.
enum ManualAlbumExport {
    static func original(_ item: MemoryItem, front: Bool, live: Bool = false, disk: LibraryDisk) -> URL? {
        guard item.capturedLayout.includes(front: front),
              let name = live ? (front ? item.frontLiveFile : item.rearLiveFile) : (front ? item.frontFile : item.rearFile) else { return nil }
        let url = disk.folder(for: item.id).appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func availableModes(for item: MemoryItem, disk: LibraryDisk) -> [MemoryExportMode] {
        let front = original(item, front: true, disk: disk) != nil
        let rear = original(item, front: false, disk: disk) != nil
        var modes: [MemoryExportMode] = []
        if front { modes.append(.front) }
        if rear { modes.append(.rear) }
        if item.capturedLayout.isDual && front && rear { modes.append(.combined) }
        return modes
    }

    static func prepare(_ item: MemoryItem, mode: MemoryExportMode, disk: LibraryDisk,
                        folder: URL) async throws -> PreparedAlbumMedia {
        guard availableModes(for: item, disk: disk).contains(mode) else {
            throw CamError.message("所选画面的原片不可用，请选择其他保存方式。")
        }
        if mode != .combined {
            let front = mode == .front
            guard let source = original(item, front: front, disk: disk) else {
                throw CamError.message("所选画面的原片不可用，请选择其他保存方式。")
            }
            let file = folder.appendingPathComponent("camera." + source.pathExtension)
            let liveName = front ? item.frontLiveFile : item.rearLiveFile
            if item.kind == .photo, liveName != nil {
                guard let movie = original(item, front: front, live: true, disk: disk) else {
                    throw CamError.message("实况视频原片不可用，照片原片仍保留在 App 中。")
                }
                let paired = folder.appendingPathComponent("camera-live.mov")
                let identifier = UUID().uuidString
                try MediaExporter.copyOriginalPhoto(item: item, sourceURL: source, outputURL: file, liveIdentifier: identifier)
                try await MediaExporter.pairLivePhotoMovie(sourceURL: movie, outputURL: paired,
                    identifier: identifier, displayTime: item.livePhotoDisplayTime, metadata: MediaExporter.videoMetadata(item))
                return PreparedAlbumMedia(file: file, pairedMovie: paired)
            }
            if item.kind == .photo {
                try MediaExporter.copyOriginalPhoto(item: item, sourceURL: source, outputURL: file)
            } else {
                // Preserve the camera's full duration, orientation, codec, frame rate and audio.
                try FileManager.default.copyItem(at: source, to: file)
            }
            return PreparedAlbumMedia(file: file, pairedMovie: nil)
        }
        guard let rear = original(item, front: false, disk: disk), let front = original(item, front: true, disk: disk) else {
            throw CamError.message("这条回忆缺少一路原片，暂时无法合成。")
        }
        let file = folder.appendingPathComponent(item.kind == .photo ? "combined." + (item.photoProfile?.processedFormat.fileExtension ?? "jpg") : "combined.mov")
        if item.isLivePhoto {
            guard let rearLive = original(item, front: false, live: true, disk: disk),
                  let frontLive = original(item, front: true, live: true, disk: disk) else {
                throw CamError.message("实况视频原片不可用，照片原片仍保留在 App 中。")
            }
            let paired = folder.appendingPathComponent("combined-live.mov")
            try await MediaExporter.makeLivePhoto(item: item, rearPhotoURL: rear, frontPhotoURL: front,
                rearMovieURL: rearLive, frontMovieURL: frontLive, photoOutputURL: file, movieOutputURL: paired)
            return PreparedAlbumMedia(file: file, pairedMovie: paired)
        }
        if item.kind == .photo { try MediaExporter.makePhoto(item: item, rearURL: rear, frontURL: front, outputURL: file) }
        else { try await MediaExporter.makeVideo(item: item, rearURL: rear, frontURL: front, outputURL: file) }
        return PreparedAlbumMedia(file: file, pairedMovie: nil)
    }
}

@MainActor
final class AlbumExporter: ObservableObject {
    @Published private(set) var isExporting = false
    @Published private(set) var status = ""
    @Published var message: String?

    func save(_ item: MemoryItem, mode: MemoryExportMode, library: MediaLibrary, saver: AutoAlbumSaver? = nil) async {
        guard !isExporting else { return }
        guard ManualAlbumExport.availableModes(for: item, disk: library.disk).contains(mode) else {
            message = "所选画面的原片不可用，请选择其他保存方式。"
            return
        }
        isExporting = true
        status = "准备保存…"
        defer { isExporting = false }
        #if !CAM_CAPTURE_EXTENSION
        let oldIdleTimer = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = oldIdleTimer }
        #endif
        let authorization = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard authorization == .authorized || authorization == .limited else {
            message = "需要允许添加到相册。请前往系统设置，打开 Cam 的照片添加权限。"
            return
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CamExport-\(UUID().uuidString)")
        let store = AlbumSaveStore(disk: library.disk)
        var receipt = AlbumDownloadReceipt(id: UUID(), mode: mode, attemptedAt: Date(), phase: .writing)
        var committed = false
        saver?.setManualStage(.queued, for: item.id)
        defer { saver?.setManualStage(nil, for: item.id) }
        do {
            status = "正在排队"
            await saver?.waitForAutomaticSaves()
            try Task.checkCancellation()
            saver?.setManualStage(.preparing, for: item.id)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            status = mode == .combined ? "正在合成，请保持 App 在前台…" : "正在准备所选画面…"
            let disk = library.disk
            let render = Task.detached(priority: .userInitiated) {
                try await ManualAlbumExport.prepare(item, mode: mode, disk: disk, folder: folder)
            }
            var media = try await withTaskCancellationHandler { try await render.value } onCancel: { render.cancel() }
            media.canMoveFiles = true
            status = "正在保存到相册…"
            try store.writeDownload(receipt, for: item.id)
            saver?.setManualStage(.writing, for: item.id)
            receipt.assetIdentifier = try await PhotosAlbumWriter.write(media, item)
            committed = true
            receipt.phase = .saved
            try store.writeDownload(receipt, for: item.id)
            message = String(format: L10n.text("已保存到相册（%@）。原片仍保留在 App 中。"), L10n.text(mode.title))
        } catch {
            if committed {
                // Leave the pre-commit marker intact if only the receipt failed.
                message = "系统相册已完成写入，但保存记录未能更新，请先在相册核对。"
            } else {
                receipt.phase = .failed; receipt.message = error.localizedDescription
                try? store.writeDownload(receipt, for: item.id)
                message = "保存失败：\(error.localizedDescription)\n原片仍保留在 App 中。"
            }
        }
    }
}
