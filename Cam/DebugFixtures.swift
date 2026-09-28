#if DEBUG
import UIKit
import AVFoundation
import CoreLocation

enum DebugFixtures {
    static func image(front: Bool, size: CGSize = CGSize(width: 600, height: 800)) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            let context = renderer.cgContext
            let background = front ? UIColor(red: 0.79, green: 0.53, blue: 0.35, alpha: 1)
                : UIColor(red: 0.42, green: 0.63, blue: 0.58, alpha: 1)
            background.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor.white.withAlphaComponent(0.12).setFill()
            context.fillEllipse(in: CGRect(x: size.width * 0.5, y: -size.height * 0.08, width: size.width * 0.75, height: size.width * 0.75))
            UIColor.black.withAlphaComponent(0.10).setFill()
            context.fillEllipse(in: CGRect(x: -size.width * 0.35, y: size.height * 0.65, width: size.width * 1.5, height: size.width))
            let title = front ? "镜头后面的你" : "眼前的美好"
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            (title as NSString).draw(in: CGRect(x: 12, y: size.height * 0.44, width: size.width - 24, height: 80),
                withAttributes: [.font: UIFont.systemFont(ofSize: size.width * 0.06, weight: .medium), .foregroundColor: UIColor.white, .paragraphStyle: paragraph])
            ((front ? "前摄 · 示例素材" : "后摄 · 示例素材") as NSString).draw(
                in: CGRect(x: 12, y: size.height * 0.53, width: size.width - 24, height: 40),
                withAttributes: [.font: UIFont.systemFont(ofSize: size.width * 0.028), .foregroundColor: UIColor.white.withAlphaComponent(0.7), .paragraphStyle: paragraph])
        }
    }

    static func seedSingle(disk: LibraryDisk) async throws {
        if !(try disk.load()).isEmpty { return }
        let photo = try disk.createDraft(kind: .photo, layout: CameraLayout(singleCamera: true, aspect: .standard))
        try image(front: false).jpegData(compressionQuality: 0.95)!.write(to: photo.rearURL)
        try await writeMovie(to: photo.rearLiveURL, front: false, seconds: 3)
        _ = try disk.finish(photo, rear: true, front: false, rearLive: true,
            livePhotoDuration: 3, livePhotoDisplayTime: 1.5)
        let video = try disk.createDraft(kind: .video, layout: CameraLayout(frontIsPrimary: true, singleCamera: true, aspect: .wide))
        try await writeMovie(to: video.frontURL, front: true, seconds: 3)
        _ = try disk.finish(video, rear: false, front: true, duration: 3)
    }

    static func seed(disk: LibraryDisk) async throws {
        if !(try disk.load()).isEmpty { return }
        let draft = try disk.createDraft(kind: .photo, layout: CameraLayout(), metadata: metadata())
        try image(front: false).jpegData(compressionQuality: 0.95)!.write(to: draft.rearURL)
        try image(front: true).jpegData(compressionQuality: 0.95)!.write(to: draft.frontURL)
        try await writeMovie(to: draft.rearLiveURL, front: false, seconds: 3)
        try await writeMovie(to: draft.frontLiveURL, front: true, seconds: 3)
        _ = try disk.finish(draft, rear: true, front: true, rearLive: true, frontLive: true,
                            livePhotoDuration: 3, livePhotoDisplayTime: 1.5)
        let movie = try disk.createDraft(kind: .video, layout: CameraLayout(), metadata: metadata())
        try await writeMovie(to: movie.rearURL, front: false, seconds: 4, startOffset: 0.065)
        try await writeMovie(to: movie.frontURL, front: true, seconds: 4)
        _ = try disk.finish(movie, rear: true, front: true, duration: 4,
                            moments: [LayoutMoment(seconds: 0, layout: CameraLayout()),
                                      LayoutMoment(seconds: 1, layout: CameraLayout(frontIsPrimary: true, x: 1, y: 1))])
        if ProcessInfo.processInfo.arguments.contains("--gallery-fixtures") {
            for index in 0..<12 {
                let aspect = CaptureAspect.allCases[index % 3]
                let extra = try disk.createDraft(kind: .photo,
                    layout: CameraLayout(aspect: aspect, insetAspectRatio: 0.75), metadata: metadata())
                try image(front: false).jpegData(compressionQuality: 0.95)!.write(to: extra.rearURL)
                try image(front: true).jpegData(compressionQuality: 0.95)!.write(to: extra.frontURL)
                var saved = try disk.finish(extra, rear: true, front: true)
                saved.createdAt = draft.item.createdAt.addingTimeInterval(-Double(index + 1) * 60)
                try disk.save(saved)
            }
        }
    }

    static func metadata(location: Bool = true) -> CaptureMetadata {
        let measuredAt = Date(timeIntervalSince1970: 1_800_000_000)
        let capturedLocation = location ? CaptureLocation(CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 31.23040, longitude: 121.47370),
            altitude: 12, horizontalAccuracy: 8, verticalAccuracy: 5, timestamp: measuredAt)) : nil
        let device = CaptureDeviceInfo(manufacturer: "Apple", modelName: "iPhone 15 Pro Max",
                                       hardwareIdentifier: "iPhone16,2", systemName: "iOS", systemVersion: "27.0",
                                       appVersion: "0.1.0", appBuild: "15")
        return CaptureMetadata(recordedAt: measuredAt, location: capturedLocation, device: device, cameras: [
            CaptureCameraInfo(position: "后置", deviceType: "builtInWideAngleCamera", name: "后置广角相机",
                              width: 1920, height: 1080, framesPerSecond: 30),
            CaptureCameraInfo(position: "前置", deviceType: "builtInWideAngleCamera", name: "前置相机",
                              width: 1920, height: 1080, framesPerSecond: 30)
        ])
    }

    static func writeMovie(to url: URL, front: Bool, seconds: Int = 2, startOffset: Double = 0,
                           width: Int = 270, height: Int = 480) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CamError.message("Fixture writer failed") }
        writer.startSession(atSourceTime: .zero)
        let image = image(front: front, size: CGSize(width: width, height: height)).cgImage!
        for frame in 0..<(seconds * 30) {
            while !input.isReadyForMoreMediaData {
                if writer.status == .failed { throw writer.error ?? CamError.message("Fixture writer failed") }
                try await Task.sleep(for: .milliseconds(5))
            }
            var buffer: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer) == kCVReturnSuccess, let buffer else {
                throw CamError.message("Fixture buffer failed")
            }
            CVPixelBufferLockBaseAddress(buffer, [])
            let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
                                    bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                    space: FrameRenderer.colorSpace,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            let presentationTime = CMTime(value: Int64(frame), timescale: 30) + CMTime(seconds: startOffset, preferredTimescale: 600)
            guard adaptor.append(buffer, withPresentationTime: presentationTime) else {
                throw writer.error ?? CamError.message("Fixture append failed")
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CamError.message("Fixture finish failed") }
    }
}
#endif
