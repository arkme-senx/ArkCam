import AVFoundation
import CoreLocation
import SwiftUI
import UIKit

struct CaptureLocation: Codable, Equatable {
    var latitude: Double
    var longitude: Double
    var altitude: Double?
    var horizontalAccuracy: Double
    var verticalAccuracy: Double?
    var measuredAt: Date

    init(_ location: CLLocation) {
        latitude = location.coordinate.latitude
        longitude = location.coordinate.longitude
        altitude = location.verticalAccuracy >= 0 ? location.altitude : nil
        horizontalAccuracy = location.horizontalAccuracy
        verticalAccuracy = location.verticalAccuracy >= 0 ? location.verticalAccuracy : nil
        measuredAt = location.timestamp
    }

    var coreLocation: CLLocation {
        CLLocation(coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                   altitude: altitude ?? 0,
                   horizontalAccuracy: horizontalAccuracy,
                   verticalAccuracy: verticalAccuracy ?? -1,
                   timestamp: measuredAt)
    }
}

struct CaptureDeviceInfo: Codable, Equatable {
    var manufacturer: String
    var modelName: String
    var hardwareIdentifier: String
    var systemName: String
    var systemVersion: String
    var appVersion: String
    var appBuild: String

    static var current: CaptureDeviceInfo {
        let identifier = Self.hardwareIdentifier()
        let info = Bundle.main.infoDictionary ?? [:]
        return CaptureDeviceInfo(
            manufacturer: "Apple",
            modelName: Self.marketingName(for: identifier),
            hardwareIdentifier: identifier,
            systemName: UIDevice.current.systemName,
            systemVersion: UIDevice.current.systemVersion,
            appVersion: info["CFBundleShortVersionString"] as? String ?? "未知",
            appBuild: info["CFBundleVersion"] as? String ?? "未知")
    }

    private static func hardwareIdentifier() -> String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return simulated }
        var system = utsname()
        uname(&system)
        return withUnsafePointer(to: &system.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
    }

    private static func marketingName(for identifier: String) -> String {
        let names = [
            "iPhone15,2": "iPhone 14 Pro", "iPhone15,3": "iPhone 14 Pro Max",
            "iPhone15,4": "iPhone 15", "iPhone15,5": "iPhone 15 Plus",
            "iPhone16,1": "iPhone 15 Pro", "iPhone16,2": "iPhone 15 Pro Max",
            "iPhone17,3": "iPhone 16", "iPhone17,4": "iPhone 16 Plus",
            "iPhone17,1": "iPhone 16 Pro", "iPhone17,2": "iPhone 16 Pro Max",
            "iPhone17,5": "iPhone 16e"
        ]
        return names[identifier] ?? identifier
    }
}

struct CaptureCameraInfo: Codable, Equatable {
    var position: String
    var deviceType: String
    var name: String
    var width: Int
    var height: Int
    var framesPerSecond: Double

    init(device: AVCaptureDevice) {
        let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        position = device.position == .front ? "前置" : "后置"
        deviceType = device.deviceType.rawValue
        name = device.localizedName
        width = Int(dimensions.width)
        height = Int(dimensions.height)
        let duration = device.activeVideoMinFrameDuration
        framesPerSecond = duration.seconds > 0 ? 1 / duration.seconds : 0
    }

    init(position: String, deviceType: String, name: String, width: Int, height: Int, framesPerSecond: Double) {
        self.position = position
        self.deviceType = deviceType
        self.name = name
        self.width = width
        self.height = height
        self.framesPerSecond = framesPerSecond
    }
}

struct CaptureMetadata: Codable, Equatable {
    var recordedAt: Date
    var location: CaptureLocation?
    var device: CaptureDeviceInfo
    var cameras: [CaptureCameraInfo]
}

final class CaptureMetadataProvider: @unchecked Sendable {
    private let lock = NSLock()
    private var locations: [CaptureLocation] = []
    private var locationEnabled = true

    func setLocationEnabled(_ enabled: Bool) {
        lock.lock(); defer { lock.unlock() }
        locationEnabled = enabled
        if !enabled { locations.removeAll() }
    }
    private let device: CaptureDeviceInfo

    init(device: CaptureDeviceInfo = .current) { self.device = device }

    func update(location: CLLocation) {
        guard location.horizontalAccuracy >= 0 else { return }
        let captured = CaptureLocation(location)
        lock.lock()
        guard locationEnabled else { lock.unlock(); return }
        locations.append(captured)
        let cutoff = captured.measuredAt.addingTimeInterval(-30 * 60)
        locations.removeAll { $0.measuredAt < cutoff }
        if locations.count > 128 { locations.removeFirst(locations.count - 128) }
        lock.unlock()
    }

