import SwiftUI
import UIKit

/// Pre-release destinations stay local until real services and documents exist.
struct AboutScreen: View {
    @AppStorage("cameraLanguage") private var interfaceLanguage = "system"
    @State private var noticeTitle: String?
    private static let logo: UIImage = {
        let image = Bundle.main.url(forResource: "ArkCamLogo", withExtension: "png")
            .flatMap { UIImage(contentsOfFile: $0.path) }
        return image ?? UIImage(systemName: "camera")!
    }()

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }
    private var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }

    var body: some View {
        let _ = interfaceLanguage
        List {
            Section {
                VStack(spacing: 10) {
                    Image(uiImage: Self.logo)
                        .resizable().scaledToFit()
                        .frame(width: 80, height: 80)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .accessibilityHidden(true)
                    Text(verbatim: "ArkCam").font(.title2.weight(.semibold))
                    Text(L10n.text("版本") + " \(version) (\(build))")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .monospacedDigit().textSelection(.enabled)
                        .accessibilityIdentifier("aboutVersion")
                }
                .frame(maxWidth: .infinity).padding(.vertical, 16)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
            Section {
                pendingAction("检查更新", symbol: "arrow.triangle.2.circlepath", id: "aboutCheckUpdates")
                pendingAction("给个好评", symbol: "star", id: "aboutRateApp")
            }
            Section {
                ForEach(AboutDocument.allCases) { document in
                    NavigationLink {
                        AboutPlaceholderScreen(document: document)
                    } label: {
                        row(document.title, symbol: document.symbol,
                            status: document == .registration ? "待补充" : nil)
                    }
                    .accessibilityIdentifier("about-" + document.rawValue)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(L10n.text("关于 ArkCam"))
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("aboutScreen")
        .alert(L10n.text(noticeTitle ?? ""), isPresented: Binding(
            get: { noticeTitle != nil }, set: { if !$0 { noticeTitle = nil } }
        )) {
            Button(L10n.text("知道了"), role: .cancel) { noticeTitle = nil }
        } message: {
            Text(L10n.text("正式上线后开放。"))
        }
    }

    private func pendingAction(_ title: String, symbol: String, id: String) -> some View {
        Button { noticeTitle = title } label: {
            HStack(spacing: 10) {
                row(title, symbol: symbol, status: "待上线")
                Image(systemName: "chevron.forward")
                    .font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityIdentifier(id)
    }

    private func row(_ title: String, symbol: String, status: String?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.body).frame(width: 22)
                .foregroundStyle(.secondary).accessibilityHidden(true)
            Text(L10n.text(title)).foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let status {
                Text(L10n.text(status)).font(.subheadline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }
}

private enum AboutDocument: String, CaseIterable, Identifiable {
    case terms, privacy, registration
    var id: String { rawValue }
    var title: String {
        switch self {
        case .terms: "用户协议"
        case .privacy: "隐私条款"
        case .registration: "备案信息"
        }
    }
    var symbol: String {
        switch self {
        case .terms: "doc.text"
        case .privacy: "hand.raised"
        case .registration: "building.2"
        }
    }
}

private struct AboutPlaceholderScreen: View {
    @AppStorage("cameraLanguage") private var interfaceLanguage = "system"
    let document: AboutDocument

    var body: some View {
        let _ = interfaceLanguage
        ContentUnavailableView(L10n.text("内容待补充"), systemImage: document.symbol,
            description: Text(L10n.text("内容将在正式上线前补充。")))
            .navigationTitle(L10n.text(document.title))
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("aboutPlaceholder-" + document.rawValue)
    }
}

#if DEBUG
/// Preview the actual destination without starting camera capture.
struct AboutPreview: View {
    var body: some View {
        NavigationStack {
            if let value = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--about-document=") })?.split(separator: "=").last,
               let document = AboutDocument(rawValue: String(value)) {
                AboutPlaceholderScreen(document: document)
            } else {
                AboutScreen()
            }
        }
        .modifier(LocalizedInterface())
        .preferredColorScheme(.dark)
        .tint(.white)
    }
}
#endif
