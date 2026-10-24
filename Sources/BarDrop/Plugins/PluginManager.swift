import AppKit
import Combine

/// Ein installiertes Plugin, so wie es gerade auf der Platte liegt.
struct InstalledPlugin: Identifiable, Equatable {
    let manifest: PluginManifest
    let directory: URL
    let script: String
    /// Über alle Dateien des Plugins; ändert sich beim Bearbeiten
    let fingerprint: String
    /// Aus dem Katalog als Standard-Plugin installiert: nicht löschbar, nicht bearbeitbar
    let isStandard: Bool

    var id: String { manifest.id }
    var scriptURL: URL { directory.appendingPathComponent(manifest.script) }
    var manifestURL: URL { directory.appendingPathComponent("manifest.json") }

    static func == (a: InstalledPlugin, b: InstalledPlugin) -> Bool {
        a.id == b.id && a.fingerprint == b.fingerprint && a.isStandard == b.isStandard
    }
}

/// Was der Nutzer für ein Plugin eingestellt und erlaubt hat.
struct PluginState: Codable, Equatable {
    var enabled = false
    /// nil: Standard des Plugins
    var automatic: Bool?
    var replaceOriginal = false
    var values: [String: PluginValue] = [:]
    /// Erteilte Rechte. Sie gelten nur für den Code mit `grantedFingerprint`.
    var granted: [PluginPermission] = []
    var grantedFingerprint: String?
    /// Dem Hinweis des Plugins (`consent`) zugestimmt
    var consented = false
    /// Der Hinweistext, dem zugestimmt wurde. Ändert ihn ein Update, wird neu gefragt.
    /// nil bei Zustimmungen aus älteren Fassungen (gelten weiter).
    var consentedText: String?
    /// Programme (`tools`), deren Download der Nutzer schon erlaubt hat, als
    /// `PluginTool.approvalKey` (Programm und Adresse). Gilt auch für automatische Läufe,
    /// die selbst nie fragen.
    var approvedTools: [String] = []
    var isStandard = false
    /// Aus dem Katalog geladen (nicht importiert): bekommt neue Versionen von dort
    var fromCatalog = false
    /// Stand in der Aktionsleiste, als das Plugin ausgeschaltet wurde: kommt beim
    /// Einschalten wieder dorthin
    var parkedInActionBar = false

    init() {}

    /// Fehlende Schlüssel (ältere Fassungen) bekommen ihren Standard, statt alles zu verwerfen
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        automatic = try c.decodeIfPresent(Bool.self, forKey: .automatic)
        replaceOriginal = try c.decodeIfPresent(Bool.self, forKey: .replaceOriginal) ?? false
        values = try c.decodeIfPresent([String: PluginValue].self, forKey: .values) ?? [:]
        granted = (try c.decodeIfPresent([String].self, forKey: .granted) ?? []).compactMap(PluginPermission.init(rawValue:))
        grantedFingerprint = try c.decodeIfPresent(String.self, forKey: .grantedFingerprint)
        consented = try c.decodeIfPresent(Bool.self, forKey: .consented) ?? false
        consentedText = try c.decodeIfPresent(String.self, forKey: .consentedText)
        approvedTools = try c.decodeIfPresent([String].self, forKey: .approvedTools) ?? []
        isStandard = try c.decodeIfPresent(Bool.self, forKey: .isStandard) ?? false
        fromCatalog = try c.decodeIfPresent(Bool.self, forKey: .fromCatalog) ?? false
        parkedInActionBar = try c.decodeIfPresent(Bool.self, forKey: .parkedInActionBar) ?? false
    }
}

/// Eintrag im Katalog (index.json). Der Katalog kennt nur Plugins, die geprüft wurden.
struct PluginCatalogEntry: Codable, Equatable, Identifiable {
    var id: String
    var version: String
    var name: LocalizedText
    var description: LocalizedText?
    var icon: PluginManifest.Icon?
    /// .bdrop-Datei (https)
    var url: String
    var sha256: String
    /// Wird mit dem Einschalten der Plugins automatisch installiert und lässt sich nicht löschen
    var standard: Bool?
    /// Zurückgezogen: BarDrop entfernt es beim nächsten Abgleich
    var removed: Bool?
    var minAppVersion: String?
    /// Für die Galerie (alles freiwillig; `scripts/publish_plugin.py` füllt es aus dem Manifest)
    /// Kategorie: images, links, documents, text, media, files, other
    var category: String?
    var author: String?
    var homepage: String?
    /// Rechte aus dem Manifest (`network`, `run`, `clipboard`), zum Anzeigen vor dem Laden
    var permissions: [String]?
    /// Namen der Programme, die das Plugin lädt
    var tools: [String]?
    /// Datum der Veröffentlichung dieser Version, JJJJ-MM-TT
    var updated: String?
    /// Seit wann das Plugin in der Galerie steht, JJJJ-MM-TT (`build_gallery.py` behält es bei
    /// neuen Versionen bei)
    var added: String?
    /// Wie oft das Plugin geladen wurde, alle Versionen zusammen (zählt GitHub an den Dateien
    /// des Releases `plugin-galerie`, siehe scripts/gallery_downloads.py)
    var downloads: Int?
    /// Größe der .bdrop-Datei in Bytes (ohne nachgeladene Programme)
    var size: Int?
    /// Größe der Programme aus `tools`, wie sie auf dem Mac liegen (Bytes)
    var toolsSize: Int?
}

