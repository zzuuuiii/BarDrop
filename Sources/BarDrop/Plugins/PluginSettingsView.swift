import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Unterseiten von Einstellungen → Plugins, wie in den Systemeinstellungen von macOS:
/// Die Liste ist die Startseite; jede Unterseite zeigt oben in der Titelzeile einen
/// Zurück-Knopf und ihren eigenen Titel (`PluginPageHeader`).
enum PluginPage: Hashable {
    case list
    case plugin(String)
    case permissions(String)
    case gallery
    case order

    /// Wohin „Zurück“ führt
    var parent: PluginPage {
        switch self {
        case .permissions(let id): return .plugin(id)
        default: return .list
        }
    }

    func title(_ manager: PluginManager) -> String {
        switch self {
        case .list: return SettingsPane.plugins.title
        case .plugin(let id): return manager.plugin(id)?.manifest.name.text ?? SettingsPane.plugins.title
        case .permissions: return L("Access", "Zugriff")
        case .gallery: return L("All plugins", "Alle Plugins")
        case .order: return L("Order when dropped", "Reihenfolge beim Ablegen")
        }
    }
}

/// Titelzeile einer Unterseite: runder Zurück-Knopf und der Titel der Seite (statt des
/// Symbols und „Plugins“). Esc führt ebenfalls zurück.
struct PluginPageHeader: View {
    @ObservedObject var navigation: SettingsNavigation
    @ObservedObject var manager: PluginManager = .shared

    var body: some View {
        HStack(spacing: 10) {
            Button(action: back) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
            }
            .modifier(BackButtonLook())
            // Ab macOS 26 liegt darüber der echte Glasknopf (SettingsNSWindow): hier nur Platzhalter
            .opacity(SettingsNSWindow.usesNativeTitlebarButtons ? 0 : 1)
            .allowsHitTesting(!SettingsNSWindow.usesNativeTitlebarButtons)
            .keyboardShortcut(.cancelAction)
            .help(L("Back", "Zurück"))
            .accessibilityLabel(L("Back", "Zurück"))
            // Liegt in der Titelleiste: Klicks kommen über das Fenster an
            .background(GeometryReader { g in
                Color.clear
                    .onAppear { register(g.frame(in: .global)) }
                    .onChange(of: g.frame(in: .global)) { _, frame in register(frame) }
            })
            // Über dem Knopf lässt sich das Fenster nicht verschieben: macOS beginnt das Ziehen an
            // der Titelleiste schon beim Drücken, bevor die App den Klick sieht. Die Sperrfläche
            // (SettingsNSWindow.updateDragBlockers) reichte dafür nicht (Nutzer, 24.10.2026)
            .onHover { inside in
                if !SettingsNSWindow.usesNativeTitlebarButtons { SettingsNSWindow.setMovable(!inside) }
            }
            .onDisappear {
                SettingsNSWindow.titlebarButtons["back"] = nil
                SettingsNSWindow.setMovable(true)
            }
            Text(navigation.pluginPage.title(manager))
                .font(.system(size: 17, weight: .semibold))
                .lineLimit(1)
        }
    }

    private func back() {
        withAnimation(.easeInOut(duration: 0.18)) { navigation.pluginBack() }
    }

    private func register(_ frame: CGRect) {
        let navigation = navigation
        SettingsNSWindow.titlebarButtons["back"] = (frame.insetBy(dx: -4, dy: -4), {
            withAnimation(.easeInOut(duration: 0.18)) { navigation.pluginBack() }
        })
    }
}

/// Zurück-Knopf: ab macOS 26 ein runder Knopf aus Liquid Glass wie in den Systemeinstellungen,
/// 26 pt: mit 22 pt wirkte er neben dem Titel zu klein, mit 28 pt zu kräftig
private struct BackButtonLook: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .buttonStyle(GlassCircleButtonStyle(size: 26))
        } else {
            content.buttonStyle(KlackCircleButtonStyle())
        }
    }
}

/// Runder Knopf aus Liquid Glass mit fester Größe. `.buttonStyle(.glass)` legt eigenen Rand
/// um das Symbol und wäre größer; hier sitzt das Glas genau auf dem Kreis.
@available(macOS 26.0, *)
private struct GlassCircleButtonStyle: ButtonStyle {
    let size: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color.primary)
            .frame(width: size, height: size)
            .contentShape(Circle())
            .glassEffect(.regular.interactive(), in: Circle())
    }
}

