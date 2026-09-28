import SwiftUI

struct LibraryScreen: View {
    @AppStorage("cameraLanguage") private var interfaceLanguage = "system"
    @ObservedObject var library: MediaLibrary
    @ObservedObject var albumSaver: AutoAlbumSaver
    @Environment(\.captureAccess) private var captureAccess
    @Environment(\.dismiss) private var dismiss
    @State private var unlockError: String?
    @State private var statusItem: MemoryItem?
    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        let _ = interfaceLanguage
        NavigationStack {
            Group {
                if library.items.isEmpty && library.isLoading {
                    ProgressView().tint(.white)
                } else if library.items.isEmpty {
                    ContentUnavailableView(L10n.text("第一条回忆，等你拍下"), systemImage: "camera.on.rectangle",
                                           description: Text(L10n.text("拍下眼前的美好，也留下镜头后面的你。\n双路原片会一起保存在这里。")))
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            HStack {
                                Text(L10n.text("\(library.items.count) 条回忆")).font(.subheadline).foregroundStyle(.secondary)
                                Spacer()
                                Label(L10n.text("原片已保留"), systemImage: "square.stack.3d.up").font(.caption).foregroundStyle(.secondary)
                            }
                            LazyVGrid(columns: columns, spacing: 20) {
                                ForEach(library.items) { item in
                                    NavigationLink { MemoryDetailScreen(item: item, library: library, albumSaver: albumSaver) } label: {
                                        MemoryCard(item: item, library: library).contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityIdentifier("memory-\(item.kind.rawValue)")
                                    .overlay(alignment: .topTrailing) {
                                        Button { statusItem = item } label: { AlbumStatusBadge(state: albumSaver.state(for: item)) }
                                            .frame(minHeight: 44).contentShape(Rectangle())
                                            .buttonStyle(.plain).padding(.horizontal, 7)
                                            .accessibilityLabel(L10n.text("相册保存状态") + ": " + L10n.text(albumSaver.state(for: item).title))
                                            .accessibilityIdentifier("albumStatus-\(item.id.uuidString)")
                                    }
                                }
                            }
                        }.padding(16)
                    }
                }
            }
            .background(Color(white: 0.055))
            .navigationTitle(L10n.text(captureAccess.isLocked ? "本次拍摄" : "我们的回忆"))
            .safeAreaInset(edge: .bottom) {
                if captureAccess.isLocked {
                    Button {
                        Task {
                            do { try await captureAccess.open() }
                            catch { unlockError = "未能打开回忆，请解锁后重试。" }
                        }
                    } label: {
                        Label(L10n.text("解锁查看全部回忆"), systemImage: "lock.open")
                            .frame(maxWidth: .infinity).padding()
                    }.background(.ultraThinMaterial)
                    .accessibilityIdentifier("unlockAllMemories")
                }
            }
            .toolbar { ToolbarItem(placement: .topBarLeading) {
                Button { dismiss() } label: { Label(L10n.text("拍摄"), systemImage: "camera") }.accessibilityIdentifier("backToCamera")
            }
                ToolbarItem(placement: .topBarTrailing) { SystemPhotosButton() }
            }
        }
        .preferredColorScheme(.dark)
        .sheet(item: $statusItem) { item in AlbumSaveStatusSheet(item: item, saver: albumSaver) }
        .alert(L10n.text("解锁未完成"), isPresented: Binding(get: { unlockError != nil }, set: { if !$0 { unlockError = nil } })) {
            Button(L10n.text("知道了")) { unlockError = nil }
        } message: { Text(L10n.text(unlockError ?? "")) }
    }
}