extension PluginCatalogEntry {
    /// So lange gilt ein Plugin in der Galerie als neu (Nutzerwunsch: zwei Monate)
    static let newPeriod: TimeInterval = 61 * 24 * 3600

    /// Neu in der Galerie: höchstens zwei Monate seit `added`. Ältere Kataloge ohne `added`
    /// nehmen das Datum der Version
    var isNew: Bool {
        guard let text = added ?? updated else { return false }
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(identifier: "UTC")
        format.dateFormat = "yyyy-MM-dd"
        guard let date = format.date(from: text) else { return false }
        return Date().timeIntervalSince(date) < Self.newPeriod
    }
}

struct PluginCatalog: Codable, Equatable {
    var schema: Int = 1
    var plugins: [PluginCatalogEntry]
}

/// Verwaltet die Plugins: installieren, entfernen, Reihenfolge, Einstellungen, Rechte
/// und den Abgleich mit dem Katalog.
///
/// Leistung: Im Ruhezustand tut die Verwaltung nichts. Plugins werden beim Start einmal
/// gelesen; der Katalog wird höchstens einmal am Tag abgefragt und nur, wenn Plugins
/// eingeschaltet sind. Skripte laufen erst, wenn ein Plugin gestartet wird.
final class PluginManager: ObservableObject {
    static let shared = PluginManager()

    /// Katalog (Galerie). Er liegt im Repository von BarDrop auf dem eigenen Zweig
    /// `plugin-katalog`: Plugins dort einzutragen baut kein Release (ein Push auf `main`
    /// täte das). Eintragen mit `scripts/publish_plugin.py`.
    static let catalogURL = URL(string: "https://raw.githubusercontent.com/zzuuuiii/BarDrop/plugin-katalog/index.json")!

    /// Installierte Plugins in der eingestellten Reihenfolge (die erste passende läuft
    /// automatisch). Standard-Plugins stehen vor den importierten.
    @Published private(set) var plugins: [InstalledPlugin] = []
    @Published private(set) var states: [String: PluginState] = [:]
    /// Standard-Plugins, die der Katalog nennt, die aber nicht geladen werden konnten
    @Published private(set) var missingStandard: [PluginCatalogEntry] = []
    /// Weitere Plugins im Katalog (nicht Standard, noch nicht installiert)
    @Published private(set) var catalogExtras: [PluginCatalogEntry] = []
    /// Die meistgeladenen noch nicht installierten Plugins für die Startseite (ohne Zahlen in
    /// der Reihenfolge des Katalogs)
    func popularExtras(_ count: Int = 5) -> [PluginCatalogEntry] {
        let extras = catalogExtras.enumerated().sorted { a, b in
            let da = a.element.downloads ?? 0, db = b.element.downloads ?? 0
            return da != db ? da > db : a.offset < b.offset
        }
        return Array(extras.prefix(count).map(\.element))
    }

    /// Alles, was die Galerie zeigt (auch schon installierte Plugins), in der Reihenfolge des Katalogs
    @Published private(set) var catalogEntries: [PluginCatalogEntry] = []
    @Published private(set) var syncing = false
    /// Gerade aus der Galerie aktualisiert (bis zum Beenden): id → neue Version. Die Liste
    /// zeigt dann „Aktualisiert auf …“ statt Version und Größe.
    @Published private(set) var recentlyUpdated: [String: String] = [:]
    /// Der letzte Abgleich mit dem Katalog ist gescheitert (kein Internet)
    @Published private(set) var syncFailed = false
    /// Plugins, deren Ordner nicht mehr lesbar ist (z. B. nach dem Bearbeiten): Fehlertext
    @Published private(set) var broken: [String: String] = [:]
    /// Letzter Fehler je Plugin (nur bis zum Beenden), sichtbar in den Einstellungen
    @Published var lastErrors: [String: String] = [:]
    /// Geladene Programme, gemeinsam für alle Läufe (lädt jedes Programm nur einmal gleichzeitig)
    lazy var tools = PluginTools(directory: toolsDirectory)
    /// „Programme aktualisieren“ je Plugin: läuft gerade bzw. Ergebnis
    enum ToolRefresh: Equatable { case running, done, failed(String) }
    @Published var toolRefresh: [String: ToolRefresh] = [:]

