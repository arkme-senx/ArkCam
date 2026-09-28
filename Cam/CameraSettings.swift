import Foundation
import AVFoundation

enum AlbumSaveMode: String, Codable, CaseIterable, Identifiable {
    case dual, primary, separate
    var id: String { rawValue }
    var title: String {
        switch self { case .dual: "双摄合成"; case .primary: "仅主画面"; case .separate: "双摄同时保存" }
    }
    var detail: String {
        switch self {
        case .dual: "保存大画面和小窗，与拍摄布局一致。"
        case .primary: "只保存大画面；录像中交换主次时，成片也随之切换镜头。"
        case .separate: "前置和后置各保存一份；单摄拍摄只保存一份。"
        }
    }
    static func current(_ defaults: UserDefaults = .standard) -> Self {
        Self(rawValue: CameraDefaults.string("cameraAlbumSaveMode", in: defaults)) ?? .dual
    }
}

enum CameraFlashMode: String, CaseIterable, Identifiable {
    case off, auto, on
    var id: String { rawValue }
    var title: String { switch self { case .off: "关闭"; case .auto: "自动"; case .on: "开启" } }
    var symbol: String { switch self { case .off: "bolt.slash.fill"; case .auto: "bolt.badge.a.fill"; case .on: "bolt.fill" } }
    var avMode: AVCaptureDevice.FlashMode { switch self { case .off: .off; case .auto: .auto; case .on: .on } }
    func next(supported: [Self]) -> Self {
        let index = Self.allCases.firstIndex(of: self)!
        return (1...Self.allCases.count).map { Self.allCases[(index + $0) % Self.allCases.count] }
            .first(where: supported.contains) ?? .off
    }

}

// Shared with the lock-screen camera through CameraCaptureIntent's app context.
// Only explicit preferences cross that boundary; never history or location data.
enum CameraPreferenceStore {
    // Live remains the explicit field in CamCaptureContext for older extensions.
    static let booleanKeys = CameraDefaults.booleans.keys.filter { $0 != "livePhotoEnabled" }.sorted()
    static let stringKeys = CameraDefaults.strings.keys.sorted()
    static func snapshot(_ defaults: UserDefaults = .standard) -> [String: String] {
        var result: [String: String] = [:]
        for key in booleanKeys { result[key] = CameraDefaults.bool(key, in: defaults) ? "true" : "false" }
        for key in stringKeys { result[key] = CameraDefaults.string(key, in: defaults) }
        return result
    }
    static func apply(_ values: [String: String]?, to defaults: UserDefaults = .standard) {
        guard let values else { return }
        for key in booleanKeys { if let value = values[key] { defaults.set(value == "true", forKey: key) } }
        for key in stringKeys { if let value = values[key] { defaults.set(value, forKey: key) } }
    }
}

// Stored per memory; old records without a profile continue to use JPEG.
enum PhotoFileFormat: String, Codable, CaseIterable, Identifiable {
    case jpeg, heif, raw
    var id: String { rawValue }
    var title: String { rawValue == "heif" ? "HEIF" : rawValue.uppercased() }
    var fileExtension: String { self == .heif ? "heic" : self == .raw ? "dng" : "jpg" }
    var codec: AVVideoCodecType { self == .heif ? .hevc : .jpeg }
}

struct PhotoCaptureProfile: Codable, Equatable {
    var format: PhotoFileFormat = PhotoFileFormat(rawValue: CameraDefaults.photoFormat)!
    var megapixels: Int = CameraDefaults.photoMegapixels
    var processedFormat: PhotoFileFormat = .jpeg
    static func current(_ defaults: UserDefaults = .standard) -> Self {
        let format = PhotoFileFormat(rawValue: CameraDefaults.string("cameraPhotoFormat", in: defaults)) ?? .jpeg
        return Self(format: format, megapixels: Int(CameraDefaults.string("cameraPhotoMP", in: defaults)) ?? CameraDefaults.photoMegapixels,
                    processedFormat: format == .jpeg ? .jpeg : .heif)
    }
}

struct PhotoCaptureCapabilities: Equatable {
    var formats: [PhotoFileFormat] = [.jpeg]
    var megapixels: [Int] = [12]
    static func pixels(_ size: CMVideoDimensions) -> Int {
        let actual = Double(size.width) * Double(size.height) / 1_000_000
        // Sensor dimensions include a small margin (8064 x 6048 is marketed as 48 MP).
        return [8, 12, 24, 48].first { abs(Double($0) - actual) < 1.0 } ?? Int(actual.rounded())
    }
    static func dimensions(_ values: [CMVideoDimensions], maximum: CMVideoDimensions) -> [CMVideoDimensions] {
        // 24 MP requires deferred Photos delivery, which cannot provide an App-owned
        // full original through this capture route. Do not advertise proxy dimensions.
        values.filter { pixels($0) != 24 && $0.width <= maximum.width && $0.height <= maximum.height }
            .sorted { Int64($0.width) * Int64($0.height) < Int64($1.width) * Int64($1.height) }
    }
    func resolve(_ wanted: PhotoCaptureProfile, live: Bool) -> PhotoCaptureProfile {
        var value = wanted
        if !formats.contains(value.format) || (live && value.format == .raw) {
            value.format = formats.contains(.heif) ? .heif : .jpeg
        }
        value.processedFormat = value.format == .jpeg || !formats.contains(.heif) ? .jpeg : .heif
        value.megapixels = megapixels.filter { $0 <= wanted.megapixels }.max() ?? megapixels.min() ?? 12
        return value
    }
}

enum PhotoTimer: String, CaseIterable, Identifiable {
    case off = "0", three = "3", five = "5", ten = "10"
    var id: String { rawValue }
    var seconds: Int { Int(rawValue) ?? 0 }
}
