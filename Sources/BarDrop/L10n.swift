import Foundation

/// Sprache der Oberfläche. Englisch ist Standard, Deutsch lässt sich in den
/// Einstellungen wählen. Die Texte stehen direkt im Code nebeneinander
/// (`L("English", "Deutsch")`), damit beide Fassungen immer zusammen gepflegt werden.
enum AppLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case german = "de"

    var id: String { rawValue }

    /// Jeweils in der eigenen Sprache, damit man die eigene immer findet
    var title: String {
        switch self {
        case .english: return "English"
        case .german: return "Deutsch"
        }
    }

    var locale: Locale { Locale(identifier: self == .german ? "de_DE" : "en_US") }
}

/// Text in der gewählten Sprache.
func L(_ english: String, _ german: String) -> String {
    AppSettings.shared.language == .german ? german : english
}

enum Format {
    /// Prozent mit landesüblichem Abstand: „20%“ bzw. „20 %“
    static func percent(_ value: Int) -> String {
        L("\(value)%", "\(value) %")
    }
}