/// Einstellungen → Plugins. Startseite: Hauptschalter, die installierten Plugins (Zeile mit
/// „Aus“ und Pfeil), „Plugin importieren“, „Alle Plugins“ und das Protokoll.
struct PluginSettings: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject private var manager: PluginManager
    @ObservedObject private var navigation: SettingsNavigation

    /// `manager` und `navigation` nur für Tests und Vorschaubilder
    init(settings: AppSettings, manager: PluginManager = .shared, navigation: SettingsNavigation = .shared) {
        self.settings = settings
        self.manager = manager
        self.navigation = navigation
    }

    private var page: PluginPage { navigation.pluginPage }
    /// „Fehlersuche“ unter „Erweitert“ aufgeklappt (Standard: zu)
    @State private var showDiagnostics = false

    var body: some View {
        SettingsPage(page: page) {
            switch page {
            case .list:
                start
            case .plugin(let id):
                if let plugin = manager.plugin(id) {
                    PluginPageView(plugin: plugin, manager: manager, settings: settings, open: open)
                } else {
                    // Entfernt oder nicht mehr lesbar: zurück zur Liste
                    start.onAppear { navigation.pluginPage = .list }
                }
            case .permissions(let id):
                if let plugin = manager.plugin(id) {
                    PluginPermissionsPage(plugin: plugin, manager: manager)
                } else {
                    start.onAppear { navigation.pluginPage = .list }
                }
            case .gallery:
                GalleryPage(manager: manager) { id in open(.plugin(id)) }
            case .order:
                PluginOrderPage(manager: manager)
            }
        } footer: {
            // Sind Plugins aus, steht in der Mitte der freien Fläche, was Plugins sind
            if page == .list && !settings.pluginsEnabled {
                PluginsOffNote()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onChange(of: page) { _, _ in manager.reload() }
        .onAppear {
            // Bearbeitete Skripte erkennen. Die Galerie gleich mit abfragen: „Alle Plugins“
            // ist so schon geladen, und neue Versionen kommen von selbst (kein Knopf
            // „Plugins aktualisieren“ mehr). Höchstens einmal pro Minute, weil jede Unterseite
            // hier neu erscheint
            manager.reload()
            manager.syncCatalog(maxAge: 60)
        }
    }

    private func open(_ next: PluginPage) {
        withAnimation(.easeInOut(duration: 0.18)) { navigation.openPluginPage(next) }
    }

    // MARK: Startseite

    /// Plugin-Protokoll ein: erst nach dem Hinweis, was erfasst wird (wie beim
    /// Diagnoseprotokoll); aus: Protokoll gelöscht
    private var pluginLog: Binding<Bool> {
        Binding(get: { settings.pluginLogEnabled }, set: { on in
            if on {
                guard PluginLog.confirm() else { return }
                settings.pluginLogEnabled = true
            } else {
                settings.pluginLogEnabled = false
                PluginLog.shared.clear()
            }
        })
    }

    /// Reihenfolge der Liste „Installiert“: eingeschaltete zuerst, dann nach Namen
    private var listed: [InstalledPlugin] {
        manager.plugins.sorted { a, b in
            let onA = manager.isOn(a), onB = manager.isOn(b)
            if onA != onB { return onA }
            return a.manifest.name.text.localizedCaseInsensitiveCompare(b.manifest.name.text) == .orderedAscending
        }
    }

    private var nothingInstalled: Bool {
        manager.plugins.isEmpty && manager.missingStandard.isEmpty && manager.broken.isEmpty
    }

    @ViewBuilder
    private var start: some View {
        SettingsSection(L("General", "Allgemein")) {
            ToggleRow(L("Use plugins", "Plugins verwenden"), isOn: $settings.pluginsEnabled)
        }

        if settings.pluginsEnabled {
            // Ohne installierte Plugins dieselbe Startseite, nur ohne „Installiert“
            if !nothingInstalled {
                SettingsSection(L("Installed", "Installiert")) {
                    // Eingeschaltete zuerst, je alphabetisch (Nutzer: übersichtlicher). Welches
                    // automatisch zuerst läuft, regelt „Reihenfolge beim Ablegen“ unter „Erweitert“
                    ForEach(listed) { plugin in
                        InstalledRow(plugin: plugin, manager: manager) { open(.plugin(plugin.id)) }
                    }
                    ForEach(manager.missingStandard) { entry in
                        MissingPluginRow(entry: entry) { manager.syncCatalog(force: true) }
                    }
                    ForEach(manager.broken.keys.sorted(), id: \.self) { id in
                        BrokenPluginRow(id: id, message: manager.broken[id] ?? "", manager: manager)
                    }
                }
            }

            // Die fünf meistgeladenen noch nicht installierten Plugins direkt zum Laden, darunter
            // der Weg zu allen. Ein geladenes Plugin wandert nach „Installiert“, und seine Seite
            // öffnet sich
            SettingsSection(L("Gallery", "Galerie")) {
                ForEach(manager.popularExtras()) { entry in
                    GalleryRow(entry: entry, manager: manager) { open(.plugin(entry.id)) }
                }
                if manager.catalogEntries.isEmpty {
                    if manager.syncFailed {
                        SettingsRow(L("No connection", "Keine Verbindung")) {
                            Button(L("Try Again", "Erneut versuchen")) { manager.syncCatalog(force: true) }
                                .buttonStyle(KlackButtonStyle())
                        }
                    } else if manager.syncing {
                        SettingsRow(L("Loading plugins", "Plugins werden geladen")) {
                            ProgressView().controlSize(.small)
                        }
                    }
                }
                // Ohne Zahl neuer Plugins (Nutzer, 28.10.2026): Was neu ist, zeigt „NEU“ an der
                // Zeile in der Liste
                NavigationRow(L("All plugins", "Alle Plugins")) { open(.gallery) }
            }

            // Als letzte Karte der Seite, nicht mehr unten am Fenster festgemacht: Dort wuchs
            // „Fehlersuche“ beim Aufklappen nach oben und schob die Zeile weg (Nutzer)
            footer
        }
    }

    /// Ganz unten auf der Startseite eine eigene Karte wie die anderen: Plugin aus einer Datei
    /// installieren und das Protokoll für die Fehlersuche (an: zusätzlich „Sichern“)
    private var footer: some View {
        SettingsSection(L("Advanced", "Erweitert")) {
            if manager.plugins.filter({ manager.isAutomatic($0) }).count > 1 {
                NavigationRow(L("Order when dropped", "Reihenfolge beim Ablegen")) { open(.order) }
            }
            SettingsRow(L("Install from file", "Aus Datei installieren"),
                        info: L("Installs a .bdrop file. You can also double-click it in the Finder.",
                                "Installiert eine .bdrop-Datei. Du kannst sie auch im Finder doppelklicken.")) {
                Button(L("Import", "Importieren")) { PluginImporter.chooseAndImport() }
                    .buttonStyle(KlackButtonStyle())
                    .fixedSize()
            }
            // Wo die Plugins liegen, etwa um ein Skript anzusehen oder zu bearbeiten (Nutzer)
            SettingsRow(L("Plugin files", "Plugin-Dateien")) {
                Button(L("Show in Finder", "Im Finder zeigen")) {
                    NSWorkspace.shared.open(manager.pluginsFolder)
                }
                .buttonStyle(KlackButtonStyle())
                .fixedSize()
            }
            // Fehlersuche eingeklappt wie die Tastenkürzel: Die meisten brauchen sie nie
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showDiagnostics.toggle() }
            } label: {
                SettingsRow(L("Troubleshooting", "Fehlersuche")) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(showDiagnostics ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if showDiagnostics {
                ToggleRow(L("Plugin log", "Plugin-Protokoll"),
                          info: L("Records what plugins do, including file names and error messages, to help find problems. Stays on this Mac until you save it. Turning it off deletes it.",
                                  "Hält fest, was Plugins tun, mit Dateinamen und Fehlermeldungen, um Probleme zu finden. Bleibt auf diesem Mac, bis du es sicherst. Ausschalten löscht es."),
                          isOn: pluginLog)
            }
            if showDiagnostics && settings.pluginLogEnabled {
                SettingsRow(L("Log file", "Protokolldatei")) {
                    Button(L("Save Log", "Protokoll sichern")) { PluginLog.shared.saveReport() }
                        .buttonStyle(KlackButtonStyle())
                        .fixedSize()
                }
            }
        }
    }
}

/// Plugins aus: mittig das Symbol der Plugins und in zwei Zeilen, was sie sind (wie leere
/// Seiten in den Systemeinstellungen)
private struct PluginsOffNote: View {
    var body: some View {
        VStack(spacing: 12) {
            PaneIcon(pane: .plugins, size: 56)
            Text(L("Plugins", "Plugins"))
                .font(.system(size: 17, weight: .semibold))
            Text(L("Plugins greatly extend what BarDrop can do, such as shrinking images or converting files. They appear in the right-click menu and the action bar, or run when you drop items. You can also create your own.",
                   "Plugins erweitern BarDrop um viele Funktionen, etwa Bilder verkleinern oder Dateien umwandeln. Sie erscheinen im Rechtsklick-Menü und in der Aktionsleiste oder laufen beim Ablegen. Du kannst auch eigene Plugins erstellen."))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 340)
        }
        .padding(.bottom, 40)
    }
}

/// Zeile, die zu einer Unterseite führt: Bezeichnung, rechts grau ein Wert und der Pfeil
private struct NavigationRow: View {
    let title: String
    var value: String?
    let action: () -> Void
    @State private var hovering = false

    init(_ title: String, value: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.value = value
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 13.5))
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                if let value {
                    Text(value)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, SettingsTheme.rowPadding)
            .frame(minHeight: SettingsTheme.rowHeight)
            .background(Color.primary.opacity(hovering ? 0.03 : 0))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: Installiert

/// Eine Zeile je Plugin: Symbol, Name, darunter die Beschreibung oder was gerade ansteht;
/// rechts „Aus“ (nur wenn aus) und der Pfeil. Ein Klick öffnet die Seite des Plugins.
private struct InstalledRow: View {
    let plugin: InstalledPlugin
    @ObservedObject var manager: PluginManager
    let open: () -> Void
    @State private var hovering = false
    /// Plugin und seine Programme zusammen
    @State private var size: Int64?

