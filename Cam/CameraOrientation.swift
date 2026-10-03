import SwiftUI
import AVFoundation

enum CameraOrientation: String, Codable {
    case portrait, portraitUpsideDown, landscapeLeft, landscapeRight
    var isLandscape: Bool { self == .landscapeLeft || self == .landscapeRight }
    var overlayRotation: Double {
        switch self { case .portrait: 0; case .portraitUpsideDown: 180
        case .landscapeLeft: -90; case .landscapeRight: 90 }
    }
    var video: AVCaptureVideoOrientation {
        switch self { case .portrait: .portrait; case .portraitUpsideDown: .portraitUpsideDown
        case .landscapeLeft: .landscapeLeft; case .landscapeRight: .landscapeRight }
    }
    init(_ orientation: UIInterfaceOrientation) {
        switch orientation { case .landscapeLeft: self = .landscapeLeft; case .landscapeRight: self = .landscapeRight
        case .portraitUpsideDown: self = .portraitUpsideDown; default: self = .portrait }
    }
}

/// Window orientation, not window aspect: a narrow iPad window can still be on
/// a landscape display. The window is authoritative for front sensor rotation.
struct CameraOrientationReader: UIViewRepresentable {
    var changed: (CameraOrientation) -> Void
    func makeUIView(context: Context) -> Reader { let view = Reader(); view.changed = changed; return view }
    func updateUIView(_ view: Reader, context: Context) { view.changed = changed; view.report() }
    final class Reader: UIView {
        var changed: ((CameraOrientation) -> Void)?
        private var previous: CameraOrientation?
        override func didMoveToWindow() { super.didMoveToWindow(); report() }
        override func layoutSubviews() { super.layoutSubviews(); report() }
        func report() {
            guard let scene = window?.windowScene, scene.interfaceOrientation != .unknown else { return }
            let regularCanvas = traitCollection.horizontalSizeClass == .regular && traitCollection.verticalSizeClass == .regular
            let value: CameraOrientation
            if regularCanvas {
                // iPhone Duo's inner display can be wider than it is tall while
                // the scene still reports portrait. Use the local window bounds
                // for that pose; the scene orientation remains authoritative
                // when UIKit reports a real landscape orientation.
                switch scene.interfaceOrientation {
                case .landscapeLeft, .landscapeRight:
                    value = CameraOrientation(scene.interfaceOrientation)
                default:
                    value = bounds.width > bounds.height ? .landscapeRight : .portrait
                }
            } else {
                value = UIDevice.current.userInterfaceIdiom == .pad ? CameraOrientation(scene.interfaceOrientation) : .portrait
            }
            guard previous != value else { return }
            previous = value
            DispatchQueue.main.async { [weak self] in self?.changed?(value) }
        }
    }
}
