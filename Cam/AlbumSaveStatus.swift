import Foundation
import SwiftUI
import UIKit

enum AlbumSaveStage: String { case queued, preparing, writing }

struct AlbumSaveTiming: Codable, Equatable {
    var queueSeconds: Double
    var prepareSeconds: Double
    var writeSeconds: Double
}

struct AlbumDownloadReceipt: Codable, Equatable, Identifiable {
    var id: UUID
    var mode: MemoryExportMode
    var attemptedAt: Date
    var phase: AlbumSaveReceipt.Phase
    var assetIdentifier: String?
    var message: String?
}

enum AlbumItemSaveState: Equatable {
    case unknown, waiting(String), preparing, writing, saved, failed, uncertain
    var title: String {
        switch self {
        case .unknown: "待确认"
        case .waiting: "待保存"
        case .preparing: "处理中"
        case .writing: "存入相册中"
        case .saved: "已存相册"
        case .failed: "保存失败"
        case .uncertain: "结果待确认"
        }
    }
    var symbol: String {
        switch self {
        case .saved: "checkmark.circle.fill"
        case .failed, .uncertain: "exclamationmark.circle"
        case .preparing, .writing: "arrow.down.circle"
        case .waiting: "clock"
        case .unknown: "questionmark.circle"
        }
    }
    var needsAttention: Bool { self == .failed || self == .uncertain }
    var detail: String {
        switch self {
        case .waiting(let reason): reason
        case .unknown: "没有可靠的保存记录，请在系统相册核对。"
        case .preparing: "准备保存…"
        case .writing: "正在保存到相册…"
        case .saved: "已保存到系统相册"
        case .failed: "保存尚未完成，请重试。原片仍保留在 App 中。"
        case .uncertain: "有一项保存结果待确认，请先查看系统相册，再决定是否重试。"
        }
    }
    static func resolve(automatic: Bool, receipt: AlbumSaveReceipt?, damaged: Bool,
                        active: AlbumSaveStage?, waiting: String,
                        downloads: [AlbumDownloadReceipt]) -> Self {
        if let active {
            switch active { case .queued: return .waiting("正在排队"); case .preparing: return .preparing; case .writing: return .writing }
        }
        if damaged { return .uncertain }
        if automatic {
            switch receipt?.phase {
            case .saved: return .saved
            case .failed: return .failed
            case .writing: return .uncertain
            case nil: return .waiting(waiting)
            }
        }
        if downloads.contains(where: { $0.phase == .saved }) { return .saved }
        if downloads.contains(where: { $0.phase == .writing }) { return .uncertain }
        if downloads.contains(where: { $0.phase == .failed }) { return .failed }
        return .unknown
    }
}

