import AppKit

/// Eine Aktion in der Leiste unten in der Ablage. Objekte darauf ziehen führt sie aus.
/// Ein Klick zeigt bei Ordnern den Inhalt in der Ablage und öffnet Apps.
struct QuickAction: Codable, Identifiable, Hashable {
    enum Kind: String, Codable, CaseIterable {
        case airdrop, share, mail, messages, folder, app, trash
        /// Ein Plugin (`path` ist seine Kennung)
        case plugin
        /// Ein Kurzbefehl aus der App Kurzbefehle (`path` ist sein Name)
        case shortcut
        /// Daraufgezogene Dateien in die Zwischenablage legen, wie ⌘C im Finder
        case clipboard
        /// In einen Cloud-Dienst hochladen und den Link teilen (`path` ist der Dienst)
        case cloud
        /// Nur noch zum Einlesen alter Einstellungen (1.28): Umwandeln steht im Kontextmenü
        case convert
    }

    var id = UUID()
    var kind: Kind
    /// Ordner- bzw. App-Pfad für `.folder` und `.app`, Kennung des Plugins für `.plugin`
    var path: String?

    var url: URL? { path.map { URL(fileURLWithPath: $0) } }

    /// Dienst einer Cloud-Aktion
    var cloudService: CloudService? { kind == .cloud ? path.flatMap(CloudService.init(rawValue:)) : nil }

    var title: String {
        switch kind {
        case .airdrop: return "AirDrop"
        case .share: return L("Share", "Teilen")
        case .mail: return "Mail"
        case .messages: return L("Messages", "Nachrichten")
        case .trash: return L("Trash", "Papierkorb")
        case .convert: return L("Convert", "Umwandeln")
        case .plugin: return PluginManager.shared.plugin(path)?.manifest.title ?? L("Plugin", "Plugin")
        case .shortcut: return path ?? L("Shortcut", "Kurzbefehl")
        case .clipboard: return L("Clipboard", "Zwischenablage")
        case .cloud: return cloudService?.title ?? "Cloud"
        case .folder, .app:
            guard let path else { return kind == .folder ? L("Folder", "Ordner") : "App" }
            let name = FileManager.default.displayName(atPath: path)
            return kind == .app ? (name as NSString).deletingPathExtension : name
        }
    }

    /// Hinweis, was beim Ablegen passiert.
    var help: String {
        switch kind {
        case .airdrop: return L("Send with AirDrop", "Per AirDrop senden")
        case .share: return L("Share with any app", "Mit einer beliebigen App teilen")
        case .mail: return L("Send as email attachment", "Als E-Mail-Anhang senden")
        case .messages: return L("Send with Messages", "Per Nachrichten senden")
        case .trash: return L("Move to Trash", "In den Papierkorb legen")
        case .convert: return L("Convert to another format", "In ein anderes Format umwandeln")
        case .plugin:
            return PluginManager.shared.plugin(path)?.manifest.description?.text ?? L("Run the plugin", "Plugin ausführen")
        case .shortcut: return L("Run the shortcut “\(title)”", "Kurzbefehl „\(title)“ ausführen")
        case .clipboard: return L("Copy to the clipboard", "In die Zwischenablage kopieren")
        case .cloud: return L("Upload to \(title) and copy the link", "In \(title) hochladen und Link kopieren")
        case .folder: return L("Move to “\(title)”", "In „\(title)“ verschieben")
        case .app: return L("Open with \(title)", "Mit \(title) öffnen")
        }
    }