    private var state: PluginState { manager.state(plugin.id) }
    private var running: Int { manager.runningCounts[plugin.id] ?? 0 }

    /// Unter dem Namen immer Version und Größe. Was gerade ansteht (läuft, hat nicht geklappt,
    /// gerade aktualisiert), zeigt ein farbiges Zeichen rechts (vor „Aus“) (Nutzer, 25.10.2026: vorher
    /// stand es als Text unter dem Namen). Fehlt eine Erlaubnis, ist das Plugin aus
    private var subtitle: String {
        var parts = [L("Version \(plugin.manifest.version)", "Version \(plugin.manifest.version)")]
        if let size { parts.append(PluginSize.text(size)) }
        return parts.joined(separator: " · ")
    }

    private var status: PluginStatus? {
        PluginStatus.current(of: plugin.id, manager: manager)
    }

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                PluginIconView(icon: plugin.manifest.icon, size: 26)
                    .modifier(PluginOffLook(off: !manager.isOn(plugin)))
                VStack(alignment: .leading, spacing: 1) {
                    Text(plugin.manifest.name.text)
                        .font(.system(size: 13.5))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if let status {
                    PluginStatusSymbol(status: status, size: 14)
                        .help(status.text)
                        .accessibilityLabel(status.text)
                        .transition(.opacity)
                }
                // Nur „Aus“ steht da; eingeschaltet ist der Normalfall (Nutzer, 28.10.2026)
                if !manager.isOn(plugin) {
                    Text(L("Off", "Aus"))
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, SettingsTheme.rowPadding)
            .frame(minHeight: 52)
            .background(Color.primary.opacity(hovering ? 0.03 : 0))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.2), value: status)
        .onAppear { measure() }
        .onChange(of: manager.toolRefresh[plugin.id]) { _, _ in measure(fresh: true) }
        .onChange(of: manager.toolsChanged) { _, _ in measure(fresh: true) }
    }

    private func measure(fresh: Bool = false) {
        let parts = PluginSize.parts(of: plugin, tools: manager.tools, fresh: fresh)
        size = parts.own + (parts.programs ?? 0)
    }
}

// MARK: Alle Plugins (Galerie)

private struct GalleryPage: View {
    @ObservedObject var manager: PluginManager
    /// Überschrift über der Liste (auf der Startseite, solange nichts installiert ist)
    var title: String?
    let open: (String) -> Void
    @State private var query = ""

    /// Nur, was noch nicht installiert ist: Installierte stehen in der Liste darüber.
    /// Meistgeladene zuerst wie auf der Startseite (Nutzer, 28.10.2026)
    private var available: [PluginCatalogEntry] {
        PluginManager.byDownloads(manager.catalogEntries.filter { manager.plugin($0.id) == nil })
    }

    private var entries: [PluginCatalogEntry] {
        let all = available
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return all }
        return all.filter { entry in
            [entry.name.text, entry.description?.text ?? "", entry.author ?? ""]
                .contains { $0.localizedCaseInsensitiveContains(q) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsHeader(title ?? L("Gallery", "Galerie")) {
                if manager.syncing && !manager.catalogEntries.isEmpty { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 8)
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        // Suche erst, wenn es etwas zu suchen gibt
        if available.count > 6 {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField(L("Search", "Suchen"), text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
            }
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(SettingsTheme.segmentTrough))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(SettingsTheme.separator, lineWidth: 1))
        }

        if manager.catalogEntries.isEmpty {
            SettingsCard {
                if manager.syncFailed {
                    SettingsRow(L("No connection", "Keine Verbindung"),
                                info: L("Check your internet connection.", "Prüf deine Internetverbindung.")) {
                        Button(L("Try Again", "Erneut versuchen")) { manager.syncCatalog(force: true) }
                            .buttonStyle(KlackButtonStyle())
                    }
                } else {
                    SettingsRow(L("No plugins available yet", "Noch keine Plugins verfügbar")) {
                        if manager.syncing { ProgressView().controlSize(.small) }
                    }
                }
            }
        } else if available.isEmpty {
            SettingsCard {
                SettingsRow(L("All plugins installed", "Alle Plugins installiert")) { EmptyView() }
            }
        } else if entries.isEmpty {
            SectionNote(L("No results", "Keine Treffer"))
                .padding(.horizontal, 8)
        } else {
            SettingsCard {
                ForEach(entries) { entry in
                    GalleryRow(entry: entry, manager: manager) { open(entry.id) }
                }
            }
        }
    }
}

/// Plugin in der Galerie: Symbol, Name, ein Satz, darunter offline oder nicht und die Größe
struct GalleryRow: View {
    let entry: PluginCatalogEntry
    @ObservedObject var manager: PluginManager
    let open: () -> Void
    @State private var loading = false
    @State private var failed = false

    private var installed: Bool { manager.plugin(entry.id) != nil }

    var body: some View {
        HStack(spacing: 10) {
            PluginIconView(icon: entry.icon, size: 26)
            // Zwei Zeilen wie bei den installierten: Name, darunter offline oder nicht und
            // die Größe. Die Beschreibung steht beim Darüberfahren und auf der Seite.
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(entry.name.text)
                        .font(.system(size: 13.5))
                        .lineLimit(1)
                    // Zwei Monate nach dem Erscheinen in der Galerie
                    if entry.isNew { Badge(L("NEW", "NEU")) }
                }
                Text(failed ? L("Download failed", "Laden fehlgeschlagen") : meta)
                    .font(.system(size: 11))
                    .foregroundStyle(failed ? Color.orange : Color.secondary)
                    .lineLimit(1)
            }
            .help(entry.description?.text ?? "")
            Spacer(minLength: 8)
            if loading {
                ProgressView().controlSize(.small)
            } else if !installed {
                Button(L("Get", "Laden")) {
                    loading = true
                    failed = false
                    Self.install(entry, manager: manager) { ok in
                        loading = false
                        failed = !ok
                        if ok { open() }
                    }
                }
                .buttonStyle(KlackButtonStyle())
            }
        }
        .padding(.horizontal, SettingsTheme.rowPadding)
        .frame(minHeight: 52)
    }

    /// Laden, einschalten und so einstellen, wie es gedacht ist. Aus der Galerie ist der
    /// Zugriff schon erteilt. `done(true)`: Danach öffnet der Aufrufer die Seite des Plugins
    static func install(_ entry: PluginCatalogEntry, manager: PluginManager, done: @escaping (Bool) -> Void) {
        // Schon installiert (Aktualisieren über den Link der Website): Einstellungen des Nutzers
        // behalten. Sonst schaltete das Update ein ausgeschaltetes Plugin wieder ein und setzte
        // Automatik, „Original ersetzen“ und die Aktionsleiste auf die Voreinstellung zurück
        let wasInstalled = manager.plugin(entry.id) != nil
        manager.installFromCatalog(entry) { ok in
            guard ok, let plugin = manager.plugin(entry.id) else { return done(false) }
            if !wasInstalled, !AppSettings.shared.pluginsEnabled { AppSettings.shared.pluginsEnabled = true }
            if manager.isFullyAuthorized(plugin) || PluginDialogs.authorize(plugin, manager: manager, ui: nil) {
                if !wasInstalled { manager.activateWithDefaults(plugin) }
            }
            // Erst im nächsten Durchlauf zur Seite: Im selben Durchlauf wie Installieren,
            // Einschalten und Aktionsleiste wechselte nur die Überschrift, der Inhalt blieb auf
            // der Liste stehen (Nutzer, nachgestellt am 24.10.2026)
            DispatchQueue.main.async { done(true) }
        }
    }

    private var meta: String { Self.summary(entry) }

    /// „Läuft lokal · 14 KB“ (Internet nur, wenn der Katalog die Rechte nennt); auch im
    /// Fenster vor dem Laden über einen Link der Website (PluginLink)
    static func summary(_ entry: PluginCatalogEntry) -> String {
        var parts: [String] = []
        if let permissions = entry.permissions {
            parts.append(PluginConnectivity(permissions: permissions.compactMap(PluginPermission.init(rawValue:)),
                                            tools: entry.tools ?? []).short)
        }
        if let size = PluginSize.catalogText(entry) { parts.append(size) }
        return parts.isEmpty ? L("Version \(entry.version)", "Version \(entry.version)") : parts.joined(separator: " · ")
    }
}

