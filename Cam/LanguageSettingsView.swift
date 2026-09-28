import SwiftUI

struct LanguageSettingsView: View {
    @AppStorage("cameraLanguage") private var selection = "system"
    var body: some View {
        List {
            Section {
                row(.system)
            } footer: {
                Text(L10n.text("未手动选择时，使用系统首选语言；不支持的语言使用英语。"))
            }
            Section {
                ForEach(AppLanguage.allCases.filter { $0 != .system }) { language in row(language) }
            }
        }
        .navigationTitle(L10n.languageTitle)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("languageSettings")
    }
    private func row(_ language: AppLanguage) -> some View {
        Button { selection = language.rawValue } label: {
            HStack {
                Text(verbatim: language.nativeName).foregroundStyle(.primary)
                Spacer()
                if selection == language.rawValue { Image(systemName: "checkmark").foregroundStyle(.yellow) }
            }.padding(.vertical, 3).contentShape(Rectangle())
        }
        .accessibilityIdentifier("language-" + language.rawValue)
        .accessibilityValue(selection == language.rawValue ? L10n.text("已选择") : L10n.text("未选择"))
    }
}