    /// Echte Symbole: App-Icons, Ordner-Icons und das AirDrop-Symbol des Systems.
    /// `nil` heißt: eigene Darstellung (Teilen).
    var icon: NSImage? {
        switch kind {
        case .airdrop:
            return NSSharingService(named: .sendViaAirDrop)?.image
        case .share, .convert, .plugin, .clipboard, .cloud:
            return nil
        case .mail:
            return Self.appIcon("com.apple.mail")
        case .messages:
            return Self.appIcon("com.apple.MobileSMS")
        case .shortcut:
            return Self.appIcon("com.apple.shortcuts")
        case .trash:
            // Das Papierkorb-Symbol des Systems, wie im Dock. Der Papierkorb-Ordner selbst
            // ist ohne Festplattenvollzugriff nicht lesbar und liefert nur ein Blatt.
            return NSImage(named: TrashState.shared.isFull ? NSImage.trashFullName : NSImage.trashEmptyName)
        case .folder, .app:
            guard let path, FileManager.default.fileExists(atPath: path) else { return nil }
            return NSWorkspace.shared.icon(forFile: path)
        }
    }

    var fallbackSymbol: String {
        switch kind {
        case .airdrop: return "dot.radiowaves.up.forward"
        case .share: return "square.and.arrow.up"
        case .mail: return "envelope.fill"
        case .messages: return "message.fill"
        case .trash: return "trash.fill"
        case .convert: return "arrow.triangle.2.circlepath"
        case .plugin: return PluginManager.shared.plugin(path)?.manifest.icon?.resolvedSymbol ?? PluginIconView.fallbackSymbol
        case .folder: return "folder.fill"
        case .app: return "app.fill"
        case .shortcut: return "square.2.layers.3d.fill"
        case .clipboard: return "doc.on.clipboard.fill"
        case .cloud: return cloudService?.symbol ?? "icloud.fill"
        }
    }

    private static func appIcon(_ bundleID: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    static var defaults: [QuickAction] {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path
        return [
            QuickAction(kind: .airdrop),
            QuickAction(kind: .folder, path: downloads),
            QuickAction(kind: .trash)
        ]
    }

    /// Art einer anheftbaren Aktion: Apps als App, andere Ordner als Ordner, sonst nichts
    static func pinnableKind(_ url: URL) -> Kind? {
        guard url.isFileURL else { return nil }
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isApplicationKey, .isPackageKey])
        guard values?.isDirectory == true else { return nil }
        if values?.isApplication == true || url.pathExtension.lowercased() == "app" { return .app }
        return values?.isPackage == true ? nil : .folder
    }

    /// Aktionen der Vorführungen in der Einführung: immer die Standardaktionen, nicht die
    /// eigenen (Nutzer, 30.10.2026). Einmal angelegt, damit ihre Kennungen gleich bleiben
    static let demo: [QuickAction] = defaults

    /// Höchstzahl in der Leiste: zwei Reihen mit je fünf
    static var limit: Int { 2 * perRow }
    /// Aktionen pro Reihe
    static let perRow = 5
}


/// Ob der Papierkorb des Mac etwas enthält, damit die Aktion „Papierkorb“ wie im Dock voll
/// oder leer aussieht. Das Dock merkt sich das selbst („trash-full“); den Papierkorb-Ordner
/// direkt lesen geht nur mit Festplattenvollzugriff und ist darum nur der zweite Weg.
final class TrashState: ObservableObject {
    static let shared = TrashState()
    /// Von außen nur für die Produktbilder gesetzt; sonst über `refresh()`
    @Published var isFull = false

    private init() { refresh() }

    /// Beim Öffnen der Ablage und nach dem Papierkorb neu nachsehen
    func refresh() {
        let full = Self.dockSaysFull() ?? Self.folderHasItems() ?? false
        if full != isFull { isFull = full }
    }

    private static func dockSaysFull() -> Bool? {
        guard let dock = UserDefaults(suiteName: "com.apple.dock"),
              dock.object(forKey: "trash-full") != nil else { return nil }
        return dock.bool(forKey: "trash-full")
    }

    private static func folderHasItems() -> Bool? {
        guard let trash = FileManager.default.urls(for: .trashDirectory, in: .userDomainMask).first,
              let items = try? FileManager.default.contentsOfDirectory(atPath: trash.path) else { return nil }
        return items.contains { !$0.hasPrefix(".") }
    }
}
