import Foundation
import AVFoundation
import ImageIO

@main
enum InspectMedia {
    static func main() async throws {
        for path in CommandLine.arguments.dropFirst() {
            let url = URL(fileURLWithPath: path)
            var result: [String: Any] = ["file": url.lastPathComponent]
            if ["jpg", "jpeg", "heic", "heif", "dng"].contains(url.pathExtension.lowercased()) {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else {
                    throw NSError(domain: "CamInspection", code: 1)
                }
                result["codec"] = CGImageSourceGetType(source) as String?
                result["width"] = image.width
                result["height"] = image.height
                result["orientation"] = properties[kCGImagePropertyOrientation as String]
                if let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] { result["flash"] = exif[kCGImagePropertyExifFlash as String] }
                result["decodable"] = true
            } else {
                let asset = AVURLAsset(url: url)
                let tracks = try await asset.loadTracks(withMediaType: .video)
                let audio = try await asset.loadTracks(withMediaType: .audio)
                result["duration"] = try await asset.load(.duration).seconds
                result["videoTracks"] = tracks.count
                result["audioTracks"] = audio.count
                if let track = tracks.first {
                    let size = try await track.load(.naturalSize)
                    result["width"] = size.width
                    result["height"] = size.height
                    result["fps"] = try await track.load(.nominalFrameRate)
                    let reader = try AVAssetReader(asset: asset)
                    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
                    ])
                    reader.add(output)
                    guard reader.startReading() else { throw reader.error! }
                    var frames = 0
                    var lastTime: Double?
                    var maximumGap = 0.0
                    while let sample = output.copyNextSampleBuffer() {
                        let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                        if let lastTime { maximumGap = max(maximumGap, time - lastTime) }
                        lastTime = time
                        frames += 1
                    }
                    result["decodedFrames"] = frames
                    result["maximumFrameGap"] = maximumGap
                    result["decodable"] = reader.status == .completed
                    if let error = reader.error { result["error"] = error.localizedDescription }
                }
                if let track = audio.first {
                    let reader = try AVAssetReader(asset: asset)
                    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
                    reader.add(output)
                    guard reader.startReading() else { throw reader.error! }
                    var samples = 0
                    while let sample = output.copyNextSampleBuffer() { samples += CMSampleBufferGetNumSamples(sample) }
                    result["decodedAudioSamples"] = samples
                    result["audioDecodable"] = reader.status == .completed
                }
            }
            let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
            print(String(data: data, encoding: .utf8)!)
        }
    }
}
