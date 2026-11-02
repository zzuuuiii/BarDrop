import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Text in Englisch und Deutsch. Im Manifest entweder ein einfacher Text (gilt für beide
/// Sprachen) oder `{"en": "…", "de": "…"}`. Fehlt die Sprache, gilt Englisch.
struct LocalizedText: Codable, Hashable {
    var values: [String: String]

    init(_ english: String, _ german: String? = nil) {
        values = ["en": english]
        if let german { values["de"] = german }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let single = try? container.decode(String.self) {
            values = ["en": single]
        } else {
            values = try container.decode([String: String].self)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if values.count == 1, let en = values["en"] {
            try container.encode(en)
        } else {
            try container.encode(values)
        }
    }

    /// Text in der Sprache der App
    var text: String { text(for: AppLanguage.current.resolved) }

    func text(for language: AppLanguage) -> String {
        let code = language == .german ? "de" : "en"
        return values[code] ?? values["en"] ?? values.sorted { $0.key < $1.key }.first?.value ?? ""
    }
}

/// Rechte, die ein Plugin braucht. Jedes wird beim ersten Gebrauch erfragt.
enum PluginPermission: String, Codable, CaseIterable, Identifiable {
    /// Webseiten und Dateien aus dem Internet laden
    case network
    /// Programme ausführen (auch nachgeladene Werkzeuge). Damit hat ein Plugin
    /// praktisch dieselben Rechte wie jede andere App auf dem Mac.
    case run
    /// Text in die Zwischenablage legen
    case clipboard

    var id: String { rawValue }

    var title: String {
        switch self {
        case .network: return L("Internet access", "Internetzugriff")
        case .run: return L("Run programs", "Programme ausführen")
        case .clipboard: return L("Clipboard", "Zwischenablage")
        }
    }

    /// Kurz unter dem Recht auf der Seite „Zugriff“. Die Bitte, nur Vertrautem zu erlauben,
    /// steht im Erlauben-Fenster (PluginDialogs), nicht dauerhaft auch hier
    var explanation: String {
        switch self {
        case .network:
            return L("The plugin can load web pages and download files.", "Das Plugin kann Webseiten und Dateien laden.")
        case .run:
            return L("Full access to your Mac.", "Voller Zugriff auf deinen Mac.")
        case .clipboard:
            return L("It can put text on the clipboard.", "Es kann Text in die Zwischenablage legen.")
        }
    }

    /// Zeile in den Listen der Fenster (Import, Erlauben)
    var summary: String {
        switch self {
        case .network: return L("Internet access", "Internetzugriff")
        case .run: return L("Run programs (full access to your Mac)", "Programme ausführen (voller Zugriff auf deinen Mac)")
        case .clipboard: return L("Clipboard", "Zwischenablage")
        }
    }

    var symbol: String {
        switch self {
        case .network: return "globe"
        case .run: return "terminal.fill"
        case .clipboard: return "doc.on.clipboard"
        }
    }

    /// Rechte, die nie still im Hintergrund wirken dürfen: Mit ihnen darf ein Plugin
    /// „Automatisch beim Ablegen“ nicht selbst einschalten.
    var isSensitive: Bool { self != .clipboard }
}

/// Wege, auf denen ein Plugin gestartet werden kann.
enum PluginTrigger: String, Codable, CaseIterable {
    /// Rechtsklick auf ein passendes Objekt
    case menu
    /// Als Aktion in der Aktionsleiste
    case action
    /// Automatisch beim Ablegen eines passenden Objekts
    case automatic
}

/// Wofür ein Plugin zuständig ist. Ein Objekt passt, wenn eine der Angaben passt.
struct PluginMatch: Codable, Hashable {
    /// Uniform Type Identifiers, z. B. `public.image`, `com.adobe.pdf`. Ein Objekt passt
    /// auch, wenn sein Typ davon abgeleitet ist (ein PNG ist ein `public.image`).
    var types: [String]?
    /// Dateiendungen ohne Punkt, z. B. `png`
    var extensions: [String]?
    /// Links (in der Ablage als .webloc gespeichert)
    var links: LinkMatch?

    struct LinkMatch: Codable, Hashable {
        /// Domains; `example.com` passt auch zu `www.example.com`. `*` passt zu allen Links.
        var hosts: [String]?
        /// Reguläre Ausdrücke auf die ganze Adresse
        var patterns: [String]?
    }
}

/// Einstellung eines Plugins, aus dem Manifest im Plugin-Reiter dargestellt.
struct PluginSettingSpec: Codable, Hashable, Identifiable {
    enum Kind: String, Codable {
        case toggle, choice, text
    }

    struct Option: Codable, Hashable {
        var value: String
        var title: LocalizedText
    }

    var key: String
    var type: Kind
    var title: LocalizedText
    var info: LocalizedText?
    var `default`: PluginValue?
    var options: [Option]?

    var id: String { key }

    var defaultValue: PluginValue {
        if let value = `default` { return value }
        switch type {
        case .toggle: return .bool(false)
        case .choice: return .string(options?.first?.value ?? "")
        case .text: return .string("")
        }
    }
}

/// Wert einer Plugin-Einstellung
enum PluginValue: Codable, Hashable {
    case bool(Bool)
    case string(String)
    case number(Double)

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let d = try? c.decode(Double.self) { self = .number(d) }
        else { self = .string(try c.decode(String.self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .bool(let b): try c.encode(b)
        case .string(let s): try c.encode(s)
        case .number(let d): try c.encode(d)
        }
    }

    var any: Any {
        switch self {
        case .bool(let b): return b
        case .string(let s): return s
        case .number(let d): return d
        }
    }

    var bool: Bool {
        switch self {
        case .bool(let b): return b
        case .string(let s): return s == "true"
        case .number(let d): return d != 0
        }
    }

    var string: String {
        switch self {
        case .bool(let b): return b ? "true" : "false"
        case .string(let s): return s
        // Int(d) stürzt bei sehr großen Zahlen (ab etwa 9,2e18) und bei unendlich ab
        case .number(let d): return d == d.rounded() && abs(d) < 1e15 ? String(Int64(d)) : String(d)
        }
    }
}

/// Ein Programm, das ein Plugin braucht und das BarDrop erst nach Zustimmung lädt
/// (nach ~/Library/Application Support/BarDrop/Tools). Es gehört nicht zu BarDrop.
struct PluginTool: Codable, Hashable, Identifiable {
    /// Name, unter dem das Plugin es mit `bardrop.run("<id>", …)` aufruft
    var id: String
    var name: String
    /// Download-Adresse (nur https)
    var url: String
    /// SHA-256 der Datei. Entweder dieser Wert …
    var sha256: String?
    /// … oder eine Prüfsummendatei des Herausgebers (Zeilen „<sha256>  <Dateiname>“),
    /// für Werkzeuge, die sich oft aktualisieren (die Adresse zeigt dann auf „latest“)
    var checksums: String?
    var homepage: String?
    var license: String?
    /// Werkzeug, das sich oft ändern muss (z. B. weil Webseiten sich ändern): BarDrop
    /// lädt es dann höchstens einmal pro Woche neu
    var refreshDays: Int?
    /// `"zip"`: Die Adresse liefert ein ZIP-Archiv; darin liegt das Programm unter `executable`
    var archive: String?
    /// Pfad des Programms im Archiv (nur mit `archive`), z. B. `"tool"` oder `"bin/tool"`
    var executable: String?
    /// `"arm64"` oder `"x86_64"`: nur für diesen Chip. Programme für den anderen Chip zeigt und
    /// lädt BarDrop gar nicht (für Herausgeber, deren Dateinamen nicht zu `{arch}` passen)
    var arch: String?

    /// Für den Chip dieses Mac (oder für alle)
    var isForThisMac: Bool {
        guard let arch else { return true }
        #if arch(arm64)
        return arch == "arm64"
        #else
        return arch == "x86_64"
        #endif
    }

    /// `{arch}` in `url` und `checksums` wird zur Architektur des Mac: `aarch64` (Apple Chip)
    /// oder `x86_64` (Intel)
    static var architecture: String {
        #if arch(arm64)
        return "aarch64"
        #else
        return "x86_64"
        #endif
    }

    var resolvedURL: String { url.replacingOccurrences(of: "{arch}", with: Self.architecture) }

    /// Wofür der Nutzer den Download erlaubt hat: dieses Programm von genau dieser Adresse.
    /// Ändert ein Update des Plugins die Adresse, wird neu gefragt.
    var approvalKey: String { id + "|" + resolvedURL }
    var resolvedChecksums: String? { checksums?.replacingOccurrences(of: "{arch}", with: Self.architecture) }
}

/// Inhalt von `manifest.json` in einem .bdrop-Paket.
struct PluginManifest: Codable, Hashable {
    /// Aufbau des Manifests; diese Version kennt 1
    var schema: Int = 1
    /// Eindeutig, in umgekehrter Domain-Schreibweise (`io.github.name.plugin`)
    var id: String
    var name: LocalizedText
    var description: LocalizedText?
    var version: String
    var author: String?
    var homepage: String?
    /// SF-Symbol (wie in Kurzbefehle) und Farbe der Kachel
    var icon: Icon?
    /// Titel im Rechtsklick-Menü und in der Aktionsleiste (sonst der Name)
    var actionTitle: LocalizedText?
    /// Älteste BarDrop-Version, mit der das Plugin läuft
    var minAppVersion: String?
    /// Skriptdatei im Paket
    var script: String = "main.js"
    var match: PluginMatch
    var triggers: [PluginTrigger]?
    /// Plugin möchte standardmäßig automatisch laufen. Gilt nur ohne heikle Rechte
    /// (Netzwerk, Programme): Die schaltet der Nutzer selbst ein.
    var automaticByDefault: Bool?
    var permissions: [PluginPermission]?
    var tools: [PluginTool]?
    var settings: [PluginSettingSpec]?
    /// Plugin kann das Original ersetzen (Schalter in seinen Einstellungen, standardmäßig aus)
    var canReplaceOriginal: Bool?
    /// Bei mehreren Objekten einmal mit allen laufen (`run(item, items)`), statt je Objekt
    var batch: Bool?
    /// Hinweis, dem der Nutzer beim Einschalten zustimmen muss (z. B. rechtliche Grenzen)
    var consent: LocalizedText?
    /// Wie das Plugin nach dem Installieren eingestellt ist (der Nutzer ändert es danach selbst)
    var defaults: Defaults?
    /// Ordner, die das Plugin selbst außerhalb von BarDrop einrichtet (z. B. eine Python-Umgebung),
    /// als „~/…“. „Plugin entfernen“ legt sie auf Wunsch mit in den Papierkorb (`installPaths`)
    var installs: [String]?

    struct Defaults: Codable, Hashable {
        /// Gleich als Aktion in der Aktionsleiste (wenn dort Platz ist)
        var actionBar: Bool?
        /// „Automatisch beim Ablegen“ an
        var automatic: Bool?
        /// „Original ersetzen“ an (nur mit `canReplaceOriginal`)
        var replaceOriginal: Bool?
    }

    struct Icon: Codable, Hashable {
        var symbol: String
        /// Farbe als #RRGGBB
        var color: String?
    }

    private enum CodingKeys: String, CodingKey {
        case schema, id, name, description, version, author, homepage, icon, actionTitle, minAppVersion,
             script, match, triggers, automaticByDefault, permissions, tools, settings, canReplaceOriginal, batch, consent,
             defaults, installs
    }

    init(id: String, name: LocalizedText, version: String, match: PluginMatch) {
        self.id = id
        self.name = name
        self.version = version
        self.match = match
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decodeIfPresent(Int.self, forKey: .schema) ?? 1
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(LocalizedText.self, forKey: .name)
        description = try c.decodeIfPresent(LocalizedText.self, forKey: .description)
        version = try c.decode(String.self, forKey: .version)
        author = try c.decodeIfPresent(String.self, forKey: .author)
        homepage = try c.decodeIfPresent(String.self, forKey: .homepage)
        icon = try c.decodeIfPresent(Icon.self, forKey: .icon)
        actionTitle = try c.decodeIfPresent(LocalizedText.self, forKey: .actionTitle)
        minAppVersion = try c.decodeIfPresent(String.self, forKey: .minAppVersion)
        script = try c.decodeIfPresent(String.self, forKey: .script) ?? "main.js"
        match = try c.decode(PluginMatch.self, forKey: .match)
        // Unbekannte Auslöser und Rechte einer neueren Fassung überspringen statt scheitern
        triggers = try c.decodeIfPresent([String].self, forKey: .triggers)?.compactMap(PluginTrigger.init(rawValue:))
        automaticByDefault = try c.decodeIfPresent(Bool.self, forKey: .automaticByDefault)
        let rawPermissions = try c.decodeIfPresent([String].self, forKey: .permissions) ?? []
        permissions = rawPermissions.compactMap(PluginPermission.init(rawValue:))
        unknownPermissions = rawPermissions.filter { PluginPermission(rawValue: $0) == nil }
        // Nur die Programme für diesen Mac: Fenster, Laden und Entfernen sehen die anderen nie
        tools = try c.decodeIfPresent([PluginTool].self, forKey: .tools)?.filter(\.isForThisMac)
        settings = try c.decodeIfPresent([PluginSettingSpec].self, forKey: .settings)
        canReplaceOriginal = try c.decodeIfPresent(Bool.self, forKey: .canReplaceOriginal)
        batch = try c.decodeIfPresent(Bool.self, forKey: .batch)
        consent = try c.decodeIfPresent(LocalizedText.self, forKey: .consent)
        defaults = try c.decodeIfPresent(Defaults.self, forKey: .defaults)
        installs = try? c.decodeIfPresent([String].self, forKey: .installs)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schema, forKey: .schema)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(description, forKey: .description)
        try c.encode(version, forKey: .version)
        try c.encodeIfPresent(author, forKey: .author)
        try c.encodeIfPresent(homepage, forKey: .homepage)
        try c.encodeIfPresent(icon, forKey: .icon)
        try c.encodeIfPresent(actionTitle, forKey: .actionTitle)
        try c.encodeIfPresent(minAppVersion, forKey: .minAppVersion)
        try c.encode(script, forKey: .script)
        try c.encode(match, forKey: .match)
        try c.encodeIfPresent(triggers, forKey: .triggers)
        try c.encodeIfPresent(automaticByDefault, forKey: .automaticByDefault)
        try c.encodeIfPresent(permissions, forKey: .permissions)
        try c.encodeIfPresent(tools, forKey: .tools)
        try c.encodeIfPresent(settings, forKey: .settings)
        try c.encodeIfPresent(canReplaceOriginal, forKey: .canReplaceOriginal)
        try c.encodeIfPresent(batch, forKey: .batch)
        try c.encodeIfPresent(consent, forKey: .consent)
        try c.encodeIfPresent(defaults, forKey: .defaults)
        try c.encodeIfPresent(installs, forKey: .installs)
    }

    /// Rechte im Manifest, die diese Version nicht kennt (das Plugin braucht eine neuere BarDrop)
    private(set) var unknownPermissions: [String] = []

    static func == (a: PluginManifest, b: PluginManifest) -> Bool {
        a.id == b.id && a.version == b.version && a.match == b.match && a.name == b.name
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(version)
    }

    var allTriggers: [PluginTrigger] { triggers ?? PluginTrigger.allCases }

    /// `installs` als Pfade, nur die erlaubten: im Benutzerordner, in einem versteckten Ordner
    /// (`~/.local/share/x`, `~/.cache/x`) oder unter `~/Library/Application Support/x` bzw.
    /// `~/Library/Caches/x`, mindestens eine Ebene unter diesen Ordnern. Nie Ordner mit eigenen
    /// Dateien des Nutzers oder Schlüsseln (Schreibtisch, Dokumente, `.ssh` …): Ein Plugin soll
    /// beim Entfernen nur wegräumen können, was es selbst angelegt hat.
    func installPaths(home: URL) -> [URL] {
        let blocked: Set<String> = [".ssh", ".gnupg", ".Trash", ".aws", ".kube", ".docker", ".config/gh", ".password-store"]
        var result: [URL] = []
        for raw in installs ?? [] {
            guard raw.hasPrefix("~/") else { continue }
            let parts = raw.dropFirst(2).split(separator: "/").map(String.init)
            guard !parts.isEmpty, !parts.contains(where: { $0 == ".." || $0 == "." || $0.isEmpty }) else { continue }
            let first = parts[0]
            let allowed: Bool
            if first == "Library" {
                allowed = parts.count >= 3 && ["Application Support", "Caches"].contains(parts[1])
                    && !["BarDrop", "com.zzuuuiii.bardrop"].contains(parts[2])
            } else {
                // `~/.local` ist ein Sammelordner mit Sammelordnern (`share`, `bin`): Erst darunter
                // beginnt der Ordner eines Programms (`~/.local/share/x`). Vorher hätte
                // „~/.local/share“ alles darin in den Papierkorb gelegt (Prüfung 28.10.2026)
                let minimum = first == ".local" ? 3 : 2
                allowed = first.hasPrefix(".") && parts.count >= minimum
                    && !blocked.contains(first) && !blocked.contains(parts.prefix(2).joined(separator: "/"))
            }
            guard allowed else { continue }
            let url = parts.reduce(home) { $0.appendingPathComponent($1, isDirectory: true) }.standardizedFileURL
            if !result.contains(url) { result.append(url) }
        }
        return result
    }
    var allPermissions: [PluginPermission] { permissions ?? [] }
    var title: String { (actionTitle ?? name).text }

    /// Hat das Plugin Rechte, mit denen es nicht still im Hintergrund laufen soll?
    var needsSensitivePermissions: Bool {
        allPermissions.contains { $0.isSensitive } || !(tools ?? []).isEmpty
    }

    /// Standardwert für „Automatisch beim Ablegen“
    var automaticDefault: Bool {
        automaticByDefault == true && allTriggers.contains(.automatic) && !needsSensitivePermissions
    }

    // MARK: Prüfen

    enum ValidationError: Error, Equatable {
        case unsupportedSchema(Int)
        case invalidID
        case missingName
        case invalidVersion
        case nothingToMatch
        case invalidPattern(String)
        case unknownPermission(String)
        case insecureToolURL(String)
        case missingChecksum(String)
        case needsNewerApp(String)
        case invalidScriptName
        case invalidTool(String)
        case noTrigger
    }

    /// Prüft das Manifest. `appVersion`: laufende Version von BarDrop.
    func validate(appVersion: String) throws {
        guard schema == 1 else { throw ValidationError.unsupportedSchema(schema) }
        let idPattern = #"^[A-Za-z0-9][A-Za-z0-9-]*(\.[A-Za-z0-9][A-Za-z0-9-]*)+\z"#
        guard id.range(of: idPattern, options: .regularExpression) != nil, id.count <= 120 else {
            throw ValidationError.invalidID
        }
        guard !name.text(for: .english).trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ValidationError.missingName
        }
        guard version.range(of: #"^\d+(\.\d+){0,2}\z"#, options: .regularExpression) != nil else {
            throw ValidationError.invalidVersion
        }
        guard !script.contains("/"), !script.hasPrefix("."), script.hasSuffix(".js") else {
            throw ValidationError.invalidScriptName
        }
        // `triggers` angegeben, aber kein bekannter Auslöser (leer oder Tippfehler): Das
        // Plugin wäre nirgends zu sehen
        if let triggers, triggers.isEmpty { throw ValidationError.noTrigger }
        let hasMatch = !(match.types ?? []).isEmpty || !(match.extensions ?? []).isEmpty
            || !(match.links?.hosts ?? []).isEmpty || !(match.links?.patterns ?? []).isEmpty
        guard hasMatch else { throw ValidationError.nothingToMatch }
        for pattern in match.links?.patterns ?? [] {
            guard (try? NSRegularExpression(pattern: pattern)) != nil else {
                throw ValidationError.invalidPattern(pattern)
            }
        }
        if let unknown = unknownPermissions.first { throw ValidationError.unknownPermission(unknown) }
        for tool in tools ?? [] {
            guard URL(string: tool.resolvedURL)?.scheme == "https" else { throw ValidationError.insecureToolURL(tool.id) }
            if let checksums = tool.resolvedChecksums, URL(string: checksums)?.scheme != "https" {
                throw ValidationError.insecureToolURL(tool.id)
            }
            if let archive = tool.archive {
                guard archive == "zip", let exe = tool.executable, !exe.isEmpty, !exe.hasPrefix("/"),
                      !exe.split(separator: "/").contains("..") else { throw ValidationError.invalidTool(tool.id) }
            }
            guard tool.id.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*\z"#, options: .regularExpression) != nil else {
                throw ValidationError.invalidTool(tool.id)
            }
            guard tool.sha256 != nil || tool.checksums != nil else { throw ValidationError.missingChecksum(tool.id) }
        }
        if let minimum = minAppVersion, Updater.isNewer(minimum, than: Self.releaseVersion(appVersion)) {
            throw ValidationError.needsNewerApp(minimum)
        }
    }

    /// Längste erlaubte Beschreibung je Sprache (wie MAX_DESCRIPTION in scripts/check_plugin.py).
    /// Gilt nur für neue Plugins und Versionen: Installierte und solche aus der Galerie laufen
    /// weiter, deshalb nicht in `validate`, sondern beim Import aus einer Datei
    static let maxDescriptionLength = 100

    /// Die längste Beschreibung über alle Sprachen, wenn sie die Grenze überschreitet
    var tooLongDescription: Int? {
        let longest = description?.values.values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.count }.max() ?? 0
        return longest > Self.maxDescriptionLength ? longest : nil
    }

    /// „1.31.0-beta.2“ zählt für Plugins wie „1.31.0“
    static func releaseVersion(_ version: String) -> String {
        version.components(separatedBy: "-").first ?? version
    }
}

