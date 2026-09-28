import SwiftUI
import UIKit

/// One native zoom surface for both still images and the composited video layer.
/// Zoom is a viewing transform and never changes a memory's saved layout.
struct MemoryZoomView<Content: View>: UIViewControllerRepresentable {
    @AppStorage("cameraLanguage") private var interfaceLanguage = "system"
    let aspectRatio: CGFloat
    let editing: Bool
    let liveEnabled: Bool
    let onTap: () -> Void
    let onStep: (Int) -> Void
    let onLivePress: (Bool) -> Void
    @ViewBuilder let content: () -> Content

    func makeUIViewController(context: Context) -> MemoryZoomController {
        let controller = MemoryZoomController()
        update(controller)
        return controller
    }

    func updateUIViewController(_ controller: MemoryZoomController, context: Context) { update(controller) }

    private func update(_ controller: MemoryZoomController) {
        let _ = interfaceLanguage
        controller.scroll.accessibilityLabel = L10n.text("回忆画面")
        controller.scroll.accessibilityHint = L10n.text("双指缩放，双击放大或还原，单击显示或隐藏工具栏")
        controller.configure(content: AnyView(content().preferredColorScheme(.dark).environment(\.locale, L10n.locale).environment(\.layoutDirection, .leftToRight)),
                             aspectRatio: aspectRatio, editing: editing, liveEnabled: liveEnabled,
                             onTap: onTap, onStep: onStep, onLivePress: onLivePress)
    }

    static func dismantleUIViewController(_ controller: MemoryZoomController, coordinator: ()) {
        controller.onLivePress(false)
    }
}

