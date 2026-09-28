import SwiftUI
import UIKit
import Darwin

struct CameraZoomControl: View {
    @AppStorage("cameraLanguage") private var interfaceLanguage = "system"
    @ObservedObject var camera: DualCamera
    let scale: CGFloat
    var photoMode = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var expanded = false
    @State private var collapseTask: Task<Void, Never>?
    @State private var dragOrigin: Double?
    @State private var dragValue: Double?
    @State private var lastHapticStop: Double?

    private var value: Double { dragValue ?? camera.rearZoom }
    private var selected: Double { CameraZoomScale.selectedStop(for: value, stops: camera.availableRearZooms) }
    private var selectedIndex: Int { camera.availableRearZooms.firstIndex { $0.factor == selected } ?? 0 }
    private var enabled: Bool { camera.state == .ready && !camera.isBusy }

    var body: some View {
        let _ = interfaceLanguage
        ZStack {
            ForEach(Array(camera.availableRearZooms.enumerated()), id: \.element.id) { index, stop in
                Button { select(stop.factor) } label: {
                    Text(L10n.text(stop.factor == selected ? "\(CameraZoomPreset.number(value))×" : stop.factor == 0.5 ? ".5" : CameraZoomPreset.number(stop.factor)))
                        .font(.system(size: 15 * scale, weight: .regular))
                        .monospacedDigit()
                        .foregroundStyle(stop.factor == selected ? .yellow : .white)
                        .frame(width: 38 * scale, height: 38 * scale)
                        .background(stop.factor == selected ? Color(white: 0.28).opacity(0.85) : .clear, in: Circle())
                }
                .offset(x: CGFloat(index - selectedIndex) * 39 * scale)
                .opacity(expanded ? 0 : 1)
                // The stable touch surface owns finger input; buttons retain
                // their labels and actions for VoiceOver / Switch Control.
                .accessibilityHidden(expanded)
                .accessibilityIdentifier("zoom-\(stop.title)")
                .accessibilityLabel(L10n.text("\(CameraZoomPreset.number(stop.factor == selected ? value : stop.factor)) 倍"))
                .accessibilityValue(L10n.text(stop.factor == selected ? "已选择" : ""))
            }
        }
        .frame(width: 375 * scale, height: 56 * scale)
        .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.9), value: selectedIndex)
        .overlay(alignment: .bottom) {
            if expanded {
                CameraZoomDial(value: value, stops: camera.availableRearZooms, range: camera.rearZoomRange)
                    .frame(width: 375 * scale, height: 422 * scale)
                    .offset(y: 301 * scale)
                    .allowsHitTesting(false)
                    .transition(.opacity)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(L10n.text("精细变焦，最大 \(CameraZoomPreset.number(camera.rearZoomRange.upperBound)) 倍"))
                    .accessibilityValue(L10n.text(CameraZoomPreset.number(value)))
                    .accessibilityIdentifier("zoomDial")
                    .accessibilityAdjustableAction { direction in
                        let factor = direction == .increment ? 1.1 : 1 / 1.1
                        let next = min(camera.rearZoomRange.upperBound, max(camera.rearZoomRange.lowerBound, value * factor))
                        dragValue = next; camera.setRearZoom(next); scheduleCollapse()
                    }
            }
        }
        .overlay {
            ZoomTouchSurface(expanded: expanded, enabled: enabled, scale: scale,
                onTap: { x in
                    let index = selectedIndex + Int((x / scale / 39).rounded())
                    guard camera.availableRearZooms.indices.contains(index) else { return }
                    select(camera.availableRearZooms[index].factor)
                }, onBegin: beginDragging, onDrag: drag, onEnd: scheduleCollapse, onCancel: collapse)
                .frame(width: 375 * scale, height: 160 * scale)
                .offset(y: -30 * scale)
                .accessibilityHidden(true)
        }
        .disabled(!enabled)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("rearZoomSelector")
        .onDisappear(perform: collapse)
        .onChange(of: scenePhase) { _, phase in if phase != .active { collapse() } }
        .onChange(of: enabled) { _, enabled in if !enabled { collapse() } }
        .onChange(of: camera.rearZoom) { _, actual in
            if dragOrigin == nil, let dragValue, abs(actual - dragValue) < 0.0001 { self.dragValue = nil }
        }
    }

    private func select(_ factor: Double) {
        guard enabled else { return }
        collapse()
        let target = photoMode && factor == 1 && selected == 1
            ? MainCameraPreference.next(after: value,
                main: CameraFocalCalibration.known(CaptureDeviceInfo.current.hardwareIdentifier)?.main,
                maximum: camera.rearZoomRange.upperBound)
            : factor
        camera.setRearZoom(target, smooth: true)
        UISelectionFeedbackGenerator().selectionChanged()
    }

    private func beginDragging() {
        guard enabled else { return }
        collapseTask?.cancel(); collapseTask = nil
        dragOrigin = value
        if !expanded {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) { expanded = true }
            UISelectionFeedbackGenerator().selectionChanged()
        }
    }

    private func drag(_ translation: CGFloat) {
        guard enabled, let origin = dragOrigin else { return }
        let next = CameraZoomScale.dragged(from: origin, points: -Double(translation / scale), range: camera.rearZoomRange)
        dragValue = next
        camera.setRearZoom(next)
        let anchors = camera.availableRearZooms.map(\.factor) + [camera.rearZoomRange.upperBound]
        let near = anchors.first { abs(log(next / $0)) < 0.025 }
        if let near, near != lastHapticStop { UISelectionFeedbackGenerator().selectionChanged() }
        lastHapticStop = near
    }

    private func scheduleCollapse() {
        dragOrigin = nil; lastHapticStop = nil
        collapseTask?.cancel()
        collapseTask = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(1600)) } catch { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { expanded = false }
            dragValue = nil
        }
    }

    private func collapse() {
        collapseTask?.cancel(); collapseTask = nil
        expanded = false; dragOrigin = nil; dragValue = nil; lastHapticStop = nil
    }
}