extension PluginManifest.ValidationError {
    var message: String {
        switch self {
        case .unsupportedSchema:
            return L("The plugin was made for a newer version of BarDrop.", "Das Plugin wurde für eine neuere Version von BarDrop entwickelt.")
        case .invalidID:
            return L("The plugin has no valid identifier.", "Das Plugin hat keine gültige Kennung.")
        case .missingName:
            return L("The plugin has no name.", "Das Plugin hat keinen Namen.")
        case .invalidVersion:
            return L("The plugin has no valid version number.", "Das Plugin hat keine gültige Versionsnummer.")
        case .nothingToMatch:
            return L("The plugin doesn’t say which items it works with.", "Das Plugin gibt nicht an, mit welchen Objekten es arbeitet.")
        case .invalidPattern(let p):
            return L("The plugin has an invalid link pattern: \(p)", "Das Plugin hat ein ungültiges Link-Muster: \(p)")
        case .unknownPermission(let p):
            return L("The plugin asks for the permission “\(p)”, which this version of BarDrop doesn’t know.",
                     "Das Plugin verlangt die Berechtigung „\(p)“, die diese Version von BarDrop nicht kennt.")
        case .insecureToolURL(let t):
            return L("The program “\(t)” isn’t loaded over a secure connection.",
                     "Das Programm „\(t)“ wird nicht über eine sichere Verbindung geladen.")
        case .missingChecksum(let t):
            return L("The program “\(t)” has no checksum, so BarDrop can’t verify it.",
                     "Für das Programm „\(t)“ fehlt die Prüfsumme, daher kann BarDrop es nicht prüfen.")
        case .needsNewerApp(let v):
            return L("The plugin needs BarDrop \(v) or later.", "Das Plugin braucht BarDrop \(v) oder neuer.")
        case .invalidScriptName:
            return L("The plugin’s script name isn’t valid.", "Der Name des Skripts im Plugin ist ungültig.")
        case .invalidTool(let t):
            return L("The program “\(t)” is described incorrectly in manifest.json.",
                     "Das Programm „\(t)“ ist in der manifest.json falsch beschrieben.")
        case .noTrigger:
            return L("The plugin names no known way to start it (“triggers”: menu, action or automatic).",
                     "Das Plugin nennt keinen bekannten Auslöser („triggers“: menu, action oder automatic).")
        }
    }
}