final class MemoryZoomController: UIViewController, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    let scroll = UIScrollView()
    private let host = UIHostingController(rootView: AnyView(EmptyView()))
    private var content = AnyView(EmptyView())
    private var aspectRatio: CGFloat = 0.75
    private var fittedSize = CGSize.zero
    private var viewport = CGSize.zero
    private var layoutEditing = false
    private var liveEnabled = false
    var onTap: () -> Void = {}
    var onStep: (Int) -> Void = { _ in }
    var onLivePress: (Bool) -> Void = { _ in }
    private var singleTap: UITapGestureRecognizer!
    private var doubleTap: UITapGestureRecognizer!
    private var hold: UILongPressGestureRecognizer!
    private var nextSwipe: UISwipeGestureRecognizer!
    private var previousSwipe: UISwipeGestureRecognizer!

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        scroll.backgroundColor = .black
        scroll.delegate = self
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 6
        scroll.bouncesZoom = true
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.accessibilityIdentifier = "detailZoom"
        scroll.accessibilityLabel = L10n.text("回忆画面")
        scroll.accessibilityHint = L10n.text("双指缩放，双击放大或还原，单击显示或隐藏工具栏")
        view.addSubview(scroll)
        addChild(host)
        host.view.backgroundColor = .clear
        host.safeAreaRegions = []
        scroll.addSubview(host.view)
        host.didMove(toParent: self)

        doubleTap = UITapGestureRecognizer(target: self, action: #selector(zoomTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        singleTap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        singleTap.require(toFail: doubleTap)
        hold = UILongPressGestureRecognizer(target: self, action: #selector(held(_:)))
        hold.minimumPressDuration = 0.3
        hold.allowableMovement = 10
        hold.numberOfTouchesRequired = 1
        nextSwipe = UISwipeGestureRecognizer(target: self, action: #selector(swiped(_:)))
        nextSwipe.direction = .left
        previousSwipe = UISwipeGestureRecognizer(target: self, action: #selector(swiped(_:)))
        previousSwipe.direction = .right
        for recognizer in [singleTap!, doubleTap!, hold!, nextSwipe!, previousSwipe!] {
            recognizer.delegate = self
            scroll.addGestureRecognizer(recognizer)
        }
        singleTap.require(toFail: hold)
        applyInteraction()
    }

    func configure(content: AnyView, aspectRatio: CGFloat, editing: Bool, liveEnabled: Bool,
                   onTap: @escaping () -> Void, onStep: @escaping (Int) -> Void,
                   onLivePress: @escaping (Bool) -> Void) {
        self.content = content
        self.aspectRatio = aspectRatio
        self.onTap = onTap
        self.onStep = onStep
        self.onLivePress = onLivePress
        let enteredEditing = editing && !self.layoutEditing
        self.layoutEditing = editing
        self.liveEnabled = liveEnabled
        guard isViewLoaded else { return }
        if enteredEditing { scroll.setZoomScale(1, animated: false) }
        applyInteraction()
        refreshContent()
        view.setNeedsLayout()
    }

    private func applyInteraction() {
        scroll.panGestureRecognizer.isEnabled = !layoutEditing
        scroll.pinchGestureRecognizer?.isEnabled = !layoutEditing
        singleTap.isEnabled = !layoutEditing
        doubleTap.isEnabled = !layoutEditing
        hold.isEnabled = !layoutEditing && liveEnabled
        nextSwipe.isEnabled = !layoutEditing
        previousSwipe.isEnabled = !layoutEditing
        // In browse mode the native recognizers own all touches, including the inset.
        host.view.isUserInteractionEnabled = layoutEditing
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let size = view.bounds.size
        guard size.width > 0, size.height > 0 else { return }
        scroll.frame = view.bounds
        let width = min(size.width, size.height * aspectRatio)
        let fitted = CGSize(width: width, height: width / aspectRatio)
        guard size != viewport || fitted != fittedSize else { return }
        let scale = scroll.zoomScale
        let oldSize = fittedSize
        let center = CGPoint(x: (scroll.contentOffset.x + viewport.width / 2) / max(1, oldSize.width * scale),
                             y: (scroll.contentOffset.y + viewport.height / 2) / max(1, oldSize.height * scale))
        viewport = size
        scroll.setZoomScale(1, animated: false)
        fittedSize = fitted
        host.view.transform = .identity
        host.view.frame = CGRect(origin: .zero, size: fitted)
        scroll.contentSize = fitted
        refreshContent()
        scroll.setZoomScale(layoutEditing ? 1 : scale, animated: false)
        centerContent()
        if oldSize != .zero, scale > 1.01, !layoutEditing {
            let x = center.x * fitted.width * scale - size.width / 2
            let y = center.y * fitted.height * scale - size.height / 2
            scroll.contentOffset = CGPoint(
                x: min(max(-scroll.contentInset.left, x), max(-scroll.contentInset.left, scroll.contentSize.width - size.width + scroll.contentInset.right)),
                y: min(max(-scroll.contentInset.top, y), max(-scroll.contentInset.top, scroll.contentSize.height - size.height + scroll.contentInset.bottom)))
        }
    }

    private func refreshContent() {
        host.rootView = AnyView(content.frame(width: fittedSize.width, height: fittedSize.height).clipped())
    }

    private func centerContent() {
        let x = max(0, (scroll.bounds.width - fittedSize.width * scroll.zoomScale) / 2)
        let y = max(0, (scroll.bounds.height - fittedSize.height * scroll.zoomScale) / 2)
        scroll.contentInset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
        scroll.accessibilityValue = L10n.number(Double(scroll.zoomScale)) + "×"
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { host.view }
    func scrollViewDidZoom(_ scrollView: UIScrollView) { centerContent() }
    func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) { onLivePress(false) }

    @objc private func tapped() { onTap() }
    @objc private func zoomTapped(_ gesture: UITapGestureRecognizer) {
        onLivePress(false)
        if scroll.zoomScale > 1.01 { scroll.setZoomScale(1, animated: true) }
        else {
            let point = gesture.location(in: host.view)
            let target: CGFloat = 2.5
            let size = CGSize(width: scroll.bounds.width / target, height: scroll.bounds.height / target)
            scroll.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                                   width: size.width, height: size.height), animated: true)
        }
    }
    @objc private func swiped(_ gesture: UISwipeGestureRecognizer) {
        onLivePress(false)
        onStep(gesture.direction == .left ? 1 : -1)
    }
    @objc private func held(_ gesture: UILongPressGestureRecognizer) {
        if gesture.state == .began { onLivePress(true) }
        else if gesture.state == .ended || gesture.state == .cancelled || gesture.state == .failed { onLivePress(false) }
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === nextSwipe || gestureRecognizer === previousSwipe {
            return !layoutEditing && scroll.zoomScale <= 1.01
        }
        return !layoutEditing
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        let swipe = gestureRecognizer === nextSwipe || gestureRecognizer === previousSwipe ||
            otherGestureRecognizer === nextSwipe || otherGestureRecognizer === previousSwipe
        if gestureRecognizer === scroll.pinchGestureRecognizer || otherGestureRecognizer === scroll.pinchGestureRecognizer {
            return gestureRecognizer === hold || otherGestureRecognizer === hold
        }
        return swipe && scroll.zoomScale <= 1.01
    }
}
