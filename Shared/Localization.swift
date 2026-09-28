import Foundation
import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable {
    case system, simplifiedChinese = "zh-Hans", traditionalChinese = "zh-Hant"
    case english = "en", japanese = "ja", korean = "ko", spanish = "es", french = "fr"
    case german = "de", italian = "it", portuguese = "pt-BR", russian = "ru"
    case arabic = "ar", hindi = "hi", indonesian = "id", thai = "th", vietnamese = "vi"
    var id: String { rawValue }
    var nativeName: String {
        switch self {
        case .system: return L10n.text("跟随系统")
        case .simplifiedChinese: return "简体中文"
        case .traditionalChinese: return "繁體中文"
        case .english: return "English"
        case .japanese: return "日本語"
        case .korean: return "한국어"
        case .spanish: return "Español"
        case .french: return "Français"
        case .german: return "Deutsch"
        case .italian: return "Italiano"
        case .portuguese: return "Português (Brasil)"
        case .russian: return "Русский"
        case .arabic: return "العربية"
        case .hindi: return "हिन्दी"
        case .indonesian: return "Bahasa Indonesia"
        case .thai: return "ไทย"
        case .vietnamese: return "Tiếng Việt"
        }
    }
    static func resolved(_ selection: String, preferred: [String] = Locale.preferredLanguages) -> AppLanguage {
        if let explicit = Self(rawValue: selection), explicit != .system { return explicit }
        for identifier in preferred {
            let code = identifier.replacingOccurrences(of: "_", with: "-").lowercased()
            if code.hasPrefix("zh") {
                return code.contains("hant") || code.contains("-tw") || code.contains("-hk") || code.contains("-mo") ? .traditionalChinese : .simplifiedChinese
            }
            if code.hasPrefix("pt") { return .portuguese }
            if let language = Self.allCases.first(where: { $0 != .system && String(code.split(separator: "-").first ?? "") == $0.rawValue.lowercased() }) { return language }
        }
        return .english
    }
}

// Translate at the presentation boundary. Original capture notes remain stable
// on disk and can be displayed in another language after the setting changes.
enum L10n {
    static var language: AppLanguage { AppLanguage.resolved(UserDefaults.standard.string(forKey: "cameraLanguage") ?? "system") }
    static var locale: Locale { Locale(identifier: language.rawValue) }
    static var languageTitle: String { language == .english ? "Language" : text("语言") + " / Language" }
    static var direction: LayoutDirection { language == .arabic ? .rightToLeft : .leftToRight }
    private struct Table {
        let values: [String: String]
        let patterns: [(NSRegularExpression, String)]
        let fragments: [(String, String)]
    }
    private static let tables: [String: Table] = {
        var result: [String: Table] = [:]
        let token = try! NSRegularExpression(pattern: #"%(?:[0-9]+\$)?[+0-9.]*[@df]"#)
        for language in AppLanguage.allCases where language != .system {
            guard let folder = Bundle.main.url(forResource: language.rawValue, withExtension: "lproj"),
                  let data = try? Data(contentsOf: folder.appendingPathComponent("Localizable.strings")),
                  let values = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: String] else { continue }
            var patterns: [(NSRegularExpression, String)] = []
            for key in values.keys.sorted(by: { $0.count > $1.count }) {
                let matches = token.matches(in: key, range: NSRange(key.startIndex..., in: key))
                guard !matches.isEmpty else { continue }
                let source = key as NSString
                var pattern = "^", start = 0
                for match in matches {
                    pattern += NSRegularExpression.escapedPattern(for: source.substring(with: NSRange(location: start, length: match.range.location - start))) + "([\\s\\S]*?)"
                    start = NSMaxRange(match.range)
                }
                pattern += NSRegularExpression.escapedPattern(for: source.substring(from: start)) + "$"
                if let regex = try? NSRegularExpression(pattern: pattern) { patterns.append((regex, values[key]!)) }
            }
            let fragments = values.filter { !$0.key.contains("%") && $0.key.count > 1 }
                .sorted { $0.key.count > $1.key.count }.map { ($0.key, $0.value) }
            result[language.rawValue] = Table(values: values, patterns: patterns, fragments: fragments)
        }
        return result
    }()

    static func text(_ source: String, language: AppLanguage? = nil) -> String {
        // Camera timers and live zoom labels contain no translatable source
        // prose; avoid scanning message templates on every numeric update.
        guard source.unicodeScalars.contains(where: { (0x3400...0x9FFF).contains(Int($0.value)) }) else { return source }
        let selected = language ?? self.language
        guard selected != .simplifiedChinese, let table = tables[selected.rawValue] else { return source }
        return resolve(source, table: table, depth: 0)
    }
    private static func resolve(_ source: String, table: Table, depth: Int) -> String {
        if let exact = table.values[source] { return exact }
        guard depth < 5 else { return source }
        for (regex, translation) in table.patterns {
            guard let match = regex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)) else { continue }
            let raw = source as NSString
            let arguments = (1..<match.numberOfRanges).map { resolve(raw.substring(with: match.range(at: $0)), table: table, depth: depth + 1) }
            return String(format: translation, arguments: arguments.map { $0 as CVarArg })
        }
        // Legacy notes may concatenate independently generated errors.
        for (key, translation) in table.fragments {
            if source.hasPrefix(key) { return translation + resolve(String(source.dropFirst(key.count)), table: table, depth: depth + 1) }
            if source.hasSuffix(key) { return resolve(String(source.dropLast(key.count)), table: table, depth: depth + 1) + translation }
        }
        return source
    }
    static func number(_ value: Double, digits: Int = 1) -> String {
        value.formatted(.number.locale(locale).precision(.fractionLength(0...digits)).grouping(.never))
    }
}

struct LocalizedInterface: ViewModifier {
    @AppStorage("cameraLanguage") private var selection = "system"
    func body(content: Content) -> some View {
        let language = AppLanguage.resolved(selection)
        content.environment(\.locale, Locale(identifier: language.rawValue))
            .environment(\.layoutDirection, language == .arabic ? .rightToLeft : .leftToRight)
    }
}