    func snapshot(cameras: [AVCaptureDevice], at date: Date = Date(),
                  maximumPastLocationAge: TimeInterval = 60,
                  maximumFutureLocationAge: TimeInterval = 0) -> CaptureMetadata {
        lock.lock()
        let candidates = locations
        lock.unlock()
        let pastLimit = max(0, maximumPastLocationAge)
        let futureLimit = max(0, maximumFutureLocationAge)
        let nearest = candidates
            .filter {
                let offset = $0.measuredAt.timeIntervalSince(date)
                return offset >= -pastLimit && offset <= futureLimit
            }
            .min {
                abs($0.measuredAt.timeIntervalSince(date)) < abs($1.measuredAt.timeIntervalSince(date))
            }
        return CaptureMetadata(recordedAt: date, location: nearest, device: device,
                               cameras: cameras.map(CaptureCameraInfo.init(device:)))
    }
}

@MainActor
final class CaptureLocationService: NSObject, ObservableObject, @preconcurrency CLLocationManagerDelegate {
    @Published private(set) var authorizationStatus: CLAuthorizationStatus
    @Published private(set) var latestLocation: CaptureLocation?
    private let manager = CLLocationManager()
    let provider: CaptureMetadataProvider
    private var started = false
    private var enabled = true
    private var precisionTask: Task<Void, Never>?

    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        provider.setLocationEnabled(enabled)
        if !enabled { latestLocation = nil; precisionTask?.cancel(); manager.stopUpdatingLocation() }
        else if started { updateCollection(for: authorizationStatus) }
    }
    private var lastCaptureRefresh: Date?

    init(provider: CaptureMetadataProvider) {
        self.provider = provider
        authorizationStatus = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter = 10
        manager.pausesLocationUpdatesAutomatically = true
    }

    func start() {
        guard !started, enabled else { return }
        started = true
        #if targetEnvironment(simulator)
        return
        #else
        #if CAM_CAPTURE_EXTENSION
        updateCollection(for: authorizationStatus)
        #else
        if authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        else { updateCollection(for: authorizationStatus) }
        #endif
        #endif
    }

    func stop() {
        started = false
        precisionTask?.cancel(); precisionTask = nil
        manager.stopUpdatingLocation()
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
    }

    func requestAccess() {
        #if CAM_CAPTURE_EXTENSION
        updateCollection(for: authorizationStatus)
        #else
        if authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        else { updateCollection(for: authorizationStatus) }
        #endif
    }

    func prepareForCapture() {
        guard enabled, started, isAuthorized else { return }
        let now = Date()
        if let lastCaptureRefresh, now.timeIntervalSince(lastCaptureRefresh) < 1 { return }
        lastCaptureRefresh = now
        precisionTask?.cancel()
        manager.desiredAccuracy = kCLLocationAccuracyBest
        precisionTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            guard let self, started else { return }
            manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        }
        #if !targetEnvironment(simulator)
        manager.requestLocation()
        #endif
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        updateCollection(for: authorizationStatus)
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard enabled, started, let location = locations.last(where: { $0.horizontalAccuracy >= 0 }) else { return }
        latestLocation = CaptureLocation(location)
        provider.update(location: location)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if (error as? CLError)?.code == .denied { authorizationStatus = manager.authorizationStatus }
    }

    private func updateCollection(for status: CLAuthorizationStatus) {
        guard enabled, started else { manager.stopUpdatingLocation(); return }
        switch status {
        case .authorizedAlways, .authorizedWhenInUse: manager.startUpdatingLocation()
        default: manager.stopUpdatingLocation()
        }
    }

    deinit { precisionTask?.cancel() }

    var isAuthorized: Bool { authorizationStatus == .authorizedAlways || authorizationStatus == .authorizedWhenInUse }
    var hasCurrentLocation: Bool {
        guard let latestLocation else { return false }
        return abs(Date().timeIntervalSince(latestLocation.measuredAt)) <= 60
    }
    var statusIcon: String {
        if hasCurrentLocation { return "location.fill" }
        if isAuthorized || authorizationStatus == .notDetermined { return "location" }
        return "location.slash"
    }
    var statusText: String {
        if hasCurrentLocation { return "位置已就绪" }
        if isAuthorized { return "正在定位" }
        if authorizationStatus == .notDetermined { return "开启拍摄位置" }
        return "未记录位置"
    }
}
