import os
import Combine
import AVFoundation
import SwiftUI
import UIKit
import ImageIO

enum CameraPressureLevel: Int, Comparable {
    case normal, fair, serious, critical, shutdown
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

struct CameraPressureCauses: OptionSet, Equatable {
    let rawValue: Int
    static let thermal = Self(rawValue: 1 << 0)
    static let peakPower = Self(rawValue: 1 << 1)
}

struct CameraLoadPlan: Equatable {
    let frameRate: Int32
    let liveFrameRate: Double
    let liveLongEdge: Int
    let notice: String?
}

enum CameraLoadPolicy {
    static func plan(level: CameraPressureLevel, causes: CameraPressureCauses) -> CameraLoadPlan {
        let notice: String?
        switch level {
        case .normal, .fair:
            notice = nil
        case .serious, .critical, .shutdown:
            if causes.contains(.thermal) {
                notice = "相机温度较高，已自动降低拍摄负载"
            } else if causes.contains(.peakPower) {
                notice = "相机功耗较高，已自动降低拍摄负载"
            } else {
                notice = "相机负载较高，已自动优化"
            }
        }
        switch level {
        case .normal:
            return CameraLoadPlan(frameRate: 30, liveFrameRate: 12, liveLongEdge: 720, notice: notice)
        case .fair:
            return CameraLoadPlan(frameRate: 30, liveFrameRate: 10, liveLongEdge: 720, notice: nil)
        case .serious:
            return CameraLoadPlan(frameRate: 24, liveFrameRate: 8, liveLongEdge: 640, notice: notice)
        case .critical, .shutdown:
            return CameraLoadPlan(frameRate: 15, liveFrameRate: 5, liveLongEdge: 540, notice: notice)
        }
    }
}

enum CameraFormatGeometry {
    static func supportsLiveBuffer(_ pixelFormat: OSType) -> Bool {
        pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ||
        pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    }
    // Relative horizontal span at a fixed distance after the 4:3 photo crop.
    // videoFieldOfView is the format's landscape horizontal angle.
    static func photoSpan(width: Int32, height: Int32, fieldOfView: Float) -> Double {
        guard width > 0, height > 0, fieldOfView > 0 else { return 0 }
        let retainedWidth = min(1, (4.0 / 3.0) / (Double(width) / Double(height)))
        return tan(Double(fieldOfView) * .pi / 360) * retainedWidth
    }
}

enum CameraStabilizationPolicy {
    enum Target { case preview, recording }

    static func preferences(for target: Target) -> [AVCaptureVideoStabilizationMode] {
        if target == .preview { return [.previewOptimized] }
        if #available(iOS 26.0, *) { return [.lowLatency, .standard] }
        return [.standard]
    }

    static func preferred(for target: Target, connectionSupported: Bool,
                          formatSupports: (AVCaptureVideoStabilizationMode) -> Bool) -> AVCaptureVideoStabilizationMode {
        guard connectionSupported else { return .off }
        return preferences(for: target).first(where: formatSupports) ?? .off
    }

    static func name(_ mode: AVCaptureVideoStabilizationMode) -> String {
        if #available(iOS 26.0, *), mode == .lowLatency { return "lowLatency" }
        switch mode {
        case .off: return "off"
        case .standard: return "standard"
        case .previewOptimized: return "previewOptimized"
        default: return "mode-\(mode.rawValue)"
        }
    }
}

final class DualCamera: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate,
                        AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    enum State: Equatable {
        case preparing, resuming, ready, denied, unavailable(String), paused
    }

    @Published private(set) var state: State = .preparing
    @Published private(set) var isRecording = false
    @Published private(set) var isStartingVideo = false
    @Published private(set) var isBusy = false
    @Published private(set) var isTakingPhoto = false
    @Published private(set) var pendingSaveCount = 0
    @Published private(set) var saveIssue: String?
    @Published private(set) var latestCaptureThumbnail: UIImage?
    @Published private(set) var latestThumbnailDate = Date.distantPast
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var livePhotoAvailable = false
    @Published private(set) var availableRearZooms = CameraZoomScale.stops(minimum: 0.5, telephoto: 5, sensorCrop: true,
        calibration: CameraFocalCalibration.known(CaptureDeviceInfo.current.hardwareIdentifier))
    @Published private(set) var rearZoom = 1.0
    @Published private(set) var rearZoomRange: ClosedRange<Double> = 0.5...25
    @Published private(set) var frontZoom = 1.0
    @Published private(set) var frontZoomRange: ClosedRange<Double> = 1...1.3
    @Published private(set) var isSwitchingLens = false
    @Published private(set) var cameraLoadNotice: String?
    @Published private(set) var pressureLevel: CameraPressureLevel = .normal
    @Published private(set) var supportedFlashModes: [CameraFlashMode] = [.off]
    @Published private(set) var torchAvailable = false
    @Published private(set) var torchActive = false
    @Published private(set) var singleVideoProfiles: [VideoRecordingProfile] = []
    @Published private(set) var dualVideoProfiles: [VideoRecordingProfile] = []
    @Published private(set) var frontPreviewNeedsMirror = false
    @Published private(set) var actualVideoProfile = VideoRecordingProfile.standard
    private var singleVideoProfile = VideoRecordingProfile.standard
    private var dualVideoProfile = VideoRecordingProfile.standard
    private var activeVideoProfile: VideoRecordingProfile?
    private var deviceVideoFrameRates: [Bool: Int] = [:]
    private var measuredVideoFrameRates: [Bool: Int] = [:]
    private var videoRateMeasurementSince = 0.0
    private var recordingFrontIsPrimary = false
    private var mirrorsFront = true
    @Published private(set) var photoCapabilities = PhotoCaptureCapabilities()
    @Published private(set) var shutterSoundSuppressionSupported: Bool?
    @Published private(set) var enhancedStabilizationAvailable = false
    @Published private(set) var enhancedStabilizationActive = false
    private var enhancedStabilizationRequested = false

    private func usableRAWPixelFormat(_ output: AVCapturePhotoOutput, device: AVCaptureDevice) -> OSType? {
        let formats = output.availableRawPhotoPixelFormatTypes
        if let proRAW = formats.first(where: AVCapturePhotoOutput.isAppleProRAWPixelFormat) { return proRAW }
        // Bayer RAW cannot be captured while digital zoom/cropping is active.
        guard !device.isRampingVideoZoom, abs(device.videoZoomFactor - 1) < 0.001,
              abs((output.connection(with: .video)?.videoScaleAndCropFactor ?? 1) - 1) < 0.001 else { return nil }
        return formats.first(where: AVCapturePhotoOutput.isBayerRAWPixelFormat)
    }

    private func currentPhotoCapabilities(front: Bool) -> PhotoCaptureCapabilities {
        guard let device = front ? frontDevice : rearDevice else { return PhotoCaptureCapabilities(formats: [], megapixels: []) }
        let primary = front ? frontPhotos : rearPhotos
        let outputs = devices.map { $0.position == .front ? frontPhotos : rearPhotos }
        var formats: [PhotoFileFormat] = [.jpeg]
        if !outputs.isEmpty && outputs.allSatisfy({ $0.availablePhotoCodecTypes.contains(.hevc) }) { formats.append(.heif) }
        if usableRAWPixelFormat(primary, device: device) != nil || (!(session is AVCaptureMultiCamSession) && primary.isAppleProRAWSupported) { formats.append(.raw) }
        let dimensions = PhotoCaptureCapabilities.dimensions(device.activeFormat.supportedMaxPhotoDimensions, maximum: primary.maxPhotoDimensions)
        return PhotoCaptureCapabilities(formats: formats, megapixels: Array(Set(dimensions.map(PhotoCaptureCapabilities.pixels))).sorted())
    }