// MARK: Seite eines Plugins

/// Wie eine Seite der Systemeinstellungen: oben Symbol, Name und Schalter, darunter was
/// ansteht, dann das Bedienen (Wann es läuft, Einstellungen), ganz unten die Info.
private struct PluginPageView: View {
    let plugin: InstalledPlugin
    @ObservedObject var manager: PluginManager
    @ObservedObject var settings: AppSettings
    let open: (PluginPage) -> Void
    @State private var sizes: PluginSize.Parts?
    /// Text des letzten Fehlers unter seiner Zeile aufgeklappt
    @State private var showError = false

    private var state: PluginState { manager.state(plugin.id) }
    private var manifest: PluginManifest { plugin.manifest }
    private var running: Int { manager.runningCounts[plugin.id] ?? 0 }

    /// Ohne Erlaubnis aus: Einschalten fragt erst (vorher stand „Ein“ neben „Braucht deine Erlaubnis“)
    private var enabled: Binding<Bool> {
        Binding(get: { manager.isOn(plugin) }, set: { on in
            // Einschalten: was noch fehlt, gleich hier in einem Fenster, nicht beim ersten Lauf
            if on, !PluginDialogs.authorize(plugin, manager: manager, ui: nil) { return }
            manager.update(plugin.id) { $0.enabled = on }
        })
    }

    private var automatic: Binding<Bool> {
        Binding(get: { manager.isAutomatic(plugin) }, set: { on in
            // Rechte und Zustimmung jetzt erfragen, damit beim Ablegen nichts aufspringt
            if on, !PluginDialogs.prepareAutomatic(plugin, manager: manager) { return }
            manager.update(plugin.id) { $0.automatic = on }
        })
    }

    private var replace: Binding<Bool> {
        Binding(get: { state.replaceOriginal }, set: { on in manager.update(plugin.id) { $0.replaceOriginal = on } })
    }

    private var hasTriggers: Bool {
        manifest.allTriggers.contains(.automatic) || manifest.canReplaceOriginal == true
    }

