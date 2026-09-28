import SwiftUI

enum CameraOptionsPage: Hashable { case overview, flash, live, aspect, exposure, timer, format, stabilization }

struct CameraOptionsPanel: View {
    @AppStorage("cameraLanguage") private var interfaceLanguage = "system"
    @ObservedObject var camera: DualCamera
    let isPresented: Bool
    @Binding var presentationProgress: CGFloat
    let video: Bool
    @Binding var flash: CameraFlashMode
    @Binding var torch: Bool
    @Binding var live: Bool
    @Binding var aspect: CaptureAspect
    @Binding var photoFormat: String
    @Binding var photoMP: String
    @Binding var timer: String
    @Binding var videoProfile: String
    @Binding var enhancedStabilization: Bool
    @Binding var page: CameraOptionsPage
    @Binding var panelHeight: CGFloat
    let dual: Bool
    @Binding var exposure: Double
    let openSettings: () -> Void
    let dismiss: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var mounted = false
    @State private var dragOrigin: CGFloat?
    @State private var generation = 0
    @State private var contentHeights: [Page: CGFloat] = [:]
    private typealias Page = CameraOptionsPage
    private var panelAnimation: Animation? {
        reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.34, dampingFraction: 0.92)
    }

    var body: some View {
        let _ = interfaceLanguage
        GeometryReader { proxy in
            let contentHeight = contentHeights[page] ?? (page == .overview ? 252 : 196)
            let height = min(contentHeight + 44, max(180, proxy.size.height - 100))
            let travel = height + 16
            ZStack(alignment: .bottom) {
                if mounted {
                    Color.black.opacity(0.001).onTapGesture(perform: dismiss)
                        .accessibilityLabel(L10n.text("收起拍摄选项")).accessibilityAddTraits(.isButton)
                        .accessibilityIdentifier("dismissCameraOptions")
                    VStack(spacing: 0) {
                        Capsule().fill(.white.opacity(0.5)).frame(width: 38, height: 4)
                            .frame(maxWidth: .infinity).frame(height: 44).contentShape(Rectangle())
                            .gesture(handleDrag(travel: travel))
                            .onTapGesture(perform: dismiss)
                            .accessibilityLabel(L10n.text("收起拍摄选项")).accessibilityAddTraits(.isButton)
                            .accessibilityIdentifier("cameraOptionsHandle")
                        ScrollView(.vertical) {
                            Group {
                                if page == .overview { overview }
                                else { detail }
                            }
                            .padding(.horizontal, 22).padding(.bottom, 24)
                            .frame(maxWidth: .infinity)
                            .fixedSize(horizontal: false, vertical: true)
                            .background(GeometryReader { size in
                                Color.clear.preference(key: PanelContentHeight.self, value: [page: size.size.height])
                            })
                        }
                        .scrollIndicators(.hidden)
                        .scrollBounceBehavior(.basedOnSize)
                    }
                    .frame(width: min(480, proxy.size.width - 16), height: height)
                    .onAppear { panelHeight = height }
                    .onChange(of: height) { _, value in withAnimation(panelAnimation) { panelHeight = value } }
                    .clipped()
                    // Keep a single material surface while the content and height change.
                    .modifier(CameraPanelMaterial())
                    .padding(.horizontal, 8).padding(.bottom, 8)
                    .offset(y: reduceMotion ? 0 : (1 - presentationProgress) * travel)
                    .opacity(reduceMotion ? presentationProgress : 1)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("cameraOptionsPanel")
                    .onPreferenceChange(PanelContentHeight.self) { heights in
                        let changes = heights.filter { abs((contentHeights[$0.key] ?? 0) - $0.value) > 0.5 }
                        guard !changes.isEmpty else { return }
                        withAnimation(panelAnimation) { contentHeights.merge(changes) { _, new in new } }
                    }
                }
            }
            .allowsHitTesting(isPresented)
            .accessibilityHidden(!isPresented)
        }
        .onChange(of: video) { _, _ in show(.overview) }
        .onChange(of: isPresented) { _, visible in present(visible) }
        .onAppear { if isPresented { present(true) } }
        .onDisappear { generation += 1; mounted = false; presentationProgress = 0; dragOrigin = nil }
    }

    private func present(_ visible: Bool) {
        generation += 1
        let revision = generation
        dragOrigin = nil
        if visible {
            if mounted {
                // Reverse an in-flight dismissal without jumping the card off screen.
                withAnimation(panelAnimation) { presentationProgress = 1 }
                return
            }
            var transaction = Transaction(); transaction.disablesAnimations = true
            withTransaction(transaction) { mounted = true; presentationProgress = 0 }
            Task { @MainActor in
                await Task.yield()
                guard generation == revision, isPresented else { return }
                withAnimation(panelAnimation) { presentationProgress = 1 }
            }
        } else {
            // Animate from the finger's final position. Do not reset the drag on release.
            withAnimation(panelAnimation, completionCriteria: .removed) { presentationProgress = 0 } completion: {
                guard generation == revision, !isPresented else { return }
                mounted = false
            }
        }
    }

    private func handleDrag(travel: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .global)
            .onChanged { value in
                if dragOrigin == nil { dragOrigin = presentationProgress }
                var transaction = Transaction(); transaction.disablesAnimations = true
                withTransaction(transaction) {
                    presentationProgress = min(1, max(0, (dragOrigin ?? 1) - value.translation.height / travel))
                }
            }
            .onEnded { value in
                dragOrigin = nil
                if value.translation.height > min(80, travel * 0.25) || value.predictedEndTranslation.height > travel * 0.45 {
                    dismiss()
                } else {
                    withAnimation(panelAnimation) { presentationProgress = 1 }
                }
            }
    }

    private func show(_ next: Page) {
        withAnimation(panelAnimation) { page = next }
    }

    private struct PanelContentHeight: PreferenceKey {
        static var defaultValue: [Page: CGFloat] = [:]
        static func reduce(value: inout [Page: CGFloat], nextValue: () -> [Page: CGFloat]) {
            value.merge(nextValue()) { _, new in new }
        }
    }

    private var overview: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .top), count: 3), spacing: 24) {
            tile("闪光灯", symbol: video ? (torch ? "bolt.fill" : "bolt.slash.fill") : flash.symbol,
                 selected: video ? torch : flash != .off, id: "optionFlash") { show(.flash) }
            if !video {
                tile("实况", symbol: live ? "livephoto" : "livephoto.slash",
                     selected: live, id: "optionLive", enabled: camera.livePhotoAvailable || live) { show(.live) }
                tile("宽高比", symbol: "viewfinder", text: aspect.rawValue, id: "optionAspect") { show(.aspect) }
                tile("计时器", symbol: "timer", text: timer == "0" ? nil : timer,
                     selected: timer != "0", id: "optionTimer", timerValue: PhotoTimer(rawValue: timer) ?? .off) { show(.timer) }
            }
            tile("曝光", symbol: "plusminus", selected: abs(exposure) > 0.01, id: "optionExposure") { show(.exposure) }
            if video {
                tile("增强防抖", symbol: "figure.run", selected: camera.enhancedStabilizationActive,
                     id: "optionStabilization") { show(.stabilization) }
            }
            tile("格式", symbol: "", id: "optionFormat", readout: formatReadout) { show(.format) }
            tile("设置", symbol: "gearshape", id: "optionSettings", action: openSettings)
        }.padding(.top, 12)
    }

    private func tile(_ title: String, symbol: String, text: String? = nil, selected: Bool = false,
                      id: String, enabled: Bool = true, timerValue: PhotoTimer? = nil,
                      readout: (title: String, detail: String, value: String)? = nil,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 11) {
                ZStack {
                    Circle().fill(.black.opacity(0.48)).frame(width: 58, height: 58)
                    if let readout {
                        VStack(spacing: 1) {
                            Text(readout.title).font(.system(size: 20, weight: .medium))
                            Text(readout.detail).font(.system(size: 12, weight: .medium).monospacedDigit())
                        }
                        .lineLimit(1).minimumScaleFactor(0.65).frame(width: 48)
                    } else if let timerValue {
                        CameraTimerIcon(value: timerValue, size: 26)
                    } else if let text {
                        Image(systemName: symbol).font(.system(size: 23, weight: .light))
                        Text(L10n.text(text)).font(.system(size: 10, weight: .medium))
                    }
                    else { Image(systemName: symbol).font(.system(size: 23, weight: .regular)) }
                }
                .foregroundStyle(selected ? .yellow : .white)
                Text(L10n.text(title)).font(.system(size: 15)).lineLimit(2).minimumScaleFactor(0.8).multilineTextAlignment(.center).foregroundStyle(.white.opacity(0.88))
            }.frame(maxWidth: .infinity).contentShape(Rectangle())
        }
        .buttonStyle(CameraPanelButtonStyle()).disabled(!enabled).opacity(enabled ? 1 : 0.4)
        .accessibilityLabel(L10n.text(title)).accessibilityValue(readout?.value ?? L10n.text(text ?? (selected ? "已开启" : "已关闭")))
        .accessibilityIdentifier(id)
    }

    private var detail: some View {
        VStack(spacing: 18) {
            HStack {
                Button { show(.overview) } label: { Image(systemName: "chevron.left").frame(width: 40, height: 40) }
                    .buttonStyle(CameraPanelButtonStyle())
                    .accessibilityLabel(L10n.text("返回拍摄选项")).accessibilityIdentifier("optionsBack")
                Spacer()
                Text(L10n.text(pageTitle)).font(.headline)
                Spacer()
                Color.clear.frame(width: 40, height: 40)
            }
            if page == .aspect {
                HStack(spacing: 12) {
                    ForEach(CaptureAspect.allCases) { value in
                        choice(value.rawValue, selected: aspect == value, id: "aspect-\(value.rawValue)") { aspect = value }
                    }
                }
                Text(L10n.text("调整大画面取景，小窗比例保持不变"))
                    .font(.footnote).foregroundStyle(.secondary)
            } else if page == .exposure {
                Text(L10n.text(String(format: "%+.1f EV", locale: L10n.locale, exposure))).font(.title2.monospacedDigit()).foregroundStyle(.yellow)
                Slider(value: $exposure, in: -2...2, step: 0.1).tint(.yellow)
                    .accessibilityLabel(L10n.text("主画面曝光")).accessibilityIdentifier("cameraExposure")
                Button(L10n.text("恢复自动曝光")) { exposure = 0 }.accessibilityIdentifier("resetExposure")
            } else if page == .timer {
                Text(timer == "0" ? L10n.text("关闭") : String(format: L10n.text("%@ 秒"), timer)).font(.system(size: 28, weight: .regular)).foregroundStyle(.white)
                HStack(spacing: 8) {
                    ForEach(PhotoTimer.allCases) { value in
                        Button { timer = value.rawValue } label: {
                            CameraTimerIcon(value: value)
                                .frame(width: 48, height: 50)
                                .contentShape(Rectangle())
                                .foregroundStyle(timer == value.rawValue ? .yellow : .white)
                        }.buttonStyle(CameraPanelButtonStyle()).accessibilityIdentifier("timer-" + value.rawValue)
                            .accessibilityLabel(value == .off ? L10n.text("关闭") : String(format: L10n.text("%@ 秒"), value.rawValue))
                            .accessibilityValue(L10n.text(timer == value.rawValue ? "已选择" : "未选择"))
                    }
                }.frame(maxWidth: .infinity)
            } else if page == .live {
                HStack(spacing: 12) {
                    choice("关闭", selected: !live, id: "live-off") { live = false }
                    choice("开启", selected: live, id: "live-on") { live = true }
                        .disabled(!camera.livePhotoAvailable)
                }
            } else if page == .format {
                if video { videoFormatOptions } else { photoFormatOptions }
            } else if page == .stabilization {
                HStack(spacing: 12) {
                    choice("关闭", selected: !camera.enhancedStabilizationActive, id: "enhanced-off") { enhancedStabilization = false }
                    choice("开启", selected: camera.enhancedStabilizationActive, id: "enhanced-on") { enhancedStabilization = true }
                        .disabled(!camera.enhancedStabilizationAvailable)
                }
                Text(L10n.text(camera.enhancedStabilizationAvailable ? "增强防抖会裁切取景，并可能增加预览延迟。" : "当前镜头或录制规格不支持增强防抖。"))
                    .font(.footnote).foregroundStyle(.secondary)
            } else if video {
                HStack(spacing: 12) {
                    choice("关闭", selected: !torch, id: "torch-off") { torch = false }
                    choice("开启", selected: torch, id: "torch-on") { torch = true }.disabled(!camera.torchAvailable)
                }
                if !camera.torchAvailable { Text(L10n.text("当前主镜头暂不支持补光")).font(.footnote).foregroundStyle(.secondary) }
            } else {
                HStack(spacing: 12) {
                    ForEach(CameraFlashMode.allCases) { value in
                        choice(value.title, selected: flash == value, id: "flash-\(value.rawValue)") { flash = value }
                            .disabled(!camera.supportedFlashModes.contains(value))
                    }
                }
                if camera.supportedFlashModes.count == 1 { Text(L10n.text("当前主镜头暂不支持闪光灯")).font(.footnote).foregroundStyle(.secondary) }
            }
        }
    }

    private var pageTitle: String {
        switch page { case .overview: "拍摄选项"; case .flash: "闪光灯"; case .live: "实况"; case .aspect: "宽高比"
        case .exposure: "曝光"; case .timer: "计时器"; case .format: "格式"; case .stabilization: "增强防抖" }
    }
    private var formatReadout: (title: String, detail: String, value: String) {
        if video {
            // Match the viewfinder readout, including device-supported fallback.
            let profile = camera.actualVideoProfile
            return (profile.resolution.rawValue, String(profile.fps), profile.title)
        }
        let profile = selectedPhoto
        let pixels = "\(profile.megapixels) MP"
        return (profile.format.title, pixels, "\(profile.format.title) · \(pixels)")
    }
    private var profiles: [VideoRecordingProfile] { dual ? camera.dualVideoProfiles : camera.singleVideoProfiles }
    private var selectedVideo: VideoRecordingProfile { VideoRecordingProfile(rawValue: videoProfile) }
    private var selectedPhoto: PhotoCaptureProfile {
        camera.photoCapabilities.resolve(PhotoCaptureProfile(format: PhotoFileFormat(rawValue: photoFormat) ?? .jpeg,
            megapixels: Int(photoMP) ?? 12), live: live)
    }
    private var videoFormatOptions: some View {
        VStack(spacing: 18) {
            HStack {
                Text(L10n.text("分辨率")).font(.footnote).frame(width: 64, alignment: .leading)
                ForEach(VideoResolution.allCases.filter { value in profiles.contains { $0.resolution == value } }) { value in
                    formatChoice(value.rawValue, selected: selectedVideo.resolution == value, id: "videoResolution-" + value.rawValue) {
                        guard let next = profiles.first(where: { $0.resolution == value && $0.fps == selectedVideo.fps })
                            ?? profiles.first(where: { $0.resolution == value && $0.fps == 30 })
                            ?? profiles.first(where: { $0.resolution == value }) else { return }
                        videoProfile = next.rawValue
                    }
                }
            }
            HStack {
                Text(L10n.text("帧速率")).font(.footnote).frame(width: 64, alignment: .leading)
                ForEach(profiles.filter { $0.resolution == selectedVideo.resolution }.map(\.fps), id: \.self) { value in
                    formatChoice(String(value), selected: selectedVideo.fps == value, id: "videoFPS-" + String(value)) {
                        videoProfile = VideoRecordingProfile(resolution: selectedVideo.resolution, fps: value).rawValue
                    }
                }
            }
        }
    }
    private var photoFormatOptions: some View {
        VStack(spacing: 18) {
            HStack {
                Text(L10n.text("格式")).font(.footnote).frame(width: 64, alignment: .leading)
                ForEach(camera.photoCapabilities.formats) { value in
                    formatChoice(value.title, selected: selectedPhoto.format == value, id: "photoFormat-" + value.rawValue) {
                        if value == .raw { live = false }
                        photoFormat = value.rawValue
                    }
                }
            }
            HStack {
                Text(L10n.text("分辨率")).font(.footnote).frame(width: 64, alignment: .leading)
                ForEach(camera.photoCapabilities.megapixels, id: \.self) { value in
                    formatChoice("\(value) MP", selected: selectedPhoto.megapixels == value, id: "photoMP-" + String(value)) { photoMP = String(value) }
                }
            }
            Text(L10n.text("像素档位以主画面原片为准，裁切后的成片像素会减少。"))
                .font(.footnote).foregroundStyle(.secondary)
            if selectedPhoto.format == .raw {
                Text(L10n.text("RAW 原片保留在 App 中，合成照片使用 HEIF 或 JPEG。"))
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
    private func formatChoice(_ title: String, selected: Bool, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if selected { Circle().frame(width: 5, height: 5) }
                Text(title).font(.system(size: 20, weight: .medium)).minimumScaleFactor(0.6).lineLimit(1)
            }.frame(maxWidth: .infinity).frame(minHeight: 44).foregroundStyle(selected ? .yellow : .white)
        }.buttonStyle(CameraPanelButtonStyle()).accessibilityIdentifier(id).accessibilityValue(L10n.text(selected ? "已选择" : "未选择"))
    }

    private func choice(_ title: String, selected: Bool, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(L10n.text(title)).font(.system(size: 19, weight: .medium)).frame(maxWidth: .infinity).frame(height: 58)
                .foregroundStyle(selected ? .yellow : .white)
                .background(selected ? .white.opacity(0.1) : .black.opacity(0.18), in: Capsule())
        }.buttonStyle(CameraPanelButtonStyle()).accessibilityValue(L10n.text(selected ? "已选择" : ""))
            .accessibilityIdentifier(id)
    }
}

