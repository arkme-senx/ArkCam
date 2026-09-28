import AVFoundation
import Foundation

// Classify actual capture/write failures, including AVFoundation's wrapped
// filesystem errors. Capacity estimates are not evidence that a write failed.
enum CaptureStorageFailure: Equatable {
    case outOfSpace
    case accessDenied

    static func classify(_ error: Error) -> Self? {
        var current: NSError? = error as NSError
        for _ in 0..<12 {
            guard let value = current else { break }
            if (value.domain == NSCocoaErrorDomain && value.code == CocoaError.fileWriteOutOfSpace.rawValue)
                || (value.domain == NSPOSIXErrorDomain && value.code == Int(ENOSPC))
                || (value.domain == AVFoundationErrorDomain && value.code == AVError.diskFull.rawValue) {
                return .outOfSpace
            }
            if (value.domain == NSCocoaErrorDomain && value.code == CocoaError.fileWriteNoPermission.rawValue)
                || (value.domain == NSPOSIXErrorDomain && [Int(EACCES), Int(EPERM)].contains(value.code)) {
                return .accessDenied
            }
            current = value.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return nil
    }

    static func message(for error: Error) -> String {
        switch classify(error) {
        case .outOfSpace:
            return "保存失败：系统报告存储空间不足，请腾出空间后重试。"
        case .accessDenied:
            return "无法访问拍摄保存目录，请解锁后重新打开双面 Cam 再试。"
        case nil:
            return error.localizedDescription
        }
    }
}