extension AlbumSaveStore {
    func downloads(_ id: UUID) throws -> [AlbumDownloadReceipt] {
        let url = disk.folder(for: id).appendingPathComponent("album-downloads.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([AlbumDownloadReceipt].self, from: Data(contentsOf: url))
    }
    // Called on the main actor by the manual exporter; automatic receipts use a
    // separate file, so a Photos transaction cannot overwrite the other history.
    @MainActor func writeDownload(_ value: AlbumDownloadReceipt, for id: UUID) throws {
        var values = try downloads(id)
        values.removeAll { $0.id == value.id }
        values.append(value)
        try JSONEncoder().encode(values).write(to: disk.folder(for: id).appendingPathComponent("album-downloads.json"), options: .atomic)
    }
}

struct AlbumStatusBadge: View {
    let state: AlbumItemSaveState
    var body: some View {
        Label(L10n.text(state.title), systemImage: state.symbol)
            .font(.system(size: 10, weight: .medium))
            .lineLimit(1).minimumScaleFactor(0.75)
            .foregroundStyle(state.needsAttention ? .yellow : .white)
            .padding(.horizontal, 7).padding(.vertical, 5)
            .background(.black.opacity(0.65), in: Capsule())
    }
}

struct SystemPhotosButton: View {
    @Environment(\.captureAccess) private var captureAccess
    @State private var issue: String?
    var body: some View {
        Button {
            Task { @MainActor in
                if captureAccess.isLocked {
                    do { try await captureAccess.open() }
                    catch { issue = "请解锁后打开系统相册。" }
                    return
                }
                #if !CAM_CAPTURE_EXTENSION
                // Photos' URL route is not a documented per-asset API. Check the
                // actual launch result, never synthesize a deep link from an ID.
                guard let url = URL(string: "photos-redirect://"), await UIApplication.shared.open(url) else {
                    issue = "无法打开系统相册，请从主屏幕打开“照片”。"; return
                }
                #endif
            }
        } label: { Label(L10n.text("系统相册"), systemImage: "arrow.up.forward.app") }
        .accessibilityIdentifier("openSystemPhotos")
        .alert(L10n.text("系统相册"), isPresented: Binding(get: { issue != nil }, set: { if !$0 { issue = nil } })) {
            Button(L10n.text("知道了")) { issue = nil }
        } message: { Text(L10n.text(issue ?? "")) }
    }
}

struct AlbumSaveStatusSheet: View {
    let item: MemoryItem
    @ObservedObject var saver: AutoAlbumSaver
    @Environment(\.dismiss) private var dismiss
    @Environment(\.captureAccess) private var captureAccess
    @State private var confirmRetry = false
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label(L10n.text(saver.state(for: item).title), systemImage: saver.state(for: item).symbol)
                    Text(L10n.text(saver.state(for: item).detail)).font(.footnote).foregroundStyle(.secondary)
                    if let failure = saver.failures[item.id] {
                        Text(L10n.text(failure)).font(.footnote).foregroundStyle(.secondary)
                        #if !CAM_CAPTURE_EXTENSION
                        Button(L10n.text("设置照片添加权限")) {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        }
                        #endif
                    }
                    if let mode = item.albumSaveMode {
                        LabeledContent(L10n.text("自动保存"), value: L10n.text(mode.title))
                    }
                    if let receipt = saver.savedReceipt(for: item.id), receipt.phase == .saved {
                        Text(L10n.text("已保存 \(receipt.assetIdentifiers?.count ?? 1) 份"))
                    }
                    if saver.state(for: item).needsAttention {
                        Button(L10n.text("重试保存")) {
                            if captureAccess.isLocked { Task { try? await captureAccess.open() } }
                            else if saver.state(for: item) == .uncertain { confirmRetry = true }
                            else { saver.retry(itemID: item.id) }
                        }.disabled(item.albumSaveMode == nil || !saver.canRetry(item.id))
                    }
                }
                let history = saver.downloads[item.id] ?? []
                if !history.isEmpty {
                    Section(L10n.text("手动另存")) {
                        ForEach(history.reversed()) { entry in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(L10n.text(entry.mode.title)); Spacer()
                                    Text(L10n.text(entry.phase == .saved ? "已存相册" : entry.phase == .failed ? "保存失败" : saver.isManualActive(item.id) ? "存入相册中" : "结果待确认"))
                                }
                                Text(entry.attemptedAt, format: .dateTime.locale(L10n.locale).month().day().hour().minute())
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section {
                    SystemPhotosButton()
                } footer: {
                    Text(L10n.text("这里记录保存成功的历史；在系统相册中删除的内容不会自动补存。"))
                }
            }
            .navigationTitle(L10n.text("相册保存状态")).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.text("完成")) { dismiss() } } }
            .confirmationDialog(L10n.text("请先核对系统相册"), isPresented: $confirmRetry, titleVisibility: .visible) {
                Button(L10n.text("确认未保存，重新保存")) { saver.retry(itemID: item.id, includeUncertain: true) }
                Button(L10n.text("取消"), role: .cancel) {}
            } message: { Text(L10n.text("重新保存可能产生重复内容。")) }
        }.preferredColorScheme(.dark).presentationDetents([.medium, .large])
    }
}