    var body: some View {
        // Kopf wie in den Systemeinstellungen: Symbol, Name, Beschreibung und der Schalter.
        // Was gerade ansteht (läuft, Erlaubnis fehlt, letzter Fehler), steht in derselben
        // Karte darunter, je eine ruhige Zeile.
        SettingsCard {
            HStack(spacing: 12) {
                PluginIconView(icon: manifest.icon, size: 36)
                    .modifier(PluginOffLook(off: !manager.isOn(plugin)))
                    .animation(.easeOut(duration: 0.2), value: manager.isOn(plugin))
                VStack(alignment: .leading, spacing: 2) {
                    Text(manifest.name.text)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    if let description = manifest.description?.text, !description.isEmpty {
                        Text(description)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                KlackSwitch(isOn: enabled)
            }
            .padding(.horizontal, SettingsTheme.rowPadding)
            .padding(.vertical, 12)
            .frame(minHeight: 60)

            // Dieselben Zeichen und Farben wie in der Liste der installierten Plugins
            if running > 0 {
                StatusRow(status: .running, text: L("Running", "Läuft")) {
                    Button(L("Stop", "Beenden")) { manager.stopRuns?(plugin.id) }
                        .buttonStyle(KlackButtonStyle())
                        .help(L("Stops all runs of this plugin, including stuck scripts.",
                                "Beendet alle Läufe dieses Plugins, auch ein hängendes Skript."))
                }
            }
            if let error = manager.lastErrors[plugin.id] {
                // Erst „Fehler anzeigen“: Der Text erscheint darunter und lässt sich dort
                // markieren oder kopieren (vorher nur „Fehler kopieren“ ohne ihn zu sehen)
                // Eine Zeile der Karte (ohne Trennlinie zwischen Zeile und Text)
                VStack(spacing: 0) {
                    StatusRow(status: .failed, text: L("Last run failed", "Letzter Lauf fehlgeschlagen")) {
                        Button(showError ? L("Hide Error", "Fehler ausblenden") : L("Show Error", "Fehler anzeigen")) {
                            withAnimation(.easeInOut(duration: 0.2)) { showError.toggle() }
                        }
                        .buttonStyle(KlackButtonStyle())
                    }
                    if showError {
                        ErrorTextRow(text: error)
                            .transition(.opacity)
                    }
                }
            }
            if let version = manager.recentlyUpdated[plugin.id] {
                StatusRow(status: .updated(version), text: L("Updated to \(version)", "Aktualisiert auf \(version)")) {
                    EmptyView()
                }
            }
        }
        .onChange(of: manager.lastErrors[plugin.id]) { _, _ in showError = false }
        .onAppear { sizes = PluginSize.parts(of: plugin, tools: manager.tools) }
        .onChange(of: manager.toolRefresh[plugin.id]) { _, _ in sizes = PluginSize.parts(of: plugin, tools: manager.tools, fresh: true) }
        .onChange(of: manager.toolsChanged) { _, _ in sizes = PluginSize.parts(of: plugin, tools: manager.tools, fresh: true) }

        if hasTriggers {
            SettingsSection(L("Behavior", "Verhalten")) {
                if manifest.allTriggers.contains(.automatic) {
                    ToggleRow(L("When dropped", "Beim Ablegen"),
                              info: L("Runs as soon as you drop a matching item.",
                                      "Läuft, sobald du ein passendes Objekt ablegst."),
                              isOn: automatic)
                }
                if manifest.canReplaceOriginal == true {
                    ToggleRow(L("Replace original", "Original ersetzen"),
                              info: L("The result takes the original’s place in the shelf. ⌘Z brings it back.",
                                      "Das Ergebnis ersetzt das Original in der Ablage. ⌘Z holt es zurück."),
                              isOn: replace)
                }
            }
            // Ist das Plugin aus, wirkt nichts davon: abgeblendet wie in den Systemeinstellungen.
            // Vorher stand „Beim Ablegen“ blau auf an, obwohl nichts lief
            .disabled(!manager.isOn(plugin))
        }

        if let specs = manifest.settings, !specs.isEmpty {
            SettingsSection(L("Settings", "Einstellungen")) {
                ForEach(specs) { spec in
                    PluginSettingRow(spec: spec, plugin: plugin, manager: manager)
                }
            }
        }

        // Info: nur, was man wissen oder tun will; der Rest als eine graue Zeile darunter
        SettingsSection(L("Info", "Info"), note: infoLine) {
            InfoValueRow(L("Internet", "Internet"), PluginConnectivity(manifest: manifest).answer)
            InfoValueRow(L("Works with", "Passt zu"), PluginSummary.matches(manifest.match))
            if let tools = manifest.tools, !tools.isEmpty {
                SettingsRow(tools.count == 1 ? L("Program", "Programm") : L("Programs", "Programme")) {
                    HStack(spacing: 8) {
                        Text(programsValue(tools))
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                        if tools.contains(where: { state.approvedTools.contains($0.approvalKey) }) {
                            Button(L("Update", "Aktualisieren")) { manager.refreshTools(of: plugin) }
                                .buttonStyle(KlackButtonStyle())
                                .disabled(manager.toolRefresh[plugin.id] == .running)
                                .help(L("Downloads the latest version of the programs.",
                                        "Lädt die neueste Version der Programme."))
                        }
                    }
                }
            }
            if !manifest.allPermissions.isEmpty || !(manifest.tools ?? []).isEmpty {
                NavigationRow(L("Access", "Zugriff"),
                              value: manager.isFullyAuthorized(plugin) ? L("Allowed", "Erlaubt") : L("Not allowed", "Nicht erlaubt")) {
                    open(.permissions(plugin.id))
                }
            }
        }

        if !plugin.isStandard {
            HStack {
                Spacer(minLength: 8)
                Button(L("Remove Plugin", "Plugin entfernen")) { confirmRemove() }
                    .buttonStyle(KlackButtonStyle(destructive: true))
            }
            .padding(.horizontal, 4)
        }
    }

    /// „Version 1.2.0 · zzuuuiii · 8 KB“
    private var infoLine: String {
        var parts = [L("Version \(manifest.version)", "Version \(manifest.version)")]
        if let author = manifest.author, !author.isEmpty { parts.append(author) }
        if let sizes { parts.append(PluginSize.text(sizes.own)) }
        return parts.joined(separator: " · ")
    }

    /// „92 MB“, „noch nicht geladen“ oder der Stand nach „Aktualisieren“
    private func programsValue(_ tools: [PluginTool]) -> String {
        switch manager.toolRefresh[plugin.id] {
        case .running: return L("Updating", "Wird aktualisiert")
        case .failed(let message): return message
        default: break
        }
        guard let sizes, let programs = sizes.programs else { return L("Not downloaded yet", "Noch nicht geladen") }
        return PluginSize.text(programs)
    }

    /// Hat das Plugin Programme geladen oder selbst etwas eingerichtet, fragt das Fenster, ob das
    /// mitgehen soll (Hauptwahl) oder nur das Plugin (Nutzer, 25.10.2026)
    private func confirmRemove() {
        let parts = manager.components(of: plugin)
        let alert = PluginDialogs.makeAlert(manifest)
        alert.messageText = L("Remove “\(manifest.name.text)”?", "„\(manifest.name.text)“ entfernen?")
        if parts.isEmpty {
            alert.informativeText = L("The plugin and its settings will be deleted. Items in the shelf aren’t affected.",
                                      "Das Plugin und seine Einstellungen werden gelöscht. Die Objekte in der Ablage bleiben.")
            alert.addButton(withTitle: L("Remove", "Entfernen"))
        } else {
            let size = PluginSize.text(parts.all.reduce(Int64(0)) { $0 + PluginSize.folder($1) })
            let names = componentNames(parts)
            let trash = parts.installed.isEmpty ? ""
                : L(" Folders outside BarDrop go to the Trash.", " Ordner außerhalb von BarDrop kommen in den Papierkorb.")
            let others = parts.sharedWith.joined(separator: ", ")
            let shared = parts.shared.isEmpty ? ""
                : L(" Programs also used by \(others) are downloaded again there when needed.",
                    " Von \(others) mitbenutzte Programme werden dort bei Bedarf neu geladen.")
            alert.informativeText = L("The plugin and its settings will be deleted. It also installed programs (\(size)): \(names).\(shared)\(trash) Items in the shelf aren’t affected.",
                                      "Das Plugin und seine Einstellungen werden gelöscht. Dazu hat es Programme eingerichtet (\(size)): \(names).\(shared)\(trash) Die Objekte in der Ablage bleiben.")
            alert.addButton(withTitle: L("Remove With Programs", "Mit Programmen entfernen"))
            alert.addButton(withTitle: L("Remove Plugin Only", "Nur Plugin entfernen"))
        }
        alert.addButton(withTitle: L("Cancel", "Abbrechen"))
        alert.buttons.first?.hasDestructiveAction = true
        let answer = alert.runModal()
        let withPrograms: Bool
        switch answer {
        case .alertFirstButtonReturn: withPrograms = !parts.isEmpty
        case .alertSecondButtonReturn where !parts.isEmpty: withPrograms = false
        default: return
        }
        open(.list)
        withAnimation(.spring(response: 0.3, dampingFraction: 0.88)) {
            manager.remove(plugin.id, withComponents: withPrograms)
        }
    }

    /// „mytool, ~/.local/share/env“: Programme mit ihrem Namen aus dem Manifest, Ordner als Pfad
    private func componentNames(_ parts: PluginManager.Components) -> String {
        var names: [String] = []
        let tools = manager.plugins.flatMap { $0.manifest.tools ?? [] }
        for folder in parts.programs + parts.shared {
            let tool = tools.first { manager.tools.storedFolders($0).contains(folder) }
            let name = tool?.name ?? folder.lastPathComponent
            if !names.contains(name) { names.append(name) }
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        for folder in parts.installed {
            let path = folder.path
            names.append(path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path)
        }
        return names.joined(separator: ", ")
    }
}

/// Symbol eines ausgeschalteten Plugins: grau und dunkler, wie ausgegraut (Nutzer, 28.10.2026)
struct PluginOffLook: ViewModifier {
    let off: Bool

    func body(content: Content) -> some View {
        content
            .saturation(off ? 0 : 1)
            .brightness(off ? -0.12 : 0)
            .opacity(off ? 0.55 : 1)
    }
}

/// Was bei einem Plugin gerade ansteht: in der Liste ein farbiges Zeichen vor „Aus“, auf
/// seiner Seite dasselbe Zeichen mit einem kurzen Satz
enum PluginStatus: Equatable {
    case running, failed, updated(String)

    /// Läuft geht vor Fehler, Fehler vor „aktualisiert“
    static func current(of id: String, manager: PluginManager) -> PluginStatus? {
        if (manager.runningCounts[id] ?? 0) > 0 { return .running }
        if manager.lastErrors[id] != nil { return .failed }
        if let version = manager.recentlyUpdated[id] { return .updated(version) }
        return nil
    }

    var symbol: String {
        switch self {
        // Wird als Ladekreis gezeichnet (PluginStatusSymbol); das Zeichen nur als Ersatz
        case .running: return "arrow.triangle.2.circlepath"
        case .failed: return "exclamationmark.triangle"
        // Grün mit Funkeln wie „Neu“ bei Apple: frisch aktualisiert, nichts zu tun (ein Pfeil
        // hätte nach „Update verfügbar“ ausgesehen)
        case .updated: return "sparkles"
        }
    }

    var color: Color {
        switch self {
        case .running: return Color(nsColor: .controlAccentColor)
        case .failed: return .orange
        case .updated: return Color(nsColor: .systemGreen)
        }
    }

    var text: String {
        switch self {
        case .running: return L("Running", "Läuft")
        case .failed: return L("Last run failed", "Letzter Lauf fehlgeschlagen")
        case .updated(let version): return L("Updated to \(version)", "Aktualisiert auf \(version)")
        }
    }
}

/// Zeichen eines Zustands. Läuft das Plugin, dreht sich der Ladekreis von macOS
/// (Nutzer: lieber das bekannte Laden als Zahnräder)
struct PluginStatusSymbol: View {
    let status: PluginStatus
    var size: CGFloat = 13

    var body: some View {
        if status == .running {
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.small)
                // Der kleine Kreis ist 16 pt groß; auf die Größe der anderen Zeichen bringen
                .scaleEffect(size / 16)
                .frame(width: size + 2, height: size + 2)
        } else {
            Image(systemName: status.symbol)
                .font(.system(size: size))
                .foregroundStyle(status.color)
        }
    }
}

/// Zeile unter dem Kopf einer Plugin-Seite: Zeichen des Zustands, kurzer Satz, rechts ein Knopf
private struct StatusRow<Control: View>: View {
    let status: PluginStatus
    let text: String
    @ViewBuilder let control: () -> Control

    var body: some View {
        HStack(spacing: 8) {
            PluginStatusSymbol(status: status)
                .frame(width: 20)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(status == .running ? Color.primary : status.color)
            Spacer(minLength: 8)
            control()
        }
        .padding(.horizontal, SettingsTheme.rowPadding)
        .frame(minHeight: 42)
    }
}

/// Aufgeklappter Fehler: der ganze Text zum Markieren, darunter rechts „Kopieren“
private struct ErrorTextRow: View {
    let text: String

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            Text(text)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.05)))
            CopyButton(text: text)
        }
        .padding(.horizontal, SettingsTheme.rowPadding)
        .padding(.bottom, 10)
    }
}

