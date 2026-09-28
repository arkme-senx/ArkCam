import SwiftUI

struct MemoryDetailScreen: View {
    @ObservedObject var albumSaver: AutoAlbumSaver
    @AppStorage("cameraLanguage") private var interfaceLanguage = "system"
    @State var item: MemoryItem
    @ObservedObject var library: MediaLibrary
    @Environment(\.captureAccess) private var captureAccess
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var exporter = AlbumExporter()
    @StateObject private var player = MemoryPlayer()
    @State private var editError: String?
    @State private var isDraggingLayout = false
    @State private var livePressing = false
    @State private var videoLayoutFrames: VideoLayoutFrames?
    @State private var videoLayoutFrameTask: Task<Void, Never>?
    @State private var resumeAfterLayoutDrag = false
    @State private var chromeVisible = true
    @State private var isEditingLayout = false
    @State private var showInformation = false
    @State private var showExportOptions = false
    @State private var showAlbumStatus = false
    @State private var exportSnapshot: MemoryItem?
    @Namespace private var dragSpace

    init(item: MemoryItem, library: MediaLibrary, albumSaver: AutoAlbumSaver) {
        _item = State(initialValue: item)
        self.library = library
        self.albumSaver = albumSaver
    }

    private var layout: Binding<CameraLayout> {
        Binding(get: { item.layout(at: player.position) }, set: { changeLayout($0) })
    }