// MARK: Symbol

extension PluginManifest.Icon {
    /// SF-Symbol, das es auf diesem Mac gibt; sonst ein Puzzleteil
    var resolvedSymbol: String {
        if let known = Self.symbolCache[symbol] { return known ? symbol : PluginIconView.fallbackSymbol }
        let exists = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil
        Self.symbolCache[symbol] = exists
        return exists ? symbol : PluginIconView.fallbackSymbol
    }

    /// Ob es ein Symbol gibt, gemerkt (wird beim Zeichnen der Leiste oft gefragt; nur Hauptthread)
    private static var symbolCache: [String: Bool] = [:]

    var tint: Color {
        guard let color, let parsed = Self.parse(color) else { return PluginIconView.fallbackTint }
        return parsed
    }

    static func parse(_ hex: String) -> Color? {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = Int(s, radix: 16) else { return nil }
        return Color(red: Double((value >> 16) & 0xFF) / 255,
                     green: Double((value >> 8) & 0xFF) / 255,
                     blue: Double(value & 0xFF) / 255)
    }
}

/// Symbol eines Plugins: ein SF-Symbol (dieselben Symbole wie in Kurzbefehle, auf jedem
/// Mac vorhanden) weiß auf einer farbigen Kachel, gebaut wie die Symbole der Einstellungen.
struct PluginIconView: View {
    let icon: PluginManifest.Icon?
    var size: CGFloat = 22