    private func refreshPhotoCapabilities() {
        #if DEBUG && targetEnvironment(simulator)
        if shutterUIFixture {
            publish { $0.photoCapabilities = PhotoCaptureCapabilities(formats: [.jpeg, .heif, .raw], megapixels: [12, 48]); $0.enhancedStabilizationAvailable = true; $0.enhancedStabilizationActive = self.enhancedStabilizationRequested }
            return
        }
        #endif
        let capabilities = currentPhotoCapabilities(front: lightingFront)
        let photoOutputs = devices.map { $0.position == .front ? frontPhotos : rearPhotos }
        let soundSuppressionSupported: Bool?
        if photoOutputs.isEmpty { soundSuppressionSupported = nil }
        else if #available(iOS 18.0, *) {
            soundSuppressionSupported = photoOutputs.allSatisfy { $0.isShutterSoundSuppressionSupported }
        } else { soundSuppressionSupported = false }
        let connections = stabilizationConnections.filter { $0.3 == .recording }
        let enhanced = !connections.isEmpty && connections.allSatisfy { _, device, connection, _ in
            connection.isVideoStabilizationSupported && device.activeFormat.isVideoStabilizationModeSupported(.cinematic)
        }
        let active = captureVideoMode && enhancedStabilizationRequested && enhanced && stabilizationEnabled &&
            connections.allSatisfy { $0.2.activeVideoStabilizationMode == .cinematic }
        publish {
            $0.photoCapabilities = capabilities; $0.enhancedStabilizationAvailable = enhanced; $0.enhancedStabilizationActive = active
            $0.shutterSoundSuppressionSupported = soundSuppressionSupported
        }
    }

    func setPhotoPreferences(live: Bool) {
        queue.async { [self] in
            guard recording == nil, photoCapture == nil else { return }
            let raw = PhotoCaptureProfile.current().format == .raw && !live && !captureVideoMode
            for output in [rearPhotos, frontPhotos] where session.outputs.contains(output) {
                if !(session is AVCaptureMultiCamSession), output.isAppleProRAWSupported, output.isAppleProRAWEnabled != raw {
                    output.isAppleProRAWEnabled = raw
                }
            }
            refreshPhotoCapabilities()
        }
    }

    func setEnhancedStabilization(_ enabled: Bool) {
        queue.async { [self] in
            guard recording == nil, enhancedStabilizationRequested != enabled else { return }
            enhancedStabilizationRequested = enabled
            for (device, preview, output) in [(rearDevice, rearPreview, rearVideo), (frontDevice, frontPreview, frontVideo)] {
                if let device { configureStabilization(device: device, preview: preview, output: output) }
            }
            refreshPhotoCapabilities()
            verifyStabilization(after: 0.5, event: "enhanced-stabilization")
        }
    }

    func setRecordingPreferences(single: VideoRecordingProfile, dual: VideoRecordingProfile, mirror: Bool) async {
        #if DEBUG && targetEnvironment(simulator)
        if shutterUIFixture {
            await MainActor.run { singleVideoProfile = single; dualVideoProfile = dual; actualVideoProfile = captureIsDual ? dual : single }
            return
        }
        #endif
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                defer { continuation.resume() }
                guard recording == nil, photoCapture == nil else { return }
                let selectedChanged = captureIsDual ? dualVideoProfile != dual : singleVideoProfile != single
                singleVideoProfile = single; dualVideoProfile = dual
                if mirrorsFront != mirror {
                    liveBuffer.setEnabled(false)
                    mirrorsFront = mirror
                    for output: AVCaptureOutput in [frontPhotos, frontVideo] {
                        if let connection = output.connection(with: .video), connection.isVideoMirroringSupported {
                            connection.automaticallyAdjustsVideoMirroring = false
                            connection.isVideoMirrored = mirror
                        }
                    }
                    publish { $0.frontPreviewNeedsMirror = !mirror }
                    refreshLiveBuffer()
                }
                if selectedChanged, configured, wantsRunning, captureVideoMode {
                    do { try prepareVideoFormat() } catch { publish { $0.message = error.localizedDescription } }
                }
            }
        }
    }

    // Cache against the exact route, OS and build. A fallback camera must never
    // inherit another camera's recording capabilities.
    private var videoCapabilitiesLoaded = false
    private var routeProfiles: [String: [VideoRecordingProfile]] = [:]
    private func profiles(for devices: [AVCaptureDevice]) -> [VideoRecordingProfile] {
        guard !devices.isEmpty else { return [] }
        let key = "cameraRouteProfiles-" + devices.map(\.uniqueID).sorted().joined(separator: "|") + "-" +
            ProcessInfo.processInfo.operatingSystemVersionString + "-" +
            (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "")
        if let cached = routeProfiles[key] { return cached }
        if let data = UserDefaults.standard.data(forKey: key),
           let cached = try? JSONDecoder().decode([VideoRecordingProfile].self, from: data), !cached.isEmpty {
            routeProfiles[key] = cached; return cached
        }
        let result = VideoCapabilityProbe.supported(groups: [devices])
        routeProfiles[key] = result
        if !result.isEmpty, let data = try? JSONEncoder().encode(result) { UserDefaults.standard.set(data, forKey: key) }
        return result
    }
    private func updateVideoCapabilities() {
        #if DEBUG && targetEnvironment(simulator)
        publish { $0.singleVideoProfiles = VideoRecordingProfile.all; $0.dualVideoProfiles = $0.supportsDualCapture ? VideoRecordingProfile.all.filter { $0.resolution != .uhd } : [] }
        #else
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized,
              !configured, !videoCapabilitiesLoaded else { return }
        videoCapabilitiesLoaded = true
        let back = AVCaptureDevice.default(.builtInTripleCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        let single = back.map { profiles(for: [$0]) } ?? []
        publish { $0.singleVideoProfiles = single }
        #endif
    }

    private var cachedVideoFormats: [String: AVCaptureDevice.Format] = [:]
    private func videoFormat(for device: AVCaptureDevice, profile: VideoRecordingProfile) -> AVCaptureDevice.Format? {
        let key = device.uniqueID + "-" + profile.rawValue + "-" + String(captureIsDual)
        if let format = cachedVideoFormats[key] { return format }
        let format = VideoCapabilityProbe.bestFormat(device, profile: profile, multiCam: captureIsDual)
        cachedVideoFormats[key] = format
        return format
    }

    private func prepareVideoFormat() throws {
        let requested = captureIsDual ? dualVideoProfile : singleVideoProfile
        if activeVideoProfile == requested {
            refreshLiveBuffer()
            applyLoadPlan(CameraLoadPolicy.plan(level: appliedPressureLevel, causes: []), level: appliedPressureLevel, force: true)
            return
        }
        if !captureVideoMode, !devices.isEmpty, devices.allSatisfy({ device in
            let size = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
            return size.width >= requested.resolution.longEdge && size.height >= requested.resolution.shortEdge &&
                size.width <= requested.resolution.longEdge * 2 &&
                abs(device.activeVideoMinFrameDuration.seconds - 1 / Double(requested.fps)) < 0.001 &&
                abs(device.activeVideoMaxFrameDuration.seconds - 1 / Double(requested.fps)) < 0.001
        }) {
            recordingReusesPhotoFormat = true
            activeVideoProfile = requested
            liveBuffer.setEnabled(false)
            refreshVideoReadout()
            return
        }
        recordingReusesPhotoFormat = false
        guard devices.allSatisfy({ videoFormat(for: $0, profile: requested) != nil }) else {
            throw CamError.message("当前镜头不支持 \(requested.title)，请在设置中选择其他录制规格。")
        }
        let oldProfile = activeVideoProfile
        let oldFormats = devices.map { ($0, $0.activeFormat) }
        let oldRates = devices.map { ($0, $0.activeVideoMinFrameDuration, $0.activeVideoMaxFrameDuration) }
        liveBuffer.setEnabled(false)
        session.beginConfiguration()
        var committed = false
        do {
            for device in devices {
                guard let format = videoFormat(for: device, profile: requested) else { continue }
                try device.lockForConfiguration()
                device.activeFormat = format
                let duration = CMTime(value: 1, timescale: Int32(requested.fps))
                device.activeVideoMinFrameDuration = duration; device.activeVideoMaxFrameDuration = duration
                device.unlockForConfiguration()
                session.inputs.compactMap { $0 as? AVCaptureDeviceInput }.first { $0.device === device }?.videoMinFrameDurationOverride = duration
                let front = device.position == .front
                configurePhotoDimensions(front ? frontPhotos : rearPhotos, device: device)
                configureStabilization(device: device, preview: front ? frontPreview : rearPreview, output: front ? frontVideo : rearVideo)
            }
            session.commitConfiguration(); committed = true
            guard hardwareCost <= 1 else { throw CamError.message("当前双摄组合无法稳定录制 \(requested.title)，请选择较低规格。") }
            activeVideoProfile = requested
            applyLoadPlan(CameraLoadPolicy.plan(level: appliedPressureLevel, causes: []), level: appliedPressureLevel, force: true)
        } catch {
            if !committed { session.commitConfiguration() }
            session.beginConfiguration()
            for (device, format) in oldFormats {
                if (try? device.lockForConfiguration()) != nil {
                    device.activeFormat = format
                    if let rate = oldRates.first(where: { $0.0 === device }) {
                        device.activeVideoMinFrameDuration = rate.1; device.activeVideoMaxFrameDuration = rate.2
                        session.inputs.compactMap { $0 as? AVCaptureDeviceInput }.first { $0.device === device }?.videoMinFrameDurationOverride = rate.1
                    }
                    device.unlockForConfiguration()
                    configurePhotoDimensions(device.position == .front ? frontPhotos : rearPhotos, device: device)
                }
            }
            session.commitConfiguration()
            activeVideoProfile = oldProfile
            refreshVideoReadout()
            refreshLiveBuffer()
            throw error
        }
    }

    private func restorePhotoFormat() {
        guard activeVideoProfile != nil, recording == nil, photoCapture == nil else { return }
        if recordingReusesPhotoFormat {
            recordingReusesPhotoFormat = false; activeVideoProfile = nil
            refreshLiveBuffer()
            return
        }
        session.beginConfiguration()
        for device in devices {
            do {
                try selectFormat(device, maximumWidth: 1920)
                configurePhotoDimensions(device.position == .front ? frontPhotos : rearPhotos, device: device)
                configureStabilization(device: device, preview: device.position == .front ? frontPreview : rearPreview,
                                       output: device.position == .front ? frontVideo : rearVideo)
            } catch { publish { $0.message = error.localizedDescription } }
        }
        activeVideoProfile = nil
        session.commitConfiguration()
        applyLoadPlan(CameraLoadPolicy.plan(level: appliedPressureLevel, causes: []), level: appliedPressureLevel, force: true)
        refreshLiveBuffer()
    }

    private var lightingFront = false
    private var wantsTorch = false
    private var stabilizationEnabled = true

    func setLighting(front: Bool, torch: Bool) {
        queue.async { [self] in
            lightingFront = front
            refreshVideoReadout()
            wantsTorch = torch
            applyLighting()
        }
    }

    private func applyLighting() {
        let primary = lightingFront ? frontDevice : rearDevice
        let output = lightingFront ? frontPhotos : rearPhotos
        let modes = CameraFlashMode.allCases.filter { mode in
            mode == .off || (primary?.isFlashAvailable == true && output.supportedFlashModes.contains(mode.avMode))
        }
        var active = false
        for device in devices where device.hasTorch {
            let turnOn = wantsRunning && wantsTorch && device === primary && device.isTorchAvailable
            guard device.torchMode != (turnOn ? .on : .off) else { active = active || turnOn; continue }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                if turnOn { try device.setTorchModeOn(level: min(0.5, AVCaptureDevice.maxAvailableTorchLevel)); active = true }
                else { device.torchMode = .off }
            } catch { publish { $0.message = "补光灯暂时不可用：\(error.localizedDescription)" } }
        }
        refreshPhotoCapabilities()
        let available = primary?.isTorchAvailable == true
        let isActive = active
        publish { $0.supportedFlashModes = modes; $0.torchAvailable = available; $0.torchActive = isActive }
    }

    func setStabilizationEnabled(_ enabled: Bool) {
        queue.async { [self] in
            guard recording == nil, stabilizationEnabled != enabled else { return }
            stabilizationEnabled = enabled
            for (device, preview, output) in [(rearDevice, rearPreview, rearVideo), (frontDevice, frontPreview, frontVideo)] {
                if let device { configureStabilization(device: device, preview: preview, output: output) }
            }
            refreshPhotoCapabilities()
            verifyStabilization(after: 0.8, event: "user-stabilization")
        }
    }
    @Published private(set) var rearUsesStabilizedFrames = true
    @Published private(set) var frontUsesStabilizedFrames = true
    @Published private(set) var rearPreviewSize = CGSize(width: 1080, height: 1920)
    @Published private(set) var frontPreviewSize = CGSize(width: 1080, height: 1920)
    @Published var message: String?
    @Published private(set) var previewReady = false
    private var previewWarmup: (after: CMTime, rear: Int, front: Int)?
    private var previewHasWarmed = false
    private let startupLog = OSLog(subsystem: "com.tison.dualcam", category: "Startup")
    private var startupSignpost: OSSignpostID?
    let savedMedia = PassthroughSubject<MemoryItem, Never>()
    @Published private(set) var savedCount = 0

    private(set) var session: AVCaptureSession = AVCaptureSession()
    private var hardwareCost: Float { (session as? AVCaptureMultiCamSession)?.hardwareCost ?? 0 }
    private var systemPressureCost: Float { (session as? AVCaptureMultiCamSession)?.systemPressureCost ?? 0 }
    let supportsDualCapture = CameraDeviceCapabilities.supportsDualCapture
    var availableCaptureModes: [CameraCaptureMode] { CameraDeviceCapabilities.modes(dual: supportsDualCapture) }

    private var rearPreview = AVCaptureVideoPreviewLayer()
    private var frontPreview = AVCaptureVideoPreviewLayer()
    let rearStabilizedPreview = AVSampleBufferDisplayLayer()
    let frontStabilizedPreview = AVSampleBufferDisplayLayer()
    private var rearVideoSize = CGSize(width: 1080, height: 1920)
    private var frontVideoSize = CGSize(width: 1080, height: 1920)
    private var rearUsesVideoDisplay = true
    private var frontUsesVideoDisplay = true
    private var rearDisplayedFrames = 0
    private var frontDisplayedFrames = 0
    private let queue = DispatchQueue(label: "cam.capture", qos: .userInitiated)
    private let disk: LibraryDisk
    private let metadataProvider: CaptureMetadataProvider
    private var rearPhotos = AVCapturePhotoOutput()
    private var frontPhotos = AVCapturePhotoOutput()
    private var rearVideo = AVCaptureVideoDataOutput()
    private var frontVideo = AVCaptureVideoDataOutput()
    private var audioOutput = AVCaptureAudioDataOutput()
    private var audioInput: AVCaptureDeviceInput?
    private var rearDevice: AVCaptureDevice?
    private var standardRearDevice: AVCaptureDevice?
    private var telephotoDevice: AVCaptureDevice?
    private var alternateUltraWideDevice: AVCaptureDevice?
    private var alternateUltraWideZoom = 0.5
    private var telephotoZoom: Double?
    private var requestedRearZoom = 1.0
    private var appliedRearZoom = 1.0
    private var supportedRearZoomRange: ClosedRange<Double> = 0.5...25
    private let zoomRequestLock = NSLock()
    private var zoomRequest: (Double, Bool)?
    private var zoomWorkScheduled = false
    private var zoomObserver: NSKeyValueObservation?
    private var zoomVerification: DispatchWorkItem?
    private var captureVideoMode = false
    private var rearPhotoMaximum = 25.0
    private var rearVideoMaximum = 15.0
    private var rearZoomStops: [CameraZoomPreset] = []
    private var frontRequest: (Double, Bool)?
    private var frontWorkScheduled = false
    private var supportedFrontZoomRange: ClosedRange<Double> = 1...1.3
    private var deferredLensSwitch: DispatchWorkItem?
    private var deferredLensID: String?
    private var cachedFormats: [String: AVCaptureDevice.Format] = [:]
    #if DEBUG
    private var zoomSwitchCount = 0
    private var zoomSwitchMilliseconds: [Double] = []
    private var zoomSwitchStages: [[String: Double]] = []
    private var lastRearFrameTime: Double?
    private var zoomFrameIntervals: [Double] = []
    private var measuringZoomFrames = false
    #endif
    #if DEBUG
    private var didRunZoomAudit = false
    #endif
    private var frontDevice: AVCaptureDevice?
    private var devices: [AVCaptureDevice] = []
    private var configured = false
    private var captureIsDual = true
    private var captureFront = false
    private var captureOrientation = CameraOrientation.portrait

    func setCaptureOrientation(_ orientation: CameraOrientation) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard recording == nil, recordingStartID == nil, photoCapture == nil else { continuation.resume(returning: false); return }
                guard captureOrientation != orientation else { continuation.resume(returning: true); return }
                liveBuffer.setEnabled(false)
                captureOrientation = orientation
                for connection in session.connections where connection.inputPorts.contains(where: { $0.mediaType == .video }) {
                    if connection.isVideoOrientationSupported { connection.videoOrientation = orientation.video }
                }
                rearStabilizedPreview.sampleBufferRenderer.flush()
                frontStabilizedPreview.sampleBufferRenderer.flush()
                refreshLiveBuffer()
                continuation.resume(returning: true)
            }
        }
    }

    // Mode and source are one transaction: never configure the new camera using
    // the previous photo/video format. A running session commits the graph in place.
    @discardableResult
    func setCaptureSource(isDual: Bool, front: Bool) async -> Bool {
        await configureCaptureSource(isDual: isDual, front: front, kind: nil)
    }

    @discardableResult
    func setCaptureMode(_ mode: CameraCaptureMode, front: Bool) async -> Bool {
        await configureCaptureSource(isDual: mode.isDual, front: front, kind: mode.kind)
    }

    private func configureCaptureSource(isDual: Bool, front: Bool, kind: CaptureKind?) async -> Bool {
        #if DEBUG && targetEnvironment(simulator)
        if shutterUIFixture {
            await MainActor.run {
                captureIsDual = isDual; captureFront = front
                actualVideoProfile = isDual ? dualVideoProfile : singleVideoProfile
            }
            if let kind { await setCaptureKind(kind) }
            return true
        }
        #endif
        return await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard recording == nil, photoCapture == nil else {
                    continuation.resume(returning: false); return
                }
                guard !isDual || supportsDualCapture else { continuation.resume(returning: false); return }
                let previous = (captureIsDual, captureFront, captureVideoMode)
                let sourceChanged = captureIsDual != isDual || (!isDual && captureFront != front)
                let video = kind.map { $0 == .video } ?? captureVideoMode
                let kindChanged = video != captureVideoMode
                captureIsDual = isDual; captureFront = front; captureVideoMode = video
                guard configured else { continuation.resume(returning: true); return }
                guard sourceChanged || kindChanged else { continuation.resume(returning: true); return }
                wantsTorch = false; applyLighting()
                liveBuffer.setEnabled(false)
                if sourceChanged { publish { $0.state = .resuming } }
                // Under pressure, changing the running graph can be rejected by
                // the capture service after commit. Use the conservative path.
                if sourceChanged, appliedPressureLevel >= .serious, session.isRunning { session.stopRunning() }
                let replacingSession = previous.0 != isDual
                if replacingSession {
                    if session.isRunning { session.stopRunning() }
                } else { session.beginConfiguration() }
                func rebuild() throws {
                    zoomVerification?.cancel(); zoomObserver = nil
                    deferredLensSwitch?.cancel(); deferredLensSwitch = nil; deferredLensID = nil
                    zoomRequestLock.lock(); zoomRequest = nil; zoomRequestLock.unlock()
                    configured = false; activeVideoProfile = nil
                    rearDevice = nil; frontDevice = nil; standardRearDevice = nil
                    telephotoDevice = nil; telephotoZoom = nil; alternateUltraWideDevice = nil; devices = []
                    requestedRearZoom = 1; appliedRearZoom = 1
                    try configure()
                    if captureVideoMode { try prepareVideoFormat() }
                    applyLoadPlan(CameraLoadPolicy.plan(level: appliedPressureLevel, causes: []), level: appliedPressureLevel, force: true)
                    if wantsRunning, AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
                        try addMicrophone()
                    }
                }
                var success = true
                do {
                    if sourceChanged { try rebuild() }
                    else if video { try prepareVideoFormat() }
                    else { restorePhotoFormat(); removeMicrophone() }
                } catch {
                    success = false
                    captureIsDual = previous.0; captureFront = previous.1; captureVideoMode = previous.2
                    do {
                        if sourceChanged { try rebuild() }
                        else if captureVideoMode { try prepareVideoFormat() }
                        else { restorePhotoFormat() }
                        publish { $0.message = "切换未完成，已恢复原模式：\(error.localizedDescription)" }
                    } catch { publish { $0.state = .unavailable(error.localizedDescription) } }
                }
                if !replacingSession { session.commitConfiguration() }
                warmRecordingResources()
                refreshLiveBuffer()
                refreshRearZoomRange(video: captureVideoMode)
                if wantsRunning, !session.isRunning { session.startRunning() }
                if configured, session.isRunning { publish { $0.state = .ready } }
                else if !wantsRunning { publish { $0.state = .paused } }
                else { success = false; publish { $0.state = .unavailable("相机切换后未能启动。") } }
                continuation.resume(returning: success)
                // Snapshot only after the caller can proceed; file I/O has its own queue.
                recordStabilizationDiagnostics(event: "capture-mode-changed")
            }
        }
    }

    private struct PreviewWait {
        let id = UUID()
        let after: CMTime
        let dual: Bool
        let front: Bool
        var rearFrames = 0
        var frontFrames = 0
        let continuation: CheckedContinuation<Bool, Never>
    }
    private var previewWait: PreviewWait?
    private var lastSessionError = ""

    func cancelModePreviewWait() {
        queue.async { [self] in finishPreviewWait(false) }
    }

    private func finishPreviewWait(_ ready: Bool) {
        let waiting = previewWait
        previewWait = nil
        waiting?.continuation.resume(returning: ready)
    }

    /// Wait for a frame captured after configuration, not a stale queued sample.
    func waitForModePreview() async -> Bool {
        #if DEBUG && targetEnvironment(simulator)
        if shutterUIFixture {
            try? await Task.sleep(for: .milliseconds(120))
            return !Task.isCancelled
        }
        #endif
        return await withCheckedContinuation { continuation in
            queue.async { [self] in
                finishPreviewWait(false)
                guard wantsRunning, session.isRunning else { continuation.resume(returning: false); return }
                let waiting = PreviewWait(after: CMClockGetTime(CMClockGetHostTimeClock()),
                    dual: captureIsDual, front: captureFront, continuation: continuation)
                previewWait = waiting
                queue.asyncAfter(deadline: .now() + 3) { [weak self] in
                    guard self?.previewWait?.id == waiting.id else { return }
                    self?.finishPreviewWait(false)
                }
            }
        }
    }

    private func beginPreviewWarmup() {
        if let id = startupSignpost { os_signpost(.end, log: startupLog, name: "Preview readiness", signpostID: id) }
        let id = OSSignpostID(log: startupLog); startupSignpost = id
        os_signpost(.begin, log: startupLog, name: "Preview readiness", signpostID: id)
        previewHasWarmed = false
        previewWarmup = (CMClockGetTime(CMClockGetHostTimeClock()), 0, 0)
        publish { $0.previewReady = false }
    }

    private func acceptStartupPreview(_ sample: CMSampleBuffer, front: Bool) {
        guard var warmup = previewWarmup, wantsRunning,
              CMSampleBufferGetPresentationTimeStamp(sample) > warmup.after else { return }
        if front { warmup.front += 1 } else { warmup.rear += 1 }
        previewWarmup = warmup
        let ready = captureIsDual ? warmup.rear >= 2 && warmup.front >= 2 : (captureFront ? warmup.front >= 2 : warmup.rear >= 2)
        if ready {
            previewWarmup = nil; previewHasWarmed = true
            if let id = startupSignpost { os_signpost(.end, log: startupLog, name: "Preview readiness", signpostID: id) }
            startupSignpost = nil
            publish { $0.previewReady = true }
        }
    }

    private func acceptModePreview(_ sample: CMSampleBuffer, front: Bool) {
        acceptStartupPreview(sample, front: front)
        guard var waiting = previewWait,
              CMSampleBufferGetPresentationTimeStamp(sample) > waiting.after else { return }
        if front { waiting.frontFrames += 1 } else { waiting.rearFrames += 1 }
        previewWait = waiting
        if (waiting.dual && waiting.rearFrames >= 2 && waiting.frontFrames >= 2) ||
            (!waiting.dual && (waiting.front ? waiting.frontFrames >= 2 : waiting.rearFrames >= 2)) {
            finishPreviewWait(true)
        }
    }

    #if DEBUG
    func modeAuditSnapshot() async -> [String: Any] {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                continuation.resume(returning: ["dual": captureIsDual, "sessionClass": String(describing: type(of: session)), "front": captureFront, "video": captureVideoMode,
                    "running": session.isRunning, "videoInputs": devices.count,
                    "photoOutputs": session.outputs.filter { $0 is AVCapturePhotoOutput }.count,
                    "videoOutputs": session.outputs.filter { $0 is AVCaptureVideoDataOutput }.count,
                    "formats": devices.map { String(describing: CMVideoFormatDescriptionGetDimensions($0.activeFormat.formatDescription)) },
                    "pressure": appliedPressureLevel.rawValue, "sessionError": lastSessionError])
            }
        }
    }
    #endif

    private func matchesSource(_ layout: CameraLayout) -> Bool {
        layout.isDual == captureIsDual && (captureIsDual || layout.frontIsPrimary == captureFront)
    }
    private var wantsRunning = false
    private var recording: BufferedVideoRecorder?
    private var recordingNotBefore: CMTime = .zero
    private var recordingStartID: UUID?
    private var activeVideoRequestID: UUID?
    private var recordingStartCompletion: CheckedContinuation<Bool, Never>?
    private var recordingReusesPhotoFormat = false
    private var cachedAudioSettings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 44100, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 128000]
    private var photoCapture: PhotoPairCapture?
    private lazy var liveBuffer = LivePhotoBuffer(callbackQueue: queue)
    private var liveBufferingEnabled = false
    private var liveCoordinators: [UUID: LivePhotoCaptureCoordinator] = [:]
    private var finishingVideos = Set<UUID>()
    private let saveQueue = DispatchQueue(label: "cam.original-save", qos: .utility)
    private var outstandingSaves: Int { liveCoordinators.count + finishingVideos.count }
    // Bound JPEG and overlapping Live windows if storage becomes slower than capture.
    private let maximumOutstandingSaves = 6
    private var saving: Bool { !finishingVideos.isEmpty }
    private var tokens: [NSObjectProtocol] = []
    private var pressureObservers: [NSKeyValueObservation] = []
    private var stabilizationObservers: [NSKeyValueObservation] = []
    #if DEBUG
    private var stabilizationDiagnostics: [[String: Any]] = []
    private var shutterSoundDiagnostics: [[String: Any]] = []
    private var lastFocusDiagnostic: [String: Any] = [:]
    #endif
    private var pressureSnapshots: [String: (level: CameraPressureLevel, causes: CameraPressureCauses)] = [:]
    private var appliedPressureLevel: CameraPressureLevel = .normal
    private var systemEnergy = CaptureEnergyState.current
    private var recoveryTarget: CameraPressureLevel?
    private var pressureNoticeWorkItem: DispatchWorkItem?
    private var pressureRecoveryWorkItem: DispatchWorkItem?
    private var lastElapsedUpdate: Double = 0
    #if !CAM_CAPTURE_EXTENSION
    private var backgroundSaveTask: UIBackgroundTaskIdentifier = .invalid
    #endif
    private var rearFocusRequest = UUID()
    private var frontFocusRequest = UUID()

    init(disk: LibraryDisk, metadataProvider: CaptureMetadataProvider) {
        self.disk = disk
        self.metadataProvider = metadataProvider
        super.init()
        queue.async { [self] in updateVideoCapabilities() }
        rearPreview.videoGravity = .resizeAspectFill
        frontPreview.videoGravity = .resizeAspectFill
        rearStabilizedPreview.videoGravity = .resizeAspectFill
        frontStabilizedPreview.videoGravity = .resizeAspectFill
        session.automaticallyConfiguresApplicationAudioSession = false
        session.sessionPreset = .inputPriority
        #if DEBUG
        queue.async { [self] in
            let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("CamDiagnostics/stabilization.json")
            if let data = try? Data(contentsOf: url),
               let records = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                stabilizationDiagnostics = Array(records.suffix(100))
            }
        }
        #endif
        observeSession()
    }

    #if DEBUG && CAM_MAIN_APP
    @MainActor
    private func runRecordingResilienceAudit() async {
        let oldIdle = UIApplication.shared.isIdleTimerDisabled
        let oldSingle = singleVideoProfile, oldDual = dualVideoProfile
        UIApplication.shared.isIdleTimerDisabled = true
        try? await Task.sleep(for: .seconds(2))
        var rows: [[String: Any]] = []
        for (name, mode, profile, interruption) in [
            ("single", CameraCaptureMode.singleVideo, VideoRecordingProfile.standard, false),
            ("dual", .dualVideo, .standard, false),
            ("dual-4k", .dualVideo, .init(resolution: .uhd, fps: 30), false),
            ("system-interruption-injected", .dualVideo, .standard, true)] {
            guard UIApplication.shared.applicationState == .active else { break }
            guard (mode.isDual ? dualVideoProfiles : singleVideoProfiles).contains(profile) else {
                rows.append(["scenario": name, "unsupported": true]); continue
            }
            await setRecordingPreferences(single: profile, dual: profile, mirror: mirrorsFront)
            guard await setCaptureMode(mode, front: false) else { break }
            try? await Task.sleep(for: .seconds(0.5))
            let count = savedCount
            guard await startVideo(layout: CameraLayout(singleCamera: !mode.isDual, aspect: .wide)) else {
                rows.append(["scenario": name, "startFailed": true, "message": message ?? ""]); break
            }
            try? await Task.sleep(for: .seconds(1))
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                queue.async { [self] in
                    recording?.performOnWriterForTesting { Thread.sleep(forTimeInterval: 0.9) }
                    continuation.resume()
                }
            }
            try? await Task.sleep(for: .seconds(2.5))
            let survived = isRecording
            if interruption {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    queue.async { [self] in
                        NotificationCenter.default.post(name: AVCaptureSession.wasInterruptedNotification, object: session,
                            userInfo: [AVCaptureSessionInterruptionReasonKey: NSNumber(value: 2)])
                        continuation.resume()
                    }
                }
            } else { stopVideo(source: "backpressure-audit") }
            for _ in 0..<100 {
                if savedCount > count && !isRecording { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            let item = try? disk.load().first
            var row: [String: Any] = ["scenario": name, "survivedCongestion": survived,
                "saved": savedCount > count, "note": item?.captureNote ?? "", "id": item?.id.uuidString ?? ""]
            if let diagnostics = item?.recordingDiagnostics,
               let data = try? JSONEncoder().encode(diagnostics),
               let object = try? JSONSerialization.jsonObject(with: data) { row["diagnostics"] = object }
            rows.append(row)
            if !survived || savedCount == count { break }
        }
        await setRecordingPreferences(single: oldSingle, dual: oldDual, mirror: mirrorsFront)
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("CamDiagnostics")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
            .write(to: folder.appendingPathComponent("recording-resilience-audit.json"), options: .atomic)
        pause()
        UIApplication.shared.isIdleTimerDisabled = oldIdle
    }

    @MainActor
    private func runVideoReadoutAudit() async {
        let oldIdle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        let oldSingle = singleVideoProfile, oldDual = dualVideoProfile
        var rows: [[String: Any]] = []
        try? await Task.sleep(for: .seconds(2))
        await setRecordingPreferences(single: .standard, dual: .standard, mirror: mirrorsFront)
        for mode in [CameraCaptureMode.singleVideo, .dualVideo] {
            guard UIApplication.shared.applicationState == .active,
                  await setCaptureMode(mode, front: false) else { break }
            let layout = CameraLayout(singleCamera: !mode.isDual, aspect: .wide)
            guard await startVideo(layout: layout) else { break }
            for (phase, requestedLevel) in [("normal", CameraPressureLevel.normal), ("reduced", .serious), ("critical", .critical), ("recovered", .normal)] {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    queue.async { [self] in
                        // Exercise the same rate application without heating the
                        // phone or overriding any real thermal protection.
                        systemEnergy = .current
                        let level = max(requestedLevel, combinedPressure)
                        applyLoadPlan(CameraLoadPolicy.plan(level: level, causes: []), level: level, force: true)
                        continuation.resume()
                    }
                }
                try? await Task.sleep(for: .seconds(3.5))
                var row: [String: Any] = await withCheckedContinuation { continuation in
                    queue.async { [self] in
                        continuation.resume(returning: ["mode": mode.rawValue, "phase": phase,
                            "appliedLevel": appliedPressureLevel.rawValue,
                            "deviceFPS": devices.map { 1 / $0.activeVideoMaxFrameDuration.seconds },
                            "measuredRear": measuredVideoFrameRates[false] ?? -1,
                            "measuredFront": measuredVideoFrameRates[true] ?? -1,
                            "targetFPS": activeVideoProfile?.fps ?? -1,
                            "recordingID": recording?.draft.item.id.uuidString ?? ""])
                    }
                }
                row["displayedFPS"] = actualVideoProfile.fps
                row["displayedResolution"] = actualVideoProfile.resolution.rawValue
                rows.append(row)
                if mode.isDual, phase == "critical" {
                    var frontLayout = layout; frontLayout.frontIsPrimary = true
                    updateLayout(frontLayout)
                    try? await Task.sleep(for: .milliseconds(300))
                    rows.append(["mode": mode.rawValue, "phase": "front-primary", "displayedFPS": actualVideoProfile.fps])
                }
            }
            stopVideo(source: "readout-audit")
            for _ in 0..<100 {
                if !isRecording && !isBusy && pendingSaveCount == 0 { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        await setRecordingPreferences(single: oldSingle, dual: oldDual, mirror: mirrorsFront)
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("CamDiagnostics")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
            .write(to: folder.appendingPathComponent("video-readout-audit.json"), options: .atomic)
        pause()
        UIApplication.shared.isIdleTimerDisabled = oldIdle
    }

    @MainActor
    private func runShutterLiveAudit() async {
        // Let CaptureScreen finish applying its startup preferences, then test
        // Live in a photo session rather than racing the initial mode change.
        try? await Task.sleep(for: .seconds(2))
        guard await setCaptureMode(.dualPhoto, front: false) else { return }
        await setLivePhotoEnabled(true)
        try? await Task.sleep(for: .seconds(3))
        let count = savedCount
        let existingIDs = Set((try? disk.load().map(\.id)) ?? [])
        await takePhoto(layout: CameraLayout(), live: true)
        for _ in 0..<150 {
            if savedCount > count && !isBusy { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        let items = (try? disk.load().filter { !existingIDs.contains($0.id) }) ?? []
        var report: [String: Any] = ["saved": savedCount > count && !isBusy,
            "items": items.map { ["id": $0.id.uuidString, "live": $0.isLivePhoto] },
            "cameraMessage": message ?? ""]
        report["shutterSound"] = await withCheckedContinuation { continuation in
            queue.async { [self] in continuation.resume(returning: shutterSoundDiagnostics) }
        }
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CamDiagnostics")
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: folder.appendingPathComponent("shutter-live-audit.json"), options: .atomic)
        pause()
    }

    @MainActor
    private func runThermalAudit() async {
        let oldSingle = singleVideoProfile, oldDual = dualVideoProfile
        let oldIdle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        var rows: [[String: Any]] = []
        func safe() -> Bool {
            UIApplication.shared.applicationState == .active && ProcessInfo.processInfo.thermalState.rawValue < 2
        }
        func snapshot(_ phase: String) async {
            let row: [String: Any] = await withCheckedContinuation { continuation in
                queue.async { [self] in
                    recordStabilizationDiagnostics(event: "thermal-audit-" + phase)
                    continuation.resume(returning: ["phase": phase, "thermal": ProcessInfo.processInfo.thermalState.rawValue,
                        "live": liveBuffer.diagnostics, "running": session.isRunning, "microphone": audioInput != nil,
                        "fps": devices.map { 1 / $0.activeVideoMinFrameDuration.seconds },
                        "hardwareCost": hardwareCost, "pressureCost": systemPressureCost])
                }
            }
            rows.append(row)
        }
        await setRecordingPreferences(single: .standard, dual: .standard, mirror: mirrorsFront)
        for (name, mode, live) in [("photo-idle", CameraCaptureMode.dualPhoto, false),
                                    ("photo-live", .dualPhoto, true), ("video-live-preference", .dualVideo, true)] {
            guard safe() else { rows.append(["stoppedForThermalOrBackground": name]); break }
            _ = await setCaptureMode(mode, front: false)
            await setLivePhotoEnabled(live)
            try? await Task.sleep(for: .seconds(2))
            await snapshot(name)
            if name == "photo-live", safe() {
                let count = savedCount
                await takePhoto(layout: CameraLayout(), live: true)
                for _ in 0..<150 {
                    if savedCount > count || UIApplication.shared.applicationState != .active { break }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                rows.append(["photoSaved": savedCount > count, "message": message ?? "", "saveIssue": saveIssue ?? "",
                             "id": (try? disk.load().first?.id.uuidString) ?? ""])
            }
        }
        for (name, mode, profile) in [("video-30", CameraCaptureMode.dualVideo, VideoRecordingProfile.standard),
                                      ("video-60", .singleVideo, VideoRecordingProfile(resolution: .fullHD, fps: 60)),
                                      ("quicktake", .dualPhoto, .standard)] {
            guard safe() else { rows.append(["stoppedForThermalOrBackground": name]); break }
            if !mode.isDual, !singleVideoProfiles.contains(profile) { continue }
            await setRecordingPreferences(single: profile, dual: profile, mirror: mirrorsFront)
            _ = await setCaptureMode(mode, front: false)
            await setLivePhotoEnabled(true)
            try? await Task.sleep(for: .seconds(1))
            await snapshot(name + "-idle")
            guard safe() else { break }
            let count = savedCount, start = CACurrentMediaTime()
            let ok = await startVideo(layout: CameraLayout(singleCamera: !mode.isDual))
            let latency = CACurrentMediaTime() - start
            try? await Task.sleep(for: .seconds(1.5))
            await snapshot(name + "-recording")
            stopVideo(source: "thermal-audit")
            for _ in 0..<150 {
                if savedCount > count { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            await snapshot(name + "-stopped")
            rows.append(["scenario": name, "accepted": ok, "firstFrameSeconds": latency,
                         "saved": savedCount > count, "id": (try? disk.load().first?.id.uuidString) ?? "",
                         "message": message ?? "", "saveIssue": saveIssue ?? ""])
        }
        await setRecordingPreferences(single: oldSingle, dual: oldDual, mirror: mirrorsFront)
        pause()
        await snapshot("paused")
        UIApplication.shared.isIdleTimerDisabled = oldIdle
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("CamDiagnostics")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let result: [String: Any] = ["build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "", "rows": rows]
        try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            .write(to: folder.appendingPathComponent("thermal-audit.json"), options: .atomic)
    }

    @MainActor
    private func runRecordingStartAudit() async {
        // A finite audit. Retain new clips and restore the user's preferences.
        let previousLive = UserDefaults.standard.bool(forKey: "livePhotoEnabled")
        let previousSingle = singleVideoProfile, previousDual = dualVideoProfile
        var rows: [[String: Any]] = []
        let began = Date()
        UIApplication.shared.isIdleTimerDisabled = true
        try? await Task.sleep(for: .seconds(2))
        await setRecordingPreferences(single: .standard, dual: .standard, mirror: mirrorsFront)
        await setLivePhotoEnabled(false)
        for (name, mode, live) in [("dual-video-first", CameraCaptureMode.dualVideo, false),
                                    ("dual-video-repeat", .dualVideo, false),
                                    ("dual-quicktake", .dualPhoto, false),
                                    ("dual-quicktake-live", .dualPhoto, true),
                                    ("single-video", .singleVideo, false),
                                    ("single-quicktake", .singlePhoto, false)] {
            guard UIApplication.shared.applicationState == .active else { rows.append(["interrupted": name]); break }
            _ = await setCaptureMode(mode, front: false)
            await setLivePhotoEnabled(live)
            try? await Task.sleep(for: .seconds(1.5))
            let count = savedCount
            let t = CACurrentMediaTime()
            let ok = await startVideo(layout: CameraLayout(singleCamera: !mode.isDual))
            let accepted = CACurrentMediaTime() - t
            try? await Task.sleep(for: .seconds(1.8))
            stopVideo(source: "recording-start-audit")
            for _ in 0..<150 {
                if savedCount > count { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            rows.append(["scenario": name, "acceptedSeconds": accepted, "accepted": ok,
                "saved": savedCount > count, "message": message ?? "", "saveIssue": saveIssue ?? "",
                "id": (try? disk.load().first?.id.uuidString) ?? ""])
            if !ok || savedCount == count { break }
        }
        if ProcessInfo.processInfo.arguments.contains("--audit-recording-profiles") {
            for (mode, wanted) in [(CameraCaptureMode.singlePhoto, VideoRecordingProfile(resolution: .uhd, fps: 30)),
                                   (.singlePhoto, .init(resolution: .fullHD, fps: 60)),
                                   (.dualPhoto, .init(resolution: .hd, fps: 30))] {
                let choices = mode.isDual ? dualVideoProfiles : singleVideoProfiles
                guard choices.contains(wanted) else { continue }
                await setRecordingPreferences(single: wanted, dual: wanted, mirror: mirrorsFront)
                _ = await setCaptureMode(mode, front: false)
                await setLivePhotoEnabled(false)
                try? await Task.sleep(for: .seconds(1.5))
                let count = savedCount
                let t = CACurrentMediaTime()
                let ok = await startVideo(layout: CameraLayout(singleCamera: !mode.isDual))
                let elapsed = CACurrentMediaTime() - t
                try? await Task.sleep(for: .seconds(1.5))
                stopVideo(source: "recording-profile-audit")
                for _ in 0..<100 {
                    if savedCount > count { break }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                rows.append(["scenario": mode.rawValue + "-" + wanted.rawValue, "accepted": ok,
                    "acceptedSeconds": elapsed, "saved": savedCount > count, "message": message ?? "",
                    "saveIssue": saveIssue ?? "", "id": (try? disk.load().first?.id.uuidString) ?? ""])
            }
        }
        await setRecordingPreferences(single: previousSingle, dual: previousDual, mirror: mirrorsFront)
        _ = await setCaptureMode(.dualPhoto, front: false)
        await setLivePhotoEnabled(previousLive)
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("CamDiagnostics")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let report: [String: Any] = ["started": began.timeIntervalSince1970, "complete": rows.count >= 6 && rows.allSatisfy { $0["saved"] as? Bool == true }, "rows": rows]
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: folder.appendingPathComponent("recording-start-audit.json"), options: .atomic)
        pause()
        UIApplication.shared.isIdleTimerDisabled = false
    }

    @MainActor
    private func runQuickTakeAudit() async {
        let startedAt = Date()
        var report: [String: Any] = [:]
        func saved(after count: Int) async -> Bool {
            for _ in 0..<100 {
                if savedCount > count && !isBusy { return true }
                try? await Task.sleep(for: .milliseconds(100))
            }
            return false
        }
        await setLivePhotoEnabled(false)
        setRearZoom(1)
        try? await Task.sleep(for: .seconds(2))
        let layout = CameraLayout(aspect: .standard, insetAspectRatio: 0.75)
        var count = savedCount
        await takePhoto(layout: layout, live: false)
        report["ordinaryPhotoSaved"] = await saved(after: count)
        if await startVideo(layout: layout) {
            try? await Task.sleep(for: .seconds(2))
            count = savedCount
            await takePhoto(layout: layout, live: false, duringRecording: true)
            report["firstRecordingPhotoSaved"] = await saved(after: count)
            report["stillRecordingAfterPhoto"] = isRecording
            try? await Task.sleep(for: .seconds(2))
            var frontLayout = layout; frontLayout.frontIsPrimary = true
            updateLayout(frontLayout)
            count = savedCount
            await takePhoto(layout: frontLayout, live: true, duringRecording: true)
            // Stop as soon as photo outputs have been submitted, before either
            // writer finishes. This exercises the overlapping completion paths.
            for _ in 0..<100 {
                if isTakingPhoto { break }
                try? await Task.sleep(for: .milliseconds(5))
            }
            report["photoBusyWhenStopped"] = isTakingPhoto
            report["recordingWhenStopped"] = isRecording
            stopVideo(source: "quicktake-audit-overlapping-photo")
            for _ in 0..<150 {
                if savedCount >= count + 2 && !isBusy && !isRecording { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            report["overlappingPhotoAndVideoSaved"] = savedCount >= count + 2 && !isBusy && !isRecording
        } else { report["videoStartFailed"] = message ?? "unknown" }
        let items = (try? disk.load().filter { $0.createdAt >= startedAt }) ?? []
        report["items"] = items.map { ["id": $0.id.uuidString, "kind": $0.kind.rawValue, "live": $0.isLivePhoto] }
        report["cameraMessage"] = message ?? ""
        report["shutterSound"] = await withCheckedContinuation { continuation in
            queue.async { [self] in continuation.resume(returning: shutterSoundDiagnostics) }
        }
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CamDiagnostics")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted])
            .write(to: folder.appendingPathComponent("quicktake-audit.json"), options: .atomic)
        pause()
    }

    @MainActor
    private func runBackgroundSaveAudit() async {
        try? await Task.sleep(for: .seconds(1))
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("CamDiagnostics")
        let existing = Set((try? disk.load().map(\.id)) ?? [])
        let before = savedCount
        let videoOnly = ProcessInfo.processInfo.arguments.contains("--audit-background-video-only")
        var events: [[String: Any]] = []
        var report: [String: Any] = ["build": 29]
        func checkpoint(_ event: String, extra: [String: Any] = [:]) {
            var row: [String: Any] = ["event": event, "time": Date().timeIntervalSince1970,
                "pending": pendingSaveCount, "busy": isBusy, "recording": isRecording,
                "saved": savedCount - before]
            for (key, value) in extra { row[key] = value }
            events.append(row); report["events"] = events
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: folder.appendingPathComponent("background-save-audit.json"), options: .atomic)
        }
        func waitAcquired() async -> Bool {
            var sawCapture = false
            for _ in 0..<250 {
                if isTakingPhoto { sawCapture = true }
                if sawCapture && !isTakingPhoto { return true }
                try? await Task.sleep(for: .milliseconds(20))
            }
            return false
        }
        func waitDrained() async {
            for _ in 0..<600 {
                if pendingSaveCount == 0 && !isTakingPhoto && !isRecording { return }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        await setCaptureKind(.photo)
        guard await setCaptureSource(isDual: true, front: false) else { checkpoint("source-failed"); return }
        await setLivePhotoEnabled(false)
        let layout = CameraLayout(aspect: .standard)
        if !videoOnly {
        for index in 0..<3 {
            checkpoint("photo-request-\(index)")
            await takePhoto(layout: layout, live: false)
            let acquired = await waitAcquired()
            checkpoint("photo-ready-\(index)", extra: ["acquired": acquired])
            if !acquired { break }
        }
        await waitDrained()
        await setLivePhotoEnabled(true)
        try? await Task.sleep(for: .seconds(2))
        for index in 0..<4 {
            checkpoint("live-request-\(index)")
            await takePhoto(layout: layout, live: true)
            let acquired = await waitAcquired()
            checkpoint("live-ready-\(index)", extra: ["acquired": acquired])
            if !acquired { break }
        }
        await waitDrained()
        }
        await setLivePhotoEnabled(false)
        await setCaptureKind(.video)
        let videoLayout = CameraLayout(aspect: .wide)
        let first = await startVideo(layout: videoLayout)
        checkpoint("video-first-start", extra: ["accepted": first])
        if first {
            try? await Task.sleep(for: .seconds(2))
            stopVideo(source: "background-audit-first")
            for _ in 0..<100 {
                if !isRecording { break }
                try? await Task.sleep(for: .milliseconds(10))
            }
            checkpoint("video-second-request")
            let second = await startVideo(layout: videoLayout)
            checkpoint("video-second-start", extra: ["accepted": second])
            if second {
                try? await Task.sleep(for: .seconds(1))
                await takePhoto(layout: videoLayout, live: false, duringRecording: true)
                _ = await waitAcquired()
                try? await Task.sleep(for: .seconds(1))
                stopVideo(source: "background-audit-second")
            }
        }
        await waitDrained()
        let items = ((try? disk.load()) ?? []).filter { !existing.contains($0.id) }
        report["items"] = items.map { ["id": $0.id.uuidString, "kind": $0.kind.rawValue,
            "live": $0.isLivePhoto, "complete": $0.isComplete, "captureTime": $0.captureDate.timeIntervalSince1970,
            "note": $0.captureNote ?? ""] as [String: Any] }
        report["message"] = message ?? ""; report["saveIssue"] = saveIssue ?? ""
        report["finished"] = items.count == (videoOnly ? 3 : 10) && items.allSatisfy(\.isComplete) && pendingSaveCount == 0
        checkpoint("finished")
        await setCaptureKind(.photo)
        pause()
    }

    @MainActor
    private func runVideoSettingsAudit() async {
        try? await Task.sleep(for: .seconds(1))
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("CamDiagnostics")
        var report: [String: Any] = ["singleAvailable": singleVideoProfiles.map(\.rawValue), "dualAvailable": dualVideoProfiles.map(\.rawValue)]
        var entries: [[String: Any]] = []
        var knownIDs = Set((try? disk.load().map(\.id)) ?? [])
        func checkpoint(_ entry: [String: Any]) {
            entries.append(entry); report["captures"] = entries
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted]).write(to: folder.appendingPathComponent("video-settings-audit.json"), options: .atomic)
        }
        func waitSaved(_ before: Int, since: Date) async -> MemoryItem? {
            for _ in 0..<200 {
                if savedCount > before && !isBusy,
                   let item = try? disk.load().first(where: { !knownIDs.contains($0.id) }) { knownIDs.insert(item.id); return item }
                try? await Task.sleep(for: .milliseconds(100))
            }
            return nil
        }
        func connectionState() async -> [String: Any] {
            await withCheckedContinuation { continuation in
                queue.async { [self] in
                    let values: [[String: Any]] = devices.map { device in
                        let size = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
                        let output = device.position == .front ? frontVideo : rearVideo
                        return ["front": device.position == .front, "size": [size.width, size.height],
                                "fps": 1 / device.activeVideoMaxFrameDuration.seconds,
                                "mirror": output.connection(with: .video)?.isVideoMirrored ?? false,
                                "photoMirror": (device.position == .front ? frontPhotos : rearPhotos).connection(with: .video)?.isVideoMirrored ?? false]
                    }
                    continuation.resume(returning: ["devices": values, "cost": hardwareCost,
                        "previewMirrorTransform": !mirrorsFront, "activeProfile": activeVideoProfile?.rawValue ?? "photo"])
                }
            }
        }
        await setLivePhotoEnabled(false)
        for dual in ProcessInfo.processInfo.arguments.contains("--audit-video-settings-mirror") ? [] : [false, true] {
            await setCaptureKind(.photo)
            guard await setCaptureSource(isDual: dual, front: false) else { checkpoint(["failed": "source"]); break }
            let profiles = dual ? dualVideoProfiles : singleVideoProfiles
            for profile in profiles {
                await setRecordingPreferences(single: profile, dual: profile, mirror: true)
                let before = savedCount, start = Date()
                var entry: [String: Any] = ["dual": dual, "profile": profile.rawValue]
                let layout = CameraLayout(singleCamera: !dual, aspect: .wide)
                guard await startVideo(layout: layout) else { entry["error"] = message ?? "start rejected"; checkpoint(entry); continue }
                entry["connections"] = await connectionState()
                try? await Task.sleep(for: .seconds(2))
                stopVideo(source: "video-settings-audit")
                if let item = await waitSaved(before, since: start) {
                    entry["id"] = item.id.uuidString; entry["saved"] = true
                    // Keep export work out of the next FPS measurement.
                    for _ in 0..<200 {
                        if (try? AlbumSaveStore(disk: disk).receipt(item.id)?.phase) == .saved { entry["albumSaved"] = true; break }
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                } else { entry["error"] = message ?? "save timed out" }
                entry["afterStop"] = await connectionState()
                checkpoint(entry)
            }
        }
        await setCaptureKind(.photo)
        _ = await setCaptureSource(isDual: true, front: false)
        for mirror in [false, true] {
            await setRecordingPreferences(single: .standard, dual: .standard, mirror: mirror)
            await setLivePhotoEnabled(true)
            try? await Task.sleep(for: .seconds(3))
            let before = savedCount, start = Date()
            await takePhoto(layout: CameraLayout(frontIsPrimary: true, aspect: .standard), live: true)
            var entry: [String: Any] = ["mirror": mirror, "type": "live", "connections": await connectionState()]
            if let item = await waitSaved(before, since: start) { entry["id"] = item.id.uuidString; entry["saved"] = item.isLivePhoto }
            else { entry["error"] = message ?? "live save timed out" }
            checkpoint(entry)
        }
        await setLivePhotoEnabled(false)
        _ = await setCaptureSource(isDual: false, front: true)
        await setRecordingPreferences(single: .init(resolution: .fullHD, fps: 60), dual: .standard, mirror: false)
        let before = savedCount, start = Date()
        if await startVideo(layout: CameraLayout(frontIsPrimary: true, singleCamera: true, aspect: .wide)) {
            var entry: [String: Any] = ["type": "front-video", "connections": await connectionState()]
            try? await Task.sleep(for: .seconds(2)); stopVideo(source: "video-settings-front-audit")
            if let item = await waitSaved(before, since: start) { entry["id"] = item.id.uuidString; entry["saved"] = true }
            checkpoint(entry)
        }
        // Validate delivered cadence on actual camera sources, including a
        // source whose nominal rate is fractional because of one dropped frame.
        for profile in [VideoRecordingProfile(resolution: .fullHD, fps: 60), .init(resolution: .uhd, fps: 30)] {
            if let item = try? disk.load().first(where: { $0.kind == .video && $0.videoProfile == profile }),
               let rearName = item.renderFile(front: false), let frontName = item.renderFile(front: true) {
                let target = folder.appendingPathComponent("settings-export-" + profile.rawValue + ".mov")
                try? FileManager.default.removeItem(at: target)
                do {
                    let source = disk.folder(for: item.id)
                    try await MediaExporter.makeVideo(item: item, rearURL: source.appendingPathComponent(rearName),
                        frontURL: source.appendingPathComponent(frontName), outputURL: target)
                    let tracks = try await AVURLAsset(url: target).loadTracks(withMediaType: .video)
                    if let track = tracks.first {
                        let fps = try await track.load(.nominalFrameRate), size = try await track.load(.naturalSize)
                        checkpoint(["export": profile.rawValue, "fps": fps, "width": size.width, "height": size.height])
                    }
                } catch { checkpoint(["export": profile.rawValue, "error": error.localizedDescription]) }
            }
        }
        await setRecordingPreferences(single: .current(dual: false), dual: .current(dual: true),
            mirror: CameraDefaults.bool("cameraMirrorFront"))
        await setCaptureKind(.photo)
        _ = await setCaptureSource(isDual: true, front: false)
        checkpoint(["finished": true, "message": message ?? ""])
        pause()
    }

    @MainActor
    private func runAutomaticAlbumAudit() async {
        let started = Date()
        var results: [String: Any] = [:]
        func check(_ key: String, after count: Int) async -> Bool {
            for _ in 0..<150 {
                if savedCount > count, !isBusy,
                   let item = try? disk.load().first(where: { $0.createdAt >= started }),
                   let receipt = try? AlbumSaveStore(disk: disk).receipt(item.id), receipt.phase == .saved {
                    results[key] = ["id": item.id.uuidString, "asset": receipt.assetIdentifier ?? "", "assets": receipt.assetIdentifiers ?? [],
                                    "live": item.isLivePhoto, "mode": item.albumSaveMode?.rawValue ?? ""]
                    return true
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
            results[key] = ["failed": true, "cameraMessage": message ?? ""]
            return false
        }
        setRearZoom(1)
        setLighting(front: false, torch: false)
        try? await Task.sleep(for: .seconds(2))
        let modes: [AlbumSaveMode] = ProcessInfo.processInfo.arguments.contains("--audit-separate-only") ? [.separate] : AlbumSaveMode.allCases
        audit: for mode in modes {
            await setLivePhotoEnabled(false)
            var count = savedCount
            await takePhoto(layout: CameraLayout(aspect: .standard, insetAspectRatio: 0.75), live: false, albumMode: mode)
            guard await check(mode.rawValue + "-photo", after: count) else { break audit }
            await setLivePhotoEnabled(true)
            try? await Task.sleep(for: .seconds(3))
            count = savedCount
            await takePhoto(layout: CameraLayout(aspect: .square, insetAspectRatio: 0.75), live: true, albumMode: mode)
            guard await check(mode.rawValue + "-live", after: count) else { break audit }
            await setLivePhotoEnabled(false)
            count = savedCount
            guard await startVideo(layout: CameraLayout(aspect: .wide, insetAspectRatio: 0.75), albumMode: mode) else {
                results[mode.rawValue + "-video"] = ["failed": true, "cameraMessage": message ?? ""]
                break audit
            }
            try? await Task.sleep(for: .seconds(1.5))
            updateLayout(CameraLayout(frontIsPrimary: true, aspect: .wide, insetAspectRatio: 0.75))
            try? await Task.sleep(for: .seconds(1.5))
            stopVideo()
            guard await check(mode.rawValue + "-video", after: count) else { break audit }
        }
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CamDiagnostics")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
            .write(to: folder.appendingPathComponent("auto-album-audit.json"), options: .atomic)
        pause()
    }

    @MainActor
    private func runOptionsAudit() async {
        var report: [String: Any] = [:]
        func waitForSave(_ count: Int) async -> Bool {
            for _ in 0..<100 {
                if savedCount > count && !isBusy { return true }
                try? await Task.sleep(for: .milliseconds(200))
            }
            return false
        }
        await setLivePhotoEnabled(false)
        setRearZoom(1)
        setLighting(front: false, torch: false)
        try? await Task.sleep(for: .seconds(2))
        report["rearFlashModes"] = supportedFlashModes.map(\.rawValue)
        for aspect in CaptureAspect.allCases {
            let before = savedCount
            let layout = CameraLayout(aspect: aspect, insetAspectRatio: 0.75)
            await takePhoto(layout: layout, live: false, flashMode: aspect == .standard ? .on : .off)
            report["photo-" + aspect.rawValue] = await waitForSave(before)
            try? await Task.sleep(for: .milliseconds(500))
        }
        await setLivePhotoEnabled(true)
        try? await Task.sleep(for: .seconds(3))
        var before = savedCount
        await takePhoto(layout: CameraLayout(aspect: .wide, insetAspectRatio: 0.75), live: true)
        report["live-16:9"] = await waitForSave(before)
        setLighting(front: false, torch: true)
        try? await Task.sleep(for: .milliseconds(400))
        report["torchActuallyOn"] = torchActive
        before = savedCount
        if await startVideo(layout: CameraLayout(aspect: .square, insetAspectRatio: 0.75)) {
            try? await Task.sleep(for: .seconds(3))
            stopVideo()
            report["video-1:1"] = await waitForSave(before)
        } else { report["video-1:1"] = false; report["videoError"] = message ?? "capture guard rejected" }
        setLighting(front: true, torch: false)
        try? await Task.sleep(for: .milliseconds(400))
        report["torchOffAfterSwap"] = !torchActive
        before = savedCount
        await takePhoto(layout: CameraLayout(frontIsPrimary: true, aspect: .square, insetAspectRatio: 0.75), live: false)
        report["frontPrimary-1:1"] = await waitForSave(before)
        let completedReport = report
        queue.async {
            let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("CamDiagnostics")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? JSONSerialization.data(withJSONObject: completedReport, options: [.sortedKeys, .prettyPrinted])
                .write(to: folder.appendingPathComponent("camera-options-audit.json"), options: .atomic)
        }
        pause()
    }

    @MainActor
    private func runCaptureModesAudit() async {
        var report: [[String: Any]] = []
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("CamDiagnostics")
        func checkpoint(_ entry: [String: Any]) {
            report.append(entry)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted])
                .write(to: folder.appendingPathComponent("capture-modes-audit.json"), options: .atomic)
        }
        func waitForSave(_ before: Int) async -> Bool {
            for _ in 0..<150 {
                if savedCount > before && !isBusy { return true }
                try? await Task.sleep(for: .milliseconds(200))
            }
            return false
        }
        // Let the screen finish applying its saved Live preference before the audit overrides it.
        try? await Task.sleep(for: .seconds(1))
        let liveOnly = ProcessInfo.processInfo.arguments.contains("--audit-capture-modes-live")
        for (dual, front) in [(false, false), (false, true), (true, false)] {
            let changed = await setCaptureSource(isDual: dual, front: front)
            let name = dual ? "dual" : front ? "single-front" : "single-rear"
            guard changed else { checkpoint(["mode": name, "switch": false]); break }
            await setLivePhotoEnabled(true)
            try? await Task.sleep(for: .seconds(2))
            let graph: [String: Any] = await withCheckedContinuation { continuation in
                queue.async { [self] in
                    let inputs = session.inputs.compactMap { $0 as? AVCaptureDeviceInput }
                        .filter { $0.device.hasMediaType(.video) }.map { $0.device.position.rawValue }
                    recordStabilizationDiagnostics(event: "audit-" + name)
                    continuation.resume(returning: ["mode": name, "sessionClass": String(describing: type(of: session)), "inputs": inputs, "live": liveBuffer.diagnostics,
                        "photoOutputs": session.outputs.filter { $0 is AVCapturePhotoOutput }.count,
                        "videoOutputs": session.outputs.filter { $0 is AVCaptureVideoDataOutput }.count])
                }
            }
            checkpoint(graph)
            let layout = CameraLayout(frontIsPrimary: front, singleCamera: !dual, aspect: .standard)
            var before = savedCount
            if !liveOnly {
                await takePhoto(layout: layout, live: false)
                checkpoint(["mode": name, "photo": await waitForSave(before)])
                try? await Task.sleep(for: .seconds(2))
            }
            before = savedCount
            await takePhoto(layout: layout, live: true)
            let liveSaved = await waitForSave(before)
            let liveItem = try? disk.load().first
            checkpoint(["mode": name, "livePhoto": liveSaved && liveItem?.isLivePhoto == true,
                        "liveItem": liveItem?.id.uuidString ?? "", "note": liveItem?.captureNote ?? ""])
            if liveOnly { continue }
            var videoLayout = layout; videoLayout.aspect = .wide
            let started = await startVideo(layout: videoLayout)
            guard started else { checkpoint(["mode": name, "videoStart": false]); break }
            try? await Task.sleep(for: .seconds(1))
            before = savedCount
            await takePhoto(layout: videoLayout, live: false, duringRecording: true)
            checkpoint(["mode": name, "recordingPhoto": await waitForSave(before), "stillRecording": isRecording])
            before = savedCount
            stopVideo(source: "capture-modes-audit")
            checkpoint(["mode": name, "video": await waitForSave(before)])
            try? await Task.sleep(for: .seconds(1))
        }
        pause()
        checkpoint(["completed": true])
    }

    @MainActor
    private func runZoomInteractionAudit() async {
        var report: [[String: Any]] = []
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("CamDiagnostics")
        func checkpoint(_ entry: [String: Any]) {
            let safe = entry.mapValues { value -> Any in
                if JSONSerialization.isValidJSONObject(["value": value]) { return value }
                print("Zoom audit unencodable value: \(type(of: value)) \(String(describing: value))")
                return String(describing: value)
            }
            report.append(safe)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted])
                .write(to: folder.appendingPathComponent("zoom-interaction-audit.json"), options: .atomic)
        }
        func snapshot(_ name: String, resetFrames: Bool = false) async -> [String: Any] {
            await withCheckedContinuation { continuation in
                queue.async { [self] in
                    let intervals = zoomFrameIntervals.sorted()
                    let report: [String: Any] = ["step": name, "range": [supportedRearZoomRange.lowerBound, supportedRearZoomRange.upperBound],
                        "rear": appliedRearZoom, "target": requestedRearZoom, "front": frontDevice.map { Double($0.videoZoomFactor) } ?? 0,
                        "rearType": rearDevice?.deviceType.rawValue ?? "", "activeLens": rearDevice?.activePrimaryConstituent?.deviceType.rawValue ?? rearDevice?.deviceType.rawValue ?? "",
                        "dual": captureIsDual, "switches": zoomSwitchCount, "switchMilliseconds": zoomSwitchMilliseconds, "switchStages": zoomSwitchStages,
                        "frameCount": intervals.count, "maxFrameGap": intervals.max() ?? 0.0,
                        "p95FrameGap": intervals.isEmpty ? 0 : intervals[min(intervals.count - 1, Int(Double(intervals.count) * 0.95))],
                        "running": session.isRunning, "ramping": rearDevice?.isRampingVideoZoom ?? false,
                        "pressure": String(describing: appliedPressureLevel)]
                    if resetFrames { measuringZoomFrames = true; zoomFrameIntervals = []; lastRearFrameTime = nil }
                    continuation.resume(returning: report)
                }
            }
        }
        func zoom(_ value: Double, front: Bool = false) async {
            _ = await snapshot("reset", resetFrames: true)
            let started = CACurrentMediaTime()
            if front { setFrontZoom(value, smooth: true) } else { setRearZoom(value, smooth: true) }
            var settled = false
            for _ in 0..<60 {
                try? await Task.sleep(for: .milliseconds(50))
                let status = await snapshot("poll")
                if let actual = status[front ? "front" : "rear"] as? Double, abs(actual - value) < 0.025 {
                    settled = true; break
                }
            }
            let latency = CACurrentMediaTime() - started
            try? await Task.sleep(for: .milliseconds(400))
            var result = await snapshot((front ? "front-" : "rear-") + String(value))
            result["settled"] = settled; result["settleMilliseconds"] = latency * 1000
            checkpoint(result)
        }
        func waitForSave(_ before: Int) async -> Bool {
            for _ in 0..<120 {
                if savedCount > before && !isBusy { return true }
                if state != .ready { return false }
                try? await Task.sleep(for: .milliseconds(200))
            }
            return false
        }
        func photo(_ name: String, layout: CameraLayout, live: Bool = false) async {
            let before = savedCount
            await takePhoto(layout: layout, live: live)
            let saved = await waitForSave(before)
            let item = try? disk.load().first
            checkpoint(["capture": name, "saved": saved, "id": saved ? item?.id.uuidString ?? "" : "", "isLive": item?.isLivePhoto ?? false, "message": message ?? ""])
        }
        let performanceOnly = ProcessInfo.processInfo.arguments.contains("--audit-zoom-performance")
        try? await Task.sleep(for: .seconds(1))
        await setLivePhotoEnabled(false)
        await setCaptureKind(.photo)
        guard await setCaptureSource(isDual: true, front: false) else { checkpoint(["failed": "dual source"]); pause(); return }
        checkpoint(await snapshot("dual-photo"))
        let tele = availableRearZooms.last?.factor ?? 3
        for value in [1, 2, tele, 1, tele] { await zoom(value) }
        if performanceOnly {
            for value in [0.5, 1, tele] { await zoom(value) }
            let changed: Bool = await withCheckedContinuation { continuation in
                queue.async { [self] in
                    guard let device = rearDevice, device.isVirtualDevice, device.activePrimaryConstituentDeviceSwitchingBehavior != .unsupported else { continuation.resume(returning: false); return }
                    do {
                        try device.lockForConfiguration()
                        device.fallbackPrimaryConstituentDevices = []
                        device.unlockForConfiguration()
                        continuation.resume(returning: true)
                    } catch { continuation.resume(returning: false) }
                }
            }
            if changed {
                await zoom(1); await zoom(tele)
                try? await Task.sleep(for: .seconds(2))
                checkpoint(await snapshot("optical-without-fallback"))
                await withCheckedContinuation { continuation in
                    queue.async { [self] in
                        if let device = rearDevice { try? device.lockForConfiguration(); device.fallbackPrimaryConstituentDevices = device.supportedFallbackPrimaryConstituentDevices; device.unlockForConfiguration() }
                        continuation.resume()
                    }
                }
            }
            pause(); checkpoint(["completed": true]); return
        }
        await photo("dual-optical", layout: CameraLayout())
        await zoom(1, front: true)
        await photo("front-wide", layout: CameraLayout(frontIsPrimary: true))
        await zoom(1.3, front: true)
        await photo("front-close", layout: CameraLayout(frontIsPrimary: true))
        // Wavering briefly at a lens boundary must not repeatedly rebuild inputs.
        for value in [tele - 0.02, tele + 0.02, tele - 0.02, tele + 0.02, tele - 0.02, tele + 0.02] {
            setRearZoom(value)
            try? await Task.sleep(for: .milliseconds(45))
        }
        try? await Task.sleep(for: .milliseconds(600))
        checkpoint(await snapshot("boundary-wavering"))
        await setCaptureKind(.video)
        checkpoint(await snapshot("dual-video"))
        let videoMaximum = rearZoomRange.upperBound
        let before = savedCount
        if await startVideo(layout: CameraLayout(aspect: .wide)) {
            for value in [1, tele, videoMaximum] { await zoom(value) }
            stopVideo(source: "zoom-interaction-audit")
            checkpoint(["capture": "dual-video", "saved": await waitForSave(before)])
        } else { checkpoint(["failed": "video start", "message": message ?? ""] ) }
        await setCaptureKind(.photo)
        await zoom(tele)
        await setLivePhotoEnabled(true)
        try? await Task.sleep(for: .seconds(2))
        await photo("dual-optical-live", layout: CameraLayout(), live: true)
        await setLivePhotoEnabled(false)
        guard await setCaptureSource(isDual: false, front: false) else { checkpoint(["failed": "single source"]); pause(); return }
        checkpoint(await snapshot("single-photo"))
        for value in [1, tele, rearZoomRange.upperBound] { await zoom(value) }
        await photo("single-maximum", layout: CameraLayout(singleCamera: true))
        await setCaptureKind(.video)
        try? await Task.sleep(for: .milliseconds(600))
        checkpoint(await snapshot("single-video"))
        await setCaptureKind(.photo)
        _ = await setCaptureSource(isDual: false, front: true)
        await zoom(1.3, front: true)
        await zoom(1, front: true)
        checkpoint(await snapshot("single-front"))
        _ = await setCaptureSource(isDual: true, front: false)
        pause()
        try? await Task.sleep(for: .milliseconds(400))
        checkpoint(await snapshot("finished"))
        checkpoint(["completed": true])
    }

    @MainActor
    private func runZoomAudit(value: Double) async {
        var results: [String: Bool] = [:]
        func waitForSave(after count: Int) async -> Bool {
            for _ in 0..<100 {
                if savedCount > count && !isBusy { return true }
                try? await Task.sleep(for: .milliseconds(200))
            }
            return false
        }
        await setLivePhotoEnabled(false)
        setRearZoom(value)
        try? await Task.sleep(for: .seconds(3))
        var count = savedCount
        await takePhoto(layout: CameraLayout(), live: false)
        results["photo"] = await waitForSave(after: count)
        await setLivePhotoEnabled(true)
        try? await Task.sleep(for: .seconds(3))
        count = savedCount
        await takePhoto(layout: CameraLayout(), live: true)
        results["liveSaved"] = await waitForSave(after: count)
        setRearZoom(1)
        try? await Task.sleep(for: .seconds(2))
        count = savedCount
        if await startVideo(layout: CameraLayout()) {
            try? await Task.sleep(for: .seconds(2))
            setRearZoom(value)
            try? await Task.sleep(for: .seconds(2))
            setRearZoom(1)
            try? await Task.sleep(for: .seconds(2))
            stopVideo()
            results["video"] = await waitForSave(after: count)
        } else { results["video"] = false }
        let report = results
        queue.async { [self] in
            recordStabilizationDiagnostics(event: "zoom-audit-finished")
            let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("CamDiagnostics")
            try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted])
                .write(to: folder.appendingPathComponent("zoom-audit.json"), options: .atomic)
        }
        pause()
    }
    #endif

    #if DEBUG && targetEnvironment(simulator)
    // Only the explicit UI fixture replaces camera I/O. It exercises the real
    // shutter view without entering AVFoundation's unsupported simulator path.
    private var shutterUIFixture: Bool { ProcessInfo.processInfo.arguments.contains("--ui-quicktake-fixture") }
    private var fixtureVideoSaving = false
    private var fixtureDidResetRecordingTip = false
    private var fixtureReadoutTask: Task<Void, Never>?
    @MainActor private func startReadoutFixtureIfNeeded() {
        guard ProcessInfo.processInfo.arguments.contains("--ui-video-readout"), fixtureReadoutTask == nil else { return }
        fixtureReadoutTask = Task { @MainActor in
            for (delay, fps) in [(10.0, 24), (7.0, 15), (7.0, 30)] {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                actualVideoProfile = .init(resolution: .fullHD, fps: VideoFrameRateReadout.fps(
                    requested: 30, device: fps, measured: fps, recording: true, constrained: fps < 30))
            }
        }
    }
    @MainActor private func fixtureTakePhoto() {
        guard !isTakingPhoto else { return }
        isTakingPhoto = true; isBusy = true; pendingSaveCount += 1
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.8))
            isTakingPhoto = false; isBusy = false
            try? await Task.sleep(for: .seconds(5))
            pendingSaveCount -= 1; savedCount += 1
        }
    }
    @MainActor private func fixtureStopVideo() {
        guard isRecording else { return }
        isRecording = false; fixtureVideoSaving = true; isBusy = isTakingPhoto; pendingSaveCount += 1
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            pendingSaveCount -= 1
            fixtureVideoSaving = false; isBusy = isTakingPhoto; savedCount += 1
        }
    }
    #endif

    deinit { tokens.forEach(NotificationCenter.default.removeObserver) }

    func resume() async {
        #if DEBUG && targetEnvironment(simulator)
        if shutterUIFixture {
            await MainActor.run {
                if !fixtureDidResetRecordingTip, ProcessInfo.processInfo.arguments.contains("--ui-reset-recording-tip") {
                    UserDefaults.standard.removeObject(forKey: "cameraRecordingPhotoTipSeen")
                    fixtureDidResetRecordingTip = true
                }
                state = .ready; previewReady = true
                livePhotoAvailable = ProcessInfo.processInfo.arguments.contains("--ui-live-available")
                if ProcessInfo.processInfo.arguments.contains("--ui-load-notice") {
                    pressureLevel = .serious
                    cameraLoadNotice = "相机温度较高，已自动降低拍摄负载"
                }
                startReadoutFixtureIfNeeded()
            }
            return
        }
        #endif
        #if targetEnvironment(simulator)
        await MainActor.run { state = .unavailable("模拟器不支持前后双摄，请在 iPhone 上拍摄。") }
        return
        #else
        let granted: Bool
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: granted = true
        case .notDetermined: granted = await AVCaptureDevice.requestAccess(for: .video)
        default: granted = false
        }
        guard granted else { await MainActor.run { state = .denied }; return }
        await MainActor.run {
            if state != .preparing && state != .ready { state = .resuming }
        }
        queue.async { [self] in
            wantsRunning = true
            do {
                if !session.isRunning || !previewHasWarmed { beginPreviewWarmup() }
                if !configured { updateVideoCapabilities(); try configure() }
                if captureVideoMode { try prepareVideoFormat() }
                systemEnergy = .current
                applyLoadPlan(CameraLoadPolicy.plan(level: combinedPressure, causes: []), level: combinedPressure, force: true)
                updateCombinedPressure()
                warmRecordingResources()
                if !session.isRunning { session.startRunning() }
                guard session.isRunning else { throw CamError.message("相机未能启动，请重试。") }
                verifyStabilization(after: 0.8, event: "resume")
                publish { $0.state = .ready; $0.livePhotoAvailable = true }
                #if DEBUG && CAM_MAIN_APP
                if !didRunZoomAudit, ProcessInfo.processInfo.arguments.contains("--audit-recording-resilience") {
                    didRunZoomAudit = true
                    Task { @MainActor [weak self] in await self?.runRecordingResilienceAudit() }
                }
                if !didRunZoomAudit, ProcessInfo.processInfo.arguments.contains("--audit-video-readout") {
                    didRunZoomAudit = true
                    Task { @MainActor [weak self] in await self?.runVideoReadoutAudit() }
                }
                if !didRunZoomAudit, ProcessInfo.processInfo.arguments.contains("--audit-thermal") {
                    didRunZoomAudit = true
                    Task { @MainActor [weak self] in await self?.runThermalAudit() }
                }
                if !didRunZoomAudit, ProcessInfo.processInfo.arguments.contains("--audit-recording-start") {
                    didRunZoomAudit = true
                    Task { @MainActor [weak self] in await self?.runRecordingStartAudit() }
                }
                if !didRunZoomAudit, ProcessInfo.processInfo.arguments.contains("--audit-background-save") {
                    didRunZoomAudit = true
                    Task { @MainActor [weak self] in await self?.runBackgroundSaveAudit() }
                }
                if !didRunZoomAudit, ProcessInfo.processInfo.arguments.contains("--audit-video-settings") {
                    didRunZoomAudit = true
                    Task { @MainActor [weak self] in await self?.runVideoSettingsAudit() }
                }
                if !didRunZoomAudit, ProcessInfo.processInfo.arguments.contains("--audit-zoom-interaction") {
                    didRunZoomAudit = true
                    Task { @MainActor [weak self] in await self?.runZoomInteractionAudit() }
                }
                if !didRunZoomAudit, (ProcessInfo.processInfo.arguments.contains("--audit-capture-modes") || ProcessInfo.processInfo.arguments.contains("--audit-capture-modes-live")) {
                    didRunZoomAudit = true
                    Task { @MainActor [weak self] in await self?.runCaptureModesAudit() }
                }
                if !didRunZoomAudit, ProcessInfo.processInfo.arguments.contains("--audit-shutter-live") {
                    didRunZoomAudit = true
                    Task { @MainActor [weak self] in await self?.runShutterLiveAudit() }
                }
                if !didRunZoomAudit, ProcessInfo.processInfo.arguments.contains("--audit-quicktake") {
                    didRunZoomAudit = true
                    Task { @MainActor [weak self] in await self?.runQuickTakeAudit() }
                }
                if !didRunZoomAudit, ProcessInfo.processInfo.arguments.contains("--audit-auto-album") {
                    didRunZoomAudit = true
                    Task { @MainActor [weak self] in await self?.runAutomaticAlbumAudit() }
                }
                if !didRunZoomAudit, ProcessInfo.processInfo.arguments.contains("--audit-camera-options") {
                    didRunZoomAudit = true
                    Task { @MainActor [weak self] in await self?.runOptionsAudit() }
                }
                if !didRunZoomAudit, let flag = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--audit-rear-zoom=") }),
                   let value = Double(flag.split(separator: "=").last ?? "") {
                    didRunZoomAudit = true
                    Task { @MainActor [weak self] in await self?.runZoomAudit(value: value) }
                }
                #endif
            } catch { publish { $0.state = .unavailable(error.localizedDescription) } }
        }
        #endif
    }

    func pause() {
        #if DEBUG && targetEnvironment(simulator)
        if shutterUIFixture {
            Task { @MainActor in fixtureStopVideo(); state = .paused; previewReady = false }
            return
        }
        #endif
        #if !CAM_CAPTURE_EXTENSION
        if (isRecording || isStartingVideo || isBusy || pendingSaveCount > 0), backgroundSaveTask == .invalid {
            backgroundSaveTask = UIApplication.shared.beginBackgroundTask(withName: "Finish Cam capture") { [weak self] in
                self?.endBackgroundSave()
            }
        }
        #endif
        queue.async { [self] in
            finishPreviewWait(false)
            previewWarmup = nil; previewHasWarmed = false
            if let id = startupSignpost { os_signpost(.end, log: startupLog, name: "Preview readiness", signpostID: id) }
            startupSignpost = nil
            publish { $0.previewReady = false }
            wantsRunning = false
            pressureRecoveryWorkItem?.cancel(); recoveryTarget = nil
            pressureNoticeWorkItem?.cancel()
            deferredLensSwitch?.cancel(); deferredLensSwitch = nil; deferredLensID = nil
            zoomVerification?.cancel()
            wantsTorch = false
            applyLighting()
            if recording != nil { finishRecording(reason: .capturePaused, note: "离开拍摄界面，录像已结束并保存。") }
            liveBuffer.finishEarly(reason: "离开拍摄界面，Live Photo 已保存当前可用的动态画面。")
            liveBufferingEnabled = false
            liveBuffer.setEnabled(false)
            removeMicrophone(force: true)
            if session.isRunning { session.stopRunning() }
            publish { $0.state = .paused }
        }
    }

    private func selectSessionKind() throws {
        guard (session is AVCaptureMultiCamSession) != captureIsDual else { return }
        guard !captureIsDual || supportsDualCapture else {
            throw CamError.message("此设备不支持前后同时拍摄，请使用单摄模式。")
        }
        if session.isRunning { session.stopRunning() }
        session.beginConfiguration()
        clearCameraConnections()
        session.commitConfiguration()
        // Capture outputs and preview layers belong to one session lifetime.
        // iOS 27 may deliver attachment/detachment notifications after commit;
        // sharing these objects with a new session races its retired graph.
        rearVideo.setSampleBufferDelegate(nil, queue: nil)
        frontVideo.setSampleBufferDelegate(nil, queue: nil)
        audioOutput.setSampleBufferDelegate(nil, queue: nil)
        rearPhotos = AVCapturePhotoOutput(); frontPhotos = AVCapturePhotoOutput()
        rearVideo = AVCaptureVideoDataOutput(); frontVideo = AVCaptureVideoDataOutput()
        audioOutput = AVCaptureAudioDataOutput()
        rearPreview = AVCaptureVideoPreviewLayer()
        frontPreview = AVCaptureVideoPreviewLayer()
        rearPreview.videoGravity = .resizeAspectFill
        frontPreview.videoGravity = .resizeAspectFill
        session = captureIsDual ? AVCaptureMultiCamSession() : AVCaptureSession()
        session.automaticallyConfiguresApplicationAudioSession = false
        // Preserve explicit activeFormat selection on an ordinary session.
        if !captureIsDual { session.sessionPreset = .inputPriority }
        observeSession()
    }

    private func configure() throws {
        #if DEBUG
        recordCameraCapabilities()
        #endif
        try selectSessionKind()
        if !captureIsDual { try configureSingle(); return }
        guard supportsDualCapture else {
            throw CamError.message("此设备不支持前后同时拍摄，请使用单摄模式。")
        }
        guard let front = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) else {
            throw CamError.message("无法找到前置摄像头。")
        }
        let candidates = rearCameraCandidates()
        guard !candidates.isEmpty else { throw CamError.message("没有可用的后置双摄画面格式。") }
        var lastError: Error = CamError.message("无法同时连接两个摄像头。")
        for rear in candidates {
            do {
                try configurePair(rear: rear, front: front)
                rearDevice = rear
                standardRearDevice = rear
                frontDevice = front
                devices = [rear, front]
                configureRearZoom(rear)
                configureFrontZoom(front)
                observeRearZoom()
                observeStabilization()
                pressureSnapshots.removeAll()
                pressureObservers = devices.map { device in
                    device.observe(\.systemPressureState, options: [.initial, .new]) { [weak self] device, _ in
                        guard let self else { return }
                        self.queue.async { [self] in self.handlePressure(device.systemPressureState, device: device) }
                    }
                }
                configured = true
                applyLighting()
                #if DEBUG
                print("Cam selected rear=\(rear.deviceType.rawValue) front=\(front.deviceType.rawValue) cost=\(hardwareCost)")
                #endif
                return
            } catch {
                lastError = error
                #if DEBUG
                print("Cam rejected rear=\(rear.deviceType.rawValue): \(error.localizedDescription)")
                #endif
            }
        }
        throw lastError
    }

    private func configureSingle() throws {
        let candidates = captureFront
            ? [AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)].compactMap { $0 }
            : rearCameraCandidates()
        var lastError: Error = CamError.message("无法找到可用的摄像头。")
        for device in candidates {
            do {
                session.beginConfiguration()
                do {
                    clearCameraConnections()
                    let available = profiles(for: [device])
                    publish { $0.singleVideoProfiles = available }
                    let photo = captureFront ? frontPhotos : rearPhotos
                    let video = captureFront ? frontVideo : rearVideo
                    let preview = captureFront ? frontPreview : rearPreview
                    try selectFormat(device, maximumWidth: 1920)
                    try addCamera(device, photoOutput: photo, videoOutput: video, preview: preview, mirrored: captureFront)
                    configureStabilization(device: device, preview: preview, output: video)
                    configurePhotoDimensions(photo, device: device)
                    if let format = [kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
                        .first(where: { video.availableVideoPixelFormatTypes.contains($0) }) {
                        video.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: format]
                    }
                    session.commitConfiguration()
                } catch { clearCameraConnections(); session.commitConfiguration(); throw error }
                devices = [device]
                if captureFront { frontDevice = device; configureFrontZoom(device) }
                else { rearDevice = device; standardRearDevice = device; configureRearZoom(device); observeRearZoom() }
                observeStabilization()
                pressureSnapshots.removeAll()
                pressureObservers = devices.map { device in
                    device.observe(\.systemPressureState, options: [.initial, .new]) { [weak self] device, _ in
                        self?.queue.async { [weak self] in self?.handlePressure(device.systemPressureState, device: device) }
                    }
                }
                configured = true; applyLighting()
                return
            } catch { lastError = error }
        }
        throw lastError
    }

    private func configurePair(rear: AVCaptureDevice, front: AVCaptureDevice) throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        clearCameraConnections()
        let available = profiles(for: [rear, front])
        publish { $0.dualVideoProfiles = available }
        do {
            try selectFormat(rear, maximumWidth: 1920)
            try selectFormat(front, maximumWidth: 1920)
            try addCamera(rear, photoOutput: rearPhotos, videoOutput: rearVideo, preview: rearPreview, mirrored: false)
            try addCamera(front, photoOutput: frontPhotos, videoOutput: frontVideo, preview: frontPreview, mirrored: true)
            configureStabilization(device: rear, preview: rearPreview, output: rearVideo)
            configureStabilization(device: front, preview: frontPreview, output: frontVideo)
            if hardwareCost > 1 {
                try selectFormat(front, maximumWidth: 1280)
                configureStabilization(device: front, preview: frontPreview, output: frontVideo)
            }
            if hardwareCost > 1 {
                try selectFormat(rear, maximumWidth: 1280)
                configureStabilization(device: rear, preview: rearPreview, output: rearVideo)
            }
            guard hardwareCost <= 1 else { throw CamError.message("当前双摄配置超出设备负荷，请稍后重试。") }
            configurePhotoDimensions(rearPhotos, device: rear)
            configurePhotoDimensions(frontPhotos, device: front)
            // Query output support after all connections and format fallbacks
            // are final, then explicitly request the Live buffer pixel type.
            for output in [rearVideo, frontVideo] {
                let pixelFormat = [kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                                   kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
                    .first { output.availableVideoPixelFormatTypes.contains($0) }
                if let pixelFormat { output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: pixelFormat] }
            }
        } catch {
            // A rejected device must not leave inputs, outputs or preview ports
            // attached when trying the next rear/front combination.
            clearCameraConnections()
            throw error
        }
    }

    private func clearCameraConnections() {
        stabilizationObservers.removeAll()
        pressureObservers.removeAll()
        audioInput = nil
        session.connections.forEach(session.removeConnection)
        rearPreview.session = nil
        frontPreview.session = nil
        session.outputs.forEach(session.removeOutput)
        session.inputs.forEach(session.removeInput)
    }

    private func rearCameraCandidates() -> [AVCaptureDevice] {
        let types: [AVCaptureDevice.DeviceType] = [
            .builtInTripleCamera, .builtInDualCamera, .builtInDualWideCamera, .builtInWideAngleCamera
        ]
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: types + [.builtInTelephotoCamera],
                                                         mediaType: .video, position: .unspecified)
        let front = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
        return types.compactMap { AVCaptureDevice.default($0, for: .video, position: .back) }
            .filter { device in
                if captureIsDual {
                    guard let front, discovery.supportedMultiCamDeviceSets.contains(where: { $0.contains(device) && $0.contains(front) }) else { return false }
                }
                return device.formats.contains { format in
                    let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                    return (!captureIsDual || format.isMultiCamSupported) && size.width <= 1920 && size.height <= 1440 &&
                        format.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= 30 && $0.maxFrameRate >= 30 }
                }
            }
    }

    private func zoomDisplayMultiplier(for device: AVCaptureDevice) -> CGFloat {
        if #available(iOS 18.0, *) { return device.displayVideoZoomFactorMultiplier }
        return device.deviceType == .builtInTripleCamera || device.deviceType == .builtInDualWideCamera ? 0.5 : 1
    }

    private func configureRearZoom(_ device: AVCaptureDevice) {
        let multiplier = Double(zoomDisplayMultiplier(for: device))
        var minimum = Double(device.minAvailableVideoZoomFactor) * multiplier
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera,
            .builtInUltraWideCamera, .builtInTelephotoCamera, .builtInTripleCamera, .builtInDualCamera,
            .builtInDualWideCamera], mediaType: .video, position: .unspecified)
        let virtual = AVCaptureDevice.default(.builtInTripleCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(.builtInDualCamera, for: .video, position: .back)
        if let virtual, let tele = AVCaptureDevice.default(.builtInTelephotoCamera, for: .video, position: .back),
           (!captureIsDual || frontDevice.map { front in discovery.supportedMultiCamDeviceSets.contains(where: { $0.contains(tele) && $0.contains(front) }) } == true),
           (!captureVideoMode || videoFormat(for: tele, profile: captureIsDual ? dualVideoProfile : singleVideoProfile) != nil),
           let index = virtual.constituentDevices.firstIndex(where: { $0.deviceType == .builtInTelephotoCamera }), index > 0,
           virtual.virtualDeviceSwitchOverVideoZoomFactors.count >= index {
            telephotoDevice = tele
            telephotoZoom = virtual.virtualDeviceSwitchOverVideoZoomFactors[index - 1].doubleValue * Double(zoomDisplayMultiplier(for: virtual))
        }
        // Prefer the native wide + telephoto route for the common 1×...tele
        // range. A separate ultra-wide route keeps 0.5× available on MultiCam
        // combinations where a triple camera cannot run alongside the front.
        if !device.constituentDevices.contains(where: { $0.deviceType == .builtInUltraWideCamera }),
           let ultra = AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back),
           (!captureIsDual || frontDevice.map { front in discovery.supportedMultiCamDeviceSets.contains(where: { $0.contains(ultra) && $0.contains(front) }) } == true),
           (!captureVideoMode || videoFormat(for: ultra, profile: captureIsDual ? dualVideoProfile : singleVideoProfile) != nil),
           ultra.formats.contains(where: { (!captureIsDual || $0.isMultiCamSupported) && CMVideoFormatDescriptionGetDimensions($0.formatDescription).width <= 1920 }) {
            alternateUltraWideDevice = ultra
            alternateUltraWideZoom = virtual.map { Double(zoomDisplayMultiplier(for: $0)) } ?? 0.5
            if alternateUltraWideZoom >= 1 { alternateUltraWideZoom = 0.5 }
            minimum = min(minimum, alternateUltraWideZoom)
        }
        let wide = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        let secondary = wide?.formats.flatMap { $0.secondaryNativeResolutionZoomFactors.map(Double.init) } ?? []
        let sensorCrop = secondary.contains { abs($0 - 2) < 0.05 }
        let teleSecondary = telephotoDevice?.formats.flatMap { format in
            format.secondaryNativeResolutionZoomFactors.map { Double($0) * (telephotoZoom ?? 1) }
        } ?? []
        let stops = CameraZoomScale.stops(minimum: minimum, telephoto: telephotoZoom, sensorCrop: sensorCrop,
                                         calibration: CameraFocalCalibration.known(CaptureDeviceInfo.current.hardwareIdentifier),
                                         extraFactors: secondary + teleSecondary)
        // A virtual route containing the telephoto constituent can switch
        // internally. Only dual-wide + front needs a separate rear input.
        let nativeTele = device.constituentDevices.contains { $0.deviceType == .builtInTelephotoCamera }
        let available = nativeTele ? Double(device.maxAvailableVideoZoomFactor) * multiplier
            : telephotoDevice.map { Double($0.maxAvailableVideoZoomFactor) * (telephotoZoom ?? 1) }
                ?? Double(device.maxAvailableVideoZoomFactor) * multiplier
        let hardware = CaptureDeviceInfo.current.hardwareIdentifier
        rearPhotoMaximum = CameraZoomPolicy.maximum(hardware: hardware, video: false, available: available,
                                                    hasTelephoto: telephotoZoom != nil, sensorCrop: sensorCrop, telephotoFactor: telephotoZoom, nativeTelephotoCrop: teleSecondary.max())
        rearVideoMaximum = CameraZoomPolicy.maximum(hardware: hardware, video: true, available: available,
                                                    hasTelephoto: telephotoZoom != nil, sensorCrop: sensorCrop, telephotoFactor: telephotoZoom, nativeTelephotoCrop: teleSecondary.max())
        rearZoomStops = stops
        let maximum = captureVideoMode ? rearVideoMaximum : rearPhotoMaximum
        let initial = captureVideoMode ? 1 : MainCameraPreference.initial(
            main: CameraFocalCalibration.known(hardware)?.main, maximum: maximum)
        requestedRearZoom = initial; appliedRearZoom = initial
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            device.videoZoomFactor = CGFloat(initial / multiplier)
        } catch { publish { $0.message = "暂时无法设置倍率：\(error.localizedDescription)" } }
        supportedRearZoomRange = minimum...max(1, maximum)
        let range = supportedRearZoomRange
        publish { $0.availableRearZooms = stops.filter { range.contains($0.factor) }; $0.rearZoom = initial; $0.rearZoomRange = range }
    }

    private func rearZoomBase(for device: AVCaptureDevice) -> Double {
        if device.uniqueID == alternateUltraWideDevice?.uniqueID { return alternateUltraWideZoom }
        if device.uniqueID == telephotoDevice?.uniqueID { return telephotoZoom ?? 1 }
        return Double(zoomDisplayMultiplier(for: device))
    }

    func setCaptureKind(_ kind: CaptureKind) async {
        #if DEBUG && targetEnvironment(simulator)
        if shutterUIFixture {
            await MainActor.run {
                captureVideoMode = kind == .video
                rearZoomRange = 0.5...(captureVideoMode ? 15 : 25)
                rearZoom = min(rearZoom, rearZoomRange.upperBound)
            }
            return
        }
        #endif
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                captureVideoMode = kind == .video
                if configured, recording == nil, photoCapture == nil {
                    if captureVideoMode {
                        do { try prepareVideoFormat() } catch { publish { $0.message = error.localizedDescription } }
                    } else { restorePhotoFormat(); removeMicrophone() }
                }
                warmRecordingResources()
                refreshRearZoomRange(video: captureVideoMode || recording != nil)
                continuation.resume()
            }
        }
    }

    private func rearRouteSupportsCurrentVideo(_ device: AVCaptureDevice) -> Bool {
        guard let profile = activeVideoProfile else { return true }
        guard let format = videoFormat(for: device, profile: profile) else { return false }
        guard recording != nil, let current = rearDevice else { return true }
        let old = CMVideoFormatDescriptionGetDimensions(current.activeFormat.formatDescription)
        let next = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        return old.width == next.width && old.height == next.height
    }

    private func refreshRearZoomRange(video: Bool) {
        var minimum = rearZoomStops.first?.factor ?? 1
        var maximum = video ? rearVideoMaximum : rearPhotoMaximum
        if video {
            if let ultra = alternateUltraWideDevice, !rearRouteSupportsCurrentVideo(ultra) { minimum = 1 }
            if let tele = telephotoDevice, !rearRouteSupportsCurrentVideo(tele), let standard = standardRearDevice {
                maximum = min(maximum, Double(standard.maxAvailableVideoZoomFactor) * rearZoomBase(for: standard))
            }
        }
        supportedRearZoomRange = minimum...max(minimum, maximum)
        let range = supportedRearZoomRange
        let stops = rearZoomStops.filter { range.contains($0.factor) }
        let clamped = min(range.upperBound, max(range.lowerBound, requestedRearZoom))
        publish { $0.rearZoomRange = range; if !stops.isEmpty { $0.availableRearZooms = stops }; $0.rearZoom = clamped }
        if configured, clamped != requestedRearZoom {
            requestedRearZoom = clamped
            do { try applyRearZoom(smooth: false, allowLensSwitch: true) }
            catch { publish { $0.message = "倍率调整未完成：\(error.localizedDescription)" } }
        }
    }

    private func configureFrontZoom(_ device: AVCaptureDevice) {
        let nativeCrop = device.activeFormat.secondaryNativeResolutionZoomFactors.map(Double.init)
            .filter { $0 > Double(device.minAvailableVideoZoomFactor) + 0.01 }.min()
        supportedFrontZoomRange = CameraZoomPolicy.frontRange(minimum: Double(device.minAvailableVideoZoomFactor),
            maximum: Double(device.maxAvailableVideoZoomFactor), nativeCrop: nativeCrop)
        let range = supportedFrontZoomRange
        do {
            try device.lockForConfiguration()
            device.videoZoomFactor = CGFloat(range.lowerBound)
            device.unlockForConfiguration()
        } catch { publish { $0.message = "前置取景范围暂时无法调整。" } }
        publish { $0.frontZoomRange = range; $0.frontZoom = range.lowerBound }
    }

    func restoreMainFraming() {
        queue.async { [self] in
            guard configured, !captureVideoMode, recording == nil, photoCapture == nil, rearDevice != nil else { return }
            let value = MainCameraPreference.initial(main: CameraFocalCalibration.known(CaptureDeviceInfo.current.hardwareIdentifier)?.main,
                maximum: supportedRearZoomRange.upperBound)
            setRearZoom(value, smooth: true)
        }
    }

    func setFrontZoom(_ value: Double, smooth: Bool = false) {
        guard value.isFinite else { return }
        #if DEBUG && targetEnvironment(simulator)
        if shutterUIFixture { publish { $0.frontZoom = min($0.frontZoomRange.upperBound, max($0.frontZoomRange.lowerBound, value)) }; return }
        #endif
        zoomRequestLock.lock()
        frontRequest = (value, smooth)
        let schedule = !frontWorkScheduled
        frontWorkScheduled = true
        zoomRequestLock.unlock()
        guard schedule else { return }
        queue.asyncAfter(deadline: .now() + 1.0 / 60) { [self] in
            zoomRequestLock.lock()
            let request = frontRequest; frontRequest = nil; frontWorkScheduled = false
            zoomRequestLock.unlock()
            guard let (value, smooth) = request, configured, photoCapture == nil, let device = frontDevice else { return }
            let factor = min(supportedFrontZoomRange.upperBound, max(supportedFrontZoomRange.lowerBound, value))
            do {
                try device.lockForConfiguration()
                device.ramp(toVideoZoomFactor: CGFloat(factor), withRate: CameraZoomPolicy.rampRate(from: Double(device.videoZoomFactor), to: factor, duration: smooth ? 0.22 : 0.1))
                device.unlockForConfiguration()
                publish { $0.frontZoom = factor }
            } catch { publish { $0.message = "前置取景范围暂时无法调整。" } }
        }
    }

    // At most one pending request per display interval; the UI represents the
    // requested framing, while hardware readback is retained for diagnostics.
    func setRearZoom(_ value: Double, smooth: Bool = false) {
        guard value.isFinite else { return }
        #if DEBUG && targetEnvironment(simulator)
        if shutterUIFixture { publish { $0.rearZoom = min($0.rearZoomRange.upperBound, max($0.rearZoomRange.lowerBound, value)) }; return }
        #endif
        zoomRequestLock.lock()
        zoomRequest = (value, smooth)
        let schedule = !zoomWorkScheduled
        zoomWorkScheduled = true
        zoomRequestLock.unlock()
        guard schedule else { return }
        queue.asyncAfter(deadline: .now() + 1.0 / 60) { [self] in drainZoomRequest() }
    }

    private func drainZoomRequest() {
        zoomRequestLock.lock()
        let request = zoomRequest; zoomRequest = nil; zoomWorkScheduled = false
        zoomRequestLock.unlock()
        guard let (value, smooth) = request, configured, wantsRunning,
              photoCapture == nil, standardRearDevice != nil else { return }
        requestedRearZoom = min(supportedRearZoomRange.upperBound, max(supportedRearZoomRange.lowerBound, value))
        let desired = requestedRearZoom
        publish { $0.rearZoom = desired }
        do { try applyRearZoom(smooth: smooth, allowLensSwitch: smooth) }
        catch {
            let actual = appliedRearZoom
            publish { $0.rearZoom = actual; $0.isSwitchingLens = false; $0.message = "暂时无法切换镜头：\(error.localizedDescription)" }
        }
    }

    private func applyRearZoom(smooth: Bool, allowLensSwitch: Bool) throws {
        guard let standardRearDevice, let current = rearDevice else { return }
        let nativeTele = standardRearDevice.constituentDevices.contains { $0.deviceType == .builtInTelephotoCamera }
        let useTele = !nativeTele && (telephotoZoom.map { requestedRearZoom >= $0 } ?? false)
            && (telephotoDevice.map(rearRouteSupportsCurrentVideo) ?? false)
        let desiredTarget: AVCaptureDevice
        if requestedRearZoom < 1, let alternateUltraWideDevice { desiredTarget = alternateUltraWideDevice }
        else { desiredTarget = useTele ? (telephotoDevice ?? standardRearDevice) : standardRearDevice }
        let changingLens = current.uniqueID != desiredTarget.uniqueID
        var target = desiredTarget
        if changingLens && !allowLensSwitch {
            // A short dwell prevents repeated graph rebuilds when the finger
            // wavers at an optical boundary. Never fake a wider telephoto FOV.
            if deferredLensID != desiredTarget.uniqueID {
                deferredLensSwitch?.cancel()
                deferredLensID = desiredTarget.uniqueID
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.deferredLensID = nil; self.deferredLensSwitch = nil
                    guard self.wantsRunning, self.photoCapture == nil else { return }
                    do { try self.applyRearZoom(smooth: false, allowLensSwitch: true) }
                    catch { self.publish { $0.isSwitchingLens = false; $0.message = "暂时无法切换镜头：\(error.localizedDescription)" } }
                }
                deferredLensSwitch = work
                queue.asyncAfter(deadline: .now() + 0.12, execute: work)
            }
            target = current
        } else {
            deferredLensSwitch?.cancel(); deferredLensSwitch = nil; deferredLensID = nil
            if changingLens { try switchRearCamera(to: target) }
        }
        let base = rearZoomBase(for: target)
        let factor = min(target.maxAvailableVideoZoomFactor, max(target.minAvailableVideoZoomFactor, CGFloat(requestedRearZoom / base)))
        try target.lockForConfiguration()
        if changingLens && target === desiredTarget { target.videoZoomFactor = factor }
        else {
            // Updating the ramp target does not cancel the system's acceleration
            // curve on every touch event, unlike direct videoZoomFactor writes.
            target.ramp(toVideoZoomFactor: factor, withRate: CameraZoomPolicy.rampRate(from: Double(target.videoZoomFactor), to: Double(factor), duration: smooth ? 0.22 : 0.1))
        }
        target.unlockForConfiguration()
        appliedRearZoom = Double(target.videoZoomFactor) * base
        publish { $0.isSwitchingLens = false }
        zoomVerification?.cancel()
        let desiredFactor = factor
        let verification = DispatchWorkItem { [weak self] in
            guard let self, self.rearDevice?.uniqueID == target.uniqueID, self.session.isRunning else { return }
            if !target.isRampingVideoZoom, abs(target.videoZoomFactor - desiredFactor) > 0.01 {
                do {
                    try target.lockForConfiguration()
                    target.videoZoomFactor = desiredFactor
                    target.unlockForConfiguration()
                } catch { self.publish { $0.message = "倍率暂时无法应用，请重试。" } }
            }
            self.refreshPhotoCapabilities()
            self.recordStabilizationDiagnostics(event: "zoom-\(CameraZoomPreset.number(self.requestedRearZoom))")
        }
        zoomVerification = verification
        queue.asyncAfter(deadline: .now() + 0.6, execute: verification)
    }

    private func observeRearZoom() {
        zoomObserver = rearDevice?.observe(\.videoZoomFactor, options: [.new]) { [weak self] device, _ in
            self?.queue.async { [weak self] in
                guard let self, self.rearDevice?.uniqueID == device.uniqueID else { return }
                let base = self.rearZoomBase(for: device)
                self.appliedRearZoom = Double(device.videoZoomFactor) * base

            }
        }
    }

    // Keep the front camera and microphone connected, including during recording.
    // Both rear routes use the same frame geometry and host-clock time base.
    private func switchRearCamera(to target: AVCaptureDevice) throws {
        guard let previous = rearDevice else { return }
        if let profile = activeVideoProfile {
            guard let format = videoFormat(for: target, profile: profile) else { throw CamError.message("此镜头不支持当前录像规格。") }
            if recording != nil {
                let old = CMVideoFormatDescriptionGetDimensions(previous.activeFormat.formatDescription)
                let next = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                guard old.width == next.width && old.height == next.height else { throw CamError.message("当前录像格式无法连续切换到这个镜头。") }
            }
        }
        #if DEBUG
        let switchStarted = CACurrentMediaTime()
        var stages: [String: Double] = [:]
        defer {
            zoomSwitchCount += 1
            zoomSwitchMilliseconds.append((CACurrentMediaTime() - switchStarted) * 1000)
            zoomSwitchStages.append(stages)
        }
        #endif
        for device in devices where device.hasTorch && device.torchMode != .off {
            try device.lockForConfiguration(); device.torchMode = .off; device.unlockForConfiguration()
        }
        publish { $0.isSwitchingLens = true }
        zoomObserver = nil
        stabilizationObservers.removeAll()
        pressureObservers.removeAll()
        liveBuffer.setEnabled(false)
        session.beginConfiguration()
        func detachRear() {
            session.connections.filter { $0.inputPorts.contains { $0.sourceDevicePosition == .back } }.forEach(session.removeConnection)
            // Retain output objects and their configured delivery paths. Only
            // reconnect the rear input ports; the front and audio keep running.
            session.inputs.compactMap { $0 as? AVCaptureDeviceInput }.filter { $0.device.position == .back }.forEach(session.removeInput)
        }
        let previousDimensions = CMVideoFormatDescriptionGetDimensions(previous.activeFormat.formatDescription)
        func attach(_ device: AVCaptureDevice) throws {
            if let profile = activeVideoProfile {
                guard let format = videoFormat(for: device, profile: profile) else { throw CamError.message("此镜头不支持当前录像规格。") }
                try device.lockForConfiguration()
                device.activeFormat = format
                device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: Int32(profile.fps))
                device.activeVideoMaxFrameDuration = device.activeVideoMinFrameDuration
                device.unlockForConfiguration()
            } else { try selectFormat(device, maximumWidth: 1920) }
            let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
            if recording != nil && (dimensions.width != previousDimensions.width || dimensions.height != previousDimensions.height) {
                throw CamError.message("当前录像格式无法连续切换到这个镜头。")
            }
            try addCamera(device, photoOutput: rearPhotos, videoOutput: rearVideo, preview: rearPreview, mirrored: false)
            configurePhotoDimensions(rearPhotos, device: device)
            configureStabilization(device: device, preview: rearPreview, output: rearVideo)
            if let format = [kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
                .first(where: { rearVideo.availableVideoPixelFormatTypes.contains($0) }) {
                rearVideo.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: format]
            }
            guard hardwareCost <= 1 else { throw CamError.message("当前长焦与前摄组合负载过高。") }
        }
        detachRear()
        #if DEBUG
        stages["detach"] = (CACurrentMediaTime() - switchStarted) * 1000
        #endif
        var switchError: Error?
        do { try attach(target); rearDevice = target }
        catch {
            switchError = error
            detachRear()
            do {
                try attach(previous); rearDevice = previous
                try previous.lockForConfiguration()
                let base = rearZoomBase(for: previous)
                previous.videoZoomFactor = min(previous.maxAvailableVideoZoomFactor, max(previous.minAvailableVideoZoomFactor, CGFloat(appliedRearZoom / base)))
                previous.unlockForConfiguration()
            }
            catch { configured = false; publish { $0.state = .unavailable("镜头恢复失败，请重新打开相机。") } }
        }
        devices = [rearDevice, frontDevice].compactMap { $0 }
        #if DEBUG
        stages["attach"] = (CACurrentMediaTime() - switchStarted) * 1000
        #endif
        // Apply the existing thermal budget inside this same transaction. A
        // second commit immediately afterwards needlessly restarts processing.
        applyLoadPlan(CameraLoadPolicy.plan(level: appliedPressureLevel, causes: []), level: appliedPressureLevel, force: true)
        session.commitConfiguration()
        #if DEBUG
        stages["commit"] = (CACurrentMediaTime() - switchStarted) * 1000
        #endif
        observeRearZoom()
        observeStabilization()
        pressureSnapshots.removeAll()
        pressureObservers = devices.map { device in
            device.observe(\.systemPressureState, options: [.initial, .new]) { [weak self] device, _ in
                self?.queue.async { [weak self] in self?.handlePressure(device.systemPressureState, device: device) }
            }
        }
        refreshLiveBuffer()
        applyLighting()
        if let switchError { throw switchError }
    }

    func focus(at previewPoint: CGPoint, previewSize: CGSize, front: Bool, lock: Bool) {
        let layer = front ? frontPreview : rearPreview
        let bounds = layer.bounds
        let layerPoint: CGPoint
        if previewSize.width > 0, previewSize.height > 0, bounds.width > 0, bounds.height > 0 {
            layerPoint = CGPoint(x: previewPoint.x * bounds.width / previewSize.width,
                                 y: previewPoint.y * bounds.height / previewSize.height)
        } else {
            layerPoint = previewPoint
        }
        let converted = layer.captureDevicePointConverted(fromLayerPoint: layerPoint)
        let nativePoint = CGPoint(x: min(1, max(0, converted.x)), y: min(1, max(0, converted.y)))
        queue.async { [self] in
            guard configured, session.isRunning, let device = front ? frontDevice : rearDevice else { return }
            let usesVideo = front ? frontUsesVideoDisplay : rearUsesVideoDisplay
            let devicePoint: CGPoint
            if usesVideo {
                let imageSize = front ? frontVideoSize : rearVideoSize
                let displayPoint = front && !mirrorsFront
                    ? CGPoint(x: previewSize.width - previewPoint.x, y: previewPoint.y) : previewPoint
                let point = CameraFocusGeometry.imagePoint(displayPoint, viewSize: previewSize, imageSize: imageSize)
                let output = front ? frontVideo : rearVideo
                // Let AVFoundation convert the actual output's rotated, mirrored
                // and scaled image back to the camera's normalized coordinates.
                let sensorRect = output.metadataOutputRectConverted(fromOutputRect:
                    CGRect(x: point.x - 0.5, y: point.y - 0.5, width: 1, height: 1))
                devicePoint = CGPoint(x: min(1, max(0, sensorRect.midX)), y: min(1, max(0, sensorRect.midY)))
            } else { devicePoint = nativePoint }
            #if DEBUG
            lastFocusDiagnostic = ["front": front, "locked": lock,
                                   "tap": [Double(previewPoint.x), Double(previewPoint.y)],
                                   "viewSize": [Double(previewSize.width), Double(previewSize.height)],
                                   "sensorPoint": [Double(devicePoint.x), Double(devicePoint.y)]]
            #endif
            let request = UUID()
            if front { frontFocusRequest = request } else { rearFocusRequest = request }
            do {
                try device.lockForConfiguration()
                if device.isFocusPointOfInterestSupported { device.focusPointOfInterest = devicePoint }
                if device.isExposurePointOfInterestSupported { device.exposurePointOfInterest = devicePoint }
                recordStabilizationDiagnostics(event: "focus-point")
                if device.isFocusModeSupported(.autoFocus) { device.focusMode = .autoFocus }
                if device.isExposureModeSupported(lock ? .autoExpose : .continuousAutoExposure) {
                    device.exposureMode = lock ? .autoExpose : .continuousAutoExposure
                }
                device.isSubjectAreaChangeMonitoringEnabled = !lock
                device.unlockForConfiguration()
            } catch {
                publish { $0.message = "暂时无法调整对焦：\(error.localizedDescription)" }
                return
            }
            guard lock else { return }
            queue.asyncAfter(deadline: .now() + 0.7) { [weak self, weak device] in
                guard let self, let device,
                      (front ? self.frontFocusRequest : self.rearFocusRequest) == request else { return }
                do {
                    try device.lockForConfiguration()
                    if device.isFocusModeSupported(.locked) { device.focusMode = .locked }
                    if device.isExposureModeSupported(.locked) { device.exposureMode = .locked }
                    device.isSubjectAreaChangeMonitoringEnabled = false
                    device.unlockForConfiguration()
                } catch {
                    self.publish { $0.message = "暂时无法锁定对焦：\(error.localizedDescription)" }
                }
            }
        }
    }

    func setExposureBias(_ bias: Float, front: Bool) {
        queue.async { [self] in
            guard configured, session.isRunning, let device = front ? frontDevice : rearDevice else { return }
            let value = min(device.maxExposureTargetBias, max(device.minExposureTargetBias, bias))
            do {
                try device.lockForConfiguration()
                device.setExposureTargetBias(value)
                device.unlockForConfiguration()
            } catch {
                publish { $0.message = "暂时无法调整曝光：\(error.localizedDescription)" }
            }
        }
    }

    private func selectFormat(_ device: AVCaptureDevice, maximumWidth: Int32) throws {
        let key = device.uniqueID + "-" + String(maximumWidth) + "-" + String(captureIsDual)
        let candidates = cachedFormats[key].map { [$0] } ?? device.formats.filter {
            let size = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
            return (!captureIsDual || $0.isMultiCamSupported) && size.width <= maximumWidth && size.height <= maximumWidth * 3 / 4 &&
                CameraFormatGeometry.supportsLiveBuffer(CMFormatDescriptionGetMediaSubType($0.formatDescription)) &&
                $0.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= 30 && $0.maxFrameRate >= 30 }
        }.sorted {
            let a = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
            let b = CMVideoFormatDescriptionGetDimensions($1.formatDescription)
            // A 16:9 sensor crop followed by a 4:3 photo crop discards image
            // on both axes. Keep the full photo-shaped stream (also used by
            // Live Photo/QuickTake), with system stabilization still supported.
            func stabilized(_ format: AVCaptureDevice.Format) -> Bool {
                CameraStabilizationPolicy.preferences(for: .recording)
                    .contains(where: format.isVideoStabilizationModeSupported)
            }
            let aStable = stabilized($0), bStable = stabilized($1)
            if aStable != bStable { return aStable }
            let aSpan = CameraFormatGeometry.photoSpan(width: a.width, height: a.height, fieldOfView: $0.videoFieldOfView)
            let bSpan = CameraFormatGeometry.photoSpan(width: b.width, height: b.height, fieldOfView: $1.videoFieldOfView)
            if abs(aSpan - bSpan) > 0.001 { return aSpan > bSpan }
            if a.width * a.height == b.width * b.height {
                return $0.secondaryNativeResolutionZoomFactors.count > $1.secondaryNativeResolutionZoomFactors.count
            }
            return a.width * a.height > b.width * b.height
        }
        guard let format = cachedFormats[key] ?? candidates.first else { throw CamError.message("没有可用的相机画面格式。") }
        cachedFormats[key] = format
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        device.activeFormat = format
        device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
        device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
        if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
        if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
        if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { device.whiteBalanceMode = .continuousAutoWhiteBalance }
    }

    private func handlePressure(_ state: AVCaptureDevice.SystemPressureState, device: AVCaptureDevice) {
        // KVO callbacks queued before a source switch may belong to a removed lens.
        guard devices.contains(where: { $0.uniqueID == device.uniqueID }) else { return }
        let level: CameraPressureLevel
        switch state.level {
        case .fair: level = .fair
        case .serious: level = .serious
        case .critical: level = .critical
        case .shutdown: level = .shutdown
        default: level = .normal
        }
        var causes: CameraPressureCauses = []
        if state.factors.contains(.systemTemperature) || state.factors.contains(.cameraTemperature) ||
            state.factors.contains(.depthModuleTemperature) {
            causes.insert(.thermal)
        }
        if state.factors.contains(.peakPower) { causes.insert(.peakPower) }
        pressureSnapshots[device.uniqueID] = (level, causes)
        updateCombinedPressure()
    }

    func setSystemEnergy(_ energy: CaptureEnergyState) {
        queue.async { [self] in
            systemEnergy = energy
            if configured, wantsRunning { updateCombinedPressure() }
        }
    }

    private var combinedPressure: CameraPressureLevel {
        max(systemEnergy.pressure, pressureSnapshots.values.map(\.level).max() ?? .normal)
    }

    private func updateCombinedPressure() {
        var causes = pressureSnapshots.values.reduce(into: CameraPressureCauses()) { $0.formUnion($1.causes) }
        if systemEnergy.thermal != .nominal { causes.insert(.thermal) }
        updateCaptureLoad(level: combinedPressure, causes: causes)
    }

    private func updateCaptureLoad(level: CameraPressureLevel, causes: CameraPressureCauses) {
        guard wantsRunning else { return }
        if level < appliedPressureLevel {
            guard recoveryTarget != level else { return }
            pressureRecoveryWorkItem?.cancel()
            recoveryTarget = level
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.wantsRunning, self.combinedPressure <= level else { return }
                self.recoveryTarget = nil
                self.pressureRecoveryWorkItem = nil
                let plan = CameraLoadPolicy.plan(level: level, causes: causes)
                self.applyLoadPlan(plan, level: level)
                self.pressureNoticeWorkItem?.cancel()
                self.publish { $0.cameraLoadNotice = plan.notice }
            }
            pressureRecoveryWorkItem = work
            queue.asyncAfter(deadline: .now() + 12, execute: work)
            return
        }
        pressureRecoveryWorkItem?.cancel(); pressureRecoveryWorkItem = nil; recoveryTarget = nil
        applyLoadPlan(CameraLoadPolicy.plan(level: level, causes: causes), level: level)
        pressureNoticeWorkItem?.cancel()
        guard level >= .serious else { publish { $0.cameraLoadNotice = nil }; return }
        let plan = CameraLoadPolicy.plan(level: level, causes: causes)
        let notice = DispatchWorkItem { [weak self] in
            guard let self, self.wantsRunning, self.appliedPressureLevel >= level else { return }
            let fps = self.devices.map { Int((1 / $0.activeVideoMaxFrameDuration.seconds).rounded()) }.min() ?? Int(plan.frameRate)
            let notice = plan.notice.map { self.activeVideoProfile != nil ? $0 + "（当前 \(fps) fps）" : $0 }
            self.publish { $0.cameraLoadNotice = notice }
        }
        pressureNoticeWorkItem = notice
        queue.asyncAfter(deadline: .now() + 2, execute: notice)
    }

    private func applyLoadPlan(_ plan: CameraLoadPlan, level: CameraPressureLevel, force: Bool = false) {
        guard force || appliedPressureLevel != level else { return }
        appliedPressureLevel = level
        publish { $0.pressureLevel = level }
        liveBuffer.configure(maxFramesPerSecond: plan.liveFrameRate, maxLongEdge: plan.liveLongEdge)
        let requested = Int32(activeVideoProfile?.fps ?? 30)
        let actualTarget = CaptureWorkPolicy.frameRate(requested: requested, pressure: level,
            videoMode: captureVideoMode, recording: recording != nil || recordingStartID != nil)
        // Keep the input allocation warm across idle/recording. Changing that
        // allocation restarts the graph and costs ~0.6 s on the device, whereas
        // changing the device cadence can take effect without restarting preview.
        let reservedTarget = CaptureWorkPolicy.frameRate(requested: requested, pressure: level,
            videoMode: captureVideoMode, recording: true)
        let rates = devices.compactMap { device -> (AVCaptureDevice, AVCaptureDeviceInput?, CMTime, CMTime)? in
            guard let actual = supportedFrameRate(near: actualTarget, device: device),
                  let reserved = supportedFrameRate(near: reservedTarget, device: device) else { return nil }
            let input = session.inputs.compactMap { $0 as? AVCaptureDeviceInput }.first { $0.device === device }
            return (device, input, CMTime(value: 1, timescale: actual), CMTime(value: 1, timescale: reserved))
        }
        let reconfigure = rates.contains { _, input, _, ceiling in input.map { $0.videoMinFrameDurationOverride != ceiling } ?? false }
        if reconfigure { session.beginConfiguration() }
        defer {
            if reconfigure { session.commitConfiguration() }
            refreshVideoReadout()
        }
        for (device, input, duration, ceiling) in rates {
            do {
                // Raise the ceiling first so the previous limit cannot clamp
                // the device's subsequent frame-duration assignment.
                if let input, input.videoMinFrameDurationOverride != ceiling {
                    input.videoMinFrameDurationOverride = ceiling
                }
                if device.activeVideoMinFrameDuration != duration || device.activeVideoMaxFrameDuration != duration {
                    try device.lockForConfiguration()
                    device.activeVideoMinFrameDuration = duration
                    device.activeVideoMaxFrameDuration = duration
                    device.unlockForConfiguration()
                }
            } catch {
                #if DEBUG
                print("Cam frame-rate reduction failed for \(device.localizedName): \(error.localizedDescription)")
                #endif
            }
        }
        verifyStabilization(after: 0.8, event: "load-\(level.rawValue)")
    }

    private func supportedFrameRate(near target: Int32, device: AVCaptureDevice) -> Int32? {
        let candidates = [target, 30, 24, 20, 15, 10].filter { $0 <= target }
        return candidates.first { rate in
            device.activeFormat.videoSupportedFrameRateRanges.contains {
                $0.minFrameRate <= Double(rate) && $0.maxFrameRate >= Double(rate)
            }
        }
    }

    /// Capture-queue only. Requested recording settings stay separate from the
    /// live readout, including frame rates (15/20/etc.) absent from the picker.
    private func refreshVideoReadout(resetMeasurements: Bool = false) {
        #if DEBUG && targetEnvironment(simulator)
        if shutterUIFixture { return }
        #endif
        let rates = Dictionary(uniqueKeysWithValues: devices.compactMap { device -> (Bool, Int)? in
            let duration = device.activeVideoMaxFrameDuration.seconds
            guard duration.isFinite, duration > 0 else { return nil }
            return (device.position == .front, max(1, Int((1 / duration).rounded())))
        })
        if resetMeasurements || rates != deviceVideoFrameRates {
            deviceVideoFrameRates = rates
            measuredVideoFrameRates.removeAll(keepingCapacity: true)
            // Reject observations spanning the previous format/cadence.
            videoRateMeasurementSince = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        }
        let requested = activeVideoProfile ?? (captureIsDual ? dualVideoProfile : singleVideoProfile)
        let capturing = recording != nil || recordingStartID != nil
        let front = capturing ? recordingFrontIsPrimary : lightingFront
        let fps = VideoFrameRateReadout.fps(requested: requested.fps, device: rates[front],
            measured: measuredVideoFrameRates[front], recording: capturing, constrained: appliedPressureLevel >= .serious)
        let profile = VideoRecordingProfile(resolution: requested.resolution, fps: fps)
        publish { if $0.actualVideoProfile != profile { $0.actualVideoProfile = profile } }
    }

    private func addCamera(_ device: AVCaptureDevice, photoOutput: AVCapturePhotoOutput,
                           videoOutput: AVCaptureVideoDataOutput, preview: AVCaptureVideoPreviewLayer,
                           mirrored: Bool) throws {
        if #available(iOS 26.0, *) {
            videoOutput.isDeferredStartEnabled = false
            preview.isDeferredStartEnabled = false
            if photoOutput.isDeferredStartSupported {
                photoOutput.isDeferredStartEnabled = true
            }
            // The system begins deferred outputs after initial preview frames;
            // no UI timer or per-shutter preparation is introduced.
            session.automaticallyRunsDeferredStart = true
        }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw CamError.message("无法同时连接两个摄像头。") }
        session.addInputWithNoConnections(input)
        // Limit resource reservation as well as delivered fps. Otherwise a
        // 60 fps-capable 4:3 format reserves 60 fps of MultiCam processing even
        // though this app only captures 30 fps (or less under pressure).
        input.videoMinFrameDurationOverride = CMTime(value: 1, timescale: Int32(activeVideoProfile?.fps ?? 30))
        guard let port = input.ports(for: .video, sourceDeviceType: device.deviceType,
                                     sourceDevicePosition: device.position).first else {
            throw CamError.message("摄像头画面连接失败。")
        }
        photoOutput.maxPhotoQualityPrioritization = .balanced
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: queue)
        for output: AVCaptureOutput in [photoOutput, videoOutput] {
            if !session.outputs.contains(output) {
                guard session.canAddOutput(output) else { throw CamError.message("无法建立双摄保存通道。") }
                session.addOutputWithNoConnections(output)
            }
            let connection = AVCaptureConnection(inputPorts: [port], output: output)
            guard session.canAddConnection(connection) else { throw CamError.message("无法连接相机与保存通道。") }
            session.addConnection(connection)
            orient(connection, mirrored: mirrored && mirrorsFront)
        }
        if preview.session !== session { preview.setSessionWithNoConnection(session) }
        let connection = AVCaptureConnection(inputPort: port, videoPreviewLayer: preview)
        guard session.canAddConnection(connection) else { throw CamError.message("无法显示双摄预览。") }
        session.addConnection(connection)
        orient(connection, mirrored: mirrored)
    }

    private func configureStabilization(device: AVCaptureDevice, preview: AVCaptureVideoPreviewLayer,
                                         output: AVCaptureVideoDataOutput) {
        for (connection, target) in [(preview.connection, CameraStabilizationPolicy.Target.preview),
                                     (output.connection(with: .video), .recording)] {
            guard let connection else { continue }
            connection.preferredVideoStabilizationMode = stabilizationEnabled ? CameraStabilizationPolicy.preferred(
                for: target, connectionSupported: connection.isVideoStabilizationSupported,
                formatSupports: device.activeFormat.isVideoStabilizationModeSupported) : .off
            if target == .recording, captureVideoMode, stabilizationEnabled, enhancedStabilizationRequested,
               connection.isVideoStabilizationSupported, devices.allSatisfy({ $0.activeFormat.isVideoStabilizationModeSupported(.cinematic) }) {
                connection.preferredVideoStabilizationMode = .cinematic
            }
            if target == .preview {
                // Use the same stabilized video frame for the aperture and its
                // surroundings. An additional preview would have its own crop
                // and timing and adds unnecessary camera processing.
                connection.preferredVideoStabilizationMode = .off
                connection.isEnabled = false
            }
        }
    }

    private var stabilizationConnections: [(String, AVCaptureDevice, AVCaptureConnection, CameraStabilizationPolicy.Target)] {
        var result: [(String, AVCaptureDevice, AVCaptureConnection, CameraStabilizationPolicy.Target)] = []
        for (name, device, preview, output) in [("rear", rearDevice, rearPreview, rearVideo),
                                               ("front", frontDevice, frontPreview, frontVideo)] {
            guard let device else { continue }
            if let connection = preview.connection { result.append((name + "-preview", device, connection, .preview)) }
            if let connection = output.connection(with: .video) { result.append((name + "-video", device, connection, .recording)) }
        }
        return result
    }

    private func observeStabilization() {
        stabilizationObservers = stabilizationConnections.map { name, _, connection, _ in
            connection.observe(\.activeVideoStabilizationMode, options: [.new]) { [weak self] _, _ in
                guard let self else { return }
                self.queue.async { [self] in
                    self.refreshPhotoCapabilities()
                    self.recordStabilizationDiagnostics(event: "changed-" + name)
                }
            }
        }
    }

    private func verifyStabilization(after delay: Double, event: String, allowFallback: Bool = true) {
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.wantsRunning, self.session.isRunning else { return }
            var fellBack = false
            // A supported format is not enough: confirm the running connection
            // accepted the request. Some camera/output combinations reject modes.
            if allowFallback {
                for (_, device, connection, target) in self.stabilizationConnections {
                    guard target == .recording, connection.isActive,
                          connection.isVideoStabilizationSupported,
                          connection.activeVideoStabilizationMode == .off,
                          connection.preferredVideoStabilizationMode != .off,
                          connection.preferredVideoStabilizationMode != .standard,
                          device.activeFormat.isVideoStabilizationModeSupported(.standard) else { continue }
                    connection.preferredVideoStabilizationMode = .standard
                    fellBack = true
                }
            }
            self.refreshPhotoCapabilities()
            self.recordStabilizationDiagnostics(event: event)
            if fellBack { self.verifyStabilization(after: 0.8, event: event + "-fallback", allowFallback: false) }
        }
    }

    #if DEBUG
    private var didRecordCameraCapabilities = false
    private let diagnosticsQueue = DispatchQueue(label: "cam.diagnostics", qos: .utility)
    private func recordCameraCapabilities() {
        guard !didRecordCameraCapabilities else { return }
        didRecordCameraCapabilities = true
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera,
            .builtInUltraWideCamera, .builtInTelephotoCamera, .builtInTrueDepthCamera,
            .builtInDualCamera, .builtInDualWideCamera, .builtInTripleCamera], mediaType: .video, position: .unspecified)
        func name(_ device: AVCaptureDevice) -> String { "\(device.position.rawValue):\(device.deviceType.rawValue)" }
        let cameras: [[String: Any]] = discovery.devices.map { device in
            let formats: [[String: Any]] = device.formats.compactMap { format in
                let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                guard format.isMultiCamSupported, size.width <= 3840, size.height <= 2880 else { return nil }
                return ["width": size.width, "height": size.height, "fov": format.videoFieldOfView,
                        "pixelFormat": CMFormatDescriptionGetMediaSubType(format.formatDescription),
                        "fps": format.videoSupportedFrameRateRanges.map { [$0.minFrameRate, $0.maxFrameRate] },
                        "stabilization": ([AVCaptureVideoStabilizationMode.previewOptimized] + CameraStabilizationPolicy.preferences(for: .recording))
                            .filter(format.isVideoStabilizationModeSupported).map(CameraStabilizationPolicy.name)]
            }
            return ["device": name(device), "formats": formats]
        }
        let report: [String: Any] = ["cameras": cameras,
            "simultaneousSets": discovery.supportedMultiCamDeviceSets.map { $0.map(name).sorted() }]
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CamDiagnostics")
        diagnosticsQueue.async {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: folder.appendingPathComponent("camera-capabilities.json"), options: .atomic)
        } catch { print("Cam capabilities diagnostic failed: \(error)") }
        }
    }
    #endif

    private func recordStabilizationDiagnostics(event: String) {
        #if DEBUG
        let connections: [[String: Any]] = stabilizationConnections.map { name, device, connection, _ in
            let size = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
            return ["connection": name, "deviceType": device.deviceType.rawValue,
                    "width": Int(size.width), "height": Int(size.height),
                    "fieldOfView": device.activeFormat.videoFieldOfView,
                    "fps": 1 / device.activeVideoMinFrameDuration.seconds,
                    "zoom": device.videoZoomFactor,
                    "displayZoom": device.position == .back ? appliedRearZoom : Double(device.videoZoomFactor),
                    "activeLens": device.activePrimaryConstituent?.deviceType.rawValue ?? device.deviceType.rawValue,
                    "nativeCropFactors": device.activeFormat.secondaryNativeResolutionZoomFactors.map(Double.init),
                    "photoWidth": device.position == .back ? rearPhotos.maxPhotoDimensions.width : frontPhotos.maxPhotoDimensions.width,
                    "photoHeight": device.position == .back ? rearPhotos.maxPhotoDimensions.height : frontPhotos.maxPhotoDimensions.height,
                    "supported": connection.isVideoStabilizationSupported,
                    "requested": CameraStabilizationPolicy.name(connection.preferredVideoStabilizationMode),
                    "active": CameraStabilizationPolicy.name(connection.activeVideoStabilizationMode),
                    "connected": connection.isActive,
                    "enabled": connection.isEnabled,
                    "formatModes": ([AVCaptureVideoStabilizationMode.previewOptimized] + CameraStabilizationPolicy.preferences(for: .recording))
                        .filter(device.activeFormat.isVideoStabilizationModeSupported).map(CameraStabilizationPolicy.name)]
        }
        let snapshot: [String: Any] = ["event": event, "time": Date().timeIntervalSince1970,
                                      "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
                                      "running": session.isRunning, "hardwareCost": hardwareCost,
                                      "captureIsDual": captureIsDual, "captureFront": captureFront,
                                      "videoInputCount": session.inputs.compactMap { $0 as? AVCaptureDeviceInput }.filter { $0.device.hasMediaType(.video) }.count,
                                      "captureState": ["configured": configured, "saving": saving, "recording": recording != nil,
                                                       "photoCapture": photoCapture != nil, "liveCoordinator": !liveCoordinators.isEmpty, "pendingSaves": outstandingSaves],
                                      "systemPressureCost": systemPressureCost,
                                      "thermalState": ProcessInfo.processInfo.thermalState.rawValue,
                                      "microphoneAttached": audioInput != nil,
                                      "videoMode": captureVideoMode,
                                      "rearDisplayFrames": rearDisplayedFrames,
                                      "frontDisplayFrames": frontDisplayedFrames,
                                      "rearDisplaySource": rearUsesVideoDisplay ? "stabilized-video" : "native-preview",
                                      "frontDisplaySource": frontUsesVideoDisplay ? "stabilized-video" : "native-preview",
                                      "focus": lastFocusDiagnostic,
                                      "liveBuffer": liveBuffer.diagnostics,
                                      "rearOutputUnitRect": String(describing: rearVideo.outputRectConverted(fromMetadataOutputRect: CGRect(x: 0, y: 0, width: 1, height: 1))),
                                      "frontOutputUnitRect": String(describing: frontVideo.outputRectConverted(fromMetadataOutputRect: CGRect(x: 0, y: 0, width: 1, height: 1))),
                                      "connections": connections, "telephotoAnchor": telephotoZoom ?? 0,
                                      "zoomRange": [supportedRearZoomRange.lowerBound, supportedRearZoomRange.upperBound],
                                      "requestedRearZoom": requestedRearZoom, "zoomSwitchCount": zoomSwitchCount,
                                      "zoomSwitchMilliseconds": zoomSwitchMilliseconds,
                                      "frontZoomRange": [supportedFrontZoomRange.lowerBound, supportedFrontZoomRange.upperBound]]
        stabilizationDiagnostics.append(snapshot)
        if stabilizationDiagnostics.count > 100 { stabilizationDiagnostics.removeFirst(stabilizationDiagnostics.count - 100) }
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CamDiagnostics")
        let snapshots = stabilizationDiagnostics
        diagnosticsQueue.async {
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let data = try JSONSerialization.data(withJSONObject: snapshots, options: [.sortedKeys, .prettyPrinted])
                try data.write(to: folder.appendingPathComponent("stabilization.json"), options: .atomic)
            } catch { print("Cam stabilization diagnostic failed: \(error.localizedDescription)") }
        }
        #endif
    }

    private func orient(_ connection: AVCaptureConnection, mirrored: Bool) {
        // AVFoundation resolves each sensor's mounting, including landscape iPad front cameras.
        if connection.isVideoOrientationSupported { connection.videoOrientation = captureOrientation.video }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = mirrored
        }
    }

    private func configurePhotoDimensions(_ output: AVCapturePhotoOutput, device: AVCaptureDevice) {
        if !(session is AVCaptureMultiCamSession), output.isAppleProRAWSupported {
            output.isAppleProRAWEnabled = PhotoCaptureProfile.current().format == .raw && !liveBufferingEnabled && !captureVideoMode
        }
        if let dimensions = device.activeFormat.supportedMaxPhotoDimensions.filter({ PhotoCaptureCapabilities.pixels($0) != 24 }).max(by: {
            Int64($0.width) * Int64($0.height) < Int64($1.width) * Int64($1.height)
        }) { output.maxPhotoDimensions = dimensions }
    }

    private func refreshLiveBuffer() {
        liveBuffer.setEnabled(CaptureWorkPolicy.liveBuffer(requested: liveBufferingEnabled,
            running: configured && wantsRunning, videoMode: captureVideoMode,
            hasVideoFormat: activeVideoProfile != nil, recording: recording != nil))
    }

    func setLivePhotoEnabled(_ enabled: Bool) async {
        #if targetEnvironment(simulator)
        return
        #else
        let audioGranted: Bool
        if enabled {
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: audioGranted = true
            case .notDetermined: audioGranted = await AVCaptureDevice.requestAccess(for: .audio)
            default: audioGranted = false
            }
        } else { audioGranted = false }

        await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard wantsRunning, configured, session.isRunning else {
                    liveBufferingEnabled = false
                    liveBuffer.setEnabled(false)
                    removeMicrophone(force: true)
                    continuation.resume()
                    return
                }
                liveBufferingEnabled = enabled
                refreshLiveBuffer()
                if enabled && audioGranted {
                    do { try addMicrophone() }
                    catch { publish { $0.message = "Live Photo 可以拍摄，但暂时没有声音：\(error.localizedDescription)" } }
                } else if !enabled, recording == nil {
                    warmRecordingResources()
                }
                #if DEBUG
                print("Cam custom Live buffering: enabled=\(enabled) audio=\(audioInput != nil)")
                #endif
                continuation.resume()
            }
        }
        #endif
    }

    func takePhoto(layout: CameraLayout, live: Bool, flashMode: CameraFlashMode = .off,
                   albumMode: AlbumSaveMode? = nil, duringRecording: Bool = false) async {
        #if DEBUG && targetEnvironment(simulator)
        if shutterUIFixture { await MainActor.run { fixtureTakePhoto() }; return }
        #endif
        let live = live && !duringRecording
        let albumSaveMode = albumMode ?? AlbumSaveMode.current()
        let shutterSoundEnabled = PhotoShutterSoundPolicy.isEnabled()
        let audioGranted: Bool
        if live {
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: audioGranted = true
            case .notDetermined: audioGranted = await AVCaptureDevice.requestAccess(for: .audio)
            default: audioGranted = false
            }
        } else { audioGranted = false }
        queue.async { [self] in
            guard configured, matchesSource(layout), session.isRunning,
                  (duringRecording ? recording != nil : recording == nil),
                  photoCapture == nil, outstandingSaves < maximumOutstandingSaves else { return }
            do {
                if deferredLensSwitch != nil { try applyRearZoom(smooth: false, allowLensSwitch: true) }
                if live && audioGranted && audioInput == nil {
                    do { try addMicrophone() }
                    catch { publish { $0.message = "Live Photo 可以拍摄，但这次没有声音：\(error.localizedDescription)" } }
                }
                let metadata = metadataProvider.snapshot(cameras: devices)
                let wantedProfile = PhotoCaptureProfile.current()
                let primaryOutput = layout.frontIsPrimary ? frontPhotos : rearPhotos
                if wantedProfile.format == .raw, !live, !duringRecording,
                   !(session is AVCaptureMultiCamSession), primaryOutput.isAppleProRAWSupported {
                    primaryOutput.isAppleProRAWEnabled = true
                }
                var capabilities = currentPhotoCapabilities(front: layout.frontIsPrimary)
                // A ProRAW-capable route may temporarily have no usable RAW format.
                // Resolve before creating the draft so metadata never promises a missing DNG.
                let rawPixel = (layout.frontIsPrimary ? frontDevice : rearDevice).flatMap { usableRAWPixelFormat(primaryOutput, device: $0) }
                if rawPixel == nil { capabilities.formats.removeAll { $0 == .raw } }
                let profile = capabilities.resolve(wantedProfile, live: live || duringRecording)
                let draft = try disk.createDraft(kind: .photo, layout: layout, metadata: metadata, albumSaveMode: albumSaveMode, photoProfile: profile, inFlight: true)
                let coordinator = LivePhotoCaptureCoordinator { [weak self] photo, movie in
                    guard let self else { return }
                    finishPhoto(draft: draft, photo: photo, movie: movie)
                }
                liveCoordinators[draft.item.id] = coordinator
                if live {
                    let audioSettings: [String: Any]? = audioInput == nil ? nil :
                        (audioOutput.recommendedAudioSettingsForAssetWriter(writingTo: .mov)
                         ?? [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100,
                             AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 128000])
                    let started = liveBuffer.beginCapture(draft: draft, audioSettings: audioSettings) {
                        rear, front, duration, displayTime, error in
                        coordinator.receiveMovie(rear: rear, front: front, duration: duration,
                                                 displayTime: displayTime, error: error)
                    }
                    if !started {
                        recordStabilizationDiagnostics(event: "live-buffer-unavailable")
                        coordinator.receiveMovie(rear: false, front: false, duration: nil, displayTime: nil,
                                                 error: "Live Photo 动态缓冲尚未准备好，这次静态原片仍会保留。")
                    }
                } else {
                    coordinator.receiveMovie(rear: false, front: false, duration: nil, displayTime: nil, error: nil)
                }

                do {
                    let capture = PhotoPairCapture(draft: draft, queue: queue, saveQueue: saveQueue, live: false,
                        onShutter: { [weak self] time in self?.liveBuffer.alignShutter(id: draft.item.id, to: time) },
                        onAcquired: { [weak self] in
                            guard let self else { return }
                            photoCapture = nil
                            if !captureVideoMode { restorePhotoFormat() }
                            publishCaptureActivity()
                        }, onThumbnail: { [weak self] image in
                            self?.publish {
                                guard draft.item.captureDate >= $0.latestThumbnailDate else { return }
                                $0.latestThumbnailDate = draft.item.captureDate
                                $0.latestCaptureThumbnail = image
                            }
                        }) {
                        rear, front, _, _, _, _, error in
                        coordinator.receivePhoto(rear: rear, front: front, error: error)
                    }
                    photoCapture = capture
                    publishCaptureActivity()
                    for (output, possibleDelegate) in [(rearPhotos, capture.rear), (frontPhotos, capture.front)] {
                        guard let delegate = possibleDelegate else { continue }
                        let isPrimary = layout.frontIsPrimary ? output === frontPhotos : output === rearPhotos
                        let primaryDevice = layout.frontIsPrimary ? frontDevice : rearDevice
                        let codec = profile.processedFormat.codec
                        let settings: AVCapturePhotoSettings
                        if isPrimary, profile.format == .raw, !live, !duringRecording,
                           let pixel = rawPixel {
                            settings = AVCapturePhotoSettings(rawPixelFormatType: pixel, processedFormat: [AVVideoCodecKey: codec])
                        } else { settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: codec]) }
                        if !duringRecording, isPrimary, primaryDevice?.isFlashAvailable == true,
                           output.supportedFlashModes.contains(flashMode.avMode) {
                            settings.flashMode = flashMode.avMode
                        }
                        // One system sound when enabled, silence both outputs when disabled.
                        // Never request suppression on a device that forbids it.
                        if #available(iOS 18.0, *) {
                            settings.isShutterSoundSuppressionEnabled = PhotoShutterSoundPolicy.suppress(
                                isPrimary: isPrimary, supported: output.isShutterSoundSuppressionSupported,
                                soundEnabled: shutterSoundEnabled)
                        }
                        #if DEBUG
                        if #available(iOS 18.0, *) {
                            shutterSoundDiagnostics.append(["id": draft.item.id.uuidString,
                                "front": output === frontPhotos, "primary": isPrimary,
                                "supported": output.isShutterSoundSuppressionSupported,
                                "soundEnabled": shutterSoundEnabled,
                                "suppressed": settings.isShutterSoundSuppressionEnabled,
                                "duringRecording": duringRecording])
                            shutterSoundDiagnostics = Array(shutterSoundDiagnostics.suffix(32))
                        }
                        #endif
                        let bayerRAW = settings.rawPhotoPixelFormatType != 0 && AVCapturePhotoOutput.isBayerRAWPixelFormat(settings.rawPhotoPixelFormatType)
                        settings.photoQualityPrioritization = duringRecording || bayerRAW ? .speed : .balanced
                        let device = output === frontPhotos ? frontDevice : rearDevice
                        let dimensions = PhotoCaptureCapabilities.dimensions(device?.activeFormat.supportedMaxPhotoDimensions ?? [], maximum: output.maxPhotoDimensions)
                        let maximum = isPrimary ? profile.megapixels : 12
                        settings.maxPhotoDimensions = dimensions.last(where: { PhotoCaptureCapabilities.pixels($0) <= maximum }) ?? dimensions.first ?? output.maxPhotoDimensions
                        output.capturePhoto(with: settings, delegate: delegate)
                    }
                }
                if live && !audioGranted {
                    publish { $0.message = "Live Photo 会正常保存；开启麦克风权限后可同时记录声音。" }
                }
            } catch {
                photoCapture = nil
                publishCaptureActivity()
                publish { $0.message = CaptureStorageFailure.message(for: error) }
            }
        }
    }

    private func finishPhoto(draft: CaptureDraft, photo: LivePhotoCaptureCoordinator.PhotoResult,
                             movie: LivePhotoCaptureCoordinator.MovieResult) {
        let note = photo.error ?? movie.error ?? (draft.item.capturedLayout.complete(rear: photo.rear, front: photo.front) ? nil : "只保存了一路照片，暂时无法合成。")
        saveQueue.async { [self] in
            let result = Result {
                try disk.finish(draft, rear: photo.rear, front: photo.front, note: note,
                    rearLive: movie.rear, frontLive: movie.front,
                    livePhotoDuration: movie.duration, livePhotoDisplayTime: movie.displayTime)
            }
            queue.async { [self] in
                CaptureDraftActivity.end(draft.item.id)
                liveCoordinators.removeValue(forKey: draft.item.id)
                completeSave(result, note: note)
            }
        }
    }

    func dismissSaveIssue() { saveIssue = nil }

    private func completeSave(_ result: Result<MemoryItem, Error>, note: String?) {
        publish {
            switch result {
            case .success(let item):
                $0.savedMedia.send(item)
                $0.savedCount += 1
                if let note { $0.saveIssue = note }
            case .failure(let error):
                $0.saveIssue = "已写入的原片仍保留在拍摄目录。" + CaptureStorageFailure.message(for: error)
            }
        }
        publishCaptureActivity()
    }

    @discardableResult
    func startVideo(layout: CameraLayout, albumMode: AlbumSaveMode? = nil, requestID: UUID = UUID()) async -> Bool {
        #if DEBUG && targetEnvironment(simulator)
        if shutterUIFixture {
            let delay = ProcessInfo.processInfo.arguments.contains("--ui-delayed-start") ? 1.4 : 0.15
            do { try await Task.sleep(for: .seconds(delay)) } catch { return false }
            return await MainActor.run {
                guard state == .ready, !isBusy, !isRecording else { return false }
                elapsed = 0; isRecording = true; return true
            }
        }
        #endif
        let trace = RecordingStartTrace()
        let albumSaveMode = albumMode ?? AlbumSaveMode.current()
        let granted: Bool
        if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized { granted = true }
        else { granted = await AVCaptureDevice.requestAccess(for: .audio) }
        guard !Task.isCancelled else { return false }
        guard granted else {
            await MainActor.run { message = "录制视频需要麦克风权限，请在系统设置中开启。" }
            return false
        }
        let request = VideoStartRequest(id: requestID)
        let trigger = CMClockGetTime(CMClockGetHostTimeClock())
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async { [self] in
                    trace.mark("queue")
                    guard !request.isCancelled, configured, matchesSource(layout), wantsRunning, session.isRunning,
                          recording == nil, photoCapture == nil, outstandingSaves < maximumOutstandingSaves else {
                        continuation.resume(returning: false); return
                    }
                    recordingStartID = request.id; activeVideoRequestID = request.id; recordingStartCompletion = continuation
                    recordingFrontIsPrimary = layout.frontIsPrimary
                    refreshVideoReadout(resetMeasurements: true)
                    publish { $0.isStartingVideo = true }
                    do {
                        refreshRearZoomRange(video: true)
                        try prepareVideoFormat()
                        trace.mark("format")
                        try addMicrophone()
                        trace.mark("microphone")
                        guard !request.isCancelled else {
                            resolveVideoStart(false)
                            if !captureVideoMode { restorePhotoFormat() }
                            return
                        }
                        let metadata = metadataProvider.snapshot(cameras: devices, maximumPastLocationAge: 5 * 60)
                        let draft = disk.reserveDraft(kind: .video, layout: layout, metadata: metadata,
                            albumSaveMode: albumSaveMode, videoProfile: activeVideoProfile, inFlight: true)
                        let sourceSizes = Dictionary(uniqueKeysWithValues: devices.map { device in
                            let size = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
                            return (device.position == .front, captureOrientation.isLandscape ? size : CMVideoDimensions(width: size.height, height: size.width))
                        })
                        recordingNotBefore = trigger
                        recording = BufferedVideoRecorder(draft: draft, audioSettings: cachedAudioSettings,
                            sourceSizes: sourceSizes, preservesSourceAspect: recordingReusesPhotoFormat, callbackQueue: queue, prepare: { [disk] in
                                try disk.writeDraft(draft); trace.mark("draft")
                            }, onFrameRate: { [weak self] front, observation in
                                guard let self, self.recording?.draft.item.id == draft.item.id,
                                      observation.windowStart >= self.videoRateMeasurementSince else { return }
                                self.measuredVideoFrameRates[front] = observation.fps
                                self.refreshVideoReadout()
                            }, onStart: { [weak self] in
                                trace.mark("firstWritten"); trace.save(id: draft.item.id)
                                guard let self, self.recording?.draft.item.id == draft.item.id else { return }
                                self.publish { $0.elapsed = 0; $0.isRecording = true }
                                self.resolveVideoStart(true)
                            }, onFailure: { [weak self] error in
                                guard let self, self.recording?.draft.item.id == draft.item.id else { return }
                                self.finishRecording(reason: .writerFailure, failure: error)
                            })
                        lastElapsedUpdate = 0
                        verifyStabilization(after: 0.8, event: "video-start")
                        queue.asyncAfter(deadline: .now() + 4) { [weak self] in
                            guard let self, self.recordingStartID == request.id else { return }
                            self.finishRecording(reason: .startTimeout, failure: CamError.message("录像尚未获取到所需画面，请重新拍摄。"))
                        }
                    } catch {
                        resolveVideoStart(false)
                        removeMicrophone()
                        if !captureVideoMode { restorePhotoFormat() }
                        refreshRearZoomRange(video: captureVideoMode)
                        publish { $0.message = CaptureStorageFailure.message(for: error) }
                    }
                }
            }
        } onCancel: {
            request.cancel()
            self.queue.async { [weak self] in
                guard let self, self.recordingStartID == request.id else { return }
                self.finishRecording(reason: .startCancelled)
            }
        }
    }

    private func resolveVideoStart(_ success: Bool) {
        let completion = recordingStartCompletion
        recordingStartCompletion = nil; recordingStartID = nil
        if completion != nil { publish { $0.isStartingVideo = false } }
        if !success, recording == nil, captureVideoMode, wantsRunning {
            applyLoadPlan(CameraLoadPolicy.plan(level: appliedPressureLevel, causes: []), level: appliedPressureLevel, force: true)
        }
        completion?.resume(returning: success)
    }

    func stopVideo(source: String = #function, requestID: UUID? = nil) {
        #if DEBUG && targetEnvironment(simulator)
        if shutterUIFixture { Task { @MainActor in fixtureStopVideo() }; return }
        #endif
        queue.async { [self] in
            guard requestID == nil || activeVideoRequestID == requestID else { return }
            recordStabilizationDiagnostics(event: "stop-request-" + source)
            finishRecording(reason: .requested, trigger: source)
        }
    }

    func updateLayout(_ layout: CameraLayout) {
        queue.async { [self] in
            recording?.setLayout(layout)
            if recordingFrontIsPrimary != layout.frontIsPrimary {
                recordingFrontIsPrimary = layout.frontIsPrimary
                refreshVideoReadout()
            }
        }
    }

    private func publishCaptureActivity() {
        let count = outstandingSaves
        let activity = CaptureActivity(recording: recording != nil, savingVideo: saving,
            takingPhoto: photoCapture != nil, pendingPhotos: liveCoordinators.count,
            capacityReached: count >= maximumOutstandingSaves)
        let started = recording?.hasStarted ?? false
        publish {
            $0.isRecording = started
            $0.isTakingPhoto = activity.takingPhoto
            $0.isBusy = activity.isBusy
            $0.pendingSaveCount = count
            if activity.canEndBackgroundSave { $0.endBackgroundSave() }
        }
    }

    private func finishRecording(reason: RecordingStopReason, trigger: String? = nil,
                                 interruptionReason: Int? = nil, diagnosticError: NSError? = nil,
                                 note: String? = nil, failure: Error? = nil) {
        resolveVideoStart(false)
        guard let recording else { return }
        self.recording = nil
        activeVideoRequestID = nil
        finishingVideos.insert(recording.draft.item.id)
        // Freeze camera/location context before another capture can change lenses.
        var item = recording.draft.item
        let startedAt = item.captureMetadata?.recordedAt ?? item.createdAt
        item.captureMetadata = metadataProvider.snapshot(cameras: devices, at: startedAt,
            maximumPastLocationAge: 5 * 60, maximumFutureLocationAge: 10)
        let error = diagnosticError ?? failure.map { $0 as NSError }
        item.recordingDiagnostics = RecordingDiagnostics(reason: reason, trigger: trigger, stoppedAt: Date(),
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            pressureLevel: appliedPressureLevel.rawValue, thermalState: ProcessInfo.processInfo.thermalState.rawValue,
            interruptionReason: interruptionReason, errorDomain: error?.domain, errorCode: error?.code,
            buffer: recording.bufferStatistics)
        let finalDraft = CaptureDraft(item: item, folder: recording.draft.folder)
        let wasStarted = recording.hasStarted
        recording.finish(on: queue) { [self] rear, front, duration, moments, error in
            var finalItem = finalDraft.item
            finalItem.recordingDiagnostics?.finalizationIssue = error
            let completedDraft = CaptureDraft(item: finalItem, folder: finalDraft.folder)
            if !wasStarted, !rear, !front, failure == nil,
               error == "录像尚未获取到所需画面，请重新拍摄。" {
                // Only this cancelled, frame-less new draft is discarded. Existing
                // memories or a take containing a written picture never enter here.
                saveQueue.async { [self] in
                    try? FileManager.default.removeItem(at: finalDraft.folder)
                    queue.async { [self] in
                        CaptureDraftActivity.end(finalDraft.item.id)
                        finishingVideos.remove(finalDraft.item.id)
                        publishCaptureActivity()
                    }
                }
                return
            }
            let finalNote = failure.map { CaptureStorageFailure.message(for: $0) } ?? error ?? note
                ?? (finalDraft.item.capturedLayout.complete(rear: rear, front: front) ? nil : "有一路录像未能保存，已保留其余原片。")
            saveQueue.async { [self] in
                let result = Result {
                    try disk.finish(completedDraft, rear: rear, front: front, duration: duration,
                        moments: moments, note: finalNote)
                }
                queue.async { [self] in
                    CaptureDraftActivity.end(finalDraft.item.id)
                    finishingVideos.remove(finalDraft.item.id)
                    completeSave(result, note: finalNote)
                }
            }
        }
        // The old writer no longer consumes samples. Its asynchronous completion
        // must never remove the microphone or change the next recording's format.
        removeMicrophone()
        refreshRearZoomRange(video: captureVideoMode)
        if !captureVideoMode { restorePhotoFormat() }
        else { applyLoadPlan(CameraLoadPolicy.plan(level: appliedPressureLevel, causes: []), level: appliedPressureLevel, force: true) }
        publishCaptureActivity()
    }

    private func addMicrophone() throws {
        guard audioInput == nil else { return }
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playAndRecord, mode: .videoRecording, options: [.defaultToSpeaker])
        try audioSession.setActive(true)
        guard let microphone = AVCaptureDevice.default(for: .audio) else { throw CamError.message("麦克风不可用。") }
        let input = try AVCaptureDeviceInput(device: microphone)
        session.beginConfiguration()
        guard session.canAddInput(input) else { session.commitConfiguration(); throw CamError.message("无法连接麦克风。") }
        session.addInput(input)
        guard session.canAddOutput(audioOutput) else {
            session.removeInput(input)
            session.commitConfiguration()
            throw CamError.message("无法保存录像声音。")
        }
        session.addOutput(audioOutput)
        audioOutput.setSampleBufferDelegate(self, queue: queue)
        audioInput = input
        session.commitConfiguration()
        if let settings = audioOutput.recommendedAudioSettingsForAssetWriter(writingTo: .mov) {
            cachedAudioSettings = settings
        }
    }

    private func warmRecordingResources() {
        guard configured, wantsRunning, recording == nil else { return }
        let profile = captureIsDual ? dualVideoProfile : singleVideoProfile
        for device in devices { _ = videoFormat(for: device, profile: profile) }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
        // Keep one audio input ready for QuickTake. No rolling video encoder and
        // no audio is stored unless a capture/Live request consumes it.
        try? addMicrophone()
    }

    private func removeMicrophone(force: Bool = false) {
        // Keep authorized audio warm while the capture screen is visible,
        // including photo mode's QuickTake. Pause/background always releases it.
        if !force && (recording != nil || liveBufferingEnabled || wantsRunning) { return }
        if let audioInput {
            session.beginConfiguration()
            session.removeOutput(audioOutput)
            session.removeInput(audioInput)
            session.commitConfiguration()
            self.audioInput = nil
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard output === rearVideo || output === frontVideo || output === audioOutput else { return }
        if output === audioOutput { liveBuffer.consumeAudio(sampleBuffer) }
        else {
            let isFront = output === frontVideo
            #if DEBUG
            if !isFront, measuringZoomFrames {
                let now = CACurrentMediaTime()
                if let lastRearFrameTime { zoomFrameIntervals.append(now - lastRearFrameTime) }
                lastRearFrameTime = now
            }
            #endif
            if let image = CMSampleBufferGetImageBuffer(sampleBuffer) {
                let size = CGSize(width: CVPixelBufferGetWidth(image), height: CVPixelBufferGetHeight(image))
                if isFront, frontVideoSize != size {
                    frontVideoSize = size
                    publish { $0.frontPreviewSize = size }
                } else if !isFront, rearVideoSize != size {
                    rearVideoSize = size
                    publish { $0.rearPreviewSize = size }
                }
            }
            if isFront ? frontUsesVideoDisplay : rearUsesVideoDisplay {
                if display(sampleBuffer, on: isFront ? frontStabilizedPreview : rearStabilizedPreview) {
                    if isFront { frontDisplayedFrames += 1 } else { rearDisplayedFrames += 1 }
                    acceptModePreview(sampleBuffer, front: isFront)
                }
            } else { acceptModePreview(sampleBuffer, front: isFront) }
            liveBuffer.consumeVideo(sampleBuffer, isFront: isFront)
        }
        guard let recording else { return }
        recording.consume(sampleBuffer, front: output === audioOutput ? nil : output === frontVideo,
                          notBefore: recordingNotBefore)
        let elapsed = recording.elapsed
        if recording.hasStarted, elapsed - lastElapsedUpdate >= 0.2 {
            lastElapsedUpdate = elapsed
            publish { $0.elapsed = elapsed }
        }
    }

    @discardableResult
    private func display(_ sample: CMSampleBuffer, on layer: AVSampleBufferDisplayLayer) -> Bool {
        let renderer = layer.sampleBufferRenderer
        if renderer.requiresFlushToResumeDecoding { renderer.flush() }
        guard renderer.isReadyForMoreMediaData else { return false }
        var copy: CMSampleBuffer?
        guard CMSampleBufferCreateCopy(allocator: kCFAllocatorDefault, sampleBuffer: sample,
                                       sampleBufferOut: &copy) == noErr, let copy else { return false }
        if let flags = CMSampleBufferGetSampleAttachmentsArray(copy, createIfNecessary: true) as? [NSMutableDictionary] {
            flags.first?[kCMSampleAttachmentKey_DisplayImmediately] = true
        }
        renderer.enqueue(copy)
        return true
    }

    private func observeSession() {
        let center = NotificationCenter.default
        tokens.forEach(center.removeObserver); tokens.removeAll()
        let observedSession = session
        tokens.append(center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil) { [weak self] notification in
            guard let self else { return }
            let interruptionReason = (notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as? NSNumber)?.intValue
            queue.async { [self] in
                guard self.session === observedSession else { return }
                self.finishRecording(reason: .systemInterruption, interruptionReason: interruptionReason,
                    note: "拍摄被系统中断，已保存能够保留的录像。")
                self.liveBuffer.finishEarly(reason: "拍摄被系统中断，Live Photo 已保存当前可用的动态画面。")
                let state = Self.interruptionState(wantsRunning: self.wantsRunning,
                                                   reason: "相机暂时被系统占用，请稍后重试。")
                self.publish { $0.state = state }
            }
        })
        tokens.append(center.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: nil) { [weak self] _ in
            guard let self else { return }
            queue.async { [self] in
                guard self.session === observedSession else { return }
                if self.wantsRunning {
                    if !self.session.isRunning { self.session.startRunning() }
                    self.verifyStabilization(after: 0.8, event: "interruption-ended")
                    self.publish { $0.state = .ready }
                }
            }
        })
        tokens.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] notification in
            guard let self else { return }
            let error = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError
            queue.async { [self] in
                guard self.session === observedSession else { return }
                self.lastSessionError = error.map { "\($0.domain) \($0.code): \($0.userInfo)" } ?? "unknown"
                self.finishPreviewWait(false)
                self.finishRecording(reason: .runtimeError, diagnosticError: error, note: "相机发生中断，已保留拍摄文件。")
                self.liveBuffer.finishEarly(reason: "相机发生中断，Live Photo 已保存当前可用的动态画面。")
                let state = Self.interruptionState(wantsRunning: self.wantsRunning,
                                                   reason: error?.localizedDescription ?? "相机暂时无法使用，请重试。")
                self.publish { $0.state = state }
            }
        })
    }

    static func interruptionState(wantsRunning: Bool, reason: String) -> State {
        wantsRunning ? .unavailable(reason) : .paused
    }

    private func publish(_ update: @escaping (DualCamera) -> Void) {
        DispatchQueue.main.async { [weak self] in if let self { update(self) } }
    }

    private func endBackgroundSave() {
        #if !CAM_CAPTURE_EXTENSION
        guard backgroundSaveTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundSaveTask)
        backgroundSaveTask = .invalid
        #endif
    }
}

