import SwiftUI
import AVFoundation
import AVKit
import os

struct CameraFocusRequest {
    let displayPoint: CGPoint
    let displaySize: CGSize
    let previewPoint: CGPoint
    let previewSize: CGSize
    let isFront: Bool
    let locked: Bool

    static func main(at point: CGPoint, size: CGSize, front: Bool, locked: Bool) -> Self {
        Self(displayPoint: point, displaySize: size, previewPoint: point,
             previewSize: size, isFront: front, locked: locked)
    }

    static func pip(at point: CGPoint, rect: CGRect, containerSize: CGSize,
                    front: Bool, locked: Bool) -> Self {
        let local = CGPoint(x: min(rect.width, max(0, point.x - rect.minX)),
                            y: min(rect.height, max(0, point.y - rect.minY)))
        return Self(displayPoint: point, displaySize: containerSize, previewPoint: local,
                    previewSize: rect.size, isFront: front, locked: locked)
    }
}

enum CameraFocusGeometry {
    static func imagePoint(_ point: CGPoint, viewSize: CGSize, imageSize: CGSize) -> CGPoint {
        let normalized = normalizedImagePoint(point, viewSize: viewSize, imageSize: imageSize)
        return CGPoint(x: normalized.x * imageSize.width, y: normalized.y * imageSize.height)
    }

    static func normalizedImagePoint(_ point: CGPoint, viewSize: CGSize, imageSize: CGSize) -> CGPoint {
        guard viewSize.width > 0, viewSize.height > 0, imageSize.width > 0, imageSize.height > 0 else {
            return CGPoint(x: 0.5, y: 0.5)
        }
        let scale = max(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
        let width = imageSize.width * scale, height = imageSize.height * scale
        return CGPoint(x: min(1, max(0, (point.x + (width - viewSize.width) / 2) / width)),
                       y: min(1, max(0, (point.y + (height - viewSize.height) / 2) / height)))
    }

    static func exposureBias(current: Float, verticalDelta: CGFloat) -> Float {
        min(2, max(-2, current - Float(verticalDelta / 70)))
    }
}

private struct CameraFocusVisual: Equatable {
    let id = UUID()
    var point: CGPoint
    var isFront: Bool
    var locked: Bool
    var exposureBias: Float
}

enum CameraTransitionPolicy {
    static func keepsPreview(for state: DualCamera.State, statusVisible: Bool) -> Bool {
        switch state {
        case .ready, .resuming, .paused: true
        case .unavailable: !statusVisible
        case .preparing, .denied: false
        }
    }

    static func showsRecoveryHint(for state: DualCamera.State, statusVisible: Bool) -> Bool {
        state == .resuming && statusVisible
    }
}

// Reference: the user's 375 × 812 pt native Camera screenshot. All geometry is
// expressed in one full-screen coordinate space, with a width-derived scale.
struct CameraChromeGeometry {
    let size: CGSize
    let kind: CaptureKind
    var aspect: CaptureAspect? = nil
    var landscapeCapture = false
    var usesSideRail: Bool { size.width >= 650 && size.width > size.height }
    private var classic: Bool { size.width <= 500 && size.height / max(1, size.width) >= 1.95 && !landscapeCapture }
    var scale: CGFloat { classic ? min(size.width / 375, size.height / 812) : min(1, max(0.92, size.width / 375)) }
    var centerX: CGFloat { usesSideRail ? size.width - 124 : size.width / 2 }
    var photoTop: CGFloat { classic ? 106 * scale : 64 }
    private var ratio: CGFloat {
        let value = aspect?.ratio ?? kind.aspectRatio
        return landscapeCapture ? 1 / value : value
    }
    var preview: CGRect {
        if classic {
            let height = size.width / ratio
            let top = ratio == 9 / 16
                ? max(0, bottomY - bottomDiameter / 2 - 20 * scale - height)
                : photoTop + (size.width * 4 / 3 - height) / 2
            return CGRect(x: 0, y: top, width: size.width, height: height)
        }
        let area = usesSideRail
            ? CGRect(x: 16, y: 64, width: max(1, size.width - 264), height: max(1, size.height - 88))
            : CGRect(x: 0, y: photoTop, width: size.width, height: max(1, shutterY - shutterDiameter / 2 - 14 - photoTop))
        let width = min(area.width, area.height * ratio)
        let height = width / ratio
        return CGRect(x: area.midX - width / 2, y: area.midY - height / 2, width: width, height: height)
    }
    var topControlsY: CGFloat { classic ? 77.3 * scale : 36 }
    var shutterY: CGFloat {
        if usesSideRail { return max(120, size.height * 0.40) }
        if !classic { return size.height - 150 }
        return min(photoTop + size.width * 4 / 3 + 55.67 * scale, bottomY - 80 * scale)
    }
    var bottomY: CGFloat { size.height - 54 * scale }
    var zoomY: CGFloat { classic ? min(preview.maxY - 36 * scale, shutterY - 91.67 * scale) : preview.maxY - 30 }
    var shutterDiameter: CGFloat { 80.67 * scale }
    var shutterInnerDiameter: CGFloat { 67.67 * scale }
    var bottomDiameter: CGFloat { max(44, 48 * scale) }
    var sideOffset: CGFloat { usesSideRail ? 64 : 133.5 * scale }
    var sideControl: CGPoint { usesSideRail ? CGPoint(x: centerX, y: shutterY + 110) : CGPoint(x: centerX + sideOffset, y: shutterY) }
}

enum CameraImageGeometry {
    // One image transform for the aperture and all genuinely available pixels
    // around it. No second aspect-fill operation and no duplicated frame.
    static func frame(imageSize: CGSize, aperture: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return aperture }
        let scale = max(aperture.width / imageSize.width, aperture.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: aperture.midX - size.width / 2, y: aperture.midY - size.height / 2,
                      width: size.width, height: size.height)
    }
}

private struct OutsideCameraAperture: Shape {
    var aperture: CGRect
    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(AnimatablePair(aperture.origin.x, aperture.origin.y), AnimatablePair(aperture.width, aperture.height)) }
        set { aperture = CGRect(x: newValue.first.first, y: newValue.first.second,
                               width: newValue.second.first, height: newValue.second.second) }
    }
    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        path.addRect(aperture)
        return path
    }
}

struct CaptureScreen: View {
    private let lifecycleLog = Logger(subsystem: "com.tison.dualcam", category: "CaptureLifecycle")
    @AppStorage("cameraLanguage") private var interfaceLanguage = CameraDefaults.string("cameraLanguage")
    @ObservedObject var camera: DualCamera
    @ObservedObject var library: MediaLibrary
    @ObservedObject var locationService: CaptureLocationService
    @StateObject private var albumSaver = AutoAlbumSaver()
    @StateObject private var energyMonitor = CaptureEnergyMonitor()
    @Environment(\.captureAccess) private var captureAccess
    @ObservedObject private var launchRoute = CameraLaunchRoute.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var captureMode: CameraCaptureMode = .dualPhoto
    @State private var changingSource = false
    @State private var initializedMode = false
    @State private var resumeTask: Task<Void, Never>?
    @State private var resumePermitted = true
    @State private var lockedViewVisible = false
    @State private var preferenceTask: Task<Void, Never>?
    @State private var modeTask: Task<Void, Never>?
    @State private var modeRevision = 0
    @State private var confirmedMode: CameraCaptureMode = .dualPhoto
    @State private var confirmedFront = false
    private var modeAnimation: Animation? { reduceMotion ? nil : .easeInOut(duration: 0.24) }
    private var kind: CaptureKind { captureMode.kind }
    @State private var pinchZoomOrigin: Double?
    @State private var layout = CameraLayout(pipEdgeToEdge: true, x: 1, y: 0)
    @State private var interfaceOrientation = CameraOrientation.portrait
    @State private var showLibrary = false
    @State private var showSettings = false
    @State private var showInfo = false
    @AppStorage("cameraPhotoAspect") private var photoAspectRaw = CameraDefaults.string("cameraPhotoAspect")
    @AppStorage("cameraVideoAspect") private var videoAspectRaw = CameraDefaults.string("cameraVideoAspect")
    @AppStorage("cameraFlash") private var flashRaw = CameraDefaults.string("cameraFlash")
    @AppStorage("cameraMirrorFront") private var mirrorsFront = CameraDefaults.bool("cameraMirrorFront")
    @AppStorage("cameraShutterSound") private var shutterSoundEnabled = CameraDefaults.bool("cameraShutterSound")
    @AppStorage("cameraSingleVideoProfile") private var singleVideoProfileRaw = CameraDefaults.string("cameraSingleVideoProfile")
    @AppStorage("cameraDualVideoProfile") private var dualVideoProfileRaw = CameraDefaults.string("cameraDualVideoProfile")
    @AppStorage("cameraGrid") private var showsGrid = CameraDefaults.bool("cameraGrid")
    @AppStorage("cameraLevel") private var showsLevel = CameraDefaults.bool("cameraLevel")
    @AppStorage("cameraStabilization") private var stabilizationOn = CameraDefaults.bool("cameraStabilization")
    @AppStorage("cameraLocation") private var recordsLocation = CameraDefaults.bool("cameraLocation")
    @AppStorage("cameraRemember") private var remembersOptions = CameraDefaults.bool("cameraRemember")
    @AppStorage("cameraMainLens28") private var mainLens28 = CameraDefaults.bool("cameraMainLens28")
    @AppStorage("cameraMainLens35") private var mainLens35 = CameraDefaults.bool("cameraMainLens35")
    @AppStorage("cameraDefaultMainLens") private var defaultMainLens = CameraDefaults.string("cameraDefaultMainLens")
    @AppStorage("cameraMode") private var savedMode = CameraDefaults.string("cameraMode")
    @AppStorage("cameraAlbumSaveMode") private var albumSaveModeRaw = CameraDefaults.string("cameraAlbumSaveMode")
    @State private var confirmAlbumRetry = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var torchRequested = false
    @State private var rearExposure = 0.0
    @State private var frontExposure = 0.0
    @State private var showLocationInfo = false
    @State private var flash = false
    @AppStorage("livePhotoEnabled") private var livePhotoEnabled = CameraDefaults.bool("livePhotoEnabled")
    @State private var shutterHeld = false
    @State private var recordingAtPressStart = false
    @State private var shutterGestureHandled = false
    @State private var quickTakeStarted = false
    @State private var videoStartPending = false
    @State private var quickTakeLocked = false
    @State private var shutterTranslation = CGSize.zero
    @State private var quickTakeGeneration = UUID()
    @GestureState private var shutterTouching = false
    @State private var holdTask: Task<Void, Never>?
    @State private var quickTakeTask: Task<Void, Never>?
    @State private var controlsExpanded = false
    @State private var optionsProgress: CGFloat = 0
    @State private var optionsPage: CameraOptionsPage = .overview
    @State private var optionsHeight: CGFloat = 260
    @AppStorage("cameraPhotoFormat") private var photoFormatRaw = CameraDefaults.string("cameraPhotoFormat")
    @AppStorage("cameraPhotoMP") private var photoMP = CameraDefaults.string("cameraPhotoMP")
    @AppStorage("cameraPhotoTimer") private var photoTimerRaw = CameraDefaults.string("cameraPhotoTimer")
    @AppStorage("cameraEnhancedStabilization") private var enhancedStabilization = CameraDefaults.bool("cameraEnhancedStabilization")
    @State private var countdown: Int?
    @State private var countdownTask: Task<Void, Never>?
    @State private var countdownID = UUID()
    @State private var focusVisual: CameraFocusVisual?
    @State private var focusDismissTask: Task<Void, Never>?
    @State private var cameraTransitionTask: Task<Void, Never>?
    @State private var cameraTransitionStatusVisible = false

