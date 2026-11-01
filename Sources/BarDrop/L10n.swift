import Foundation

/// Sprache der Oberfläche. Englisch ist Standard, Deutsch lässt sich in den
/// Einstellungen wählen. Die Texte stehen direkt im Code nebeneinander
/// (`L("English", "Deutsch")`), damit beide Fassungen immer zusammen gepflegt werden.
enum AppLanguage: String, CaseIterable, Identifiable {
    /// Wie macOS: die erste der bevorzugten Sprachen des Systems, die BarDrop kann,
    /// sonst Englisch
    case system = "system"
    case english = "en"
    case german = "de"

    var id: String { rawValue }

    /// Jeweils in der eigenen Sprache, damit man die eigene immer findet
    var title: String {
        switch self {
        case .system: return "System"
        case .english: return "English"
        case .german: return "Deutsch"
        }
    }

    /// Die tatsächlich verwendete Sprache (nie `.system`)
    var resolved: AppLanguage {
        self == .system ? Self.systemLanguage() : self
    }

    /// Sprache für „Wie System“, nach den bevorzugten Sprachen in den Systemeinstellungen
    static func systemLanguage(preferred: [String] = Locale.preferredLanguages) -> AppLanguage {
        for identifier in preferred {
            let code = Locale(identifier: identifier).language.languageCode?.identifier
                ?? String(identifier.prefix(2))
            if code == "de" { return .german }
            if code == "en" { return .english }
        }
        return .english
    }

    var locale: Locale { Locale(identifier: resolved == .german ? "de_DE" : "en_US") }

    /// Aktuelle Sprache, auch aus Hintergrund-Threads sicher lesbar (z. B. beim
    /// Benennen neu übernommener Dateien). Gesetzt von `AppSettings`.
    static var current: AppLanguage {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
    private static let lock = NSLock()
    private static var stored: AppLanguage = .english
}

/// Text in der gewählten Sprache.
func L(_ english: String, _ german: String) -> String {
    AppLanguage.current == .german ? german : english
}

enum Format {
    /// Prozent mit landesüblichem Abstand: „20%“ bzw. „20 %“
    static func percent(_ value: Int) -> String {
        L("\(value)%", "\(value) %")
    }
}
