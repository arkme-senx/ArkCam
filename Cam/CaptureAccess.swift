import SwiftUI

// The locked extension only receives a library rooted in this capture session.
// Authentication and the transition to the containing app are owned by iOS.
struct CaptureAccess {
    var openApplication: (@MainActor (String) async throws -> Void)?
    var isLocked: Bool { openApplication != nil }

    @MainActor
    func open(_ destination: String = "library") async throws {
        try await openApplication?(destination)
    }
}

private struct CaptureAccessKey: EnvironmentKey {
    static let defaultValue = CaptureAccess()
}

extension EnvironmentValues {
    var captureAccess: CaptureAccess {
        get { self[CaptureAccessKey.self] }
        set { self[CaptureAccessKey.self] = newValue }
    }
}

@MainActor
final class CameraLaunchRoute: ObservableObject {
    enum Destination { case camera, library }
    static let shared = CameraLaunchRoute()
    @Published var destination: Destination?
}