/// One stationary input surface handles tap, hold, and immediate horizontal drag.
/// It never moves with selected labels and retains the touch outside the strip.
private struct ZoomTouchSurface: UIViewRepresentable {
    let expanded: Bool
    let enabled: Bool
    let scale: CGFloat
    let onTap: (CGFloat) -> Void
    let onBegin: () -> Void
    let onDrag: (CGFloat) -> Void
    let onEnd: () -> Void
    let onCancel: () -> Void

    func makeUIView(context: Context) -> ZoomTouchView { ZoomTouchView() }
    func updateUIView(_ view: ZoomTouchView, context: Context) {
        view.expanded = expanded; view.scale = scale
        view.onTap = onTap; view.onBegin = onBegin; view.onDrag = onDrag
        view.onEnd = onEnd; view.onCancel = onCancel
        if !enabled { view.cancelTouch() }
        view.isUserInteractionEnabled = enabled
    }
}

private final class ZoomTouchView: UIView {
    var expanded = false
    var scale: CGFloat = 1
    var onTap: (CGFloat) -> Void = { _ in }
    var onBegin: () -> Void = {}
    var onDrag: (CGFloat) -> Void = { _ in }
    var onEnd: () -> Void = {}
    var onCancel: () -> Void = {}
    private var start: CGPoint?
    private var current: CGPoint = .zero
    private var tapX: CGFloat = 0
    private var dragging = false
    private var hold: DispatchWorkItem?

    init() {
        super.init(frame: .zero)
        backgroundColor = .clear
        isMultipleTouchEnabled = false
        isExclusiveTouch = true
        isAccessibilityElement = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard isUserInteractionEnabled else { return false }
        if !expanded {
            return abs(point.x - bounds.midX) <= 175 * scale && abs(point.y - 110 * scale) <= 28 * scale
        }
        // Only the visible arc receives input. Keep the shutter, options and
        // bottom row outside this hit area, even though the dial is drawn below.
        let dx = point.x - bounds.midX, dy = point.y - 235 * scale
        return bounds.contains(point) && dx * dx + dy * dy <= pow(214 * scale, 2)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard start == nil, let touch = touches.first else { return }
        current = touch.location(in: window); start = current
        tapX = touch.location(in: self).x - bounds.midX
        if expanded { beginDrag() }
        else {
            let work = DispatchWorkItem { [weak self] in self?.beginDrag() }
            hold = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
        }
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first, let start else { return }
        current = touch.location(in: window)
        let dx = current.x - start.x, dy = current.y - start.y
        if !dragging, abs(dx) >= 6 * scale { beginDrag() }
        if dragging { onDrag(dx) }
        else if abs(dy) > 24 * scale { cancelTouch() }
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let start else { return }
        hold?.cancel(); hold = nil
        if let touch = touches.first { current = touch.location(in: window) }
        if dragging { onDrag(current.x - start.x); onEnd() }
        else { onTap(tapX) }
        self.start = nil; dragging = false
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { cancelTouch() }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { cancelTouch() }
    }
    private func beginDrag() {
        guard start != nil, !dragging else { return }
        hold?.cancel(); hold = nil; dragging = true
        onBegin()
    }
    func cancelTouch() {
        hold?.cancel(); hold = nil
        let wasActive = start != nil
        start = nil; dragging = false
        if wasActive { onCancel() }
    }
}

struct FrontCameraFramingControl: View {
    @AppStorage("cameraLanguage") private var interfaceLanguage = "system"
    @ObservedObject var camera: DualCamera
    let scale: CGFloat