private final class LivePhotoCaptureCoordinator {
    struct PhotoResult {
        let rear: Bool
        let front: Bool
        let error: String?
    }

    struct MovieResult {
        let rear: Bool
        let front: Bool
        let duration: Double?
        let displayTime: Double?
        let error: String?
    }

    private var photo: PhotoResult?
    private var movie: MovieResult?
    private var completed = false
    private let completion: (PhotoResult, MovieResult) -> Void

    init(completion: @escaping (PhotoResult, MovieResult) -> Void) {
        self.completion = completion
    }

    func receivePhoto(rear: Bool, front: Bool, error: String?) {
        photo = PhotoResult(rear: rear, front: front, error: error)
        finishIfReady()
    }

    func receiveMovie(rear: Bool, front: Bool, duration: Double?, displayTime: Double?, error: String?) {
        movie = MovieResult(rear: rear, front: front, duration: duration,
                            displayTime: displayTime, error: error)
        finishIfReady()
    }

    private func finishIfReady() {
        guard !completed, let photo, let movie else { return }
        completed = true
        completion(photo, movie)
    }
}

final class PhotoDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    let completion: (PhotoCaptureResult) -> Void
    private var photo: Result<Data, Error>?
    private var raw: Result<Data, Error>?
    private var captureTime: CMTime = .invalid
    private var liveMovieSucceeded = false
    private var liveDuration: Double?
    private var displayTime: Double?
    private var liveError: Error?

    init(completion: @escaping (PhotoCaptureResult) -> Void) { self.completion = completion }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        captureTime = photo.timestamp
        let result: Result<Data, Error>
        if let error { result = .failure(error) }
        else if let data = photo.fileDataRepresentation() { result = .success(data) }
        else { result = .failure(CamError.message("照片数据为空。")) }
        if photo.isRawPhoto { raw = result } else { self.photo = result }
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingLivePhotoToMovieFileAt outputFileURL: URL,
                     duration: CMTime, photoDisplayTime: CMTime,
                     resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        liveMovieSucceeded = error == nil && FileManager.default.fileExists(atPath: outputFileURL.path)
        liveDuration = duration.seconds.isFinite ? duration.seconds : nil
        displayTime = photoDisplayTime.seconds.isFinite ? photoDisplayTime.seconds : nil
        liveError = error
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        if raw == nil, resolvedSettings.rawPhotoDimensions.width > 0 {
            raw = .failure(error ?? CamError.message("照片采集未完成。"))
        }
        let result = photo ?? error.map { Result<Data, Error>.failure($0) }
            ?? .failure(CamError.message("照片采集未完成。"))
        completion(PhotoCaptureResult(photo: result, captureTime: captureTime, liveMovieSucceeded: liveMovieSucceeded,
                                      liveDuration: liveDuration, displayTime: displayTime,
                                      liveError: liveError.map { CaptureStorageFailure.message(for: $0) }, raw: raw))
    }
}

