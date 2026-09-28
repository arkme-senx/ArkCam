import SwiftUI

/// Let the system coordinate glass rendering within a control. Keep the
/// camera image outside this container and never rasterize its live backdrop.
struct CameraGlassGroup: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 8) { content }
        } else {
            content
        }
    }
}

/// Preserve the existing touch target and layout: a system button style can
/// introduce its own padding, whereas glassEffect follows the label's bounds.
struct CameraGlassButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        if #available(iOS 26.0, *) {
            configuration.label
                .contentShape(Circle())
                .glassEffect(.regular.interactive(), in: Circle())
        } else {
            configuration.label
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.16), lineWidth: 0.5))
                .contentShape(Circle())
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: configuration.isPressed)
        }
    }
}

/// A panel already owns one glass surface; its child buttons should react to
/// touch without adding another refractive layer over that surface.
struct CameraPanelButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.75 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .animation(reduceMotion ? nil : .smooth(duration: 0.16), value: configuration.isPressed)
    }
}