    static let fallbackSymbol = "puzzlepiece.extension.fill"
    static let fallbackTint = Color(red: 0.45, green: 0.45, blue: 0.5)

    /// Hell oder dunkel wie die Kacheln der Aktionsleiste (Einstellungen → Aussehen → Symbole)
    @ObservedObject private var appearance = IconAppearance.shared
    @Environment(\.colorfulIcons) private var colorful

    var body: some View {
        let tint = icon?.tint ?? Self.fallbackTint
        if appearance.isDark && !colorful {
            SymbolIconTile(symbol: icon?.resolvedSymbol ?? Self.fallbackSymbol, colors: SettingsTheme.iconColors(tint),
                           size: size, weight: .semibold, glyphScale: 0.5)
        } else {
            lightTile(tint)
        }
    }

    /// Farbige Kachel mit weißem Zeichen (Form wie App-Symbole: 26 % Ecken, AppIconShape)
    private func lightTile(_ tint: Color) -> some View {
        AppIconShape.shape(size)
            .fill(SettingsTheme.iconGradient(tint))
            .overlay(
                Image(systemName: icon?.resolvedSymbol ?? Self.fallbackSymbol)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .iconGlyphShadow(size: size)
            )
            .frame(width: size, height: size)
            .iconTileShadow(size: size)
    }

    /// Als Bild für Dialoge (Installieren, Erlauben, Link der Website), dieselbe Kachel (nur auf
    /// dem Hauptthread). Immer farbig wie in der Galerie, unabhängig von Aussehen → Symbole
    /// (Nutzer, 30.10.2026: im dunklen Stil wirkte das Installieren-Fenster fremd)
    static func image(_ icon: PluginManifest.Icon?, size: CGFloat = 16) -> NSImage? {
        MainActor.assumeIsolated {
            // Rundum Platz für den Schatten der Kachel: Am Bildrand abgeschnitten zeichnete er
            // im Erlauben-Fenster ein sichtbares Viereck um das Symbol
            let margin = size >= 32 ? (size * 0.1).rounded() : 1
            let renderer = ImageRenderer(content: PluginIconView(icon: icon, size: size - 2 * margin)
                .frame(width: size, height: size)
                .environment(\.colorScheme, .dark)
                .environment(\.colorfulIcons, true))
            renderer.scale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
            return renderer.nsImage
        }
    }
}