    private var cameraCanvas: some View {
        GeometryReader { geometry in
            let previewKind: CaptureKind = camera.isRecording ? .video : kind
            let chrome = CameraChromeGeometry(size: geometry.size, kind: previewKind, aspect: layout.aspect, landscapeCapture: layout.orientation?.isLandscape == true)

            let panelLift = optionsPage == .overview ? 0 : min(0,
                geometry.size.height - optionsHeight - 28 - chrome.shutterDiameter / 2 - chrome.shutterY) * optionsProgress
            ZStack(alignment: .topLeading) {
                Color.black
                if CameraTransitionPolicy.keepsPreview(for: camera.state,
                                                       statusVisible: cameraTransitionStatusVisible) {
                    CameraVideoSurface(rear: camera.rearStabilizedPreview, front: camera.frontStabilizedPreview,
                                       rearSize: camera.rearPreviewSize, frontSize: camera.frontPreviewSize,
                                       frontNeedsMirror: camera.frontPreviewNeedsMirror,
                                       aperture: chrome.preview, layout: layout, showsGrid: showsGrid,
                                       modeRevision: modeRevision, transitioning: changingSource, reduceMotion: reduceMotion)
                        .equatable()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .allowsHitTesting(false)
                    OutsideCameraAperture(aperture: chrome.preview)
                        .fill(.black.opacity(0.64), style: FillStyle(eoFill: true))
                        .allowsHitTesting(false)
                }

                capturePreview(size: chrome.preview.size)
                    .position(x: chrome.preview.midX, y: chrome.preview.midY)

                topCameraControls(scale: chrome.scale)
                    .position(x: chrome.preview.midX, y: chrome.topControlsY)

                zoomControls(scale: chrome.scale)
                    .position(x: chrome.preview.midX, y: chrome.zoomY + panelLift)

                cameraOptions.zIndex(2)
                shutterControl(chrome: chrome)
                    .position(x: chrome.centerX, y: chrome.shutterY + panelLift)
                    .opacity(optionsPage == .overview ? 1 - optionsProgress : 1)
                    .allowsHitTesting(!controlsExpanded || optionsPage != .overview)
                    .accessibilityHidden(controlsExpanded && optionsPage == .overview)
                    .zIndex(3)
                if kind == .photo, let remaining = countdown ?? (photoTimerRaw == "0" ? nil : Int(photoTimerRaw)) {
                    Text(String(remaining))
                        .font(.system(size: 56 * chrome.scale, weight: .regular).monospacedDigit())
                        .foregroundStyle(.white).shadow(color: .black.opacity(0.45), radius: 3)
                        .frame(width: 104 * chrome.scale, height: 76 * chrome.scale, alignment: .leading)
                        .position(x: chrome.preview.minX + 64 * chrome.scale, y: chrome.preview.minY + 46 * chrome.scale)
                        .accessibilityIdentifier(countdown == nil ? "photoTimerIndicator" : "photoCountdown")
                        .accessibilityLabel(String(format: L10n.text("%@ 秒"), String(remaining)))
                        .accessibilityValue(String(remaining))
                        .allowsHitTesting(false).zIndex(1)
                }

                recordingSideControl(scale: chrome.scale)
                    .animation(shutterAnimation, value: camera.isRecording)
                    .animation(shutterAnimation, value: quickTakeHolding)
                    .position(x: chrome.sideControl.x, y: chrome.sideControl.y)
                    .opacity(1 - optionsProgress)

                bottomCameraControls(chrome: chrome)
                    .position(x: chrome.centerX, y: chrome.bottomY)
                    .opacity(1 - optionsProgress)


                ShutterGuidance(holding: quickTakeHolding, locked: quickTakeLocked,
                    recording: camera.isRecording, active: captureVisible && !controlsExpanded,
                    scale: chrome.scale)
                    .position(x: chrome.centerX, y: chrome.shutterY - 53 * chrome.scale)

                CaptureLoadStatus(message: camera.cameraLoadNotice, level: camera.pressureLevel,
                    active: captureVisible && !controlsExpanded, scale: chrome.scale,
                    availableWidth: geometry.size.width)
                    .position(x: 30 * chrome.scale, y: chrome.topControlsY)

                if let focusVisual, focusVisual.locked {
                    (Text(Image(systemName: "lock.fill")) + Text(" AE/AF"))
                        .font(.system(size: 10 * chrome.scale, weight: .semibold))
                        .foregroundStyle(.yellow)
                        .position(x: geometry.size.width - 44 * chrome.scale, y: chrome.topControlsY)
                        .allowsHitTesting(false)
                        .accessibilityLabel(L10n.text("自动曝光/自动对焦锁定"))
                        .accessibilityIdentifier("focusLockLabel")
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
            .background(CameraOrientationReader { value in
                interfaceOrientation = value
                Task { await applyInterfaceOrientation() }
            })
            .coordinateSpace(name: "cameraShutterCanvas")
        }
        // Physical camera geometry and drag directions never mirror with text.
        .environment(\.layoutDirection, .leftToRight)
        .ignoresSafeArea()
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
    }

    private var selectedVideoBinding: Binding<String> {
        Binding(get: { captureMode.isDual ? dualVideoProfileRaw : singleVideoProfileRaw }, set: {
            if captureMode.isDual { dualVideoProfileRaw = $0 } else { singleVideoProfileRaw = $0 }
        })
    }
    private var cameraOptions: some View {
        CameraOptionsPanel(camera: camera, isPresented: controlsExpanded, presentationProgress: $optionsProgress, video: kind == .video,
            flash: flashSelection, torch: $torchRequested, live: $livePhotoEnabled,
            aspect: aspectSelection, photoFormat: $photoFormatRaw, photoMP: $photoMP, timer: $photoTimerRaw,
            videoProfile: selectedVideoBinding, enhancedStabilization: $enhancedStabilization, page: $optionsPage,
            panelHeight: $optionsHeight, dual: captureMode.isDual, exposure: exposureSelection,
            openSettings: {
                cancelCountdown(); setOptionsVisible(false); camera.pause(); showSettings = true
            }, dismiss: { setOptionsVisible(false) })
            .allowsHitTesting(controlsExpanded && countdown == nil)
    }

    private var preferenceStamp: String {
        [photoAspectRaw, videoAspectRaw, flashRaw, String(showsGrid), String(showsLevel), String(stabilizationOn),
         String(recordsLocation), String(remembersOptions), albumSaveModeRaw, String(mirrorsFront), singleVideoProfileRaw, dualVideoProfileRaw,
         String(mainLens28), String(mainLens35), defaultMainLens, photoFormatRaw, photoMP, photoTimerRaw, String(enhancedStabilization)].joined(separator: "|")
    }

    private var aspectSelection: Binding<CaptureAspect> {
        Binding(get: { CaptureAspect(rawValue: kind == .photo ? photoAspectRaw : videoAspectRaw) ?? (kind == .photo ? .standard : .wide) },
                set: { value in
                    guard !camera.isRecording else { return }
                    if kind == .photo { photoAspectRaw = value.rawValue } else { videoAspectRaw = value.rawValue }
                    applySelectedAspect()
                })
    }
    private var flashSelection: Binding<CameraFlashMode> {
        Binding(get: { CameraFlashMode(rawValue: flashRaw) ?? .off }, set: { flashRaw = $0.rawValue })
    }
    private var exposureSelection: Binding<Double> {
        Binding(get: { layout.frontIsPrimary ? frontExposure : rearExposure }, set: { value in
            if layout.frontIsPrimary { frontExposure = value } else { rearExposure = value }
            camera.setExposureBias(Float(value), front: layout.frontIsPrimary)
        })
    }
    private func applySelectedAspect() {
        guard !camera.isRecording else { return }
        layout.aspect = aspectSelection.wrappedValue
        layout.insetAspectRatio = layout.orientation?.isLandscape == true ? 4.0 / 3 : 0.75
        clearFocus()
    }
    private func applyPreferences() {
        locationService.setEnabled(recordsLocation)
        updateLocationCollection()
        camera.setStabilizationEnabled(stabilizationOn || enhancedStabilization)
        camera.setEnhancedStabilization(enhancedStabilization)
        camera.setPhotoPreferences(live: livePhotoEnabled)
        updateLighting()
    }
    private func updateLighting() {
        camera.setLighting(front: layout.frontIsPrimary, torch: kind == .video && torchRequested)
    }
    private func setOptionsVisible(_ visible: Bool, page: CameraOptionsPage = .overview) {
        if visible { optionsPage = page; updateLighting() }
        controlsExpanded = visible
    }

    private var cameraSettings: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        LanguageSettingsView()
                    } label: {
                        LabeledContent(L10n.languageTitle, value: AppLanguage(rawValue: interfaceLanguage)?.nativeName ?? AppLanguage.system.nativeName)
                    }.accessibilityIdentifier("settingsLanguage")
                    Toggle(L10n.text("快门声音"), isOn: $shutterSoundEnabled)
                        .accessibilityIdentifier("settingsShutterSound")
                        .tint(.green)
                } header: {
                    Text(L10n.text("通用"))
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L10n.text("控制所有拍照的快门提示音，包括录像中拍照。不影响视频和实况照片的录音。"))
                        if !shutterSoundEnabled && camera.shutterSoundSuppressionSupported == false {
                            Text(L10n.text("当前设备受系统限制，无法关闭快门声音。"))
                        }
                    }
                }
                Section {
                    NavigationLink {
                        List {
                            ForEach(AlbumSaveMode.allCases) { mode in
                                Button {
                                    albumSaveModeRaw = mode.rawValue
                                } label: {
                                    HStack(alignment: .top, spacing: 12) {
                                        VStack(alignment: .leading, spacing: 6) {
                                            Text(L10n.text(mode.title)).foregroundStyle(.primary)
                                            Text(L10n.text(mode.detail)).font(.footnote).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        if albumSaveModeRaw == mode.rawValue { Image(systemName: "checkmark").foregroundStyle(.yellow) }
                                    }.padding(.vertical, 4)
                                }
                                .accessibilityIdentifier("albumSaveMode-" + mode.rawValue)
                                .accessibilityValue(L10n.text(albumSaveModeRaw == mode.rawValue ? "已选择" : "未选择"))
                            }
                        }.navigationTitle(L10n.text("保存内容")).navigationBarTitleDisplayMode(.inline)
                    } label: {
                        LabeledContent(L10n.text("保存内容"), value: L10n.text((AlbumSaveMode(rawValue: albumSaveModeRaw) ?? .dual).title))
                    }.accessibilityIdentifier("settingsAlbumSaveMode")
                    if albumSaver.pendingCount > 0 || albumSaver.isSaving {
                        Text(L10n.text(albumSaver.status)).font(.footnote).foregroundStyle(.secondary)
                    }
                    if let issue = camera.saveIssue {
                        Text(L10n.text(issue)).font(.footnote).foregroundStyle(.secondary)
                        Button(L10n.text("知道了")) { camera.dismissSaveIssue() }
                    }
                    if let issue = albumSaver.issue {
                        Text(L10n.text(issue)).font(.footnote).foregroundStyle(.secondary)
                        Button(L10n.text(captureAccess.isLocked ? "解锁并继续保存" : "重试待保存项目")) {
                            if captureAccess.isLocked { Task { try? await captureAccess.open() } }
                            else { albumSaver.retry() }
                        }.disabled(albumSaver.isSaving).accessibilityIdentifier("retryAutoAlbumSave")
                        if !captureAccess.isLocked {
                            Button(L10n.text("设置照片添加权限")) { openPermissions() }
                        }
                    }
                    if albumSaver.uncertainCount > 0 {
                        ForEach(albumSaver.uncertainItems) { item in
                            Text(L10n.text("\(item.createdAt.formatted(.dateTime.locale(L10n.locale).year().month().day().hour().minute())) · \(item.kind.title) · \(item.albumSaveMode?.title ?? "")"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Button(L10n.text("核对相册后重试…")) { confirmAlbumRetry = true }
                            .disabled(albumSaver.isSaving)
                    }
                } header: { Text(L10n.text("自动保存到系统相册")) } footer: {
                    Text(L10n.text("每次拍摄自动保存一份照片、实况照片或视频。此设置用于之后的拍摄，App 中仍保留所用摄像头的原片。"))
                }
                Section {
                    NavigationLink { MainCameraSettingsView(camera: camera) } label: {
                        Label(L10n.text("主相机"), systemImage: "camera.aperture")
                    }.accessibilityIdentifier("settingsMainCamera")
                }
                Section(L10n.text("视频")) {
                    Picker(L10n.text("宽高比"), selection: $videoAspectRaw) {
                        ForEach(CaptureAspect.allCases) { Text($0.rawValue).tag($0.rawValue) }
                    }.accessibilityIdentifier("settingsVideoAspect")
                    NavigationLink {
                        VideoRecordingSettingsView(dual: false, available: camera.singleVideoProfiles, selection: $singleVideoProfileRaw)
                    } label: {
                        LabeledContent(L10n.text("单摄录制规格"), value: VideoRecordingProfile(rawValue: singleVideoProfileRaw).title)
                    }.accessibilityIdentifier("settingsSingleVideo")
                    if camera.supportsDualCapture {
                    NavigationLink {
                        VideoRecordingSettingsView(dual: true, available: camera.dualVideoProfiles, selection: $dualVideoProfileRaw)
                    } label: {
                        LabeledContent(L10n.text("双摄录制规格"), value: VideoRecordingProfile(rawValue: dualVideoProfileRaw).title)
                    }.accessibilityIdentifier("settingsDualVideo")
                    }
                    Toggle(L10n.text("视频防抖"), isOn: $stabilizationOn).accessibilityIdentifier("settingsStabilization").tint(.green)
                }
                Section {
                    Toggle(L10n.text("镜像前置相机"), isOn: $mirrorsFront).accessibilityIdentifier("settingsMirrorFront").tint(.green)
                    Toggle(L10n.text("网格"), isOn: $showsGrid).accessibilityIdentifier("settingsGrid").tint(.green)
                    Toggle(L10n.text("水平"), isOn: $showsLevel).accessibilityIdentifier("settingsLevel").tint(.green)
                } header: { Text(L10n.text("构图")) } footer: {
                    Text(L10n.text("前置预览保持镜像。开启后，照片、实况和视频中的前置画面按预览方向保存；关闭后按真实左右方向保存。网格和水平仅用于取景。"))
                }
                Section {
                    Toggle(L10n.text("记录拍摄位置"), isOn: $recordsLocation).accessibilityIdentifier("settingsLocation").tint(.green)
                    if recordsLocation {
                        Label(L10n.text(locationService.statusText), systemImage: locationService.statusIcon)
                        if !locationService.isAuthorized {
                            Button(L10n.text(captureAccess.isLocked ? "解锁并设置定位权限" : "设置定位权限")) {
                                if locationService.authorizationStatus == .notDetermined && !captureAccess.isLocked { locationService.requestAccess() }
                                else { openPermissions() }
                            }
                        }
                    }
                } header: { Text(L10n.text("位置信息")) } footer: {
                    Text(L10n.text("只记录拍摄时的位置。关闭后，新拍摄不记录位置，已有回忆保持原样。"))
                }
                Section {
                    Toggle(L10n.text("保留上次拍摄选项"), isOn: $remembersOptions).accessibilityIdentifier("settingsRemember").tint(.green)
                } footer: { Text(L10n.text("记住单拍、单录、双拍或双录，以及宽高比与闪光灯选择。关闭后默认进入双拍。补光灯每次进入相机默认关闭。")) }
                Section {
                    NavigationLink {
                        AboutScreen()
                    } label: {
                        Label(L10n.text("关于 ArkCam"), systemImage: "info.circle")
                            .foregroundStyle(.primary)
                    }.accessibilityIdentifier("settingsAbout")
                }
            }
            .navigationTitle(L10n.text("相机设置")).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button(L10n.text("完成")) { showSettings = false }.accessibilityIdentifier("settingsDone") } }
            .confirmationDialog(L10n.text("请先核对系统相册"), isPresented: $confirmAlbumRetry, titleVisibility: .visible) {
                Button(L10n.text("确认未保存，重新保存")) { albumSaver.retry(includeUncertain: true) }
            } message: {
                Text(L10n.text("上次保存被中断，无法确认相册是否已接收。只有确认这些成片不在相册中时才重试，以免生成重复项。"))
            }
        }.presentationDetents([.large]).presentationDragIndicator(.visible)
    }

    private var cameraPreferences: some View {
        cameraCanvas
        .modifier(CameraHardwareButtons(enabled: !changingSource && camera.state == .ready && (camera.isRecording || videoStartPending || !camera.isBusy) && !showLibrary && !showSettings && !controlsExpanded,
                                        capture: shutterTap))
        .task {
            if !initializedMode {
                initializedMode = true
                captureMode = CameraDeviceCapabilities.resolved(.dualPhoto, dual: camera.supportsDualCapture); confirmedMode = captureMode; savedMode = captureMode.rawValue
                if !camera.supportsDualCapture, !UserDefaults.standard.bool(forKey: "cameraExplainedSingleOnly") {
                    UserDefaults.standard.set(true, forKey: "cameraExplainedSingleOnly")
                    camera.message = "此设备不支持前后同时拍摄，已使用单摄模式。"
                }
                if !remembersOptions {
                    photoAspectRaw = CaptureAspect.standard.rawValue
                    videoAspectRaw = CaptureAspect.wide.rawValue; flashRaw = CameraFlashMode.off.rawValue
                }
            }
            layout.singleCamera = !captureMode.isDual
            applySelectedAspect()
            updateLocationCollection()
            await resumeCamera()
            consumeLaunchRoute()
        }
        .onDisappear { cancelCountdown() }
        .onChange(of: photoTimerRaw) { _, _ in cancelCountdown() }
        .onChange(of: interfaceLanguage) { _, _ in
            if #available(iOS 18.0, *) {
                Task { try? await CamCaptureIntent.updateAppContext(CamCaptureContext(livePhotoEnabled: livePhotoEnabled, options: CameraPreferenceStore.snapshot())) }
            }
        }
        .onChange(of: launchRoute.destination) { _, _ in consumeLaunchRoute() }
        .onChange(of: layout) { _, value in library.work.userInteracted(); camera.updateLayout(value) }
        .onChange(of: livePhotoEnabled) { _, enabled in
            Task {
                await camera.setLivePhotoEnabled(enabled)
                camera.setPhotoPreferences(live: enabled)
                if #available(iOS 18.0, *) {
                    try? await CamCaptureIntent.updateAppContext(CamCaptureContext(livePhotoEnabled: enabled, options: CameraPreferenceStore.snapshot()))
                }
            }
        }
        .onChange(of: layout.frontIsPrimary) { _, _ in pinchZoomOrigin = nil; clearFocus(); updateLighting() }
         .onChange(of: captureMode) { _, _ in
            clearFocus(); savedMode = captureMode.rawValue
            torchRequested = false
            if !changingSource { applySelectedAspect(); updateLighting() }
        }
        .onChange(of: preferenceStamp) { _, _ in

            if #available(iOS 18.0, *) {
                Task { try? await CamCaptureIntent.updateAppContext(CamCaptureContext(livePhotoEnabled: livePhotoEnabled, options: CameraPreferenceStore.snapshot())) }
            }
        }
        .onChange(of: [photoAspectRaw, videoAspectRaw]) { _, _ in applySelectedAspect() }
        .onChange(of: [photoFormatRaw, photoMP]) { _, _ in camera.setPhotoPreferences(live: livePhotoEnabled) }
        .onChange(of: [stabilizationOn, enhancedStabilization]) { _, _ in
            camera.setStabilizationEnabled(stabilizationOn || enhancedStabilization)
            camera.setEnhancedStabilization(enhancedStabilization)
        }
        .onChange(of: recordsLocation) { _, enabled in locationService.setEnabled(enabled); updateLocationCollection() }
        .onChange(of: singleVideoProfileRaw + "|" + dualVideoProfileRaw + "|" + String(mirrorsFront)) { _, _ in
            preferenceTask?.cancel()
            preferenceTask = Task {
                do { try await Task.sleep(for: .milliseconds(80)) } catch { return }
                await camera.setRecordingPreferences(single: VideoRecordingProfile(rawValue: singleVideoProfileRaw),
                    dual: VideoRecordingProfile(rawValue: dualVideoProfileRaw), mirror: mirrorsFront)
            }
        }
        .onChange(of: shutterSoundEnabled) { _, _ in
            // Sound is a per-photo option; do not reconfigure cameras or audio.
            if #available(iOS 18.0, *) {
                Task { try? await CamCaptureIntent.updateAppContext(CamCaptureContext(livePhotoEnabled: livePhotoEnabled, options: CameraPreferenceStore.snapshot())) }
            }
        }
        .onChange(of: torchRequested) { _, _ in updateLighting() }
        .onChange(of: camera.torchActive) { _, active in if !active { torchRequested = false } }
    }

    private var activeCamera: some View {
        cameraPreferences
        .onChange(of: camera.isRecording) { _, recording in
            #if !CAM_CAPTURE_EXTENSION
            #if DEBUG
            let auditing = ProcessInfo.processInfo.arguments.contains("--audit-recording-start") || ProcessInfo.processInfo.arguments.contains("--audit-thermal")
            #else
            let auditing = false
            #endif
            UIApplication.shared.isIdleTimerDisabled = recording || auditing
            #endif
            if recording { controlsExpanded = false }
            if !recording {
                Task { await applyInterfaceOrientation() }
                quickTakeStarted = false
                quickTakeLocked = false
                shutterHeld = false
                shutterTranslation = .zero
            }
        }
        .onChange(of: camera.isTakingPhoto) { _, active in if !active { Task { await applyInterfaceOrientation() } } }
        .onChange(of: shutterTouching) { _, touching in
            if !touching {
                // onEnded handles a successful release first; only a lost or
                // interrupted gesture reaches this deferred cancellation.
                Task { @MainActor in
                    await Task.yield()
                    if shutterHeld { cancelShutterPress() }
                }
            }
        }
        .onAppear {
            guard captureAccess.isLocked else { return }
            lockedViewVisible = true
            resumePermitted = true
            lifecycleLog.notice("locked capture view appeared")
            updateLocationCollection()
            updateAlbumSaving()
            albumSaver.retry()
            Task { await resumeCamera() }
        }
        .onDisappear {
            if captureAccess.isLocked {
                lockedViewVisible = false
                resumePermitted = false
                lifecycleLog.notice("locked capture view disappeared")
                camera.pause()
            }
            locationService.stop(); cancelShutterPress(); modeTask?.cancel(); camera.cancelModePreviewWait()
            updateAlbumSaving()
        }
        .onReceive(camera.savedMedia) { library.insert($0) }
        .onChange(of: camera.state) { _, state in
            lifecycleLog.notice("camera state=\(String(describing: state), privacy: .public) locked=\(captureAccess.isLocked)")
            updateCameraTransition(for: state)
            updateLocationCollection()
            updateAlbumSaving()
            if state == .ready { updateLighting() }
            if state == .paused { torchRequested = false }
            if state != .ready { cancelCountdown(); cancelShutterPress() }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            lifecycleLog.notice("scene phase=\(String(describing: phase), privacy: .public) locked=\(captureAccess.isLocked) state=\(String(describing: camera.state), privacy: .public)")
            // The secure-capture scene is visible even when SwiftUI reports
            // background. Its view appearance owns camera startup and teardown.
            if captureAccess.isLocked { return }
            resumePermitted = phase != .background
            updateLocationCollection()
            if phase != .active { cancelCountdown() }
            if phase == .active, !showLibrary, !showSettings { Task { await resumeCamera() } }
            else if phase == .background { cancelShutterPress(); modeTask?.cancel(); camera.cancelModePreviewWait(); torchRequested = false; camera.pause(); clearFocus(); setOptionsVisible(false) }
            else if phase == .inactive, shutterHeld { cancelShutterPress() }
        }
    }

    var body: some View {
        let _ = interfaceLanguage
        activeCamera
        .task { camera.setSystemEnergy(energyMonitor.state); updateAlbumSaving() }
        .onChange(of: workPhase) { _, _ in updateAlbumSaving() }
        .onChange(of: optionsProgress) { _, _ in library.work.userInteracted() }
        .onChange(of: camera.frontZoom) { _, _ in library.work.userInteracted() }
        .onChange(of: optionsPage) { _, _ in library.work.userInteracted() }
        .onChange(of: camera.rearZoom) { _, _ in library.work.userInteracted() }
        .onReceive(library.work.$allowsBackgroundWork.dropFirst().receive(on: RunLoop.main)) { _ in updateAlbumSaving() }
        .onChange(of: energyMonitor.state) { _, value in camera.setSystemEnergy(value); updateAlbumSaving() }
        .onChange(of: camera.pressureLevel) { _, _ in updateAlbumSaving() }
        .onChange(of: camera.isStartingVideo) { _, _ in updateAlbumSaving() }
        .onChange(of: videoStartPending) { _, _ in updateAlbumSaving() }
        .onChange(of: showLibrary) { _, _ in cancelCountdown(); updateLocationCollection(); updateAlbumSaving() }
        .onChange(of: showSettings) { _, _ in cancelCountdown(); updateLocationCollection(); updateAlbumSaving() }
        #if DEBUG && CAM_MAIN_APP
        .task {
            if ProcessInfo.processInfo.arguments.contains("--audit-mode-transition") { await auditModeTransition() }
        }
        .task {
            guard ProcessInfo.processInfo.arguments.contains("--audit-level") else { return }
            for _ in 0..<100 {
                if camera.state == .ready { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard camera.state == .ready else { return }
            try? await Task.sleep(for: .seconds(3))
            setOptionsVisible(true)
            try? await Task.sleep(for: .seconds(1))
            setOptionsVisible(false)
            try? await Task.sleep(for: .seconds(2))
            camera.pause(); showSettings = true
            try? await Task.sleep(for: .seconds(1))
            showSettings = false
            try? await Task.sleep(for: .seconds(3))
            camera.pause()
        }
        #endif
        .onChange(of: library.items) { _, _ in updateAlbumSaving() }
        .onChange(of: camera.isBusy) { _, _ in updateAlbumSaving() }
        .onChange(of: camera.isRecording) { _, _ in updateAlbumSaving() }
        .onChange(of: scenePhase) { _, phase in
            updateAlbumSaving()
            if phase == .active { albumSaver.retry() }
        }
        .fullScreenCover(isPresented: $showLibrary, onDismiss: { Task { await resumeCamera() } }) {
            LibraryScreen(library: library, albumSaver: albumSaver).environment(\.captureAccess, captureAccess).modifier(LocalizedInterface())
        }
        .sheet(isPresented: $showSettings, onDismiss: { Task { await resumeCamera() } }) { cameraSettings.modifier(LocalizedInterface()) }
        .sheet(isPresented: $showInfo) { information.modifier(LocalizedInterface()) }
        .sheet(isPresented: $showLocationInfo) { locationInformation.modifier(LocalizedInterface()) }
        .alert(L10n.text("拍摄提示"), isPresented: Binding(get: { camera.message != nil }, set: { if !$0 { camera.message = nil } })) {
            Button(L10n.text("知道了")) { camera.message = nil }
        } message: { Text(L10n.text(camera.message ?? "")) }
        .alert(L10n.text("保存提示"), isPresented: Binding(get: { library.message != nil }, set: { if !$0 { library.message = nil } })) {
            Button(L10n.text("知道了")) { library.message = nil }
        } message: { Text(L10n.text(library.message ?? "")) }
    }

    private var captureVisible: Bool {
        captureSceneVisible && !showLibrary && !showSettings && camera.state == .ready
    }

    private var captureSceneVisible: Bool {
        captureAccess.isLocked ? lockedViewVisible : scenePhase == .active
    }

    private func updateLocationCollection() {
        if captureVisible && recordsLocation { locationService.start() }
        else { locationService.stop() }
    }

    private var workPhase: CaptureWorkScheduler.Phase {
        if !captureSceneVisible { return .suspended }
        if showLibrary || showSettings { return .browsing }
        if camera.isRecording || camera.isStartingVideo || videoStartPending || camera.isTakingPhoto || countdown != nil || shutterHeld { return .capturing }
        if changingSource { return .starting }
        switch camera.state {
        case .denied, .unavailable, .paused: return .browsing
        case .preparing, .resuming: return .starting
        case .ready: break
        }
        if !camera.previewReady { return .starting }
        return .preview
    }

    private func updateAlbumSaving() {
        library.work.setPhase(workPhase)
        albumSaver.update(items: library.items, disk: library.disk,
                          canWork: captureSceneVisible,
                          locked: captureAccess.isLocked, energy: energyMonitor.state,
                          pressure: camera.pressureLevel, cameraVisible: captureVisible,
                          capturing: camera.isRecording || camera.isStartingVideo || videoStartPending || camera.isTakingPhoto,
                          backgroundWorkAllowed: library.work.allowsBackgroundWork)
    }

    private func capturePreview(size: CGSize) -> some View {
        ZStack {
            if CameraTransitionPolicy.keepsPreview(for: camera.state,
                                                   statusVisible: cameraTransitionStatusVisible),
               !(captureAccess.isLocked && camera.state == .paused) {
                cameraFrames(interactive: camera.state == .ready && !changingSource)
                if CameraTransitionPolicy.showsRecoveryHint(for: camera.state,
                                                            statusVisible: cameraTransitionStatusVisible) {
                    ProgressView(L10n.text("正在恢复相机…"))
                        .font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(.black.opacity(0.62), in: Capsule())
                }
            } else {
                cameraPlaceholder
            }

            CameraLevelOverlay(active: showsLevel && captureSceneVisible && camera.state == .ready && camera.previewReady
                && !showLibrary && !showSettings && !showInfo && !showLocationInfo && !controlsExpanded,
                scale: min(1.15, size.width / 375), orientation: layout.orientation ?? .portrait)
                .frame(width: size.width, height: size.height)
                .mask(OutsideCameraAperture(aperture: layout.isDual ? layout.pipRect(in: size) : .zero)
                    .fill(.white, style: FillStyle(eoFill: true)))
                .allowsHitTesting(false)

            if flash { Color.white.opacity(0.85).allowsHitTesting(false) }

            if let focusVisual {
                CameraFocusIndicator(locked: focusVisual.locked, exposureBias: focusVisual.exposureBias)
                    .id(focusVisual.id)
                    .position(focusVisual.point)
                    .allowsHitTesting(false)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(L10n.text(focusVisual.locked ? "自动曝光和自动对焦已锁定" : "正在对焦"))
                    .accessibilityValue(L10n.text(focusVisual.isFront ? "前摄" : "后摄"))
                    .accessibilityIdentifier("focusIndicator")
            }

        }
        .frame(width: size.width, height: size.height)
        .background(Color.black.opacity(0.001))
        .clipped()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("captureAperture")
    }

    private func cameraFrames(interactive: Bool) -> some View {
        DualFrameView(layout: $layout,
                      interactionEnabled: interactive,
                      showsGrid: false,
                      onFocus: interactive ? { handleFocus($0) } : nil,
                      onExposureChange: interactive ? { adjustExposure($0, front: $1) } : nil,
                      focusedLensIsFront: focusVisual?.isFront) {
            Color.clear
        } front: {
            Color.clear
        }
        .allowsHitTesting(interactive)
        .simultaneousGesture(MagnifyGesture().onChanged { value in
            guard interactive, !camera.isBusy else { return }
            if pinchZoomOrigin == nil { pinchZoomOrigin = layout.frontIsPrimary ? camera.frontZoom : camera.rearZoom }
            let zoom = (pinchZoomOrigin ?? 1) * value.magnification
            if layout.frontIsPrimary { camera.setFrontZoom(zoom) }
            else { camera.setRearZoom(zoom) }
        }.onEnded { _ in pinchZoomOrigin = nil })
    }

    private func topCameraControls(scale: CGFloat) -> some View {
        ZStack {
            if camera.isRecording {
                HStack(spacing: 6) {
                    Circle().fill(.red).frame(width: 7, height: 7)
                    Text(L10n.text(Self.time(camera.elapsed))).monospacedDigit()
                        .font(.system(size: 14 * scale, weight: .semibold))
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(.black.opacity(0.5), in: Capsule())
                .accessibilityIdentifier("recordingTimer")
                Text(camera.actualVideoProfile.title).font(.caption2).foregroundStyle(.white)
                    .monospacedDigit()
                    .offset(y: 31).accessibilityIdentifier("recordingFormat")
            } else {
                HStack(spacing: 0) {
                    Button(action: cycleLighting) {
                        Image(systemName: kind == .video ? (torchRequested ? "bolt.fill" : "bolt.slash.fill") : flashSelection.wrappedValue.symbol)
                            .font(.system(size: 21 * scale))
                            .foregroundStyle((kind == .video ? torchRequested : flashSelection.wrappedValue != .off) ? .yellow : .white)
                            .frame(width: max(44, 44 * scale), height: max(44, 44 * scale))
                    }
                    .disabled(camera.state != .ready || camera.isBusy || (kind == .video ? !camera.torchAvailable : camera.supportedFlashModes.count < 2))
                    .accessibilityLabel(L10n.text(kind == .video ? "补光灯" : "闪光灯"))
                    .accessibilityValue(L10n.text(kind == .video ? (torchRequested ? "开启" : "关闭") : flashSelection.wrappedValue.title))
                    .accessibilityIdentifier("topFlashOptions")
                    if kind == .photo {
                        Button {
                            if camera.livePhotoAvailable { livePhotoEnabled.toggle() }
                            else { camera.message = "当前双摄配置暂时不支持 Live Photo。" }
                        } label: {
                            Image(systemName: livePhotoEnabled && camera.livePhotoAvailable ? "livephoto" : "livephoto.slash")
                                .font(.system(size: 23 * scale, weight: .regular))
                                .foregroundStyle(livePhotoEnabled && camera.livePhotoAvailable ? .yellow : .white)
                                .frame(width: max(44, 44 * scale), height: max(44, 44 * scale))
                        }
                        .disabled(camera.state != .ready || camera.isBusy)
                        .accessibilityLabel(L10n.text(livePhotoEnabled ? "关闭 Live Photo" : "开启 Live Photo"))
                        .accessibilityIdentifier("livePhotoToggle")
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    }
                    if kind == .video {
                        Button { setOptionsVisible(true, page: .format) } label: {
                            VStack(spacing: 0) {
                                Text(camera.actualVideoProfile.resolution.rawValue).font(.system(size: 17 * scale, weight: .medium))
                                Text(String(camera.actualVideoProfile.fps)).font(.system(size: 11 * scale))
                            }.foregroundStyle(.white).frame(width: 56 * scale, height: 44 * scale)
                        }.accessibilityIdentifier("topVideoFormat")
                            .accessibilityLabel(camera.actualVideoProfile.title)
                            .disabled(camera.state != .ready || camera.isBusy || videoStartPending)
                    }
                    if kind == .photo { Color.clear.frame(width: max(44, 44 * scale), height: max(44, 44 * scale)) }
                }
                .animation(modeAnimation, value: kind)
            }
        }
        .frame(width: 180 * scale, height: 44 * scale)
    }

    private func cycleLighting() {
        if kind == .video {
            guard camera.torchAvailable else { return }
            torchRequested.toggle()
        } else {
            flashSelection.wrappedValue = flashSelection.wrappedValue.next(supported: camera.supportedFlashModes)
        }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    private func settingsControl(scale: CGFloat) -> some View {
        Button {
            setOptionsVisible(!controlsExpanded)
        } label: {
            SixDotCameraIcon()
                .frame(width: 18 * scale, height: 13 * scale)
                .frame(width: 48 * scale, height: 48 * scale)
        }
        .buttonStyle(CameraGlassButtonStyle())
        .disabled(camera.isRecording || camera.isBusy)
        .accessibilityLabel(L10n.text(controlsExpanded ? "收起拍摄设置" : "展开拍摄设置"))
        .accessibilityIdentifier("cameraControlsToggle")
    }

    @ViewBuilder
    private func zoomControls(scale: CGFloat) -> some View {
        if layout.frontIsPrimary { FrontCameraFramingControl(camera: camera, scale: scale) }
        else { CameraZoomControl(camera: camera, scale: scale, photoMode: kind == .photo && !camera.isRecording) }
    }

    private var quickTakeHolding: Bool { quickTakeStarted && shutterHeld && !recordingAtPressStart }
    private var shutterAnimation: Animation? { reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.86) }

    @ViewBuilder
    private func recordingSideControl(scale: CGFloat) -> some View {
        if quickTakeHolding {
            Image(systemName: quickTakeLocked ? "lock.fill" : "lock.open.fill")
                .font(.system(size: 19 * scale, weight: .medium))
                .foregroundStyle(quickTakeLocked ? .yellow : .white)
                .frame(width: 48 * scale, height: 48 * scale)
                .background(.white.opacity(0.14), in: Circle())
                .accessibilityLabel(L10n.text(quickTakeLocked ? "录像已锁定" : "向右拖动锁定录像"))
                .accessibilityIdentifier("quickTakeLock")
                .transition(.opacity)
        } else if camera.isRecording {
            Button(action: recordingPhoto) {
                Circle().fill(.white)
                    .frame(width: 31 * scale, height: 31 * scale)
                    .padding(6 * scale)
                    .overlay(Circle().strokeBorder(.white.opacity(0.75), lineWidth: 2 * scale))
                    .opacity(camera.isTakingPhoto ? 0.45 : 1)
                    .scaleEffect(camera.isTakingPhoto ? 0.88 : 1)
                    .frame(width: 48 * scale, height: 48 * scale)
            }
            .buttonStyle(.plain)
            .disabled(camera.isTakingPhoto || camera.state != .ready)
            .accessibilityLabel(L10n.text("录像中拍照"))
            .accessibilityIdentifier("recordingPhotoShutter")
            .transition(.opacity.combined(with: .scale(scale: 0.8)))
            .animation(shutterAnimation, value: camera.isTakingPhoto)
        } else { settingsControl(scale: scale) }
    }

    private func shutterControl(chrome: CameraChromeGeometry) -> some View {
        let stop = countdown != nil || ((camera.isRecording || videoStartPending) && !quickTakeHolding)
        let red = camera.isRecording || videoStartPending || quickTakeStarted || kind == .video
        let offset = quickTakeHolding ? (quickTakeLocked ? chrome.sideOffset :
            ShutterGesturePolicy.thumbOffset(translation: shutterTranslation) * chrome.scale) : 0
        return Button(action: accessibilityShutter) {
            ZStack {
                if quickTakeHolding {
                    Capsule().fill(.white.opacity(0.09))
                        .frame(width: chrome.sideOffset + chrome.shutterDiameter, height: 54 * chrome.scale)
                        .offset(x: chrome.sideOffset / 2)
                        .transition(.opacity)
                }
                Circle().fill(Color(white: 0.16))
                    .overlay(Circle().strokeBorder(.black.opacity(0.48), lineWidth: 0.6))
                RoundedRectangle(cornerRadius: stop ? 5 * chrome.scale : chrome.shutterInnerDiameter / 2)
                    .fill(red ? Color.red : Color.white)
                    .frame(width: stop ? 27 * chrome.scale : chrome.shutterInnerDiameter,
                           height: stop ? 27 * chrome.scale : chrome.shutterInnerDiameter)
                    .scaleEffect(shutterHeld && !stop ? (quickTakeHolding ? 0.72 : 0.94) : 1)
                    .offset(x: offset)
                    .animation(shutterAnimation, value: stop)
                    .animation(shutterAnimation, value: red)
                    .animation(shutterAnimation, value: shutterHeld)
                    .animation(shutterAnimation, value: quickTakeLocked)
            }
            .frame(width: chrome.shutterDiameter, height: chrome.shutterDiameter)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        // The hit target never moves. Only its visual thumb moves in a fixed
        // canvas, so drag coordinates cannot feed back into the gesture.
        .highPriorityGesture(shutterGesture(scale: chrome.scale))
        .disabled(changingSource || camera.state != .ready || (camera.isBusy && !camera.isRecording && !videoStartPending))
        .accessibilityLabel(L10n.text(countdown != nil ? "取消倒计时" : (camera.isRecording || videoStartPending) ? "停止录像" : (captureMode.isDual ? (kind == .photo ? "拍摄双面照片" : "开始双面录像") : (kind == .photo ? "拍摄单摄照片" : "开始单摄录像"))))
        .accessibilityIdentifier("shutter")
    }

    private var savingCount: Int { camera.pendingSaveCount + albumSaver.pendingCount }
    private var saveNeedsAttention: Bool { camera.saveIssue != nil || albumSaver.issue != nil }

    private func bottomCameraControls(chrome: CameraChromeGeometry) -> some View {
        ZStack {
            Button {
                clearFocus()
                controlsExpanded = false
                camera.pause()
                library.reload(); showLibrary = true
            } label: {
                ZStack {
                    Circle().fill(Color(white: 0.13))
                    if let image = camera.latestCaptureThumbnail,
                       camera.latestThumbnailDate >= (library.items.first?.captureDate ?? .distantPast) {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else if let item = library.items.first,
                       let url = library.url(for: item, front: false) ?? library.url(for: item, front: true) {
                        ThumbnailView(url: url, kind: item.kind, maximumPixelSize: 180)
                    } else {
                        Image(systemName: "photo.on.rectangle")
                            .font(.system(size: 19 * chrome.scale)).foregroundStyle(.white.opacity(0.8))
                    }
                }
                .frame(width: chrome.bottomDiameter, height: chrome.bottomDiameter)
                .clipShape(Circle())
                .overlay {
                    if savingCount > 0 {
                        Circle().strokeBorder(.black.opacity(0.45), lineWidth: 3)
                        ProgressView().tint(.white)
                            .padding(5).background(.black.opacity(0.45), in: Circle())
                            .accessibilityIdentifier("gallerySaveProgress")
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if saveNeedsAttention {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(.yellow, .black)
                            .font(.system(size: 16 * chrome.scale))
                    } else if savingCount > 1 {
                        Text(L10n.text("\(savingCount)")).font(.system(size: 10 * chrome.scale, weight: .semibold))
                            .padding(4).background(.black.opacity(0.75), in: Capsule())
                    }
                }
            }
            .offset(x: -chrome.sideOffset)
            .disabled(camera.isRecording)
            .accessibilityLabel(L10n.text(saveNeedsAttention ? "查看保存提示" : "查看回忆"))
            .accessibilityValue(L10n.text(savingCount > 0 ? "正在保存 \(savingCount) 项" : "保存完成"))
            .accessibilityIdentifier("openLibrary")

            CameraModeSelector(kind: Binding(get: { captureMode }, set: { changeCaptureMode($0) }), disabled: camera.isRecording || camera.isBusy || quickTakeStarted || shutterHeld || videoStartPending,
                               scale: chrome.scale, modes: camera.availableCaptureModes)
                .environment(\.layoutDirection, .leftToRight)
                .offset(y: chrome.usesSideRail ? -70 : 0)

            Button {
                guard !changingSource else { return }
                if layout.isDual { clearFocus(); layout.frontIsPrimary.toggle() }
                else { changeCaptureMode(captureMode, front: !layout.frontIsPrimary) }
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 25 * chrome.scale, weight: .regular))
                    .frame(width: chrome.bottomDiameter, height: chrome.bottomDiameter)
            }
            .buttonStyle(CameraGlassButtonStyle())
            .offset(x: chrome.sideOffset)
            .disabled(changingSource || camera.isBusy || videoStartPending || quickTakeStarted || shutterHeld || (!layout.isDual && camera.isRecording))
            .accessibilityLabel(L10n.text(layout.isDual ? "交换前后画面" : "切换前后摄像头")).accessibilityIdentifier("swapCameras")
        }
        .frame(width: chrome.usesSideRail ? 232 : chrome.size.width, height: chrome.bottomDiameter)
        .foregroundStyle(.white)
    }

    private func handleFocus(_ request: CameraFocusRequest) {
        guard camera.state == .ready, !camera.isBusy else { return }
        focusDismissTask?.cancel()
        let inset: CGFloat = 42
        let visiblePoint = CGPoint(x: min(request.displaySize.width - inset, max(inset, request.displayPoint.x)),
                                   y: min(request.displaySize.height - inset, max(inset, request.displayPoint.y)))
        focusVisual = CameraFocusVisual(point: visiblePoint, isFront: request.isFront,
                                        locked: request.locked, exposureBias: 0)
        camera.focus(at: request.previewPoint, previewSize: request.previewSize,
                     front: request.isFront, lock: request.locked)
        if request.isFront { frontExposure = 0 } else { rearExposure = 0 }
        camera.setExposureBias(0, front: request.isFront)
        UISelectionFeedbackGenerator().selectionChanged()
        if !request.locked { scheduleFocusDismissal() }
    }

    private func adjustExposure(_ delta: CGFloat, front: Bool) {
        guard var visual = focusVisual, visual.isFront == front else { return }
        focusDismissTask?.cancel()
        visual.exposureBias = CameraFocusGeometry.exposureBias(current: visual.exposureBias,
                                                               verticalDelta: delta)
        focusVisual = visual
        if front { frontExposure = Double(visual.exposureBias) } else { rearExposure = Double(visual.exposureBias) }
        camera.setExposureBias(visual.exposureBias, front: front)
        if !visual.locked { scheduleFocusDismissal(after: 2) }
    }

    private func scheduleFocusDismissal(after seconds: Double = 1.4) {
        focusDismissTask?.cancel()
        let id = focusVisual?.id
        focusDismissTask = Task {
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            guard focusVisual?.id == id, focusVisual?.locked == false else { return }
            withAnimation(.easeOut(duration: 0.2)) { focusVisual = nil }
        }
    }

    private func clearFocus() {
        focusDismissTask?.cancel()
        focusDismissTask = nil
        focusVisual = nil
    }

    private func updateCameraTransition(for state: DualCamera.State) {
        cameraTransitionTask?.cancel()
        cameraTransitionTask = nil
        cameraTransitionStatusVisible = false
        switch state {
        case .resuming, .unavailable:
            cameraTransitionTask = Task {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard camera.state == state else { return }
                cameraTransitionStatusVisible = true
            }
        default:
            break
        }
    }

    private var cameraPlaceholder: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.on.rectangle").font(.system(size: 40, weight: .light)).foregroundStyle(.white.opacity(0.4))
            switch camera.state {
            case .preparing: ProgressView(L10n.text("正在打开双摄…")).font(.system(size: 14))
            case .resuming: ProgressView(L10n.text("正在恢复相机…")).font(.system(size: 14))
            case .denied:
                Text(L10n.text("允许使用相机，开始双面记录")).font(.system(size: 16, weight: .medium))
                Button(L10n.text(captureAccess.isLocked ? "解锁并开启权限" : "打开系统设置")) { openPermissions() }
            case .unavailable(let reason):
                Text(L10n.text("暂时无法拍摄")).font(.system(size: 17, weight: .medium))
                Text(L10n.text(reason)).font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                #if !targetEnvironment(simulator)
                Button(L10n.text("重新打开相机")) { Task { await resumeCamera() } }.buttonStyle(.bordered)
                #endif
            case .paused:
                Text(L10n.text("相机已暂停")).foregroundStyle(.secondary)
                if captureAccess.isLocked {
                    Button(L10n.text("重新打开相机")) {
                        resumePermitted = true
                        Task { await resumeCamera() }
                    }.buttonStyle(.bordered)
                }
            case .ready: EmptyView()
            }
        }.padding(30).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var information: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 24) {
                Label(L10n.text("一次拍摄，两个视角"), systemImage: "camera.on.rectangle").font(.title3.bold())
                Text(L10n.text("后摄记录眼前，前摄留下你。点击画面对焦，轻点小窗交换主次，拖动小窗调整位置。"))
                Label(L10n.text("原片留在 App"), systemImage: "square.stack").font(.headline)
                Text(L10n.text("前后原片保存在这台 iPhone 的 App 空间内，作为一条回忆展示。请保留 App，并做好设备备份。"))
                Label(L10n.text("成片保存到相册"), systemImage: "square.and.arrow.down").font(.headline)
                Text(L10n.text("拍摄后按设置自动保存一份成片。回看时也可调整布局，再手动保存新的成片；原片继续保留。"))
                Spacer()
                Text(L10n.text("ArkCam · iOS 预览版 0.1"))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .padding(24)
            .navigationTitle(L10n.text("ArkCam")).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button(L10n.text("完成")) { showInfo = false } } }
        }.presentationDetents([.large])
    }

    private var locationInformation: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                Label(L10n.text(locationService.statusText), systemImage: locationService.statusIcon).font(.title3.bold())
                if let location = locationService.latestLocation, locationService.hasCurrentLocation {
                    Text(L10n.text("拍摄照片或开始录像时，会保存当时的位置。当前定位精度约 ±\(Int(location.horizontalAccuracy.rounded())) 米。"))
                } else if locationService.isAuthorized {
                    Text(L10n.text("正在获取当前位置。定位尚未完成时仍可拍摄，只是这条回忆可能没有位置信息。"))
                } else if locationService.authorizationStatus == .notDetermined {
                    Text(L10n.text("允许定位后，App 会在拍摄时保存当前位置，不会持续记录移动轨迹。"))
                    Button(L10n.text(captureAccess.isLocked ? "解锁并开启位置" : "允许记录位置")) {
                        if captureAccess.isLocked { openPermissions() } else { locationService.requestAccess() }
                    }.buttonStyle(.borderedProminent)
                } else {
                    Text(L10n.text("定位权限未开启。照片和视频仍可正常拍摄，但不会记录位置。"))
                    Button(L10n.text(captureAccess.isLocked ? "解锁并开启位置" : "打开系统设置")) { openPermissions() }.buttonStyle(.borderedProminent)
                }
                Label(L10n.text("位置与设备信息保存在这条回忆中；保存到系统相册时也会随成片写入。"),
                      systemImage: "lock.shield")
                    .font(.footnote).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(24)
            .navigationTitle(L10n.text("拍摄位置")).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button(L10n.text("完成")) { showLocationInfo = false } } }
        }.presentationDetents([.medium])
    }

    private func shutterGesture(scale: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("cameraShutterCanvas"))
            .updating($shutterTouching) { _, active, _ in active = true }
            .onChanged { value in
                guard !changingSource, camera.state == .ready, camera.isRecording || !camera.isBusy else { return }
                shutterGestureHandled = true
                if !shutterHeld { beginShutterPress() }
                guard !recordingAtPressStart else { return }
                let translation = CGSize(width: value.translation.width / scale, height: value.translation.height / scale)
                if kind == .photo, !quickTakeStarted,
                   ShutterGesturePolicy.shouldStartVideo(translation: translation) { beginQuickTake() }
                if quickTakeStarted, !quickTakeLocked {
                    var transaction = Transaction(); transaction.animation = nil
                    withTransaction(transaction) { shutterTranslation = translation }
                    if ShutterGesturePolicy.shouldLock(translation: translation) {
                        withAnimation(shutterAnimation) { quickTakeLocked = true }
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    }
                }
            }
            .onEnded { _ in if shutterHeld { finishShutterPress() } }
    }

    private func beginShutterPress() {
        shutterHeld = true
        shutterTranslation = .zero
        recordingAtPressStart = camera.isRecording || videoStartPending
        if !recordingAtPressStart { locationService.prepareForCapture() }
        guard kind == .photo, !recordingAtPressStart, countdown == nil else { return }
        holdTask?.cancel()
        holdTask = Task {
            do { try await Task.sleep(for: .milliseconds(220)) } catch { return }
            guard shutterHeld, !quickTakeStarted else { return }
            beginQuickTake()
        }
    }

    private func beginQuickTake() {
        cancelCountdown()
        guard kind == .photo, !quickTakeStarted, !camera.isRecording, !videoStartPending else { return }
        withAnimation(shutterAnimation) { quickTakeStarted = true }
        videoStartPending = true
        let generation = UUID()
        quickTakeGeneration = generation
        holdTask?.cancel()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        quickTakeTask = Task {
            let started = await camera.startVideo(layout: layout, requestID: generation)
            guard generation == quickTakeGeneration else {
                if started { camera.stopVideo(source: "cancelled-quicktake-start", requestID: generation) }
                return
            }
            videoStartPending = false
            if !started {
                // Consume this hold even if authorization/start fails; releasing
                // it must not unexpectedly take a still photo.
                if !shutterHeld { quickTakeStarted = false }
                quickTakeLocked = false
            } else if !shutterHeld && !quickTakeLocked { camera.stopVideo() }
        }
    }

    private func finishShutterPress() {
        holdTask?.cancel(); holdTask = nil
        withAnimation(shutterAnimation) { shutterHeld = false; shutterTranslation = .zero }
        if recordingAtPressStart { shutterTap() }
        else if quickTakeStarted {
            if !quickTakeLocked {
                camera.stopVideo(requestID: quickTakeGeneration)
                if videoStartPending {
                    quickTakeTask?.cancel()
                    quickTakeGeneration = UUID()
                    videoStartPending = false; quickTakeStarted = false
                }
            }
            if !camera.isRecording && !videoStartPending { quickTakeStarted = false }
        } else { shutterTap() }
        Task { await Task.yield(); shutterGestureHandled = false }
    }

    private func cancelShutterPress() {
        holdTask?.cancel(); holdTask = nil
        quickTakeTask?.cancel()
        if quickTakeHolding || videoStartPending { camera.stopVideo(source: "cancelled-shutter-gesture", requestID: quickTakeGeneration) }
        quickTakeGeneration = UUID()
        videoStartPending = false
        withAnimation(shutterAnimation) {
            shutterHeld = false; shutterTranslation = .zero
            if !camera.isRecording { quickTakeStarted = false; quickTakeLocked = false }
        }
        shutterGestureHandled = false
    }

    private func accessibilityShutter() {
        guard !shutterGestureHandled else { return }
        shutterTap()
    }

    private func recordingPhoto() {
        guard camera.isRecording, !camera.isTakingPhoto, camera.state == .ready else { return }
        locationService.prepareForCapture()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        // Real photo outputs keep both originals. Never start Live buffering or
        // reconfigure flash/microphone while the movie writer is running.
        Task { await camera.takePhoto(layout: layout, live: false, duringRecording: true) }
    }

    private func shutterTap() {
        if countdown != nil { cancelCountdown(); return }
        if videoStartPending {
            quickTakeTask?.cancel()
            camera.stopVideo(source: "cancelled-pending-start", requestID: quickTakeGeneration)
            quickTakeGeneration = UUID()
            withAnimation(shutterAnimation) {
                videoStartPending = false; quickTakeStarted = false; quickTakeLocked = false
            }
            return
        }
        if camera.isRecording {
            camera.stopVideo()
            quickTakeLocked = false
            return
        }
        guard !changingSource, camera.state == .ready, !camera.isBusy, !videoStartPending else { return }
        locationService.prepareForCapture()
        if kind == .photo {
            if let timer = PhotoTimer(rawValue: photoTimerRaw), timer.seconds > 0 { startCountdown(seconds: timer.seconds) }
            else { capturePhotoNow() }
        } else {
            videoStartPending = true
            let generation = UUID(); quickTakeGeneration = generation
            quickTakeTask = Task {
                let started = await camera.startVideo(layout: layout, requestID: generation)
                guard generation == quickTakeGeneration else {
                    if started { camera.stopVideo(source: "cancelled-video-start", requestID: generation) }
                    return
                }
                videoStartPending = false
            }
        }
    }

    private func capturePhotoNow() {
        let captureLive = livePhotoEnabled && camera.livePhotoAvailable
        Task { await camera.takePhoto(layout: layout, live: captureLive, flashMode: flashSelection.wrappedValue) }
        flash = true
        Task { try? await Task.sleep(for: .milliseconds(90)); flash = false }
    }
    private func startCountdown(seconds: Int) {
        cancelCountdown()
        setOptionsVisible(false)
        let id = UUID(); countdownID = id
        countdown = seconds
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        countdownTask = Task { @MainActor in
            do {
                for tick in stride(from: seconds - 1, through: 0, by: -1) {
                    try await ContinuousClock().sleep(until: deadline.advanced(by: .seconds(-tick)))
                    guard !Task.isCancelled, countdownID == id, captureSceneVisible,
                          camera.state == .ready, kind == .photo else { cancelCountdown(); return }
                    if tick > 0 { countdown = tick }
                    else { countdown = nil; countdownTask = nil; capturePhotoNow() }
                }
            } catch { }
        }
    }
    private func cancelCountdown() {
        countdownID = UUID(); countdownTask?.cancel(); countdownTask = nil; countdown = nil
    }

    private func openPermissions() {
        #if CAM_CAPTURE_EXTENSION
        Task {
            do { try await captureAccess.open("camera") }
            catch { camera.message = "未能打开 App，请解锁后重试。" }
        }
        #else
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        #endif
    }

    private func consumeLaunchRoute() {
        guard !captureAccess.isLocked, let destination = launchRoute.destination else { return }
        launchRoute.destination = nil
        showInfo = false
        showLocationInfo = false
        controlsExpanded = false
        if destination == .library {
            camera.pause()
            library.reload()
            showLibrary = true
        } else {
            showLibrary = false
            Task { await resumeCamera() }
        }
    }

    private func changeCaptureMode(_ next: CameraCaptureMode, front: Bool? = nil) {
        guard camera.availableCaptureModes.contains(next) else { return }
        guard !camera.isBusy, !camera.isRecording,
              !videoStartPending, !quickTakeStarted, !shutterHeld else { return }
        let nextFront = front ?? layout.frontIsPrimary
        guard next != captureMode || nextFront != layout.frontIsPrimary else { return }
        cancelCountdown()
        if !changingSource { confirmedMode = captureMode; confirmedFront = layout.frontIsPrimary }
        clearFocus(); controlsExpanded = false; torchRequested = false
        camera.cancelModePreviewWait()
        withAnimation(modeAnimation) {
            changingSource = true
            modeRevision += 1
            captureMode = next
            layout.singleCamera = !next.isDual
            layout.frontIsPrimary = nextFront
            applySelectedAspect()
        }
        guard modeTask == nil else { return }
        modeTask = Task { @MainActor in
            defer {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { changingSource = false }
                modeTask = nil
            }
            // Coalesce short flicks, then keep only the newest target while a
            // hardware transaction is in flight. The selector remains interactive.
            try? await Task.sleep(for: .milliseconds(60))
            while !Task.isCancelled {
                let revision = modeRevision
                let target = captureMode
                let front = layout.frontIsPrimary
                let success = await camera.setCaptureMode(target, front: front)
                guard !Task.isCancelled else { return }
                if revision != modeRevision { continue }
                let ready = success ? await camera.waitForModePreview() : false
                guard !Task.isCancelled else { return }
                if revision != modeRevision { continue }
                if ready {
                    confirmedMode = target; confirmedFront = front
                    updateLighting()
                } else {
                    // A failed switch must restore the actual camera as well as
                    // its labels, otherwise a shutter could save the wrong source.
                    _ = await camera.setCaptureMode(confirmedMode, front: confirmedFront)
                    guard revision == modeRevision, !Task.isCancelled else { continue }
                    withAnimation(modeAnimation) {
                        captureMode = confirmedMode
                        layout.singleCamera = !confirmedMode.isDual
                        layout.frontIsPrimary = confirmedFront
                        applySelectedAspect()
                        modeRevision += 1
                    }
                    if success { camera.message = "相机切换后未能启动。" }
                }
                return
            }
        }
    }

    #if DEBUG && CAM_MAIN_APP
    @MainActor private func auditModeTransition() async {
        let previousIdle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = previousIdle }
        var report: [[String: Any]] = []
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CamDiagnostics")
        func checkpoint(_ entry: [String: Any]) {
            report.append(entry)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: folder.appendingPathComponent("mode-transition-audit.json"), options: .atomic)
        }
        func waitReady() async -> Bool {
            for _ in 0..<160 {
                if Task.isCancelled { return false }
                if UIApplication.shared.applicationState == .active, !changingSource, camera.state == .ready { return true }
                try? await Task.sleep(for: .milliseconds(50))
            }
            return false
        }
        func waitSaved(after count: Int) async -> Bool {
            for _ in 0..<160 {
                if camera.savedCount > count && !camera.isBusy { return true }
                if Task.isCancelled || UIApplication.shared.applicationState != .active { return false }
                try? await Task.sleep(for: .milliseconds(100))
            }
            return false
        }
        guard await waitReady() else { checkpoint(["failed": "startup"]); return }
        try? await Task.sleep(for: .seconds(1))
        checkpoint(["default": captureMode.rawValue, "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""])
        let captureMedia = ProcessInfo.processInfo.arguments.contains("--audit-mode-media")
        let targets: [(CameraCaptureMode, Bool)] = [(.dualVideo, false), (.singleVideo, false), (.singlePhoto, false),
            (.dualPhoto, false), (.singlePhoto, true), (.singleVideo, true), (.dualPhoto, false)]
        for (target, front) in targets {
            camera.message = nil
            let start = ProcessInfo.processInfo.systemUptime
            changeCaptureMode(target, front: front)
            let ready = await waitReady()
            let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1000
            var entry = await camera.modeAuditSnapshot()
            entry["target"] = target.rawValue; entry["targetFront"] = front
            entry["ready"] = ready; entry["milliseconds"] = elapsed
            entry["selected"] = captureMode.rawValue; entry["message"] = camera.message ?? ""
            entry["appState"] = UIApplication.shared.applicationState.rawValue
            entry["cameraState"] = String(describing: camera.state); entry["changingSource"] = changingSource
            checkpoint(entry)
            guard ready, captureMode == target, camera.message == nil else { camera.pause(); return }
            if captureMedia {
                let before = camera.savedCount
                if target.kind == .video {
                    let started = await camera.startVideo(layout: layout)
                    for _ in 0..<100 {
                        if camera.isRecording { break }
                        try? await Task.sleep(for: .milliseconds(50))
                    }
                    guard started, camera.isRecording else {
                        checkpoint(["failed": "recording-start", "target": target.rawValue, "started": started,
                            "message": camera.message ?? "", "appState": UIApplication.shared.applicationState.rawValue])
                        camera.pause(); return
                    }
                    try? await Task.sleep(for: .seconds(1.3))
                    camera.stopVideo()
                } else {
                    try? await Task.sleep(for: .seconds(1.5))
                    await camera.takePhoto(layout: layout, live: livePhotoEnabled, flashMode: flashSelection.wrappedValue)
                }
                let saved = await waitSaved(after: before)
                checkpoint(["capture": target.rawValue, "front": front, "saved": saved, "message": camera.message ?? ""])
                guard saved else { camera.pause(); return }
            }
        }
        // New selections arriving during an active switch must settle on the
        // final intent, including returning to the mode where the sequence began.
        changeCaptureMode(.singleVideo)
        try? await Task.sleep(for: .milliseconds(80))
        changeCaptureMode(.singlePhoto)
        try? await Task.sleep(for: .milliseconds(25))
        changeCaptureMode(.dualVideo)
        try? await Task.sleep(for: .milliseconds(25))
        changeCaptureMode(.dualPhoto)
        let ready = await waitReady()
        var last = await camera.modeAuditSnapshot()
        last["rapidFinal"] = captureMode.rawValue; last["ready"] = ready
        last["message"] = camera.message ?? ""
        checkpoint(last)
        try? await Task.sleep(for: .milliseconds(300))
        camera.pause()
        checkpoint(["complete": true])
    }
    #endif

    private func applyInterfaceOrientation() async {
        guard !camera.isRecording, !videoStartPending, !camera.isTakingPhoto,
              await camera.setCaptureOrientation(interfaceOrientation) else { return }
        layout.orientation = interfaceOrientation
        applySelectedAspect()
    }

    private func resumeCamera() async {
        // Initial launch can still be inactive. Only background blocks startup;
        // the scene observer updates this state rather than a task's old environment.
        if let resumeTask { await resumeTask.value; return }
        lifecycleLog.notice("resume begin phase=\(String(describing: scenePhase), privacy: .public) locked=\(captureAccess.isLocked) state=\(String(describing: camera.state), privacy: .public)")
        resumeTask = Task { @MainActor in
            if let modeTask { await modeTask.value }
            if #available(iOS 18.0, *) {
                var shouldImport = true
                #if DEBUG
                shouldImport = !ProcessInfo.processInfo.arguments.contains("--ui-fixtures") &&
                    !ProcessInfo.processInfo.arguments.contains("--ui-quicktake-fixture")
                #endif
                if shouldImport, let context = try? await CamCaptureIntent.appContext {
                    let ownLanguage = interfaceLanguage
                    livePhotoEnabled = context.livePhotoEnabled
                    CameraPreferenceStore.apply(context.options)
                    if !captureAccess.isLocked { interfaceLanguage = ownLanguage }
                }
            }
            guard resumePermitted, !showLibrary, !showSettings else {
                lifecycleLog.notice("resume skipped permitted=\(resumePermitted) library=\(showLibrary) settings=\(showSettings)")
                return
            }
            applyPreferences()
            await camera.setRecordingPreferences(single: VideoRecordingProfile(rawValue: singleVideoProfileRaw),
                dual: VideoRecordingProfile(rawValue: dualVideoProfileRaw), mirror: mirrorsFront)
            await applyInterfaceOrientation()
            await camera.setCaptureMode(captureMode, front: layout.frontIsPrimary)
            camera.updateLayout(layout)
            await camera.resume()
            lifecycleLog.notice("resume camera returned state=\(String(describing: camera.state), privacy: .public)")
            if !resumePermitted { camera.pause(); return }
            if kind == .photo, !layout.frontIsPrimary { camera.restoreMainFraming() }
            await camera.setLivePhotoEnabled(livePhotoEnabled)
            if #available(iOS 18.0, *) {
                try? await CamCaptureIntent.updateAppContext(CamCaptureContext(livePhotoEnabled: livePhotoEnabled,
                    options: CameraPreferenceStore.snapshot()))
            }
        }
        await resumeTask?.value
        resumeTask = nil
    }

    static func time(_ seconds: Double) -> String {
        let value = max(0, Int(seconds))
        return String(format: "%02d:%02d", value / 60, value % 60)
    }
}