    var body: some View {
        let _ = interfaceLanguage
        VStack(spacing: 0) {
            if chromeVisible { topBar.transition(.opacity) }
            MemoryZoomView(aspectRatio: item.aspectRatio, editing: isEditingLayout,
                           liveEnabled: item.isLivePhoto && player.isReady,
                           onTap: toggleChrome, onStep: step, onLivePress: setLivePlayback) {
                mediaSurface
            }
            .id(item.id)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .topLeading) {
                if chromeVisible, item.isLivePhoto, !isEditingLayout {
                    Label(L10n.text(player.isReady ? "按住播放" : "正在准备 LIVE"), systemImage: "livephoto")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(.black.opacity(0.55), in: Capsule())
                        .padding(12).allowsHitTesting(false)
                }
            }
            if chromeVisible {
                VStack(spacing: 6) {
                    if item.kind == .video, item.isComplete { playbackControls }
                    if isEditingLayout { layoutControls }
                    else { filmstrip }
                    actionBar
                }
                .padding(.top, 8).padding(.bottom, 4)
                .background(.black)
                .transition(.opacity)
            }
        }
        .background(.black)
        .toolbar(.hidden, for: .navigationBar)
        .statusBarHidden(!chromeVisible)
        .persistentSystemOverlays(chromeVisible ? .automatic : .hidden)
        .preferredColorScheme(.dark)
        .task(id: item.id) { await prepareMedia() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { livePressing = false; player.pause() }
        }
        .onDisappear { cancelInteractions(); player.unload() }
        .sheet(isPresented: $showInformation) { informationSheet }
        .sheet(isPresented: $showAlbumStatus) { AlbumSaveStatusSheet(item: item, saver: albumSaver) }
        .alert(L10n.text("保存到相册"), isPresented: Binding(get: { exporter.message != nil }, set: { if !$0 { exporter.message = nil } })) {
            Button(L10n.text("完成")) { exporter.message = nil }
        } message: { Text(L10n.text(exporter.message ?? "")) }
        .alert(L10n.text("回看提示"), isPresented: Binding(get: { editError != nil || player.error != nil }, set: { if !$0 { editError = nil; player.error = nil } })) {
            Button(L10n.text("知道了")) { editError = nil; player.error = nil }
        } message: { Text(L10n.text(editError ?? player.error ?? "")) }
    }

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left").font(.system(size: 20, weight: .medium)).frame(width: 48, height: 48)
            }
            .accessibilityLabel(L10n.text("返回回忆")).accessibilityIdentifier("detailBack")
            .disabled(exporter.isExporting)
            Spacer(minLength: 0)
            VStack(spacing: 2) {
                Text(item.createdAt, format: .dateTime.locale(L10n.locale).year().month().day()).font(.system(size: 15, weight: .semibold))
                Text(item.createdAt, format: .dateTime.hour().minute()).font(.system(size: 12)).foregroundStyle(.secondary)
                Button { showAlbumStatus = true } label: {
                    Label(L10n.text(albumSaver.state(for: item).title), systemImage: albumSaver.state(for: item).symbol)
                        .font(.system(size: 11)).foregroundStyle(albumSaver.state(for: item).needsAttention ? Color.yellow : Color.secondary)
                }.buttonStyle(.plain).accessibilityIdentifier("detailAlbumStatus")
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("detailDate")
            Spacer(minLength: 0)
            if isEditingLayout {
                Button(L10n.text("完成")) { isEditingLayout = false }
                    .font(.system(size: 15, weight: .semibold)).frame(width: 48, height: 48)
                    .accessibilityIdentifier("finishLayout")
            } else { Color.clear.frame(width: 48, height: 48) }
        }.padding(.horizontal, 6).foregroundStyle(.white)
    }

    private var mediaSurface: some View {
        GeometryReader { geometry in
            Group {
                if let rear = library.renderURL(for: item, front: false), let front = library.renderURL(for: item, front: true) {
                    if item.kind == .photo {
                        ZStack {
                            DualFrameView(layout: layout, interactionEnabled: isEditingLayout,
                                          onDraggingChanged: draggingChanged) {
                                ThumbnailView(url: rear, kind: .photo, maximumPixelSize: 4096)
                            } front: {
                                ThumbnailView(url: front, kind: .photo, maximumPixelSize: 4096)
                            }
                            .allowsHitTesting(isEditingLayout)
                            if item.isLivePhoto {
                                PlayerSurface(player: player.player, onReadyForDisplay: player.displayReadinessChanged)
                                    .opacity(livePressing ? 1 : 0).allowsHitTesting(false)
                                    .accessibilityElement(children: .ignore)
                                    .accessibilityLabel(L10n.text("Live Photo 动态画面"))
                                    .accessibilityValue(L10n.text(livePressing ? "正在播放" : "静止"))
                                    .accessibilityIdentifier("livePhotoSurface")
                            }
                        }
                    } else {
                        ZStack {
                            PlayerSurface(player: player.player, onReadyForDisplay: player.displayReadinessChanged)
                                .opacity(videoLayoutFrames == nil ? 1 : 0)
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel(L10n.text("视频画面"))
                                .accessibilityValue(L10n.text(player.hasFirstFrame ? "画面已就绪" : "正在准备画面"))
                                .accessibilityIdentifier("videoSurface")
                            if let frames = videoLayoutFrames {
                                DualFrameView(layout: layout, interactionEnabled: false) {
                                    Image(uiImage: frames.rear).resizable().scaledToFill()
                                } front: { Image(uiImage: frames.front).resizable().scaledToFill() }
                                .allowsHitTesting(false).accessibilityHidden(true)
                            }
                            if player.isLoading { ProgressView(L10n.text("正在准备画面…")).font(.footnote) }
                            if isEditingLayout { videoGestureOverlay(size: geometry.size) }
                        }.coordinateSpace(name: dragSpace)
                    }
                } else {
                    ZStack(alignment: .bottom) {
                        if let url = library.renderURL(for: item, front: false) ?? library.renderURL(for: item, front: true) {
                            ThumbnailView(url: url, kind: item.kind, maximumPixelSize: 4096)
                        }
                        Text(L10n.text(item.captureNote ?? "两路原片不完整，暂时无法合成。"))
                            .font(.callout).padding().background(.black.opacity(0.7))
                    }
                }
            }.frame(width: geometry.size.width, height: geometry.size.height).clipped()
        }
    }

    private var playbackControls: some View {
        HStack(spacing: 10) {
            Button { player.toggle() } label: {
                Image(systemName: player.isPlaying || player.isWaiting ? "pause.fill" : "play.fill")
                    .frame(width: 40, height: 40)
            }
            .disabled(!player.isReady)
            .accessibilityLabel(L10n.text(player.isPlaying || player.isWaiting ? "暂停" : "播放"))
            Slider(value: Binding(get: { min(player.position, max(0.01, player.duration)) }, set: { player.seek($0) }),
                   in: 0...max(0.01, player.duration))
                .accessibilityLabel(L10n.text("播放进度")).disabled(!player.isReady)
            Text(L10n.text("\(CaptureScreen.time(player.position)) / \(CaptureScreen.time(player.duration))"))
                .font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary)
                .accessibilityIdentifier("playbackTime")
        }.padding(.horizontal, 12).tint(.white)
    }

    private var filmstrip: some View {
        MemoryFilmstrip(items: library.items, selectedID: item.id, library: library,
                        enabled: !exporter.isExporting, onSelect: select)
            .frame(height: 52)
    }

    private var layoutControls: some View {
        VStack(spacing: 4) {
            HStack {
                Button { var next = layout.wrappedValue; next.frontIsPrimary.toggle(); changeLayout(next) } label: {
                    Label(L10n.text("交换主次"), systemImage: "arrow.triangle.2.circlepath")
                }.accessibilityIdentifier("detailSwap")
                Spacer()
                Button(L10n.text(item.kind == .video ? "恢复拍摄布局" : "恢复布局")) {
                    item.layoutOverride = nil; player.updateLayout(nil); persist()
                }.disabled(item.layoutOverride == nil)
            }.font(.system(size: 13, weight: .medium))
            Text(L10n.text("轻点小窗交换 · 拖动调整位置"))
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }.frame(height: 52).padding(.horizontal, 22)
            .disabled(exporter.isExporting || !item.isComplete)
    }

    private var actionBar: some View {
        HStack {
            Button(action: chooseExportMode) {
                if exporter.isExporting { ProgressView().frame(width: 48, height: 44) }
                else { Image(systemName: "square.and.arrow.down").frame(width: 48, height: 44) }
            }
            .accessibilityLabel(L10n.text(captureAccess.isLocked ? "解锁后保存到相册" : "保存到相册"))
            .accessibilityIdentifier("saveToPhotos")
            .disabled(exporter.isExporting || ManualAlbumExport.availableModes(for: item, disk: library.disk).isEmpty)
            .confirmationDialog(L10n.text("保存到相册"), isPresented: $showExportOptions,
                                titleVisibility: .visible, presenting: exportSnapshot) { snapshot in
                ForEach(ManualAlbumExport.availableModes(for: snapshot, disk: library.disk)) { mode in
                    Button(L10n.text(mode.title)) { Task { await exporter.save(snapshot, mode: mode, library: library, saver: albumSaver) } }
                        .accessibilityIdentifier("export-" + mode.rawValue)
                }
                Button(L10n.text("取消"), role: .cancel) { exportSnapshot = nil }
            }
            Spacer()
            if item.capturedLayout.isDual {
                Button {
                    livePressing = false
                    if item.isLivePhoto { player.pause() }
                    isEditingLayout.toggle()
                } label: {
                    Label(L10n.text(isEditingLayout ? "完成调整" : "调整布局"), systemImage: "slider.horizontal.3")
                        .font(.system(size: 14)).frame(minHeight: 44)
                }
                .accessibilityIdentifier("editMemoryLayout")
                .disabled(exporter.isExporting || !item.isComplete)
            }
            Spacer()
            SystemPhotosButton().labelStyle(.iconOnly).frame(width: 44, height: 44)
            Spacer()
            Button { showInformation = true } label: { Image(systemName: "info.circle").frame(width: 48, height: 44) }
                .accessibilityLabel(L10n.text("拍摄信息")).accessibilityIdentifier("showCaptureInfo")
                .disabled(exporter.isExporting)
        }.padding(.horizontal, 16).foregroundStyle(.white)
        .overlay(alignment: .top) {
            if exporter.isExporting { Text(L10n.text(exporter.status)).font(.caption).offset(y: -16) }
        }
    }

    private var informationSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(item.createdAt, format: .dateTime.locale(L10n.locale).year().month().day().hour().minute())
                        .font(.headline)
                    CaptureInformationCard(metadata: item.captureMetadata)
                    if let note = item.captureNote { Text(L10n.text(note)).font(.callout).foregroundStyle(.secondary) }
                    Text(L10n.text("保存到相册时可选择镜头或双摄合成，原片保留在 App 中。"))
                        .font(.footnote).foregroundStyle(.secondary)
                }.padding(20)
            }
            .navigationTitle(L10n.text("拍摄信息")).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) {
                Button(L10n.text("完成")) { showInformation = false }.accessibilityIdentifier("closeCaptureInfo")
            } }
        }.preferredColorScheme(.dark).presentationDetents([.medium, .large])
    }

    private func toggleChrome() {
        guard !isEditingLayout, !exporter.isExporting else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { chromeVisible.toggle() }
    }

    private func step(_ offset: Int) {
        guard let index = library.items.firstIndex(where: { $0.id == item.id }),
              library.items.indices.contains(index + offset) else { return }
        select(library.items[index + offset].id)
    }

    private func select(_ id: UUID) {
        guard !isEditingLayout, !exporter.isExporting, id != item.id,
              let next = library.items.first(where: { $0.id == id }) else { return }
        showExportOptions = false; exportSnapshot = nil
        cancelInteractions()
        player.unload()
        item = next
    }

    private func cancelInteractions() {
        videoLayoutFrameTask?.cancel(); videoLayoutFrameTask = nil
        videoLayoutFrames = nil; resumeAfterLayoutDrag = false
        livePressing = false; isDraggingLayout = false
    }

    private func prepareMedia() async {
        if item.kind == .video,
           let rear = library.renderURL(for: item, front: false), let front = library.renderURL(for: item, front: true) {
            await player.load(item, rear: rear, front: front)
        } else if item.isLivePhoto,
                  let rear = library.renderURL(for: item, front: false, live: true), let front = library.renderURL(for: item, front: true, live: true) {
            await player.load(item, rear: rear, front: front)
        }
    }

    private func chooseExportMode() {
        livePressing = false; player.pause()
        exportSnapshot = item
        Task {
            if captureAccess.isLocked {
                do { try await captureAccess.open() }
                catch { exporter.message = "未能打开 App，请解锁后重试。" }
            } else { showExportOptions = true }
        }
    }

    private func videoGestureOverlay(size: CGSize) -> some View {
        let pip = layout.wrappedValue.pipRect(in: size)
        return Color.clear
            .frame(width: pip.width, height: pip.height)
            .contentShape(Rectangle())
            .modifier(PIPInteraction(layout: layout, size: size, coordinateSpace: dragSpace,
                                     onDraggingChanged: draggingChanged))
            .position(x: pip.midX, y: pip.midY)
            .allowsHitTesting(!exporter.isExporting)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L10n.text("小窗，轻点交换前后画面")).accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("pipWindow")
            .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    private func setLivePlayback(_ playing: Bool) {
        guard playing else { livePressing = false; if item.isLivePhoto { player.pause() }; return }
        guard item.isLivePhoto, player.isReady, !isEditingLayout else { return }
        livePressing = true
        player.playFromBeginning()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func changeLayout(_ next: CameraLayout) {
        guard isEditingLayout, !exporter.isExporting else { return }
        item.layoutOverride = next
        if item.kind != .video || !isDraggingLayout {
            player.updateLayout(next, interactive: isDraggingLayout)
        }
        if !isDraggingLayout { persist() }
    }

    private func draggingChanged(_ dragging: Bool) {
        guard item.kind == .video else {
            isDraggingLayout = dragging
            if !dragging { player.finishLayoutInteraction(); persist() }
            return
        }
        if dragging {
            guard !isDraggingLayout else { return }
            isDraggingLayout = true
            resumeAfterLayoutDrag = player.isPlaying || player.isWaiting
            player.pause()
            videoLayoutFrameTask?.cancel()
            videoLayoutFrameTask = Task {
                let frames = await player.layoutFramesAtCurrentTime()
                guard !Task.isCancelled, isDraggingLayout else { return }
                videoLayoutFrames = frames
            }
        } else {
            guard isDraggingLayout else { return }
            isDraggingLayout = false
            videoLayoutFrameTask?.cancel()
            videoLayoutFrameTask = nil
            let shouldResume = resumeAfterLayoutDrag
            resumeAfterLayoutDrag = false
            let editedID = item.id
            player.commitLayoutInteraction(item.layoutOverride) {
                guard item.id == editedID else { return }
                videoLayoutFrames = nil
                if shouldResume { player.resume() }
            }
            persist()
        }
    }

    private func persist() {
        do { try library.disk.save(item); library.insert(item) }
        catch { editError = "布局保存失败：\(error.localizedDescription)" }
    }
}


struct MemoryStripThumbnail: View {
    @AppStorage("cameraLanguage") private var interfaceLanguage = "system"
    let item: MemoryItem
    let library: MediaLibrary

    var body: some View {
        let _ = interfaceLanguage
        ZStack(alignment: .bottomTrailing) {
            if let rear = library.renderURL(for: item, front: false), let front = library.renderURL(for: item, front: true) {
                DualFrameView(layout: .constant(item.layout()), interactionEnabled: false) {
                    ThumbnailView(url: rear, kind: item.kind, maximumPixelSize: 160)
                } front: { ThumbnailView(url: front, kind: item.kind, maximumPixelSize: 160) }
                .allowsHitTesting(false)
            } else if let url = library.renderURL(for: item, front: false) ?? library.renderURL(for: item, front: true) {
                ThumbnailView(url: url, kind: item.kind, maximumPixelSize: 160)
            } else { Color(white: 0.15) }
            if item.kind == .video || item.isLivePhoto {
                Image(systemName: item.kind == .video ? "play.fill" : "livephoto")
                    .font(.system(size: 9, weight: .semibold)).padding(3)
                    .shadow(color: .black, radius: 2)
            }
        }.accessibilityHidden(true)
    }
}
