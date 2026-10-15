import AppKit

/// Eine Aktion in der Leiste unten in der Ablage. Objekte darauf ziehen
/// (oder auswählen und anklicken) führt sie aus.
struct QuickAction: Codable, Identifiable, Hashable {
    enum Kind: String, Codable, CaseIterable {
        case airdrop, share, mail, messages, folder, app, trash
    }

    var id = UUID()
    var kind: Kind
    /// Ordner- bzw. App-Pfad für `.folder` und `.app`
    var path: String?

    var url: URL? { path.map { URL(fileURLWithPath: $0) } }

    var title: String {
        switch kind {
        case .airdrop: return "AirDrop"
        case .share: return L("Share", "Teilen")
        case .mail: return "Mail"
        case .messages: return L("Messages", "Nachrichten")
        case .trash: return L("Trash", "Papierkorb")
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
        case .share:
            return nil
        case .mail:
            return Self.appIcon("com.apple.mail")
        case .messages:
            return Self.appIcon("com.apple.MobileSMS")
        case .trash:
            // Das Papierkorb-Symbol des Systems, wie im Dock. Der Papierkorb-Ordner selbst
            // ist ohne Festplattenvollzugriff nicht lesbar und liefert nur ein Blatt.
            return NSImage(named: NSImage.trashEmptyName)
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
        case .folder: return "folder.fill"
        case .app: return "app.fill"
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
            QuickAction(kind: .folder, path: downloads)
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

    /// Höchstzahl in der Leiste: eine Reihe mit sechs, zwei Reihen mit je fünf
    static func limit(twoRows: Bool) -> Int { twoRows ? 2 * perRow : 6 }
    /// Aktionen pro Reihe bei zwei Reihen
    static let perRow = 5
}
