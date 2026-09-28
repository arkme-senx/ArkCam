import SwiftUI

@MainActor
final class CaptureNoticePresentation: ObservableObject {
    @Published private(set) var expanded = false
    private var seen = Set<String>()
    private var currentKey: String?
    private var dismissal: Task<Void, Never>?
    private let duration: Duration

    init(duration: Duration = .seconds(3)) { self.duration = duration }

    // The suffix is a changing readout, not a new condition. Keep the identity
    // independent of FPS so rate updates never restart the banner's lifetime.
    static func key(message: String, level: CameraPressureLevel) -> String {
        let reason = message.components(separatedBy: "（当前 ").first ?? message
        return "\(level.rawValue):\(reason)"
    }

    func update(message: String?, level: CameraPressureLevel, active: Bool) {
        guard active, let message else { hide(); currentKey = nil; return }
        let key = Self.key(message: message, level: level)
        guard currentKey != key else { return }
        currentKey = key
        hide()
        if seen.insert(key).inserted { reveal() }
    }

    func toggle() {
        guard currentKey != nil else { return }
        if expanded { hide() } else { reveal() }
    }

    private func reveal() {
        dismissal?.cancel()
        expanded = true
        dismissal = Task { [weak self, duration] in
            do { try await Task.sleep(for: duration) } catch { return }
            guard !Task.isCancelled else { return }
            self?.expanded = false
        }
    }

    private func hide() {
        dismissal?.cancel(); dismissal = nil; expanded = false
    }

    deinit { dismissal?.cancel() }
}

struct CaptureLoadStatus: View {
    let message: String?
    let level: CameraPressureLevel
    let active: Bool
    let scale: CGFloat
    let availableWidth: CGFloat
    @StateObject private var presentation = CaptureNoticePresentation()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var identity: String? { message.map { CaptureNoticePresentation.key(message: $0, level: level) } }
    private var touchSize: CGFloat { max(44, 44 * scale) }
    var body: some View {
        ZStack {
            if active, let message {
                Button { presentation.toggle() } label: {
                    Image(systemName: message.hasPrefix("相机温度") ? "thermometer.medium" : "gauge.with.dots.needle.67percent")
                        .font(.system(size: 17 * scale, weight: .medium))
                        .foregroundStyle(.yellow)
                        .frame(width: 28 * scale, height: 28 * scale)
                        .background(.black.opacity(0.4), in: Circle())
                        .frame(width: touchSize, height: touchSize)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.text("拍摄提示"))
                .accessibilityValue(L10n.text(message))
                .accessibilityIdentifier("cameraLoadStatus")
                .overlay(alignment: .topLeading) {
                    if presentation.expanded {
                        Text(L10n.text(message))
                            .font(.system(size: 11 * scale, weight: .medium))
                            .foregroundStyle(.white)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .frame(width: min(260 * scale, max(44, availableWidth - 24)), alignment: .leading)
                            .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 14))
                            .offset(y: touchSize / 2 + 52)
                            .allowsHitTesting(false)
                            .transition(.opacity)
                            .accessibilityIdentifier("cameraLoadNotice")
                    }
                }
            }
        }
        .frame(width: touchSize, height: touchSize)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: presentation.expanded)
        .onChange(of: identity, initial: true) { _, _ in refresh() }
        .onChange(of: active) { _, _ in refresh() }
        .onDisappear { presentation.update(message: nil, level: level, active: false) }
    }
    private func refresh() { presentation.update(message: message, level: level, active: active) }
}

struct ShutterGuidance: View {
    let holding: Bool
    let locked: Bool
    let recording: Bool
    let active: Bool
    let scale: CGFloat
    @AppStorage("cameraRecordingPhotoTipSeen") private var tipSeen = false
    @State private var tipVisible = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var shouldTeach: Bool { recording && !holding && active }
    private var text: String? {
        guard active else { return nil }
        if holding { return locked ? "松手继续录像" : "向右滑动锁定 · 松手结束" }
        return tipVisible && recording ? "轻点右侧白色按钮拍照" : nil
    }
    var body: some View {
        ZStack {
            if let text {
                Text(L10n.text(text))
                    .font(.system(size: 11 * scale))
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(.black.opacity(0.55), in: Capsule())
                    .transition(.opacity)
                    .accessibilityIdentifier("shutterGuidance")
            } else { Color.clear.frame(width: 1, height: 1) }
        }
        .allowsHitTesting(false)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: text)
        .task(id: shouldTeach) {
            tipVisible = false
            guard shouldTeach, !tipSeen else { return }
            tipSeen = true; tipVisible = true
            do { try await Task.sleep(for: .seconds(2)) } catch { tipVisible = false; return }
            tipVisible = false
        }
    }
}
