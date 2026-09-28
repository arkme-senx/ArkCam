import SwiftUI

enum CameraModeDragPolicy {
    static let spacing: CGFloat = 64
    static func index(_ kind: CameraCaptureMode, modes: [CameraCaptureMode] = CameraCaptureMode.allCases) -> CGFloat { CGFloat(modes.firstIndex(of: kind) ?? 0) }
    static func mode(at index: CGFloat, modes: [CameraCaptureMode] = CameraCaptureMode.allCases) -> CameraCaptureMode {
        guard !modes.isEmpty, index.isFinite else { return .singlePhoto }
        return modes[min(modes.count - 1, max(0, Int(index.rounded())))]
    }

    /// Continuous visual offset, with bounded resistance beyond either endpoint.
    static func offset(_ translation: CGFloat, from kind: CameraCaptureMode, continuous: Bool = true,
                       modes: [CameraCaptureMode] = CameraCaptureMode.allCases) -> CGFloat {
        guard translation.isFinite else { return 0 }
        let lower = -min(continuous ? .greatestFiniteMagnitude : 1, max(0, CGFloat(modes.count - 1) - index(kind, modes: modes))) * spacing
        let upper = min(continuous ? .greatestFiniteMagnitude : 1, index(kind, modes: modes)) * spacing
        if translation < lower { return lower - resistance(lower - translation) }
        if translation > upper { return upper + resistance(translation - upper) }
        return translation
    }

    private static func resistance(_ distance: CGFloat) -> CGFloat {
        18 * distance / (distance + 18)
    }

    /// A released swipe never gains momentum or skips an adjacent mode.
    /// Prediction is intentionally ignored, including after a stationary hold.
    static func destination(from kind: CameraCaptureMode, translation: CGFloat, predicted: CGFloat,
                            idleTime: TimeInterval = 0, modes: [CameraCaptureMode] = CameraCaptureMode.allCases) -> CameraCaptureMode {
        guard translation.isFinite, predicted.isFinite, abs(translation) >= spacing / 2 else { return kind }
        return mode(at: index(kind, modes: modes) - (translation > 0 ? 1 : -1), modes: modes)
    }

    static func tapped(at x: CGFloat, from kind: CameraCaptureMode, modes: [CameraCaptureMode] = CameraCaptureMode.allCases) -> CameraCaptureMode {
        let center: CGFloat = 203 / 2
        let candidate = index(kind, modes: modes) + (x - center) / spacing
        return mode(at: candidate, modes: modes)
    }
}

/// Short swipes are limited to one detent. A deliberate stationary hold followed
/// by more horizontal movement unlocks continuous selection. Promotion rebases at
/// the current position so an earlier fast swipe cannot suddenly catch up.
struct CameraModeDragSession {
    static let holdDuration: TimeInterval = 0.28
    static let hysteresis: CGFloat = 0.06
    let origin: CameraCaptureMode
    let modes: [CameraCaptureMode]
    private(set) var selection: CameraCaptureMode
    private(set) var offset: CGFloat = 0
    private(set) var horizontal: Bool?
    private(set) var continuous = false
    private var lastTranslation = CGSize.zero
    private var lastMotionAt: TimeInterval
    private var anchorTranslation: CGFloat = 0
    private var anchorOffset: CGFloat = 0

    init(origin: CameraCaptureMode, modes: [CameraCaptureMode] = CameraCaptureMode.allCases, time: TimeInterval) {
        self.origin = origin; self.selection = origin; self.modes = modes; self.lastMotionAt = time
    }

    mutating func beginContinuousSelection() {
        guard !continuous else { return }
        continuous = true
        anchorTranslation = lastTranslation.width
        anchorOffset = offset
    }