    private var wide: Bool { camera.frontZoom < (camera.frontZoomRange.lowerBound + camera.frontZoomRange.upperBound) / 2 }
    var body: some View {
        let _ = interfaceLanguage
        if camera.frontZoomRange.upperBound > camera.frontZoomRange.lowerBound + 0.01 {
            Button {
                camera.setFrontZoom(wide ? camera.frontZoomRange.upperBound : camera.frontZoomRange.lowerBound, smooth: true)
                UISelectionFeedbackGenerator().selectionChanged()
            } label: {
                Image(systemName: wide ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 17 * scale, weight: .medium))
                    .foregroundStyle(wide ? .yellow : .white)
                    .frame(width: 38 * scale, height: 38 * scale)
                    .background(Color(white: 0.28).opacity(0.85), in: Circle())
            }
            .accessibilityIdentifier("frontFraming")
            .accessibilityLabel(L10n.text(wide ? "缩小取景范围" : "扩大取景范围"))
            .accessibilityValue(L10n.text(wide ? "广角" : "近景"))
            .disabled(camera.state != .ready || camera.isBusy)
        }
    }
}

private struct CameraZoomDial: View {
    @AppStorage("cameraLanguage") private var interfaceLanguage = "system"
    let value: Double
    let stops: [CameraZoomPreset]
    let range: ClosedRange<Double>

    var body: some View {
        let _ = interfaceLanguage
        Canvas { context, size in
            let scale = size.width / 375
            let center = CGPoint(x: size.width / 2, y: 218 * scale)
            let radius = CameraZoomDialGeometry.radius * scale
            context.fill(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)),
                         with: .color(Color(white: 0.23).opacity(0.72)))
            // The wheel rotates behind the camera controls; only the upper arc
            // shows graduations. Do not carry ticks down beside the shutter.
            context.clip(to: Path(CGRect(x: 0, y: 0, width: size.width, height: 140 * scale)))
            let lower = log(range.lowerBound), upper = log(range.upperBound)
            let count = max(1, Int((upper - lower) / 0.038))
            for i in 0...count {
                let factor = exp(lower + Double(i) * (upper - lower) / Double(count))
                let angle = CameraZoomDialGeometry.angle(factor, value: value, range: range)
                strokeTick(&context, center: center, radius: radius, angle: angle,
                           length: (i % 5 == 0 ? 16 : 9) * scale, width: (i % 5 == 0 ? 1.1 : 0.65) * scale)
            }
            for (stop, angle) in CameraZoomDialGeometry.labels(value: value, stops: stops, range: range) {
                strokeTick(&context, center: center, radius: radius,
                           angle: CameraZoomDialGeometry.angle(stop.factor, value: value, range: range), length: 20 * scale, width: 1.2 * scale)
                var label = context
                label.opacity = min(1, max(0, (abs(angle) - 0.14) / 0.07))
                let labelRadius = CameraZoomDialGeometry.labelRadius * scale
                let baseline = center.y - CGFloat(Darwin.cos(angle)) * labelRadius
                let bottom = baseline + (stop.focalLength == nil ? 9 : 22) * scale
                label.opacity *= min(1, max(0, (140 * scale - bottom) / (8 * scale)))
                label.translateBy(x: center.x + CGFloat(Darwin.sin(angle)) * labelRadius,
                                  y: baseline)
                label.rotate(by: .radians(angle))
                label.draw(Text(L10n.text(CameraZoomPreset.number(stop.factor))).font(.system(size: 14 * scale)).foregroundStyle(.white), at: .zero)
                if let mm = stop.focalLength {
                    label.draw(Text(L10n.text("\(Int(mm.rounded()))MM")).font(.system(size: 9 * scale)).foregroundStyle(.white.opacity(0.6)), at: CGPoint(x: 0, y: 15 * scale))
                }
            }
            var pointer = Path()
            pointer.move(to: CGPoint(x: center.x - 2.3 * scale, y: 18 * scale))
            pointer.addLine(to: CGPoint(x: center.x + 2.3 * scale, y: 18 * scale))
            pointer.addLine(to: CGPoint(x: center.x, y: 28 * scale))
            pointer.closeSubpath()
            context.fill(pointer, with: .color(.yellow))
            context.draw(Text(L10n.text("\(CameraZoomPreset.number(value))×")).font(.system(size: 15 * scale)).foregroundStyle(.yellow), at: CGPoint(x: center.x, y: 51 * scale))
            if let mm = stops.first(where: { abs(log($0.factor / value)) < 0.015 })?.focalLength {
                context.draw(Text(L10n.text("\(Int(mm.rounded()))MM")).font(.system(size: 10 * scale)).foregroundStyle(.yellow), at: CGPoint(x: center.x, y: 67 * scale))
            }
        }
    }

    private func strokeTick(_ context: inout GraphicsContext, center: CGPoint, radius: CGFloat, angle: Double, length: CGFloat, width: CGFloat) {
        var line = Path()
        line.move(to: CGPoint(x: center.x + CGFloat(Darwin.sin(angle)) * (radius - 5), y: center.y - CGFloat(Darwin.cos(angle)) * (radius - 5)))
        line.addLine(to: CGPoint(x: center.x + CGFloat(Darwin.sin(angle)) * (radius - 5 - length), y: center.y - CGFloat(Darwin.cos(angle)) * (radius - 5 - length)))
        context.stroke(line, with: .color(.white.opacity(0.78)), lineWidth: width)
    }
}