/// Info-Zeile: Bezeichnung links, Wert rechts in Grau (lange Werte brechen um)
private struct InfoValueRow: View {
    let title: String
    let value: String

    init(_ title: String, _ value: String) {
        self.title = title
        self.value = value
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(.system(size: 13.5))
                .layoutPriority(1)
            Spacer(minLength: 12)
            Text(value)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, SettingsTheme.rowPadding)
        .padding(.vertical, 12)
        .frame(minHeight: SettingsTheme.rowHeight)
    }
}

// MARK: Zugriff

/// Was das Plugin darf, welche Programme es lädt und welchem Hinweis man zugestimmt hat.
/// Aufgebaut wie „Datenschutz & Sicherheit“: oben in einem Satz der Stand, darunter je
/// Gruppe eine Karte mit Symbol, Erklärung und Stand.
private struct PluginPermissionsPage: View {
    let plugin: InstalledPlugin
    @ObservedObject var manager: PluginManager

    private var state: PluginState { manager.state(plugin.id) }
    private var allowed: Bool { manager.isFullyAuthorized(plugin) }
    private var anythingGranted: Bool { !state.granted.isEmpty || !state.approvedTools.isEmpty || state.consented }

    var body: some View {
        let manifest = plugin.manifest
        // Stand in einer Zeile, rechts der Knopf, der gerade passt; die Erklärung darunter
        SettingsSection(L("Status", "Status")) {
            SettingsRow(allowed ? L("Allowed", "Erlaubt") : L("Not allowed", "Nicht erlaubt"),
                        info: L("If the plugin’s files change, it asks again. Without access the plugin is off.",
                                "Ändern sich die Dateien des Plugins, fragt es erneut. Ohne Zugriff ist das Plugin aus.")) {
                if allowed {
                    if anythingGranted {
                        Button(L("Revoke", "Entziehen")) { manager.revokeAccess(plugin.id) }
                            .buttonStyle(KlackButtonStyle())
                            .help(L("The plugin asks again before its next run.",
                                    "Vor dem nächsten Lauf fragt das Plugin erneut."))
                    }
                } else {
                    Button(L("Allow", "Erlauben")) { _ = PluginDialogs.authorize(plugin, manager: manager, ui: nil) }
                        .buttonStyle(KlackButtonStyle(prominent: true))
                }
            }
        }

        if !manifest.allPermissions.isEmpty {
            SettingsSection(L("Permissions", "Berechtigungen")) {
                ForEach(manifest.allPermissions) { permission in
                    AccessRow(symbol: permission.symbol, title: permission.title, subtitle: permission.explanation,
                              granted: manager.isGranted(permission, for: plugin))
                }
            }
        }

        if let tools = manifest.tools, !tools.isEmpty {
            SettingsSection(tools.count == 1 ? L("Program", "Programm") : L("Programs", "Programme"),
                            info: L("Downloaded once and checked against the checksum in the plugin.",
                                    "Wird einmal geladen und mit der Prüfsumme aus dem Plugin verglichen.")) {
                ForEach(tools, id: \.approvalKey) { tool in
                    AccessRow(symbol: "arrow.down.circle", title: tool.name,
                              subtitle: [URL(string: tool.resolvedURL)?.host, tool.license].compactMap { $0 }.joined(separator: " · "),
                              granted: state.approvedTools.contains(tool.approvalKey))
                }
            }
        }

        if let consent = manifest.consent {
            // Kurze Zeile mit dem Stand, der lange Text des Plugins darunter in voller Breite
            // (in der Zeile stand er schmal zwischen Zeichen und Stand und wirkte verschoben)
            SettingsSection(L("Notice", "Hinweis"), note: consent.text) {
                AccessRow(symbol: "text.bubble", title: L("Plugin’s notice", "Hinweis des Plugins"), subtitle: nil,
                          granted: manager.hasConsented(plugin), allowed: L("Agreed", "Zugestimmt"))
            }
        }
    }
}

/// Eine Zeile auf „Zugriff“: Symbol, Bezeichnung mit Erklärung, rechts der Stand
private struct AccessRow: View {
    let symbol: String
    let title: String
    let subtitle: String?
    let granted: Bool
    var allowed = L("Allowed", "Erlaubt")

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13.5))
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Text(granted ? allowed : L("Not allowed", "Nicht erlaubt"))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, SettingsTheme.rowPadding)
        .padding(.vertical, 10)
        .frame(minHeight: SettingsTheme.rowHeight)
    }
}

/// „Kopieren“ mit kurzer Bestätigung: Für einen Moment steht dort „Kopiert“ mit Haken
private struct CopyButton: View {
    let text: String
    var title = L("Copy", "Kopieren")
    @State private var copied = false
    @State private var resetTask: DispatchWorkItem?

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            withAnimation(.easeOut(duration: 0.15)) { copied = true }
            resetTask?.cancel()
            let task = DispatchWorkItem { withAnimation(.easeIn(duration: 0.2)) { copied = false } }
            resetTask = task
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: task)
        } label: {
            // Beide Beschriftungen liegen übereinander: Die Breite springt nicht
            ZStack {
                Label(L("Copied", "Kopiert"), systemImage: "checkmark").opacity(copied ? 1 : 0)
                Text(title).opacity(copied ? 0 : 1)
            }
        }
        .buttonStyle(KlackButtonStyle())
        .accessibilityLabel(copied ? L("Copied", "Kopiert") : title)
    }
}

