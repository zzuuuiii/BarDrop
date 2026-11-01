import AppKit

/// Links von der Website: Der Plus-Knopf einer Plugin-Karte öffnet
/// `bardrop://plugin/install?id=<ID>`. BarDrop nimmt aus dem Link nur die ID und sucht sie
/// im eigenen Katalog (`PluginManager.catalogURL`); Adressen oder Dateien aus dem Link werden
/// nie geladen, so kann keine fremde Seite etwas Beliebiges installieren. Installiert wird erst
/// nach „Laden“, über denselben Weg wie in der Galerie (`GalleryRow.install`).
enum PluginLink {
    static let scheme = "bardrop"

    /// Die Plugin-ID aus einem Link, oder nil, wenn es kein gültiger Installationslink ist:
    /// nur `bardrop://plugin/install`, ID aus Buchstaben, Ziffern, `.`, `-`, `_`, höchstens 200 Zeichen
    static func installID(from url: URL) -> String? {
        guard url.scheme?.lowercased() == scheme, url.host?.lowercased() == "plugin",
              url.path == "/install" || url.path == "/install/",
              let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                  .queryItems?.first(where: { $0.name == "id" })?.value,
              (1...200).contains(id.count),
              id.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) && $0.isASCII || "._-".unicodeScalars.contains($0) })
        else { return nil }
        return id
    }
}

/// Bearbeitet die Links nacheinander: immer nur ein Fenster, weitere warten. Derselbe Link
/// mehrmals hintereinander öffnet kein zweites Fenster.
final class PluginLinkHandler {
    static let shared = PluginLinkHandler()

    /// Öffnet die Einstellungen bei Plugins (vom AppDelegate gesetzt)
    var showPluginsPane: (() -> Void)?

    private var queue: [String] = []
    private var busy = false

    func handle(_ id: String) {
        guard !queue.contains(id) else { return }
        queue.append(id)
        next()
    }

    private func next() {
        guard !busy, let id = queue.first else { return }
        busy = true
        Log.app.info("Plugin-Link: \(id, privacy: .public)")
        loadCatalog { [weak self] catalog in
            self?.present(id, catalog: catalog) {
                self?.queue.removeFirst()
                self?.busy = false
                self?.next()
            }
        }
    }

    /// Immer frisch aus dem Katalog: Der Link soll auch gehen, wenn Plugins aus sind oder der
    /// letzte Abgleich älter ist (`syncCatalog` fragt dann nicht)
    private func loadCatalog(_ done: @escaping (PluginCatalog?) -> Void) {
        var request = URLRequest(url: PluginManager.catalogURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("BarDrop/\(Updater.shared.currentVersion)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { data, response, _ in
            let ok = (response as? HTTPURLResponse)?.statusCode == 200
            let catalog = ok ? data.flatMap { try? JSONDecoder().decode(PluginCatalog.self, from: $0) } : nil
            DispatchQueue.main.async { done(catalog?.schema == 1 ? catalog : nil) }
        }.resume()
    }

    private func present(_ id: String, catalog: PluginCatalog?, done: @escaping () -> Void) {
        let manager = PluginManager.shared
        guard let catalog else {
            message(L("The plugin gallery can’t be reached", "Die Plugin-Galerie ist nicht erreichbar"),
                    L("Check your internet connection and try again.", "Prüf die Internetverbindung und versuch es noch einmal."))
            return done()
        }
        guard let entry = catalog.plugins.first(where: { $0.id == id }), entry.removed != true else {
            message(L("This plugin is no longer in the gallery", "Dieses Plugin gibt es in der Galerie nicht mehr"), nil)
            return done()
        }
        if let minimum = entry.minAppVersion,
           Updater.isNewer(minimum, than: PluginManifest.releaseVersion(Updater.shared.currentVersion)) {
            message(L("“\(entry.name.text)” needs a newer BarDrop", "„\(entry.name.text)“ braucht ein neueres BarDrop"),
                    L("This plugin needs BarDrop \(minimum) or later. Update BarDrop in Settings → About BarDrop.",
                      "Für dieses Plugin brauchst du BarDrop \(minimum) oder neuer. Aktualisieren kannst du in den Einstellungen unter „Über BarDrop“."),
                    icon: entry.icon)
            return done()
        }
        // Schon installiert und aktuell: nur seine Seite zeigen, nichts zweimal installieren
        if let installed = manager.plugin(id), !Updater.isNewer(entry.version, than: installed.manifest.version) {
            openPage(id)
            return done()
        }

        // Vor dem Installieren immer fragen, mit dem, was die Galerie auch zeigt
        let alert = NSAlert()
        if let image = PluginIconView.image(entry.icon, size: 64) { alert.icon = image }
        let update = manager.plugin(id) != nil
        alert.messageText = update ? L("Update “\(entry.name.text)”?", "„\(entry.name.text)“ aktualisieren?")
                                   : L("Get “\(entry.name.text)”?", "„\(entry.name.text)“ laden?")
        var lines: [String] = []
        if let description = entry.description?.text, !description.isEmpty { lines.append(description) }
        var facts: [String] = []
        if let author = entry.author, !author.isEmpty { facts.append(L("by \(author)", "von \(author)")) }
        facts.append(GalleryRow.summary(entry))
        lines.append(facts.joined(separator: " · "))
        alert.informativeText = lines.joined(separator: "\n\n")
        alert.addButton(withTitle: update ? L("Update", "Aktualisieren") : L("Get", "Laden"))
        alert.addButton(withTitle: L("Cancel", "Abbrechen"))
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return done() }

        GalleryRow.install(entry, manager: manager) { [weak self] ok in
            if ok {
                self?.openPage(id)
            } else {
                self?.message(L("“\(entry.name.text)” couldn’t be loaded", "„\(entry.name.text)“ konnte nicht geladen werden"),
                              L("Try again later or get it in Settings → Plugins.",
                                "Versuch es später noch einmal oder lade es unter Einstellungen → Plugins."),
                              icon: entry.icon)
            }
            done()
        }
    }

    /// Einstellungen → Plugins mit der Seite dieses Plugins
    private func openPage(_ id: String) {
        showPluginsPane?()
        // Erst im nächsten Durchlauf: Der Wechsel des Bereichs setzt die Unterseite auf die Liste zurück
        DispatchQueue.main.async { SettingsNavigation.shared.openPluginPage(.plugin(id)) }
    }

    private func message(_ title: String, _ text: String?, icon: PluginManifest.Icon? = nil) {
        let alert = NSAlert()
        if let icon, let image = PluginIconView.image(icon, size: 64) { alert.icon = image }
        alert.messageText = title
        if let text { alert.informativeText = text }
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
