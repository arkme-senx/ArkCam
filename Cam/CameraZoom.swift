import Foundation

struct CameraZoomPreset: Identifiable, Equatable {
    let factor: Double
    var focalLength: Double? = nil
    var id: Double { factor }
    var title: String { factor == 1 ? "1×" : Self.number(factor) }
    static func number(_ value: Double) -> String {
        L10n.number(abs(value - value.rounded()) < 0.025 ? value.rounded() : value)
    }
}

enum CameraZoomScale {
    static func stops(minimum: Double, telephoto: Double?, sensorCrop: Bool,
                      calibration: CameraFocalCalibration?, extraFactors: [Double] = []) -> [CameraZoomPreset] {
        var values = [1.0]
        if minimum < 0.9 { values.insert(minimum, at: 0) }
        if sensorCrop { values.append(2) }
        values.append(contentsOf: extraFactors.filter { $0.isFinite && $0 > 1 })
        if let telephoto, telephoto > 1.1 { values.append(telephoto) }
        return Array(Set(values)).sorted().map { value in
            let mm: Double?
            if value < 1 { mm = calibration?.ultraWide }
            else if value == telephoto { mm = calibration?.telephoto }
            else { mm = calibration.map { $0.main * value } }
            return CameraZoomPreset(factor: value, focalLength: mm)
        }
    }

    static func dragged(from origin: Double, points: Double, range: ClosedRange<Double>) -> Double {
        // The full range fits a comfortable sweep on a 375 pt display. Log
        // spacing preserves fine relative adjustment at the lower magnifications.
        let span = log(range.upperBound / range.lowerBound)
        return min(range.upperBound, max(range.lowerBound, origin * exp(points * span / 200)))
    }

    static func selectedStop(for value: Double, stops: [CameraZoomPreset]) -> Double {
        stops.last(where: { $0.factor <= value + 0.00001 })?.factor ?? stops.first?.factor ?? 1
    }
}

enum CameraZoomPolicy {
    // These are product limits, not the number of physical cameras. Always
    // intersect them with the actual route's range before offering a control.
    static func maximum(hardware: String, video: Bool, available: Double,
                        hasTelephoto: Bool, sensorCrop: Bool, telephotoFactor: Double? = nil, nativeTelephotoCrop: Double? = nil) -> Double {
        let reference = CameraModelReference.known[hardware]
        let optical = max(1, telephotoFactor ?? (hasTelephoto ? 2 : 1))
        let crop = max(optical, nativeTelephotoCrop ?? optical)
        let fallback: Double = hasTelephoto
            ? (video ? min(15, floor(optical * 3) + (crop >= 8 ? 3 : 0)) : min(40, floor(crop * 5)))
            : (sensorCrop ? (video ? 6 : 10) : (video ? 3 : 5))
        let limit = reference.map { video ? $0.video : $0.photo } ?? fallback
        return max(1, min(limit, available))
    }

    static func rampRate(from: Double, to: Double, duration: Double = 0.22) -> Float {
        Float(min(24, max(4, abs(log2(max(0.001, to) / max(0.001, from))) / duration)))
    }

    static func frontRange(minimum: Double, maximum: Double, nativeCrop: Double? = nil) -> ClosedRange<Double> {
        let lower = max(1, minimum)
        return lower...max(lower, min(maximum, max(lower, nativeCrop ?? lower * 1.3)))
    }
}

enum CameraZoomDialGeometry {
    static let radius = 204.0
    static let labelRadius = 164.0
    static let sweep = 1.8
    static let visibleAngle = 1.24

    // A single rigid scale rotates beneath the pointer. Never pin endpoints or
    // redistribute labels as the value changes: that makes a dial look stuck.
    static func angle(_ factor: Double, value: Double, range: ClosedRange<Double>) -> Double {
        log(factor / value) * sweep / max(0.001, log(range.upperBound / range.lowerBound))
    }

    static func labels(value: Double, stops: [CameraZoomPreset], range: ClosedRange<Double>) -> [(CameraZoomPreset, Double)] {
        var anchors = stops.filter { range.contains($0.factor) }
        if !anchors.contains(where: { abs($0.factor - range.upperBound) < 0.001 }) {
            anchors.append(CameraZoomPreset(factor: range.upperBound))
        }
        return anchors.map { ($0, angle($0.factor, value: value, range: range)) }
            .filter { abs($0.1) > 0.14 && abs($0.1) < visibleAngle }
    }
}

// Labels only. Lens availability and routing always come from AVFoundation.
// Unknown hardware retains zoom controls without inventing focal lengths.
struct CameraFocalCalibration {
    let main: Double
    let ultraWide: Double?
    let telephoto: Double?

    static func known(_ hardware: String) -> Self? { CameraModelReference.known[hardware]?.focal }
}
