import AVFoundation
import SwiftUI

struct RecordedFrameRate {
    let fps: Int
    let windowStart: Double
}

/// Counts accepted video frames by their media timestamps, not callback speed.
/// Constant memory; one observation per second and no polling timer.
struct VideoFrameRateMeter {
    private var start: Double?
    private var last: Double?
    private var intervals = 0
    private var stable: Int?
    private var pending: Int?

    mutating func consume(_ time: Double) -> RecordedFrameRate? {
        guard time.isFinite else { return nil }
        if let last, time == last { return nil }
        if start == nil || last.map({ time < $0 || time - $0 > 2 }) == true {
            start = time; last = time; intervals = 0; stable = nil; pending = nil
            return nil
        }
        last = time; intervals += 1
        guard let start, time - start >= 1 else { return nil }
        let candidate = max(1, Int((Double(intervals) / (time - start)).rounded()))
        // Require a second window for a one-frame fluctuation; large changes
        // (such as thermal throttling) are reflected immediately.
        if let stable, abs(candidate - stable) == 1, pending != candidate {
            pending = candidate
        } else { stable = candidate; pending = nil }
        self.start = time; intervals = 0
        return RecordedFrameRate(fps: stable ?? candidate, windowStart: start)
    }
}

enum VideoFrameRateReadout {
    static func fps(requested: Int, device: Int?, measured: Int?, recording: Bool, constrained: Bool) -> Int {
        // The actual idle preview cadence is thermally capped by
        // CaptureWorkPolicy. Keep the selected recording rate in the readout
        // until recording starts so the selected 60 fps profile is not shown as
        // a misleading 30 fps value.
        guard recording || constrained else { return requested }
        let applied = max(1, min(requested, device ?? requested))
        return recording ? max(1, min(applied, measured ?? applied)) : applied
    }
}

enum VideoResolution: String, Codable, CaseIterable, Identifiable {
    case hd = "720p", fullHD = "1080p", uhd = "4K"
    var id: String { rawValue }
    var shortEdge: Int { switch self { case .hd: 720; case .fullHD: 1080; case .uhd: 2160 } }
    var longEdge: Int { shortEdge * 16 / 9 }
}

struct VideoRecordingProfile: Codable, Equatable, Hashable {
    var resolution: VideoResolution = VideoResolution(rawValue: CameraDefaults.videoResolution)!
    var fps: Int = CameraDefaults.videoFPS
    static let standard = Self()
    static let frameRates = [24, 30, 60]
    static var all: [Self] {
        VideoResolution.allCases.flatMap { resolution in frameRates.map { Self(resolution: resolution, fps: $0) } }
    }
    var title: String { "\(resolution.rawValue) · \(fps) fps" }
    var rawValue: String { "\(resolution.rawValue)-\(fps)" }
    init(resolution: VideoResolution = VideoResolution(rawValue: CameraDefaults.videoResolution)!, fps: Int = CameraDefaults.videoFPS) { self.resolution = resolution; self.fps = fps }
    init(rawValue: String) {
        let parts = rawValue.split(separator: "-")
        resolution = parts.first.flatMap { VideoResolution(rawValue: String($0)) } ?? VideoResolution(rawValue: CameraDefaults.videoResolution)!
        fps = parts.last.flatMap { Int($0) }.flatMap { Self.frameRates.contains($0) ? $0 : nil } ?? CameraDefaults.videoFPS
    }
    static func current(dual: Bool, defaults: UserDefaults = .standard) -> Self {
        Self(rawValue: CameraDefaults.string(dual ? "cameraDualVideoProfile" : "cameraSingleVideoProfile", in: defaults))
    }
    var portraitSize: CGSize { CGSize(width: resolution.shortEdge, height: resolution.longEdge) }
    var bitRate: Int { Int(Double(resolution.shortEdge * resolution.longEdge) * 4 * Double(fps) / 30) }
    func exportSize(aspect: CGFloat) -> CGSize {
        let short = CGFloat(resolution.shortEdge), long = CGFloat(resolution.longEdge)
        if aspect >= 1 { return CGSize(width: floor(min(long, short * aspect) / 2) * 2, height: short) }
        return CGSize(width: short, height: floor(min(long, short / aspect) / 2) * 2)
    }
    func supports(_ format: AVCaptureDevice.Format, multiCam: Bool = true) -> Bool {
        let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        return (!multiCam || format.isMultiCamSupported) && size.width == resolution.longEdge && size.height == resolution.shortEdge &&
            CameraFormatGeometry.supportsLiveBuffer(CMFormatDescriptionGetMediaSubType(format.formatDescription)) &&
            format.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= Double(fps) && $0.maxFrameRate >= Double(fps) }
    }
    static func nearest(to requested: Self, in available: [Self]) -> Self? {
        available.min {
            func score(_ p: Self) -> Int {
                // Keep resolution first, then prefer a lower frame rate over an increase.
                abs(p.resolution.shortEdge - requested.resolution.shortEdge) * 100 + abs(p.fps - requested.fps) + (p.fps > requested.fps ? 20 : 0)
            }
            return score($0) < score($1)
        }
    }
}

