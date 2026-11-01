import SwiftUI

/// Einstellungen → Cloud: Dienste verbinden und wohin der Link kommt.
/// Aktionen für die Leiste kommen wie alle anderen über Einstellungen → Aktionen.
struct CloudSettingsPane: View {
    @ObservedObject private var manager = CloudManager.shared
    @ObservedObject private var settings = CloudSettings.shared

    var body: some View {
        SettingsPage {
            // Dienste und wohin der Link kommt in einer Karte; jeder verbundene Dienst steht im
            // Rechtsklick (Nutzer, 30.10.2026: eigene Karten dafür waren zu viel)
            SettingsSection(L("Services", "Dienste"),
                            info: L("BarDrop only sees what it uploads itself: everything goes into the “\(CloudService.folderName)” folder. Sign-in happens in your browser, and the access stays in your keychain. Connected services also appear in the right-click menu.",
                                    "BarDrop sieht nur, was es selbst hochlädt: alles kommt in den Ordner „\(CloudService.folderName)“. Angemeldet wird im Browser, der Zugang bleibt in deinem Schlüsselbund. Verbundene Dienste stehen auch im Rechtsklick-Menü.")) {
                ForEach(CloudService.allCases) { service in
                    CloudServiceRow(service: service, manager: manager)
                }
                PickerRow(L("Link", "Link"),
                          info: L("Shelf: the link appears as an item next to the file. Files dropped together get one link (zipped), folders are always zipped.",
                                  "Ablage: Der Link erscheint als Objekt neben der Datei. Zusammen abgelegte Dateien bekommen einen Link (als ZIP), Ordner immer als ZIP."),
                          selection: $settings.linkTarget,
                          options: CloudLinkTarget.allCases.map { ($0, $0.title) })
            }
        }
    }
}

/// Ein Dienst: Kachel, Name, Konto bzw. Zustand, rechts Verbinden oder Trennen
private struct CloudServiceRow: View {
    let service: CloudService
    @ObservedObject var manager: CloudManager

    private var provider: CloudProvider { service.provider }

    private var subtitle: String? {
        if let error = manager.connectErrors[service] { return error }
        if !provider.isConfigured { return L("Not available yet", "Derzeit noch nicht verfügbar") }
        if provider.isConnected {
            if service == .icloud { return L("Uses iCloud Drive on this Mac", "Nutzt iCloud Drive auf diesem Mac") }
            return provider.account ?? L("Connected", "Verbunden")
        }
        return service == .icloud ? L("iCloud Drive is off", "iCloud Drive ist aus") : nil
    }

    var body: some View {
        HStack(spacing: 10) {
            CloudServiceIcon(service: service, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(service.title)
                    .font(.system(size: 13.5))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(manager.connectErrors[service] != nil ? Color.orange : .secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            control
        }
        // Ohne Kennung (etwa OneDrive, solange Microsoft keine App-Registrierung erlaubt)
        // ausgegraut und ohne Knopf, damit gleich klar ist, dass es den Dienst noch nicht gibt
        .opacity(provider.isConfigured ? 1 : 0.45)
        .padding(.horizontal, SettingsTheme.rowPadding)
        .frame(minHeight: 52)
    }

    @ViewBuilder
    private var control: some View {
        if !provider.isConfigured {
            EmptyView()
        } else if manager.connecting == service {
            ProgressView().controlSize(.small)
        } else if service == .icloud {
            if provider.isConnected {
                Button(L("Show Folder", "Ordner zeigen")) { provider.openFolder() }
                    .buttonStyle(KlackButtonStyle())
            } else {
                Button(L("Turn On", "Einschalten")) { Task { await manager.connect(service) } }
                    .buttonStyle(KlackButtonStyle())
            }
        } else if provider.isConnected {
            Button(L("Disconnect", "Trennen")) { manager.disconnect(service) }
                .buttonStyle(KlackButtonStyle())
        } else {
            Button(L("Connect", "Verbinden")) { Task { await manager.connect(service) } }
                .buttonStyle(KlackButtonStyle(prominent: true))
                .disabled(manager.connecting != nil)
        }
    }
}