    /// Returns a new detent once; callers use it for a single selection haptic.
    mutating func update(translation: CGSize, time: TimeInterval) -> CameraCaptureMode? {
        guard translation.width.isFinite, translation.height.isFinite, time.isFinite else { return nil }
        let delta = CGSize(width: translation.width - lastTranslation.width, height: translation.height - lastTranslation.height)
        if horizontal == nil, hypot(translation.width, translation.height) >= 6 {
            horizontal = abs(translation.width) > abs(translation.height)
        }
        let moved = hypot(delta.width, delta.height) >= 4
        if horizontal == true, !continuous, moved,
           abs(delta.width) > abs(delta.height), time - lastMotionAt >= Self.holdDuration {
            beginContinuousSelection()
        }
        if moved { lastTranslation = translation; lastMotionAt = time }
        guard horizontal == true else { return nil }
        let travel = continuous ? anchorOffset + translation.width - anchorTranslation : translation.width
        offset = CameraModeDragPolicy.offset(travel, from: origin, continuous: continuous, modes: modes)
        let originIndex = CameraModeDragPolicy.index(origin, modes: modes)
        let current = CameraModeDragPolicy.index(selection, modes: modes)
        let position = originIndex - offset / CameraModeDragPolicy.spacing
        guard abs(position - current) > 0.5 + Self.hysteresis else { return nil }
        let lower = continuous ? 0 : max(0, originIndex - 1)
        let upper = continuous ? CGFloat(max(0, modes.count - 1)) : min(CGFloat(max(0, modes.count - 1)), originIndex + 1)
        let next = CameraModeDragPolicy.mode(at: min(upper, max(lower, position)), modes: modes)
        guard next != selection else { return nil }
        selection = next
        return next
    }
}

struct CameraModeSelector: View {
    @AppStorage("cameraLanguage") private var interfaceLanguage = "system"
    @Binding var kind: CameraCaptureMode
    let disabled: Bool
    let scale: CGFloat
    var modes: [CameraCaptureMode] = CameraCaptureMode.allCases
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var tracking: CameraModeDragSession?
    @State private var offset: CGFloat = 0
    @State private var feedback = UISelectionFeedbackGenerator()
    @State private var feedbackSelection: CameraCaptureMode?
    @GestureState private var touching = false