private struct SixDotCameraIcon: View {
    @AppStorage("cameraLanguage") private var interfaceLanguage = CameraDefaults.string("cameraLanguage")
    var body: some View {
        let _ = interfaceLanguage
        VStack(spacing: 3) {
            ForEach(0..<2) { _ in
                HStack(spacing: 3) {
                    ForEach(0..<3) { _ in Circle().fill(.white) }
                }
            }
        }
    }
}

private struct CameraGrid: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            for division in 1...2 {
                let x = rect.width * CGFloat(division) / 3
                let y = rect.height * CGFloat(division) / 3
                path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: rect.height))
                path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: rect.width, y: y))
            }
        }
    }
}

enum ShutterGesturePolicy {
    static let dragThreshold: CGFloat = 12
    static let lockDistance: CGFloat = 112

    static func shouldStartVideo(translation: CGSize) -> Bool {
        hypot(translation.width, translation.height) >= dragThreshold
    }

    static func shouldLock(translation: CGSize) -> Bool {
        translation.width >= lockDistance && abs(translation.height) <= 44
    }

    static func thumbOffset(translation: CGSize) -> CGFloat {
        min(133.5, max(0, translation.width))
    }
}

struct CameraVideoSurface: UIViewRepresentable, Equatable {
    let rear: AVSampleBufferDisplayLayer
    let front: AVSampleBufferDisplayLayer
    let rearSize: CGSize
    let frontSize: CGSize
    var frontNeedsMirror = false
    let aperture: CGRect
    let layout: CameraLayout
    var showsGrid = true
    var modeRevision = 0
    var transitioning = false
    var reduceMotion = false

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.rear === rhs.rear && lhs.front === rhs.front &&
            lhs.rearSize == rhs.rearSize && lhs.frontSize == rhs.frontSize &&
            lhs.frontNeedsMirror == rhs.frontNeedsMirror && lhs.aperture == rhs.aperture &&
            lhs.layout == rhs.layout && lhs.showsGrid == rhs.showsGrid &&
            lhs.modeRevision == rhs.modeRevision && lhs.transitioning == rhs.transitioning &&
            lhs.reduceMotion == rhs.reduceMotion
    }

    func makeUIView(context: Context) -> Host { Host() }
    func updateUIView(_ view: Host, context: Context) {
        view.update(self)
    }

    final class Host: UIView {
        private let rearContainer = CALayer()
        private let frontContainer = CALayer()
        private let grid = CAShapeLayer()
        private let veil = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
        private var lastRevision: Int?
        private var animationUntil: CFTimeInterval = 0
        private var wasTransitioning = false

        override init(frame: CGRect) {
            super.init(frame: frame)
            clipsToBounds = true
            layer.addSublayer(rearContainer)
            layer.addSublayer(frontContainer)
            layer.addSublayer(grid)
            grid.fillColor = nil
            grid.strokeColor = UIColor.white.withAlphaComponent(0.30).cgColor
            grid.lineWidth = 0.5
            grid.zPosition = 1
            veil.alpha = 0
            veil.isUserInteractionEnabled = false
            veil.layer.zPosition = 3
            addSubview(veil)
        }
        override func layoutSubviews() {
            super.layoutSubviews()
            veil.frame = bounds
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        func update(_ surface: CameraVideoSurface) {
            let now = CACurrentMediaTime()
            if lastRevision != surface.modeRevision {
                if lastRevision != nil, !surface.reduceMotion { animationUntil = now + 0.24 }
                lastRevision = surface.modeRevision
            }
            let duration = max(0, animationUntil - now)
            if wasTransitioning != surface.transitioning {
                wasTransitioning = surface.transitioning
                UIView.animate(withDuration: surface.reduceMotion ? 0 : (surface.transitioning ? 0.10 : 0.18),
                               delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
                    self.veil.alpha = surface.transitioning ? 0.88 : 0
                }
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            // Each camera permanently owns one container. Swapping, dragging
            // and mode changes never move a video layer between SwiftUI hosts.
            let pip = surface.layout.pipRect(in: surface.aperture.size)
                .offsetBy(dx: surface.aperture.minX, dy: surface.aperture.minY)
            for (display, container, size, isPrimary) in [
                (surface.rear, rearContainer, surface.rearSize, !surface.layout.frontIsPrimary),
                (surface.front, frontContainer, surface.frontSize, surface.layout.frontIsPrimary)
            ] {
                if display.superlayer !== container { container.addSublayer(display) }
                let visible = isPrimary || surface.layout.isDual
                let oldContainer = container.presentation() ?? container
                let oldPosition = oldContainer.position, oldBounds = oldContainer.bounds, oldOpacity = oldContainer.opacity
                let oldDisplay = display.presentation() ?? display
                let oldDisplayPosition = oldDisplay.position, oldDisplayBounds = oldDisplay.bounds
                container.isHidden = false
                container.opacity = visible ? 1 : 0
                container.frame = isPrimary ? CameraImageGeometry.frame(imageSize: size, aperture: surface.aperture) : pip
                container.zPosition = isPrimary ? 0 : 2
                container.masksToBounds = !isPrimary
                container.cornerRadius = isPrimary ? 0 : surface.aperture.width * 0.028
                display.setAffineTransform(.identity)
                display.frame = container.bounds
                if display === surface.front && surface.frontNeedsMirror {
                    display.setAffineTransform(CGAffineTransform(scaleX: -1, y: 1))
                }
                if duration > 0 {
                    animate(container, "position", from: oldPosition, to: container.position, duration: duration)
                    animate(container, "bounds", from: oldBounds, to: container.bounds, duration: duration)
                    animate(container, "opacity", from: oldOpacity, to: container.opacity, duration: duration)
                    animate(display, "position", from: oldDisplayPosition, to: display.position, duration: duration)
                    animate(display, "bounds", from: oldDisplayBounds, to: display.bounds, duration: duration)
                }
            }
            let oldGrid = grid.presentation() ?? grid
            let oldGridPosition = oldGrid.position, oldGridBounds = oldGrid.bounds, oldPath = oldGrid.path
            grid.frame = surface.aperture
            let path = CGMutablePath()
            for fraction in [CGFloat(1.0 / 3), CGFloat(2.0 / 3)] {
                path.move(to: CGPoint(x: grid.bounds.width * fraction, y: 0))
                path.addLine(to: CGPoint(x: grid.bounds.width * fraction, y: grid.bounds.height))
                path.move(to: CGPoint(x: 0, y: grid.bounds.height * fraction))
                path.addLine(to: CGPoint(x: grid.bounds.width, y: grid.bounds.height * fraction))
            }
            grid.path = path
            grid.isHidden = !surface.showsGrid
            if duration > 0 {
                animate(grid, "position", from: oldGridPosition, to: grid.position, duration: duration)
                animate(grid, "bounds", from: oldGridBounds, to: grid.bounds, duration: duration)
                if let oldPath { animate(grid, "path", from: oldPath, to: path, duration: duration) }
            }
            CATransaction.commit()
        }

        private func animate(_ layer: CALayer, _ key: String, from: Any, to: Any, duration: Double) {
            let animation = CABasicAnimation(keyPath: key)
            animation.fromValue = from; animation.toValue = to
            animation.duration = duration
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(animation, forKey: "mode-" + key)
        }
    }
}

struct CameraPreview: UIViewRepresentable {
    let layer: AVCaptureVideoPreviewLayer
    func makeUIView(context: Context) -> PreviewHost { PreviewHost() }
    func updateUIView(_ uiView: PreviewHost, context: Context) {
        if uiView.preview !== layer || layer.superlayer !== uiView.layer {
            if uiView.preview?.superlayer === uiView.layer { uiView.preview?.removeFromSuperlayer() }
            uiView.preview = layer
            uiView.layer.addSublayer(layer)
        }
        uiView.setNeedsLayout()
    }
    final class PreviewHost: UIView {
        var preview: AVCaptureVideoPreviewLayer?
        override func layoutSubviews() {
            super.layoutSubviews()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            preview?.frame = bounds
            CATransaction.commit()
        }
    }
}

struct CameraFocusIndicator: View {
    @AppStorage("cameraLanguage") private var interfaceLanguage = CameraDefaults.string("cameraLanguage")
    let locked: Bool
    let exposureBias: Float
    @State private var scale: CGFloat = 1.24

    var body: some View {
        let _ = interfaceLanguage
        ZStack {
            RoundedRectangle(cornerRadius: 2)
                .stroke(.yellow, lineWidth: 1.3)
                .frame(width: 70, height: 70)
            ZStack {
                Capsule().fill(.yellow.opacity(0.72)).frame(width: 1, height: 46)
                Image(systemName: "sun.max.fill")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.yellow)
                    .padding(4)
                    .background(.black.opacity(0.32), in: Circle())
                    .offset(y: -CGFloat(exposureBias) * 11)
            }
            .offset(x: 52)
            if locked {
                Image(systemName: "lock.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.yellow)
                    .offset(y: -46)
            }
        }
        .frame(width: 132, height: 100)
        .scaleEffect(scale)
        .onAppear {
            withAnimation(.easeOut(duration: 0.22)) { scale = 1 }
        }
    }
}

struct DualFrameView<Rear: View, Front: View>: View {
    @AppStorage("cameraLanguage") private var interfaceLanguage = CameraDefaults.string("cameraLanguage")
    @Binding var layout: CameraLayout
    var interactionEnabled = true
    var showsGrid = false
    var onDraggingChanged: (Bool) -> Void = { _ in }
    var onFocus: ((CameraFocusRequest) -> Void)? = nil
    var onExposureChange: ((CGFloat, Bool) -> Void)? = nil
    var focusedLensIsFront: Bool? = nil
    @ViewBuilder let rear: () -> Rear
    @ViewBuilder let front: () -> Front
    @Namespace private var dragSpace

    var body: some View {
        let _ = interfaceLanguage
        GeometryReader { geometry in
            let size = geometry.size
            let pip = layout.pipRect(in: size)
            ZStack(alignment: .topLeading) {
                Group { if layout.frontIsPrimary { front() } else { rear() } }
                    .frame(width: size.width, height: size.height).clipped()
                    .overlay {
                        if showsGrid {
                            CameraGrid().stroke(.white.opacity(0.30), lineWidth: 0.5)
                                .allowsHitTesting(false)
                        }
                    }
                    .contentShape(Rectangle())
                    .modifier(FocusSurfaceInteraction(size: size,
                                                      isFront: layout.frontIsPrimary,
                                                      enabled: onFocus != nil,
                                                      focusActive: focusedLensIsFront == layout.frontIsPrimary,
                                                      onFocus: onFocus,
                                                      onExposureChange: onExposureChange))
                    .accessibilityIdentifier(interactionEnabled
                                             ? (layout.frontIsPrimary ? "frontPrimary" : "rearPrimary")
                                             : "inactivePrimary")
                    .accessibilityHidden(!interactionEnabled)
                if layout.isDual {
                    Group { if layout.frontIsPrimary { rear() } else { front() } }
                        .frame(width: pip.width, height: pip.height).clipped()
                        .clipShape(RoundedRectangle(cornerRadius: size.width * 0.028))
                        .overlay(RoundedRectangle(cornerRadius: size.width * 0.028)
                            .strokeBorder(.white.opacity(0.9), lineWidth: size.width * 0.004))
                        .shadow(color: .black.opacity(0.38), radius: 6, y: 2)
                        .contentShape(Rectangle())
                        .modifier(PIPInteraction(layout: $layout, size: size, coordinateSpace: dragSpace,
                                                 onDraggingChanged: onDraggingChanged))
                        .position(x: pip.midX, y: pip.midY)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(L10n.text("小窗，轻点交换前后画面"))
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { layout.frontIsPrimary.toggle() }
                        .accessibilityIdentifier(interactionEnabled ? "pipWindow" : "inactivePipWindow")
                        .accessibilityHidden(!interactionEnabled)
                }
            }
            .coordinateSpace(name: dragSpace)
        }
    }
}

private struct FocusSurfaceInteraction: ViewModifier {
    let size: CGSize
    let isFront: Bool
    let enabled: Bool
    let focusActive: Bool
    let onFocus: ((CameraFocusRequest) -> Void)?
    let onExposureChange: ((CGFloat, Bool) -> Void)?
    @State private var pressID: UUID?
    @State private var pressStart: CGPoint?
    @State private var longPressHandled = false
    @State private var lastExposureTranslation: CGFloat = 0
    @State private var longPressTask: Task<Void, Never>?

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged(handleChanged)
                    .onEnded(handleEnded)
            )
            .onDisappear { reset() }
        } else {
            content
        }
    }

    private func handleChanged(_ value: DragGesture.Value) {
        if pressID == nil {
            let id = UUID()
            pressID = id
            pressStart = value.startLocation
            longPressHandled = false
            lastExposureTranslation = 0
            longPressTask = Task { @MainActor in
                do { try await Task.sleep(for: .milliseconds(600)) } catch { return }
                guard pressID == id, let point = pressStart else { return }
                longPressHandled = true
                onFocus?(.main(at: point, size: size, front: isFront, locked: true))
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
        }
        let distance = hypot(value.translation.width, value.translation.height)
        guard distance >= 8 else { return }
        longPressTask?.cancel()
        if focusActive {
            let delta = value.translation.height - lastExposureTranslation
            lastExposureTranslation = value.translation.height
            onExposureChange?(delta, isFront)
        }
    }

    private func handleEnded(_ value: DragGesture.Value) {
        longPressTask?.cancel()
        let distance = hypot(value.translation.width, value.translation.height)
        if distance < 8, !longPressHandled {
            let point = value.location
            onFocus?(.main(at: point, size: size, front: isFront, locked: false))
        }
        reset()
    }

    private func reset() {
        longPressTask?.cancel()
        longPressTask = nil
        pressID = nil
        pressStart = nil
        longPressHandled = false
        lastExposureTranslation = 0
    }
}