struct PhotoCaptureResult {
    let photo: Result<Data, Error>
    let captureTime: CMTime
    let liveMovieSucceeded: Bool
    let liveDuration: Double?
    let displayTime: Double?
    let liveError: String?
    var raw: Result<Data, Error>? = nil
}

final class PhotoPairCapture {
    var rear: PhotoDelegate!
    var front: PhotoDelegate!
    private var received = 0
    private var written = 0
    private var rearOK = false
    private var frontOK = false
    private var failure: String?

    init(draft: CaptureDraft, queue: DispatchQueue, saveQueue: DispatchQueue, live: Bool,
         onShutter: @escaping (CMTime) -> Void = { _ in },
         onAcquired: @escaping () -> Void,
         onThumbnail: @escaping (UIImage) -> Void = { _ in },
         completion: @escaping (Bool, Bool, Bool, Bool, Double?, Double?, String?) -> Void) {
        let expected = draft.item.capturedLayout.isDual ? 2 : 1
        func receive(_ result: PhotoCaptureResult, front: Bool) {
            queue.async { [self] in
                onShutter(result.captureTime)
                received += 1
                // Hardware delivery and durable persistence are distinct milestones.
                if received == expected {
                    rear = nil; self.front = nil
                    onAcquired()
                }
                saveQueue.async { [self] in
                    var problem: String?
                    var imageSaved = false
                    if let raw = result.raw {
                        do { try raw.get().write(to: draft.rawURL(front: front), options: .atomic) }
                        catch { problem = CaptureStorageFailure.message(for: error) }
                    }
                    do {
                        let data = try result.photo.get()
                        try data.write(to: front ? draft.frontURL : draft.rearURL, options: .atomic)
                        imageSaved = true
                        if front == draft.item.capturedLayout.frontIsPrimary,
                           let source = CGImageSourceCreateWithData(data as CFData, nil),
                           let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                               kCGImageSourceCreateThumbnailFromImageAlways: true,
                               kCGImageSourceCreateThumbnailWithTransform: true,
                               kCGImageSourceThumbnailMaxPixelSize: 200] as CFDictionary) {
                            onThumbnail(UIImage(cgImage: image))
                        }
                    } catch { problem = CaptureStorageFailure.message(for: error) }
                    let error = problem
                    let saved = imageSaved
                    queue.async { [self] in
                        if let error { failure = error }
                        if saved { if front { frontOK = true } else { rearOK = true } }
                        written += 1
                        if written == expected { completion(rearOK, frontOK, false, false, nil, nil, failure) }
                    }
                }
            }
        }
        if draft.item.capturedLayout.includes(front: false) { rear = PhotoDelegate { receive($0, front: false) } }
        if draft.item.capturedLayout.includes(front: true) { front = PhotoDelegate { receive($0, front: true) } }
    }
}