// MARK: Reihenfolge

/// Welches automatische Plugin läuft, wenn mehrere zum selben Objekt passen: das oberste
private struct PluginOrderPage: View {
    @ObservedObject var manager: PluginManager

    /// Wie die Aktionsliste (Einstellungen → Aktionen): Zeilen am Griff ziehen, die anderen
    /// gleiten an ihren neuen Platz, jeder Platz rastet mit einem Impuls ein; gespeichert wird
    /// beim Loslassen. Standard-Plugins bleiben vor den eigenen
    @State private var dragging: String?
    @State private var dragStartY: CGFloat = 0
    @State private var dragTranslation: CGFloat = 0
    @State private var proposal: [String]?

    private static let rowHeight: CGFloat = 52
    private static let pitch: CGFloat = rowHeight + 1
    private static let space = "pluginOrder"

    private var automatic: [InstalledPlugin] { manager.plugins.filter { manager.isAutomatic($0) } }
    private var shown: [String] { proposal ?? automatic.map(\.id) }

    var body: some View {
        let list = automatic
        SettingsSection(L("When dropped", "Beim Ablegen"),
                        info: L("If several plugins match the same item, only the top one runs. Standard plugins stay above your own.",
                                "Passen mehrere Plugins zum selben Objekt, läuft nur das oberste. Standard-Plugins bleiben über deinen eigenen.")) {
            if list.isEmpty {
                SettingsRow(L("No plugin runs automatically", "Kein Plugin läuft automatisch")) { EmptyView() }
            } else {
                rows(list)
            }
        }
    }

    private func rows(_ list: [InstalledPlugin]) -> some View {
        let order = shown
        return ZStack(alignment: .topLeading) {
            ForEach(1..<max(list.count, 1), id: \.self) { i in
                Rectangle()
                    .fill(SettingsTheme.separator)
                    .frame(height: 1)
                    .padding(.leading, SettingsTheme.rowPadding + 34)
                    .offset(y: CGFloat(i) * Self.pitch - 1)
            }
            ForEach(list) { plugin in
                let lifted = dragging == plugin.id
                OrderRow(plugin: plugin, lifted: lifted)
                    .frame(height: Self.rowHeight)
                    .offset(y: lifted ? dragStartY + dragTranslation
                                      : CGFloat(order.firstIndex(of: plugin.id) ?? 0) * Self.pitch)
                    .zIndex(lifted ? 2 : 1)
                    .gesture(drag(plugin, list: list))
                    .contextMenu {
                        Button(L("Move Up", "Nach oben")) { manager.moveAutomatic(plugin.id, by: -1) }
                            .disabled(!manager.canMoveAutomatic(plugin.id, by: -1))
                        Button(L("Move Down", "Nach unten")) { manager.moveAutomatic(plugin.id, by: 1) }
                            .disabled(!manager.canMoveAutomatic(plugin.id, by: 1))
                    }
            }
            .animation(nil, value: dragTranslation)
        }
        .frame(height: CGFloat(list.count) * Self.pitch - 1, alignment: .top)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .coordinateSpace(name: Self.space)
    }

    private func drag(_ plugin: InstalledPlugin, list: [InstalledPlugin]) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named(Self.space))
            .onChanged { g in
                let ids = list.map(\.id)
                if dragging != plugin.id {
                    dragging = plugin.id
                    dragStartY = CGFloat(ids.firstIndex(of: plugin.id) ?? 0) * Self.pitch
                }
                // Nur innerhalb der eigenen Gruppe (Standard oder eigene)
                let group = list.indices.filter { list[$0].isStandard == plugin.isStandard }
                guard let low = group.first, let high = group.last else { return }
                let top = min(max(dragStartY + g.translation.height, CGFloat(low) * Self.pitch), CGFloat(high) * Self.pitch)
                dragTranslation = top - dragStartY
                var next = ids
                next.removeAll { $0 == plugin.id }
                let target = min(max(Int((top / Self.pitch).rounded()), low), high)
                next.insert(plugin.id, at: target)
                if next != shown {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) { proposal = next }
                    Haptics.tap()
                }
            }
            .onEnded { _ in
                if let proposal {
                    var t = Transaction()
                    t.disablesAnimations = true
                    withTransaction(t) { manager.setAutomaticOrder(proposal) }
                }
                withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
                    dragging = nil
                    dragTranslation = 0
                    proposal = nil
                }
            }
    }
}

/// Eine Zeile der Reihenfolge, gestaltet wie eine Zeile der Aktionsliste
private struct OrderRow: View {
    let plugin: InstalledPlugin
    let lifted: Bool

    var body: some View {
        HStack(spacing: 10) {
            PluginIconView(icon: plugin.manifest.icon, size: 24)
            Text(plugin.manifest.name.text)
                .font(.system(size: 13.5))
                .lineLimit(1)
                .help(PluginSummary.matches(plugin.manifest.match))
            Spacer(minLength: 8)
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.secondary.opacity(lifted ? 1 : 0.6))
                .frame(width: 30, height: 40)
                .contentShape(Rectangle())
                .help(L("Drag to reorder", "Zum Verschieben ziehen"))
        }
        .padding(.leading, SettingsTheme.rowPadding)
        .padding(.trailing, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: SettingsTheme.cardRadius, style: .continuous)
                .fill(lifted ? SettingsTheme.cardSolid : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: SettingsTheme.cardRadius, style: .continuous)
                .strokeBorder(SettingsTheme.cardBorder, lineWidth: lifted ? 1 : 0)
        )
        .shadow(color: .black.opacity(lifted ? 0.4 : 0), radius: 10, y: 4)
        .scaleEffect(lifted ? 1.02 : 1)
        .contentShape(Rectangle())
    }
}

/// Einstellung aus dem Manifest: Schalter, Auswahl oder Textfeld
private struct PluginSettingRow: View {
    let spec: PluginSettingSpec
    let plugin: InstalledPlugin
    @ObservedObject var manager: PluginManager

    private var value: PluginValue { manager.value(spec, of: plugin.id) }

    private func set(_ new: PluginValue) {
        manager.update(plugin.id) { $0.values[spec.key] = new }
    }

    var body: some View {
        switch spec.type {
        case .toggle:
            ToggleRow(spec.title.text, info: spec.info?.text,
                      isOn: Binding(get: { value.bool }, set: { set(.bool($0)) }))
        case .choice:
            PickerRow(spec.title.text, info: spec.info?.text,
                      selection: Binding(get: { value.string }, set: { set(.string($0)) }),
                      options: (spec.options ?? []).map { ($0.value, $0.title.text) })
        case .text:
            SettingsRow(spec.title.text, info: spec.info?.text) {
                TextField("", text: Binding(get: { value.string }, set: { set(.string($0)) }))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
            }
        }
    }
}

/// Standard-Plugin, das gerade nicht geladen werden konnte (z. B. ohne Internet)
private struct MissingPluginRow: View {
    let entry: PluginCatalogEntry
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            PluginIconView(icon: entry.icon, size: 26)
                .opacity(0.5)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name.text)
                    .font(.system(size: 13.5))
                Text(L("Not downloaded yet", "Noch nicht geladen"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button(L("Try Again", "Erneut versuchen"), action: retry)
                .buttonStyle(KlackButtonStyle())
        }
        .padding(.horizontal, SettingsTheme.rowPadding)
        .frame(minHeight: 52)
    }
}