struct VideoRecordingSettingsView: View {
    @AppStorage("cameraLanguage") private var interfaceLanguage = "system"
    let dual: Bool
    let available: [VideoRecordingProfile]
    @Binding var selection: String
    private var selected: VideoRecordingProfile { VideoRecordingProfile(rawValue: selection) }
    var body: some View {
        let _ = interfaceLanguage
        List {
            Section(L10n.text("分辨率")) {
                ForEach(VideoResolution.allCases) { resolution in
                    let profiles = available.filter { $0.resolution == resolution }
                    Button {
                        guard let next = VideoRecordingProfile.nearest(to: .init(resolution: resolution, fps: selected.fps), in: profiles) else { return }
                        selection = next.rawValue
                    } label: {
                        choice(resolution.rawValue, selected: selected.resolution == resolution, enabled: !profiles.isEmpty)
                    }.disabled(profiles.isEmpty).accessibilityIdentifier("videoResolution-" + resolution.rawValue)
                }
            }
            Section(L10n.text("帧率")) {
                ForEach(VideoRecordingProfile.frameRates, id: \.self) { fps in
                    let profile = VideoRecordingProfile(resolution: selected.resolution, fps: fps)
                    let supported = available.contains(profile)
                    Button { selection = profile.rawValue } label: {
                        choice("\(fps) fps", selected: selected.fps == fps, enabled: supported)
                    }.disabled(!supported).accessibilityIdentifier("videoFPS-\(fps)")
                }
            }
            Section {
                Text(L10n.text("更高分辨率保留更多细节；更高帧率让运动更流畅，同时增加文件体积和拍摄负载。"))
                Text(L10n.text("仅开放此设备在当前拍摄方式下支持的规格。宽高比仍按取景设置裁切，原片保留完整画面。"))
                if !available.contains(selected) { Text(L10n.text("所选规格当前不可用，请选择可用档位。")).foregroundStyle(.orange) }
            }.font(.footnote).foregroundStyle(.secondary)
        }
        .navigationTitle(L10n.text(dual ? "双摄录制规格" : "单摄录制规格"))
        .navigationBarTitleDisplayMode(.inline)
    }
    private func choice(_ text: String, selected: Bool, enabled: Bool) -> some View {
        HStack {
            Text(L10n.text(text)).foregroundStyle(enabled ? Color.primary : Color.secondary)
            Spacer()
            if !enabled { Text(L10n.text("不支持")).font(.footnote).foregroundStyle(.secondary) }
            else if selected { Image(systemName: "checkmark").foregroundStyle(.yellow) }
        }.accessibilityValue(L10n.text(selected && enabled ? "已选择" : enabled ? "未选择" : "不支持"))
    }
}