    private var settling: Animation? {
        reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.86)
    }
    private var previewKind: CameraCaptureMode {
        tracking?.selection ?? kind
    }
    private var glassPull: CGFloat {
        reduceMotion ? 0 : min(6, max(-6, offset * 0.12))
    }
    private var glassStretch: CGFloat {
        reduceMotion ? 0 : min(12, abs(offset) * 0.2)
    }

    var body: some View {
        let _ = interfaceLanguage
        ZStack {
            Capsule().fill(.white.opacity(0.07))
            selectionGlass
                .frame(width: (74 + glassStretch) * scale, height: 42 * scale)
                .offset(x: glassPull * scale)
                .scaleEffect(touching && !disabled && !reduceMotion ? 1.025 : 1)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: touching)
                .allowsHitTesting(false)
        }
        .modifier(CameraGlassGroup())
        // Keep the moving labels above the glass container. Sibling views
        // inside a container can otherwise become part of its sampled backdrop.
        .overlay {
            ZStack {
              ForEach(modes, id: \.self) { mode in
                Button { settle(on: mode) } label: {
                    Text(L10n.text(mode.title))
                        .font(.system(size: 15 * scale, weight: .regular))
                        .lineLimit(1).minimumScaleFactor(0.6)
                        .frame(width: 58 * scale)
                        .foregroundStyle(previewKind == mode ? .yellow : .white.opacity(0.9))
                        .frame(width: 74 * scale, height: max(44, 44 * scale))
                        .contentShape(Capsule())
                }
                .offset(x: ((CameraModeDragPolicy.index(mode, modes: modes) - CameraModeDragPolicy.index(kind, modes: modes))
                            * CameraModeDragPolicy.spacing + offset) * scale)
                .buttonStyle(.plain)
                .disabled(disabled)
                .accessibilityIdentifier(mode == .dualPhoto ? "photoMode" : mode == .dualVideo ? "videoMode" : mode.rawValue + "Mode")
                .accessibilityLabel(L10n.text(mode.accessibilityTitle))
                .accessibilityValue(L10n.text(kind == mode ? "已选择" : "未选择"))
              }
            }
            // Clip the scrolling labels only. The glass highlight and its
            // system edge lighting retain their full rendering bounds.
            .frame(width: 203 * scale, height: 48 * scale)
            .clipShape(Capsule())
        }
        .frame(width: 203 * scale, height: 48 * scale)
        .contentShape(Capsule())
        // One recognizer owns both physical taps and drags; child buttons retain
        // their accessibility actions without competing with a held finger.
        .highPriorityGesture(drag.simultaneously(with: hold), including: disabled ? .none : .all)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("captureModeSelector")
        .onChange(of: touching) { _, active in if !active, tracking != nil { cancel() } }
        .onChange(of: disabled) { _, value in if value { cancel() } }
        .onChange(of: kind) { _, value in if let tracking, tracking.origin != value { cancel() } }
        .onChange(of: modes) { _, _ in cancel() }
        .onChange(of: scenePhase) { _, value in if value != .active { cancel() } }
        .onDisappear { cancel() }
    }

    private var hold: some Gesture {
        LongPressGesture(minimumDuration: CameraModeDragSession.holdDuration, maximumDistance: 6 * scale)
            .onEnded { _ in
                guard !disabled else { return }
                if tracking == nil { feedbackSelection = kind; feedback.prepare() }
                var session = tracking ?? CameraModeDragSession(origin: kind, modes: modes,
                                                                time: ProcessInfo.processInfo.systemUptime)
                session.beginContinuousSelection()
                tracking = session
            }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .updating($touching) { _, state, _ in if !disabled { state = true } }
            .onChanged { value in
                guard !disabled else { return }
                let now = ProcessInfo.processInfo.systemUptime
                if tracking == nil { feedbackSelection = kind; feedback.prepare() }
                var session = tracking ?? CameraModeDragSession(origin: kind, modes: modes, time: now)
                let selection = session.update(translation: CGSize(width: value.translation.width / scale,
                                                                  height: value.translation.height / scale), time: now)
                var transaction = Transaction(); transaction.animation = nil
                withTransaction(transaction) { tracking = session; offset = session.offset }
                if let selection { selectionFeedback(for: selection) }
            }
            .onEnded { value in
                guard !disabled, let session = tracking else { cancel(); return }
                let distance = hypot(value.translation.width, value.translation.height) / scale
                if session.horizontal == true {
                    // Settle on the last detent actually reached by the finger.
                    // Holding before release does not add momentum or enable scrubbing.
                    settle(on: session.selection)
                } else if distance < 6 {
                    settle(on: CameraModeDragPolicy.tapped(at: value.startLocation.x / scale, from: session.origin, modes: modes))
                } else { cancel() }
            }
    }

    private func selectionFeedback(for next: CameraCaptureMode) {
        guard feedbackSelection != next else { return }
        feedback.selectionChanged()
        feedback.prepare()
        feedbackSelection = next
    }

    private func settle(on next: CameraCaptureMode) {
        guard !disabled else { cancel(); return }
        if next != kind { selectionFeedback(for: next) }
        withAnimation(settling) { kind = next; offset = 0; tracking = nil }
        feedbackSelection = nil
    }

    private func cancel() {
        withAnimation(settling) { offset = 0; tracking = nil }
        feedbackSelection = nil
    }

    @ViewBuilder private var selectionGlass: some View {
        if #available(iOS 26.0, *) {
            Capsule().fill(.clear)
                // The fixed parent owns scrolling input and drives the small
                // stretch; this background does not need its own touch response.
                .glassEffect(.regular, in: Capsule())
        } else {
            Capsule().fill(.ultraThinMaterial)
                .overlay(Capsule().stroke(.white.opacity(0.28), lineWidth: 0.7))
        }
    }
}