    /// Programme eines Plugins neu laden (nur die, die es schon geladen und erlaubt hat).
    /// Läuft im Hintergrund; Stand in `toolRefresh`.
    func refreshTools(of plugin: InstalledPlugin) {
        let approved = Set(state(plugin.id).approvedTools)
        let list = (plugin.manifest.tools ?? []).filter { approved.contains($0.approvalKey) }
        guard !list.isEmpty, toolRefresh[plugin.id] != .running else { return }
        toolRefresh[plugin.id] = .running
        PluginLog.shared.record(plugin.id, "programm", "aktualisiere: " + list.map(\.id).joined(separator: ", "))
        let tools = self.tools
        tools.markOutdated(list)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var failure: String?
            for tool in list {
                do {
                    _ = try tools.ensure(tool, owner: plugin.id, ask: { false }, cancelled: { false })
                } catch {
                    failure = (error as? PluginTools.ToolError)?.message ?? error.localizedDescription
                }
            }
            DispatchQueue.main.async {
                self?.toolRefresh[plugin.id] = failure.map { .failed($0) } ?? .done
            }
        }
    }
    /// Laufende und wartende Läufe je Plugin (für „Läuft gerade“ in den Einstellungen)
    @Published var runningCounts: [String: Int] = [:]
    /// Beendet alle Läufe eines Plugins (gesetzt von der Ablage, die sie startet)
    var stopRuns: ((String) -> Void)?

    let baseDirectory: URL
    private var pluginsDirectory: URL { baseDirectory.appendingPathComponent("Plugins", isDirectory: true) }
    var toolsDirectory: URL { baseDirectory.appendingPathComponent("Tools", isDirectory: true) }
    var scratchDirectory: URL { baseDirectory.appendingPathComponent("PluginWork", isDirectory: true) }
    private var stateURL: URL { pluginsDirectory.appendingPathComponent("plugins.json") }
    private var order: [String] = []
    private var lastSync: Date?
    private var cachedCatalog: PluginCatalog?
    private let appVersion: String
    private var enabledObserver: AnyCancellable?

    /// `baseDirectory` nur für Tests; normal ~/Library/Application Support/BarDrop
    init(baseDirectory: URL? = nil, appVersion: String? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.baseDirectory = baseDirectory ?? support.appendingPathComponent("BarDrop", isDirectory: true)
        self.appVersion = appVersion ?? (Bundle.main.object(forInfoDictionaryKey: "BarDropVersion") as? String ?? "1.31.0")
        try? FileManager.default.createDirectory(at: pluginsDirectory, withIntermediateDirectories: true)
        loadState()
        reload()
        // Arbeitsordner laufender Plugins vom letzten Mal sind verwaist
        try? FileManager.default.removeItem(at: scratchDirectory)
    }

    /// Beim Start der App: Katalog abgleichen, wenn die Plugins an sind (höchstens täglich)
    /// Nur der Manager der App räumt die Aktionsleiste auf (nicht die in Tests)
    private var managesActionBar = false

    func start(settings: AppSettings = .shared) {
        managesActionBar = true
        syncActionBar()
        enabledObserver = settings.$pluginsEnabled
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] on in
                self?.syncActionBar()
                if on { self?.syncCatalog(force: true) }
            }
        // Gespeicherten Katalog sofort zeigen: Vorher blieb „Weitere Plugins“ leer, bis man
        // „Aktualisieren“ drückte, weil der tägliche Abgleich den Speicher nicht anwendete
        applyCatalog(cachedCatalog, online: false)
        if settings.pluginsEnabled {
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.syncCatalog(maxAge: Self.syncInterval) }
        }
        // Neue Versionen aus der Galerie kommen von selbst (kein Knopf mehr): alle paar Stunden
        // eine kleine Abfrage (index.json, wenige KB)
        syncTimer = Timer.scheduledTimer(withTimeInterval: Self.syncInterval, repeats: true) { [weak self] _ in
            self?.syncCatalog(maxAge: Self.syncInterval)
        }
        syncTimer?.tolerance = 600
    }

    /// Abstand der Abgleiche im Hintergrund
    static let syncInterval: TimeInterval = 3 * 3600
    private var syncTimer: Timer?

    // MARK: Lesen

    /// Liest alle installierten Plugins neu von der Platte (nach Bearbeiten, Installieren).
    func reload() {
        let fm = FileManager.default
        let dirs = ((try? fm.contentsOfDirectory(at: pluginsDirectory, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
        var found: [InstalledPlugin] = []
        var errors: [String: String] = [:]
        for dir in dirs {
            do {
                let unpacked = try PluginPackage.read(directory: dir, appVersion: appVersion)
                guard unpacked.manifest.id == dir.lastPathComponent else { continue }
                let stamp = PluginPackage.fingerprint(directory: dir)
                found.append(InstalledPlugin(manifest: unpacked.manifest, directory: dir, script: unpacked.script,
                                             fingerprint: stamp, isStandard: states[unpacked.manifest.id]?.isStandard ?? false))
            } catch let error as PluginPackage.PackageError {
                errors[dir.lastPathComponent] = error.message
            } catch {
                errors[dir.lastPathComponent] = error.localizedDescription
            }
        }
        // Reihenfolge: gespeicherte zuerst, neue hinten; Standard-Plugins vor importierten
        found.sort { a, b in
            if a.isStandard != b.isStandard { return a.isStandard }
            let ia = order.firstIndex(of: a.id) ?? Int.max
            let ib = order.firstIndex(of: b.id) ?? Int.max
            if ia != ib { return ia < ib }
            return a.manifest.name.text.localizedCaseInsensitiveCompare(b.manifest.name.text) == .orderedAscending
        }
        // Geänderter Code: Erteilte Rechte gelten nicht mehr
        for plugin in found {
            var state = states[plugin.id] ?? PluginState()
            if state.grantedFingerprint != nil, state.grantedFingerprint != plugin.fingerprint {
                state.granted = []
                state.grantedFingerprint = nil
                states[plugin.id] = state
            }
        }
        if found != plugins { plugins = found }
        if errors != broken { broken = errors }
        order = found.map(\.id)
        saveState()
    }

    /// Liest ein einzelnes Plugin neu, bevor es läuft (es könnte bearbeitet worden sein).
    func refreshed(_ id: String) -> InstalledPlugin? {
        guard let current = plugin(id) else { return nil }
        if PluginPackage.fingerprint(directory: current.directory) != current.fingerprint { reload() }
        return plugin(id)
    }

    func plugin(_ id: String?) -> InstalledPlugin? {
        guard let id else { return nil }
        return plugins.first { $0.id == id }
    }

    func state(_ id: String) -> PluginState { states[id] ?? PluginState() }

    // MARK: Zustand

    private struct Saved: Codable {
        var order: [String]
        var states: [String: PluginState]
        var lastSync: Date?
        var catalog: PluginCatalog?
    }

    private func loadState() {
        guard let data = try? Data(contentsOf: stateURL),
              let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return }
        order = saved.order
        states = saved.states
        lastSync = saved.lastSync
        cachedCatalog = saved.catalog
    }

    private func saveState() {
        let saved = Saved(order: order, states: states, lastSync: lastSync, catalog: cachedCatalog)
        if let data = try? JSONEncoder().encode(saved) { try? data.write(to: stateURL, options: .atomic) }
    }

    func update(_ id: String, _ change: (inout PluginState) -> Void) {
        var state = states[id] ?? PluginState()
        let wasActive = isActive(id)
        change(&state)
        guard state != states[id] else { return }
        states[id] = state
        saveState()
        // Auch Erlauben und Entziehen schalten ein Plugin an oder aus (siehe isOn)
        if isActive(id) != wasActive { syncActionBar() }
    }

    /// Aktionen ausgeschalteter Plugins stehen weder in der Ablage noch in Einstellungen →
    /// Aktionen und zählen nicht zur Grenze der Leiste. Das Plugin merkt sich, dass es dort
    /// stand, und kommt beim Einschalten wieder ans Ende (wenn Platz ist).
    func syncActionBar(settings: AppSettings = .shared) {
        guard managesActionBar else { return }
        var actions = settings.quickActions
        var changed = false
        // Nur installierte Plugins: Ein Standard-Plugin, das gerade nicht geladen ist, oder
        // eines, das sich nicht lesen lässt, behält seinen Platz (Entfernen räumt selbst auf)
        for action in actions where action.kind == .plugin {
            guard let id = action.path, plugin(id) != nil, !isActive(id, settings: settings) else { continue }
            var s = states[id] ?? PluginState()
            s.parkedInActionBar = true
            states[id] = s
            actions.removeAll { $0.id == action.id }
            changed = true
        }
        var returning: [QuickAction] = []
        for plugin in plugins where state(plugin.id).parkedInActionBar && isActive(plugin.id, settings: settings) {
            var s = state(plugin.id)
            s.parkedInActionBar = false
            states[plugin.id] = s
            changed = true
            guard actions.count + returning.count < QuickAction.limit,
                  !actions.contains(where: { $0.kind == .plugin && $0.path == plugin.id }) else { continue }
            returning.append(QuickAction(kind: .plugin, path: plugin.id))
        }
        guard changed else { return }
        saveState()
        if actions != settings.quickActions { settings.quickActions = actions }
        // Zurück in die obere Reihe wie jede neue Aktion
        returning.forEach { settings.addQuickAction($0) }
    }

    /// Eingeschaltet und erlaubt. Ein Plugin ohne Erlaubnis gilt als aus: Vorher stand in den
    /// Einstellungen „Ein“ und zugleich „Braucht deine Erlaubnis“, es lief aber nicht. Einschalten
    /// fragt erst nach der Erlaubnis (PluginDialogs.authorize)
    func isOn(_ plugin: InstalledPlugin) -> Bool {
        state(plugin.id).enabled && isFullyAuthorized(plugin)
    }

    /// Ist das Plugin eingeschaltet (und die Plugins überhaupt)?
    func isActive(_ id: String?, settings: AppSettings = .shared) -> Bool {
        guard settings.pluginsEnabled, let plugin = plugin(id) else { return false }
        return isOn(plugin)
    }

    var activePlugins: [InstalledPlugin] {
        guard AppSettings.shared.pluginsEnabled else { return [] }
        return plugins.filter { isOn($0) }
    }

    /// Braucht ein eingeschaltetes Plugin gezielt diese Adresse als Link? (Beim Hineinziehen
    /// aus dem Browser kommt oft ein Vorschaubild mit; dann wird trotzdem der Link übernommen.)
    /// Plugins, die jede Adresse annehmen, zählen nicht: Sonst wurde jedes Bild aus dem Web,
    /// das in einem Link steckt (Google-Bildersuche), zum Link.
    func wantsLink(_ url: URL) -> Bool {
        activePlugins.contains { PluginMatcher.specificallyMatchesLink($0.manifest.match, url) }
    }

    func isAutomatic(_ plugin: InstalledPlugin) -> Bool {
        guard plugin.manifest.allTriggers.contains(.automatic) else { return false }
        return state(plugin.id).automatic ?? plugin.manifest.automaticDefault
    }

    func value(_ spec: PluginSettingSpec, of id: String) -> PluginValue {
        state(id).values[spec.key] ?? spec.defaultValue
    }

    func settingsValues(of plugin: InstalledPlugin) -> [String: Any] {
        var values: [String: Any] = [:]
        for spec in plugin.manifest.settings ?? [] { values[spec.key] = value(spec, of: plugin.id).any }
        values["replaceOriginal"] = state(plugin.id).replaceOriginal
        return values
    }

    /// Hat der Nutzer dem jetzigen Hinweis des Plugins zugestimmt? (Ohne Hinweis: ja)
    func hasConsented(_ plugin: InstalledPlugin) -> Bool {
        guard let consent = plugin.manifest.consent else { return true }
        let s = state(plugin.id)
        guard s.consented else { return false }
        return s.consentedText == nil || s.consentedText == Self.consentKey(consent)
    }

    func recordConsent(_ plugin: InstalledPlugin) {
        update(plugin.id) { s in
            s.consented = true
            s.consentedText = plugin.manifest.consent.map(Self.consentKey)
        }
    }

    /// Alle Sprachen des Hinweises, stabil sortiert
    private static func consentKey(_ text: LocalizedText) -> String {
        text.values.sorted { $0.key < $1.key }.map { $0.key + ":" + $0.value }.joined(separator: "\n")
    }

    func isGranted(_ permission: PluginPermission, for plugin: InstalledPlugin) -> Bool {
        // Text in die Zwischenablage legen fragt auch macOS nicht ab: gilt als erteilt,
        // sobald das Plugin es angibt
        if permission == .clipboard { return true }
        let s = state(plugin.id)
        return s.grantedFingerprint == plugin.fingerprint && s.granted.contains(permission)
    }

    func grant(_ permission: PluginPermission, for plugin: InstalledPlugin) {
        update(plugin.id) { s in
            if s.grantedFingerprint != plugin.fingerprint { s.granted = [] }
            s.grantedFingerprint = plugin.fingerprint
            if !s.granted.contains(permission) { s.granted.append(permission) }
        }
    }

    /// Alles, was das Plugin angibt, auf einmal erteilen: Zustimmung, Rechte und Programme.
    /// Nach „Installieren“ (die Liste stand im Fenster) und „Erlauben“.
    func grantAll(_ plugin: InstalledPlugin) {
        if plugin.manifest.consent != nil, !hasConsented(plugin) { recordConsent(plugin) }
        for permission in plugin.manifest.allPermissions where !isGranted(permission, for: plugin) {
            grant(permission, for: plugin)
        }
        let tools = plugin.manifest.tools ?? []
        if !tools.isEmpty {
            update(plugin.id) { s in
                for tool in tools where !s.approvedTools.contains(tool.approvalKey) { s.approvedTools.append(tool.approvalKey) }
            }
        }
    }

    /// Nach dem Installieren und Erlauben: einschalten und so einstellen, wie das Plugin es
    /// vorsieht (`defaults` im Manifest). Der Nutzer hat gerade alles erlaubt, darum darf hier
    /// auch ein Plugin mit heiklen Rechten gleich automatisch laufen.
    func activateWithDefaults(_ plugin: InstalledPlugin) {
        let defaults = plugin.manifest.defaults
        let triggers = plugin.manifest.allTriggers
        update(plugin.id) { s in
            s.enabled = true
            if triggers.contains(.automatic),
               let automatic = defaults?.automatic ?? plugin.manifest.automaticByDefault {
                s.automatic = automatic
            }
            if plugin.manifest.canReplaceOriginal == true, let replace = defaults?.replaceOriginal {
                s.replaceOriginal = replace
            }
        }
        if defaults?.actionBar == true, triggers.contains(.action) {
            let settings = AppSettings.shared
            let present = settings.quickActions.contains { $0.kind == .plugin && $0.path == plugin.id }
            if !present, settings.quickActions.count < QuickAction.limit {
                settings.addQuickAction(QuickAction(kind: .plugin, path: plugin.id))
            }
        }
        PluginLog.shared.record(plugin.id, "install", "eingeschaltet")
    }

    /// Fehlt noch eine Zustimmung, ein Recht oder ein Programm?
    func isFullyAuthorized(_ plugin: InstalledPlugin) -> Bool {
        hasConsented(plugin)
            && plugin.manifest.allPermissions.allSatisfy { isGranted($0, for: plugin) }
            && (plugin.manifest.tools ?? []).allSatisfy { state(plugin.id).approvedTools.contains($0.approvalKey) }
    }

    /// Zugriff entziehen: Rechte, Programme und Zustimmung. Vor dem nächsten Lauf fragt es neu.
    func revokeAccess(_ id: String) {
        update(id) { s in
            s.granted = []
            s.grantedFingerprint = nil
            s.approvedTools = []
            s.consented = false
            s.consentedText = nil
        }
    }

    /// Reihenfolge ändern (nur innerhalb von Standard- bzw. importierten Plugins)
    func move(_ id: String, by offset: Int) {
        guard let i = plugins.firstIndex(where: { $0.id == id }) else { return }
        let j = i + offset
        guard plugins.indices.contains(j), plugins[i].isStandard == plugins[j].isStandard else { return }
        var list = plugins
        list.swapAt(i, j)
        plugins = list
        order = list.map(\.id)
        saveState()
    }

    /// Reihenfolge nur unter den automatischen Plugins (Einstellungen → Plugins →
    /// Reihenfolge): mit dem nächsten automatischen Plugin darüber bzw. darunter tauschen.
    /// Standard-Plugins bleiben vor den importierten.
    func canMoveAutomatic(_ id: String, by offset: Int) -> Bool {
        let auto = plugins.filter { isAutomatic($0) }
        guard let i = auto.firstIndex(where: { $0.id == id }), auto.indices.contains(i + offset) else { return false }
        return auto[i].isStandard == auto[i + offset].isStandard
    }

    func moveAutomatic(_ id: String, by offset: Int) {
        guard canMoveAutomatic(id, by: offset) else { return }
        let auto = plugins.filter { isAutomatic($0) }.map(\.id)
        guard let i = auto.firstIndex(of: id) else { return }
        let other = auto[i + offset]
        var list = plugins
        guard let from = list.firstIndex(where: { $0.id == id }) else { return }
        let item = list.remove(at: from)
        guard let to = list.firstIndex(where: { $0.id == other }) else { return }
        list.insert(item, at: offset < 0 ? to : to + 1)
        plugins = list
        order = list.map(\.id)
        saveState()
    }

    /// Neue Reihenfolge der automatischen Plugins nach dem Ziehen (Einstellungen → Plugins →
    /// Reihenfolge beim Ablegen). Sie nehmen die Plätze ein, die automatische Plugins schon
    /// hatten; Standard-Plugins bleiben vor den eigenen
    func setAutomaticOrder(_ ids: [String]) {
        var list = plugins
        let slots = list.indices.filter { isAutomatic(list[$0]) }
        let byID = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
        let ordered = ids.compactMap { byID[$0] }
        guard ordered.count == slots.count,
              ordered.map(\.isStandard) == slots.map({ list[$0].isStandard }) else { return }
        for (slot, plugin) in zip(slots, ordered) { list[slot] = plugin }
        guard list != plugins else { return }
        plugins = list
        order = list.map(\.id)
        saveState()
    }

    /// Katalog ohne Abfrage übernehmen (Vorschaubilder und Tests)
    func applyCatalogForPreview(_ catalog: PluginCatalog) {
        cachedCatalog = catalog
        applyCatalog(catalog, online: false)
    }

    // MARK: Installieren

    enum InstallError: Error {
        case package(PluginPackage.PackageError)
        case standardExists
        case failed(String)

        var message: String {
            switch self {
            case .package(let e): return e.message
            case .standardExists:
                return L("A standard plugin with this identifier is already installed.",
                         "Ein Standard-Plugin mit dieser Kennung ist schon installiert.")
            case .failed(let text): return text
            }
        }
    }

    /// Prüft eine .bdrop-Datei, ohne sie zu installieren (für den Dialog vor dem Import)
    func inspect(_ file: URL) throws -> PluginPackage.Unpacked {
        try FileManager.default.createDirectory(at: scratchDirectory, withIntermediateDirectories: true)
        do {
            return try PluginPackage.unpack(file, into: scratchDirectory, appVersion: appVersion)
        } catch let error as PluginPackage.PackageError {
            throw InstallError.package(error)
        }
    }

    /// Übernimmt ein geprüftes, entpacktes Plugin. Eine vorhandene Fassung wird ersetzt,
    /// Einstellungen bleiben; Rechte gelten danach nur weiter, wenn `keepPermissions`.
    @discardableResult
    func install(_ unpacked: PluginPackage.Unpacked, standard: Bool, keepPermissions: Bool = false) throws -> InstalledPlugin {
        let id = unpacked.manifest.id
        if !standard, state(id).isStandard, plugin(id) != nil { throw InstallError.standardExists }
        let fm = FileManager.default
        let target = pluginsDirectory.appendingPathComponent(id, isDirectory: true)
        let staging = pluginsDirectory.appendingPathComponent(".install-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.copyItem(at: unpacked.directory, to: staging)
            if fm.fileExists(atPath: target.path) {
                _ = try fm.replaceItemAt(target, withItemAt: staging)
            } else {
                try fm.moveItem(at: staging, to: target)
            }
        } catch {
            try? fm.removeItem(at: staging)
            throw InstallError.failed(error.localizedDescription)
        }
        try? fm.removeItem(at: unpacked.directory)
        let stamp = PluginPackage.fingerprint(directory: target)
        update(id) { s in
            s.isStandard = standard
            if keepPermissions, s.grantedFingerprint != nil {
                // Aktualisierung aus dem Katalog: Rechte, die es noch braucht, bleiben
                s.granted = s.granted.filter { unpacked.manifest.allPermissions.contains($0) }
                s.grantedFingerprint = stamp
            } else {
                s.granted = []
                s.grantedFingerprint = nil
            }
        }
        if !order.contains(id) { order.append(id) }
        PluginLog.shared.record(id, "install", "\(unpacked.manifest.version)\(standard ? " (Standard)" : "")")
        reload()
        guard let installed = plugin(id) else { throw InstallError.failed(L("The plugin couldn’t be read.", "Das Plugin ließ sich nicht lesen.")) }
        return installed
    }

    /// Ordner eines installierten Plugins (auch eines, das sich nicht lesen lässt)
    func folder(of id: String) -> URL {
        pluginsDirectory.appendingPathComponent(id, isDirectory: true)
    }

    /// Entfernt ein Plugin, das sich nicht mehr lesen lässt (außer Standard-Plugins)
    func removeBroken(_ id: String) {
        guard broken[id] != nil, !state(id).isStandard else { return }
        uninstall(id)
    }

    /// Entfernt ein importiertes Plugin. Standard-Plugins lassen sich nur ausschalten.
    func remove(_ id: String) {
        guard let plugin = plugin(id), !plugin.isStandard else { return }
        uninstall(id)
    }

    private func uninstall(_ id: String) {
        PluginLog.shared.record(id, "install", "entfernt")
        try? FileManager.default.removeItem(at: pluginsDirectory.appendingPathComponent(id, isDirectory: true))
        states.removeValue(forKey: id)
        order.removeAll { $0 == id }
        reload()
        // Steht es in der Galerie, gehört es wieder zu den ladbaren (Top 5 auf der Startseite);
        // vorher wurde die Liste erst beim nächsten Abgleich neu gebildet (Nutzer, 24.10.2026)
        catalogExtras = catalogEntries.filter { $0.standard != true && plugin($0.id) == nil }
        // Aktionen dieses Plugins aus der Leiste nehmen
        let settings = AppSettings.shared
        if settings.quickActions.contains(where: { $0.kind == .plugin && $0.path == id }) {
            settings.quickActions.removeAll { $0.kind == .plugin && $0.path == id }
        }
    }

    // MARK: Katalog

    /// Gleicht mit dem Katalog ab: Standard-Plugins installieren und still aktualisieren,
    /// zurückgezogene entfernen. Ohne `force` höchstens einmal am Tag.
    /// `maxAge`: so alt darf der letzte Abgleich sein (im Hintergrund ein Tag; beim Öffnen
    /// der Plugin-Einstellungen kürzer, damit neue Plugins der Galerie bald erscheinen)
    func syncCatalog(force: Bool = false, maxAge: TimeInterval = 24 * 3600, completion: (() -> Void)? = nil) {
        guard AppSettings.shared.pluginsEnabled, !syncing else { completion?(); return }
        if !force, let lastSync, Date().timeIntervalSince(lastSync) < maxAge { completion?(); return }
        syncing = true
        var request = URLRequest(url: Self.catalogURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("BarDrop/\(appVersion)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            let ok = (response as? HTTPURLResponse)?.statusCode == 200
            let catalog = ok ? data.flatMap { try? JSONDecoder().decode(PluginCatalog.self, from: $0) } : nil
            DispatchQueue.main.async {
                guard let self else { return }
                guard let catalog, catalog.schema == 1 else {
                    self.syncing = false
                    self.syncFailed = true
                    self.applyCatalog(self.cachedCatalog, online: false)
                    completion?()
                    return
                }
                self.cachedCatalog = catalog
                self.lastSync = Date()
                self.syncFailed = false
                self.saveState()
                self.applyCatalog(catalog, online: true) {
                    self.syncing = false
                    completion?()
                }
            }
        }.resume()
    }

    private func applyCatalog(_ catalog: PluginCatalog?, online: Bool, completion: @escaping () -> Void = {}) {
        guard let catalog else {
            missingStandard = []
            catalogExtras = []
            catalogEntries = []
            return completion()
        }
        let usable = catalog.plugins.filter { entry in
            entry.minAppVersion.map { !Updater.isNewer($0, than: PluginManifest.releaseVersion(appVersion)) } ?? true
        }
        // Zurückgezogen: entfernen, auch Standard-Plugins (das darf nur der Katalog)
        for entry in catalog.plugins where entry.removed == true && plugin(entry.id) != nil {
            if state(entry.id).isStandard || entry.standard == true { uninstall(entry.id) }
        }
        let live = usable.filter { $0.removed != true }
        catalogExtras = live.filter { $0.standard != true && plugin($0.id) == nil }
        catalogEntries = live
        let needed = live.filter { entry in
            let standard = entry.standard == true || state(entry.id).isStandard
            // Aus der Galerie geladene Plugins bekommen neue Versionen ebenfalls
            guard standard || state(entry.id).fromCatalog else { return false }
            guard let installed = plugin(entry.id) else { return standard }
            // Plugins aus der Galerie brauchen keine Erlaubnis. Fehlt sie trotzdem (Dateien
            // geändert, ältere Installation), wird die geprüfte Fassung neu geladen und erlaubt
            return Updater.isNewer(entry.version, than: installed.manifest.version) || !isFullyAuthorized(installed)
        }
        guard online, !needed.isEmpty else {
            missingStandard = live.filter { $0.standard == true && plugin($0.id) == nil }
            return completion()
        }
        let group = DispatchGroup()
        for entry in needed {
            group.enter()
            let oldVersion = plugin(entry.id)?.manifest.version
            download(entry) { [weak self] result in
                if let self, let unpacked = result,
                   let installed = try? self.install(unpacked, standard: entry.standard == true || self.state(entry.id).isStandard,
                                                     keepPermissions: true) {
                    // Aus dem eigenen Katalog (geprüft, Prüfsumme stimmt): braucht keine Erlaubnis
                    self.grantAll(installed)
                    // Nur echte neue Versionen melden, nicht das Neuladen ohne Erlaubnis
                    if let oldVersion, oldVersion != unpacked.manifest.version {
                        self.recentlyUpdated[entry.id] = unpacked.manifest.version
                        PluginLog.shared.record(entry.id, "install", "aktualisiert auf \(unpacked.manifest.version)")
                    }
                }
                group.leave()
            }
        }
        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            self.missingStandard = live.filter { $0.standard == true && self.plugin($0.id) == nil }
            completion()
        }
    }

    /// Lädt ein Plugin aus dem Katalog und prüft seine Prüfsumme
    private func download(_ entry: PluginCatalogEntry, completion: @escaping (PluginPackage.Unpacked?) -> Void) {
        guard let url = URL(string: entry.url), url.scheme == "https" else { return completion(nil) }
        URLSession.shared.downloadTask(with: url) { [weak self] file, response, _ in
            guard let self, let file, (response as? HTTPURLResponse)?.statusCode == 200,
                  PluginPackage.sha256(of: file)?.lowercased() == entry.sha256.lowercased() else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let renamed = file.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".bdrop")
            try? FileManager.default.moveItem(at: file, to: renamed)
            let unpacked = try? self.inspect(renamed)
            try? FileManager.default.removeItem(at: renamed)
            DispatchQueue.main.async {
                completion(unpacked?.manifest.id == entry.id ? unpacked : nil)
            }
        }.resume()
    }

    /// Installiert ein weiteres Plugin aus dem Katalog (nicht Standard). Plugins aus dem
    /// eigenen Katalog sind geprüft und kommen mit Prüfsumme: Sie bekommen gleich alles, was
    /// sie angeben, ohne Erlauben-Fenster. Ändert jemand danach ihre Dateien, gilt das nicht
    /// mehr (Rechte hängen am Fingerabdruck) und es wird wie sonst gefragt.
    func installFromCatalog(_ entry: PluginCatalogEntry, completion: @escaping (Bool) -> Void) {
        download(entry) { [weak self] unpacked in
            guard let self, let unpacked, let installed = try? self.install(unpacked, standard: false) else {
                return completion(false)
            }
            self.grantAll(installed)
            self.update(entry.id) { $0.fromCatalog = true }
            self.catalogExtras.removeAll { $0.id == entry.id }
            completion(true)
        }
    }

    /// Alles zurücksetzen (Einstellungen → Alle Einstellungen zurücksetzen): Plugins
    /// bleiben installiert, sind aber aus und haben keine Rechte mehr.
    func resetAll() {
        for id in states.keys {
            update(id) { s in
                let standard = s.isStandard
                s = PluginState()
                s.isStandard = standard
            }
        }
    }
}