/// Installiertes Plugin, das sich nicht mehr lesen lässt (z. B. nach dem Bearbeiten)
private struct BrokenPluginRow: View {
    let id: String
    let message: String
    @ObservedObject var manager: PluginManager

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 16))
                .foregroundStyle(.orange)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(id)
                    .font(.system(size: 13.5))
                    .lineLimit(1)
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Button(L("Show in Finder", "Im Finder zeigen")) {
                NSWorkspace.shared.activateFileViewerSelecting([manager.folder(of: id)])
            }
            .buttonStyle(KlackButtonStyle())
            if !manager.state(id).isStandard {
                Button(L("Remove", "Entfernen")) { manager.removeBroken(id) }
                    .buttonStyle(KlackButtonStyle(destructive: true))
            }
        }
        .padding(.horizontal, SettingsTheme.rowPadding)
        .frame(minHeight: 52)
    }
}

/// Braucht ein Plugin das Internet? Aus seinen Rechten und Programmen abgeleitet:
/// Ohne `network` kann das Skript selbst keine Verbindung aufbauen; Programme aus `tools`
/// werden einmal geladen (ein mit `run` gestartetes Programm könnte trotzdem ins Netz).
struct PluginConnectivity {
    let permissions: [PluginPermission]
    let tools: [String]

    var usesNetwork: Bool { permissions.contains(.network) }

    /// Kurz für die Zeilen der Galerie
    var short: String {
        if usesNetwork { return L("Internet", "Internet") }
        // „Läuft lokal“ statt „Offline“ (Nutzer, 28.10.2026)
        if !tools.isEmpty { return L("Runs locally after setup", "Läuft lokal nach Einrichtung") }
        return L("Runs locally", "Läuft lokal")
    }

    var symbol: String {
        if usesNetwork { return "globe" }
        return tools.isEmpty ? "wifi.slash" : "arrow.down.circle"
    }
}

extension PluginConnectivity {
    init(manifest: PluginManifest) {
        self.init(permissions: manifest.allPermissions, tools: (manifest.tools ?? []).map(\.name))
    }

    /// Antwort in der Info einer Plugin-Seite: Geht es ins Internet?
    var answer: String {
        if usesNetwork { return L("Yes", "Ja") }
        if !tools.isEmpty { return L("Once, for programs", "Einmal, für Programme") }
        return L("No", "Nein")
    }
}

/// Größe eines Plugins: eigene Dateien und die Programme, die es geladen hat
enum PluginSize {
    static func text(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func folder(_ url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileSizeKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in walker {
            guard let v = try? file.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            total += Int64(v.totalFileAllocatedSize ?? v.fileSize ?? 0)
        }
        return total
    }

    /// Galerie, vor dem Laden: „14 KB“ oder, mit Programmen, „8 KB + 61 MB“ (das Zeichen
    /// und „Programm“ davor nennt die Zeile schon; ohne bekannte Größe nur „8 KB“)
    static func catalogText(_ entry: PluginCatalogEntry) -> String? {
        guard let size = entry.size else { return nil }
        guard (entry.tools?.count ?? 0) > 0, let programs = entry.toolsSize else { return text(Int64(size)) }
        return text(Int64(size)) + " + " + text(Int64(programs))
    }

    /// Plugin und Programme getrennt, für die Seite eines Plugins. `programs` nil: noch
    /// keines geladen (oder das Plugin braucht keine)
    struct Parts: Equatable {
        let own: Int64
        let programs: Int64?
    }

    /// Gemerkte Größen (Hauptthread): Jedes Öffnen der Liste zählte sonst alle Dateien der Plugins
    /// und ihrer Programme neu, bei einem Programm mit zehntausenden Dateien spürbar. `fresh`,
    /// sobald Programme geladen oder entfernt wurden
    private static var known: [String: Parts] = [:]

    static func parts(of plugin: InstalledPlugin, tools: PluginTools, fresh: Bool = false) -> Parts {
        let key = plugin.directory.path + "|" + plugin.manifest.version
        // Geänderte Programme können mehreren Plugins gehören: dann alle neu zählen
        if fresh { known.removeAll() }
        if !fresh, let cached = known[key] { return cached }
        // Alles, was auf der Platte liegt, auch ein veraltetes Programm (wie beim Entfernen):
        // Vorher stand dann „noch nicht geladen“, obwohl es Platz belegte
        let folders = Set((plugin.manifest.tools ?? []).flatMap(tools.storedFolders))
        let parts = Parts(own: folder(plugin.directory),
                          programs: folders.isEmpty ? nil : folders.reduce(Int64(0)) { $0 + folder($1) })
        known[key] = parts
        return parts
    }
}

/// Kategorien der Galerie (Werte in index.json)
enum PluginCategory {
    static let all = ["images", "links", "documents", "text", "media", "files", "other"]

    static func title(_ key: String) -> String? {
        switch key {
        case "images": return L("Images", "Bilder")
        case "links": return L("Links and web", "Links und Web")
        case "documents": return L("Documents", "Dokumente")
        case "text": return L("Text", "Text")
        case "media": return L("Audio and video", "Audio und Video")
        case "files": return L("Files", "Dateien")
        case "other": return L("Other", "Sonstiges")
        default: return nil
        }
    }
}

private struct Badge: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(Color.primary.opacity(0.07)))
            .overlay(Capsule().strokeBorder(SettingsTheme.separator, lineWidth: 1))
    }
}

/// Lesbare Kurzfassung, wofür ein Plugin zuständig ist
enum PluginSummary {
    /// Häufige Typen in der Sprache der App; sonst die Kennung selbst (die Beschreibung
    /// des Systems käme in der Sprache von macOS, nicht der von BarDrop)
    static func typeName(_ identifier: String) -> String {
        switch identifier {
        case "public.image": return L("Images", "Bilder")
        case "public.movie", "public.video", "public.audiovisual-content": return L("Videos", "Videos")
        case "public.audio": return L("Audio", "Audio")
        case "com.adobe.pdf": return "PDF"
        case "public.text", "public.plain-text": return L("Text", "Text")
        case "public.folder", "public.directory": return L("Folders", "Ordner")
        case "public.archive", "public.zip-archive": return L("Archives", "Archive")
        case "public.url", "com.apple.web-internet-location": return L("Links", "Links")
        case "public.data", "public.item", "public.content": return L("All files", "Alle Dateien")
        default: return identifier
        }
    }

    static func matches(_ match: PluginMatch) -> String {
        var parts: [String] = []
        for identifier in match.types ?? [] {
            parts.append(typeName(identifier))
        }
        if let ext = match.extensions, !ext.isEmpty {
            parts.append(ext.map { "." + $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) }.joined(separator: " "))
        }
        if let hosts = match.links?.hosts, !hosts.isEmpty {
            parts.append(hosts.contains("*") ? L("All links", "Alle Links") : L("Links: ", "Links: ") + hosts.joined(separator: ", "))
        }
        if !(match.links?.patterns ?? []).isEmpty, (match.links?.hosts ?? []).isEmpty {
            parts.append(L("Some links", "Bestimmte Links"))
        }
        return parts.joined(separator: " · ")
    }
}