struct PIPInteraction: ViewModifier {
    @Binding var layout: CameraLayout
    let size: CGSize
    let coordinateSpace: Namespace.ID
    var onDraggingChanged: (Bool) -> Void = { _ in }
    @State private var gestureOrigin: CameraLayout?
    @State private var didDrag = false
    @GestureState private var gestureActive = false

    func body(content: Content) -> some View {
        content
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(coordinateSpace))
                .updating($gestureActive) { _, active, _ in active = true }
                .onChanged(handleChanged)
                .onEnded(handleEnded))
            .onChange(of: gestureActive) { _, active in
                if !active { finishGesture() }
            }
            .onDisappear { finishGesture() }
    }

    private func handleChanged(_ value: DragGesture.Value) {
        if gestureOrigin == nil {
            let origin = layout
            gestureOrigin = origin
        }
        let distance = hypot(value.translation.width, value.translation.height)
        guard distance >= 8, let origin = gestureOrigin else { return }
        if !didDrag {
            didDrag = true
            onDraggingChanged(true)
        }
        layout = origin.moved(by: value.translation, in: size)
    }

    private func handleEnded(_ value: DragGesture.Value) {
        if didDrag, let origin = gestureOrigin {
            layout = origin.moved(by: value.translation, in: size)
        } else {
            var next = layout
            next.frontIsPrimary.toggle()
            layout = next
            UISelectionFeedbackGenerator().selectionChanged()
        }
        finishGesture()
    }

    private func finishGesture() {
        guard gestureOrigin != nil else { return }
        if didDrag { onDraggingChanged(false) }
        gestureOrigin = nil
        didDrag = false
    }
}

struct ThumbnailView: View {
    @AppStorage("cameraLanguage") private var interfaceLanguage = CameraDefaults.string("cameraLanguage")
    let url: URL
    let kind: CaptureKind
    var maximumPixelSize: Int = 800
    @State private var image: UIImage?
    var body: some View {
        let _ = interfaceLanguage
        GeometryReader { geometry in
            Group {
                if let image { Image(uiImage: image).resizable().scaledToFill() }
                else { Color(white: 0.15).overlay { Image(systemName: "photo").foregroundStyle(.secondary) } }
            }.frame(width: geometry.size.width, height: geometry.size.height).clipped()
        }
        .task(id: url) {
            let loaded = await ThumbnailLoader.image(url: url, kind: kind, maximumPixelSize: maximumPixelSize)
            if !Task.isCancelled { image = loaded }
        }
    }
}

private struct CameraHardwareButtons: ViewModifier {
    let enabled: Bool
    let capture: () -> Void
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onCameraCaptureEvent(isEnabled: enabled) { event in
                if event.phase == .ended { capture() }
            }
        } else { content }
    }
}
