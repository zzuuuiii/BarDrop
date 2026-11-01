import AppKit
import SwiftUI

/// Ein Cloud-Dienst, in den BarDrop Dateien hochlädt und einen Link dazu gibt.
/// Jeder Dienst ist ein eigener `CloudProvider`; neue kommen hier und in `provider` dazu.
enum CloudService: String, CaseIterable, Identifiable, Codable {
    case icloud, dropbox, googleDrive, oneDrive

    var id: String { rawValue }

    var title: String {
        switch self {
        case .icloud: return "iCloud Drive"
        case .dropbox: return "Dropbox"
        case .googleDrive: return "Google Drive"
        case .oneDrive: return "OneDrive"
        }
    }

    /// Farbe der Kachel, wie die Dienste selbst
    var tint: Color {
        switch self {
        case .icloud: return Color(red: 0.2, green: 0.6, blue: 1)
        case .dropbox: return Color(red: 0, green: 0.38, blue: 1)
        case .googleDrive: return Color(red: 0.1, green: 0.65, blue: 0.33)
        case .oneDrive: return Color(red: 0.02, green: 0.45, blue: 0.85)
        }
    }

    /// SF-Symbol auf der Kachel. Eigene Logos der Dienste liegen nicht in BarDrop; die Farbe
    /// und der Name machen den Dienst kenntlich
    var symbol: String {
        switch self {
        case .icloud: return "icloud.fill"
        case .dropbox: return "shippingbox.fill"
        case .googleDrive: return "triangle.fill"
        case .oneDrive: return "cloud.fill"
        }
    }

    /// Für Plugin-Kacheln und Menüs: dieselbe Form wie das Symbol eines Plugins
    var icon: PluginManifest.Icon {
        PluginManifest.Icon(symbol: symbol, color: Self.hex(tint))
    }

    var provider: CloudProvider {
        switch self {
        case .icloud: return ICloudProvider.shared
        case .dropbox: return DropboxProvider.shared
        case .googleDrive: return GoogleDriveProvider.shared
        case .oneDrive: return OneDriveProvider.shared
        }
    }

    /// Name des Ordners in jedem Dienst, in den BarDrop hochlädt
    static let folderName = "BarDrop Share"

    /// Der Ordner „BarDrop Share“ auf diesem Mac, wenn es ihn hier gibt: iCloud Drive immer
    /// (wird angelegt), die anderen nur, wenn ihre App den Speicher im Finder einbindet
    /// (`~/Library/CloudStorage`). Ein Klick auf die Aktion zeigt ihn in der Ablage
    /// (Nutzer, 28.10.2026); sonst öffnet sich der Ordner im Browser.
    var localFolder: URL? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let name = Self.folderName
        if self == .icloud {
            let provider = ICloudProvider.shared
            guard provider.isConnected else { return nil }
            if !fm.fileExists(atPath: provider.folder.path) {
                try? fm.createDirectory(at: provider.folder, withIntermediateDirectories: true)
                CloudFolderIcon.apply(to: provider.folder)
            }
            return provider.folder
        }
        let storage = home.appendingPathComponent("Library/CloudStorage", isDirectory: true)
        let mounts = ((try? fm.contentsOfDirectory(at: storage, includingPropertiesForKeys: nil)) ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var candidates: [URL] = []
        switch self {
        case .icloud:
            break
        case .dropbox:
            candidates = mounts.filter { $0.lastPathComponent.hasPrefix("Dropbox") }
                .map { $0.appendingPathComponent(name) }
            candidates.append(home.appendingPathComponent("Dropbox/\(name)"))
        case .googleDrive:
            // „My Drive“ heißt auf Deutsch „Meine Ablage“
            for mount in mounts where mount.lastPathComponent.hasPrefix("GoogleDrive") {
                for root in ["My Drive", "Meine Ablage"] {
                    candidates.append(mount.appendingPathComponent(root).appendingPathComponent(name))
                }
            }
        case .oneDrive:
            candidates = mounts.filter { $0.lastPathComponent.hasPrefix("OneDrive") }
                .map { $0.appendingPathComponent(name) }
        }
        return candidates.first { FolderBrowser.isBrowsable($0) }
    }

    private static func hex(_ color: Color) -> String {
        let c = NSColor(color).usingColorSpace(.sRGB) ?? .systemBlue
        return String(format: "#%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }
}

/// Kachel eines Dienstes mit seinem Logo (Einstellungen, Aktionsleiste, Menüs)
struct CloudServiceIcon: View {
    let service: CloudService
    var size: CGFloat = 22

    var body: some View {
        CloudLogoTile(service: service, size: size)
    }
}

/// Wo der Link hinkommt
enum CloudLinkTarget: String, CaseIterable, Identifiable {
    case clipboard, shelf, both
    var id: String { rawValue }
    var title: String {
        switch self {
        case .clipboard: return L("Clipboard", "Zwischenablage")
        case .shelf: return L("Shelf", "Ablage")
        case .both: return L("Both", "Beides")
        }
    }
}

/// Gespeicherte Einstellungen der Cloud-Dienste (UserDefaults, wie AppSettings)
final class CloudSettings: ObservableObject {
    static let shared = CloudSettings()
    private let defaults = UserDefaults.standard

    @Published var linkTarget: CloudLinkTarget {
        didSet { defaults.set(linkTarget.rawValue, forKey: "cloudLinkTarget") }
    }
    private init() {
        linkTarget = CloudLinkTarget(rawValue: defaults.string(forKey: "cloudLinkTarget") ?? "") ?? .clipboard
    }
}