// Probe resource cost without starting the camera. This runs only before the
// capture graph is configured; restore device formats before returning.
enum VideoCapabilityProbe {
    static func supported(groups: [[AVCaptureDevice]]) -> [VideoRecordingProfile] {
        guard !groups.isEmpty, groups.allSatisfy({ !$0.isEmpty }) else { return [] }
        var common = Set(VideoRecordingProfile.all)
        for devices in groups {
            let multiCam = devices.count > 1
            if multiCam && !AVCaptureMultiCamSession.isMultiCamSupported { return [] }
            let session: AVCaptureSession = multiCam ? AVCaptureMultiCamSession() : AVCaptureSession()
            if !multiCam { session.sessionPreset = .inputPriority }
            let original = devices.map { ($0, $0.activeFormat, $0.activeVideoMinFrameDuration, $0.activeVideoMaxFrameDuration) }
            defer {
                session.beginConfiguration()
                session.connections.forEach(session.removeConnection)
                session.inputs.forEach(session.removeInput)
                session.outputs.forEach(session.removeOutput)
                session.commitConfiguration()
                for (device, format, minimum, maximum) in original {
                    if (try? device.lockForConfiguration()) != nil {
                        device.activeFormat = format
                        device.activeVideoMinFrameDuration = minimum; device.activeVideoMaxFrameDuration = maximum
                        device.unlockForConfiguration()
                    }
                }
            }
            var valid = Set<VideoRecordingProfile>()
            for profile in VideoRecordingProfile.all where common.contains(profile) {
                guard devices.allSatisfy({ $0.formats.contains { profile.supports($0, multiCam: multiCam) } }) else { continue }
                session.beginConfiguration()
                session.connections.forEach(session.removeConnection)
                session.inputs.forEach(session.removeInput)
                session.outputs.forEach(session.removeOutput)
                var configured = true
                do {
                    for device in devices {
                        guard let format = bestFormat(device, profile: profile, multiCam: multiCam) else { configured = false; break }
                        try device.lockForConfiguration()
                        device.activeFormat = format
                        let duration = CMTime(value: 1, timescale: Int32(profile.fps))
                        device.activeVideoMinFrameDuration = duration; device.activeVideoMaxFrameDuration = duration
                        device.unlockForConfiguration()
                        let input = try AVCaptureDeviceInput(device: device)
                        guard session.canAddInput(input) else { configured = false; break }
                        session.addInputWithNoConnections(input)
                        input.videoMinFrameDurationOverride = duration
                        guard let port = input.ports(for: .video, sourceDeviceType: device.deviceType, sourceDevicePosition: device.position).first else { configured = false; break }
                        let video = AVCaptureVideoDataOutput()
                        video.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
                        let photo = AVCapturePhotoOutput()
                        photo.maxPhotoQualityPrioritization = .balanced
                        for output: AVCaptureOutput in [video, photo] {
                            guard session.canAddOutput(output) else { configured = false; break }
                            session.addOutputWithNoConnections(output)
                            let connection = AVCaptureConnection(inputPorts: [port], output: output)
                            guard session.canAddConnection(connection) else { configured = false; break }
                            session.addConnection(connection)
                            if output === video, connection.isVideoStabilizationSupported, format.isVideoStabilizationModeSupported(.standard) {
                                connection.preferredVideoStabilizationMode = .standard
                            }
                        }
                    }
                } catch { configured = false }
                session.commitConfiguration()
                if configured && ((session as? AVCaptureMultiCamSession)?.hardwareCost ?? 0) <= 1 { valid.insert(profile) }
            }
            common.formIntersection(valid)
        }
        return VideoRecordingProfile.all.filter(common.contains)
    }
    static func bestFormat(_ device: AVCaptureDevice, profile: VideoRecordingProfile, multiCam: Bool = true) -> AVCaptureDevice.Format? {
        device.formats.filter { profile.supports($0, multiCam: multiCam) }.sorted {
            let a = $0.isVideoStabilizationModeSupported(.standard), b = $1.isVideoStabilizationModeSupported(.standard)
            if a != b { return a }
            return $0.videoFieldOfView > $1.videoFieldOfView
        }.first
    }
}