private struct MemoryCard: View {
    @AppStorage("cameraLanguage") private var interfaceLanguage = "system"
    let item: MemoryItem
    @ObservedObject var library: MediaLibrary
    @Environment(\.captureAccess) private var captureAccess
    var body: some View {
        let _ = interfaceLanguage
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                if let rear = library.renderURL(for: item, front: false), let front = library.renderURL(for: item, front: true) {
                    GeometryReader { geometry in
                        let layout = item.layout()
                        let pip = layout.pipRect(in: geometry.size)
                        ZStack(alignment: .topLeading) {
                            ThumbnailView(url: layout.frontIsPrimary ? front : rear, kind: item.kind)
                            if layout.isDual {
                            ThumbnailView(url: layout.frontIsPrimary ? rear : front, kind: item.kind)
                                .frame(width: pip.width, height: pip.height)
                                .clipShape(RoundedRectangle(cornerRadius: geometry.size.width * 0.028))
                                .overlay(RoundedRectangle(cornerRadius: geometry.size.width * 0.028).strokeBorder(.white, lineWidth: 1))
                                .position(x: pip.midX, y: pip.midY)
                            }
                        }
                    }.accessibilityHidden(true)
                } else if let url = library.renderURL(for: item, front: false) ?? library.renderURL(for: item, front: true) {
                    ThumbnailView(url: url, kind: item.kind)
                } else {
                    Color(white: 0.12).overlay { Image(systemName: "exclamationmark.triangle").foregroundStyle(.secondary) }
                }
                if item.kind == .video {
                    Label(L10n.text(CaptureScreen.time(item.duration ?? 0)), systemImage: "play.fill")
                        .font(.system(size: 10, weight: .medium)).monospacedDigit()
                        .padding(.horizontal, 7).padding(.vertical, 5)
                        .background(.black.opacity(0.6), in: Capsule()).padding(7)
                } else if item.isLivePhoto {
                    Label(L10n.text("LIVE"), systemImage: "livephoto")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 7).padding(.vertical, 5)
                        .background(.black.opacity(0.6), in: Capsule()).padding(7)
                }
            }
            .aspectRatio(3 / 4, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            Text(item.createdAt, format: .dateTime.locale(L10n.locale).month().day().hour().minute())
                .font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.85))
            if !item.isComplete {
                Text(L10n.text("拍摄中断 · 查看素材"))
                    .font(.system(size: 11)).foregroundStyle(Color.orange)
            }
        }
    }
}

struct CaptureInformationCard: View {
    @AppStorage("cameraLanguage") private var interfaceLanguage = "system"
    let metadata: CaptureMetadata?
    @Environment(\.captureAccess) private var captureAccess

    var body: some View {
        let _ = interfaceLanguage
        VStack(alignment: .leading, spacing: 9) {
            Text(L10n.text("拍摄信息")).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
            if let metadata {
                if let location = metadata.location {
                    Button { openMaps(location) } label: {
                        informationRow(icon: "location.fill", title: "拍摄位置",
                                       detail: String(format: "%.5f, %.5f · ±%d 米",
                                                      location.latitude, location.longitude,
                                                      Int(location.horizontalAccuracy.rounded())), disclosure: !captureAccess.isLocked)
                    }
                    .buttonStyle(.plain)
                    .disabled(captureAccess.isLocked)
                    .accessibilityIdentifier("captureLocation")
                } else {
                    informationRow(icon: "location.slash", title: "未记录位置", detail: nil)
                        .accessibilityIdentifier("captureLocation")
                }
                informationRow(icon: "iphone", title: metadata.device.modelName,
                               detail: "\(metadata.device.systemName) \(metadata.device.systemVersion) · \(cameraSummary(metadata.cameras))")
                    .accessibilityIdentifier("captureDevice")
            } else {
                informationRow(icon: "info.circle", title: "该回忆没有拍摄信息", detail: "旧回忆不会补写推测数据")
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 13))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("captureInfo")
    }

    private func informationRow(icon: String, title: String, detail: String?, disclosure: Bool = false) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).frame(width: 18).foregroundStyle(.white.opacity(0.75))
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.text(title)).font(.system(size: 11, weight: .medium))
                if let detail { Text(L10n.text(detail)).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 4)
            if disclosure { Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(.secondary) }
        }
        .accessibilityElement(children: .combine)
    }

    private func cameraSummary(_ cameras: [CaptureCameraInfo]) -> String {
        guard let first = cameras.first else { return L10n.text("设备信息已记录") }
        let sameFormat = cameras.allSatisfy { $0.width == first.width && $0.height == first.height && abs($0.framesPerSecond - first.framesPerSecond) < 0.1 }
        if sameFormat {
            return L10n.text("双摄 \(first.width)×\(first.height) · \(Int(first.framesPerSecond.rounded())) fps")
        }
        return cameras.map { "\(L10n.text($0.position)) \($0.width)×\($0.height)" }.joined(separator: " · ")
    }

    private func openMaps(_ location: CaptureLocation) {
        let value = "\(location.latitude),\(location.longitude)"
        var components = URLComponents(string: "https://maps.apple.com/")!
        components.queryItems = [URLQueryItem(name: "ll", value: value), URLQueryItem(name: "q", value: L10n.text("拍摄位置"))]
        if let url = components.url {
            #if !CAM_CAPTURE_EXTENSION
            UIApplication.shared.open(url)
            #endif
        }
    }
}