/// A dial with a gap and a short twelve-o'clock mark, never an arrowhead.
/// Both the dial and the numeral use the same square and geometric center.
private struct CameraTimerIcon: View {
    let value: PhotoTimer
    var size: CGFloat = 30

    var body: some View {
        ZStack {
            CameraTimerDial().stroke(style: StrokeStyle(lineWidth: size * 0.055, lineCap: .round, lineJoin: .round))
            if value == .off {
                Path { path in
                    path.move(to: CGPoint(x: size * 0.12, y: size * 0.12))
                    path.addLine(to: CGPoint(x: size * 0.88, y: size * 0.88))
                }.stroke(style: StrokeStyle(lineWidth: size * 0.055, lineCap: .round))
            } else {
                Text(value.rawValue)
                    .font(.system(size: size * (value == .ten ? 0.44 : 0.52), weight: .regular, design: .rounded).monospacedDigit())
                    .frame(width: size, height: size)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private struct CameraTimerDial: Shape {
    func path(in rect: CGRect) -> Path {
        let radius = min(rect.width, rect.height) * 0.42
        let center = CGPoint(x: rect.midX, y: rect.midY)
        var path = Path()
        path.addArc(center: center, radius: radius, startAngle: .degrees(-90), endAngle: .degrees(225), clockwise: false)
        path.move(to: CGPoint(x: center.x, y: center.y - radius))
        path.addLine(to: CGPoint(x: center.x, y: center.y - radius * 0.66))
        return path
    }
}

private struct CameraPanelMaterial: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 42, style: .continuous))
        } else {
            content.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 42, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 42).strokeBorder(.white.opacity(0.22), lineWidth: 0.7))
        }
    }
}
