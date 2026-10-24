import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ShelfFile: Codable, Hashable, Identifiable {
    var id = UUID()
    var url: URL
    /// true, wenn die Datei von BarDrop selbst angelegt wurde (Bild aus dem Web, Text, Link …)
    /// und beim Entfernen gelöscht werden darf.
    var owned: Bool
    /// Lesezeichen auf Dateien des Nutzers (nach boring.notch): Wird die Datei
    /// verschoben oder umbenannt, findet BarDrop sie darüber wieder.
    var bookmark: Data?
    /// Bei einer Kopie: Lesezeichen auf die Originaldatei („Im Finder zeigen“ zeigt sie)
    var originBookmark: Data?

    init(url: URL, owned: Bool) {
        self.url = url
        self.owned = owned
        if !owned { bookmark = ShelfFile.makeBookmark(url) }
    }

    /// Datei in einem angehefteten Ordner (siehe FolderBrowser): ohne Lesezeichen, das
    /// kostet bei großen Ordnern zu viel, und mit fester Kennung je Pfad
    init(listed url: URL, id: UUID) {
        self.id = id
        self.url = url
        self.owned = false
    }

    /// Kopie einer Datei des Nutzers, die sich ihr Original merkt
    init(copy url: URL, of original: URL) {
        self.init(url: url, owned: true)
        originBookmark = ShelfFile.makeBookmark(original)
    }

    /// Das Original einer Kopie, sofern es noch existiert und nicht im Papierkorb liegt
    func originURL() -> URL? {
        guard let originBookmark else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: originBookmark, options: [.withoutUI, .withoutMounting],
                                 relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        let path = url.path
        guard FileManager.default.fileExists(atPath: path),
              !path.contains("/.Trash/"), !path.contains("/.Trashes/") else { return nil }
        return url
    }

    static func makeBookmark(_ url: URL) -> Data? {
        try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// Aktueller Ort laut Lesezeichen, sofern die Datei noch existiert und nicht im Papierkorb liegt.
    func resolvedURL() -> URL? {
        guard let bookmark else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
                                 relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        let path = url.path
        guard FileManager.default.fileExists(atPath: path),
              !path.contains("/.Trash/"), !path.contains("/.Trashes/") else { return nil }
        return url
    }

    /// Name des Laufwerks, wenn die Datei auf einem externen Laufwerk oder Netzlaufwerk
    /// liegt, das gerade nicht angeschlossen ist. Solche Einträge bleiben in der Ablage
    /// und sind wieder da, sobald das Laufwerk zurück ist.
    var offlineVolumeName: String? { Self.offlineVolumeName(of: url) }

    /// Wie `offlineVolumeName`, aber kurz zwischengespeichert: Kacheln fragen das bei
    /// jedem Neuzeichnen, und eine Abfrage an ein Netzlaufwerk kann dauern.
    var offlineVolumeNameForDisplay: String? { Self.offlineVolumeName(of: url, cached: true) }

    static func offlineVolumeName(of url: URL, cached: Bool = false) -> String? {
        let parts = url.standardizedFileURL.pathComponents      // ["/", "Volumes", "Stick", …]
        guard parts.count > 3, parts[1] == "Volumes" else { return nil }
        let root = "/Volumes/" + parts[2]
        if cached, let online = VolumeState.cached(root) { return online ? nil : parts[2] }
        // Angeschlossen: Der Ordner ist selbst der Einhängepunkt eines Laufwerks
        let mount = try? URL(fileURLWithPath: root, isDirectory: true).resourceValues(forKeys: [.volumeURLKey]).volume
        let online = mount?.standardizedFileURL.path == root
        VolumeState.store(root, online: online)
        return online ? nil : parts[2]
    }
}

/// Ob ein Laufwerk angeschlossen ist, für zwei Sekunden gemerkt; beim An- oder
/// Abstecken eines Laufwerks sofort vergessen.
private enum VolumeState {
    private static let lock = NSLock()
    private static var states: [String: (online: Bool, at: Date)] = [:]
    private static let observers: [NSObjectProtocol] = {
        let center = NSWorkspace.shared.notificationCenter
        return [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification].map {
            center.addObserver(forName: $0, object: nil, queue: nil) { _ in
                VolumeState.lock.lock(); VolumeState.states.removeAll(); VolumeState.lock.unlock()
            }
        }
    }()

    static func cached(_ root: String) -> Bool? {
        _ = observers
        lock.lock(); defer { lock.unlock() }
        guard let s = states[root], Date().timeIntervalSince(s.at) < 2 else { return nil }
        return s.online
    }

    static func store(_ root: String, online: Bool) {
        lock.lock(); states[root] = (online, Date()); lock.unlock()
    }
}

struct ShelfEntry: Codable, Hashable, Identifiable {
    var id = UUID()
    var files: [ShelfFile]
    var added = Date()

    var urls: [URL] { files.map(\.url) }
    var isStack: Bool { files.count > 1 }

    var title: String {
        if files.count == 1 { return ShelfEntry.displayName(for: files[0].url) }
        return L("\(files.count) items", "\(files.count) Objekte")
    }

    static func displayName(for url: URL) -> String {
        if url.pathExtension.lowercased() == "webloc" { return url.deletingPathExtension().lastPathComponent }
        return url.lastPathComponent
    }
}

/// Liest jeden Eintrag einzeln: Ein beschädigter Eintrag kostet nicht die ganze Ablage
/// (nach boring.notch, ShelfPersistenceService).
private struct LossyEntry: Decodable {
    let entry: ShelfEntry?
    init(from decoder: Decoder) throws {
        entry = try? ShelfEntry(from: decoder)
    }
}

/// Ein Entfernen, das sich widerrufen lässt: welche Dateien aus welchen Einträgen
/// genommen wurden und an welcher Stelle diese Einträge standen.
final class ShelfRemoval {
    struct Item {
        let index: Int
        let before: ShelfEntry
    }
    let items: [Item]
    let fileIDs: Set<UUID>
    /// Eigene Dateien, die bis zum Verfall des Widerrufens aufgehoben werden
    let heldFiles: [ShelfFile]
    /// In den Papierkorb gelegt: alter Ort → Ort im Papierkorb. Widerrufen legt sie zurück.
    let trashed: [URL: URL]
    /// Aus einem angehefteten Ordner in den Papierkorb gelegt: Widerrufen legt sie nur
    /// zurück in den Ordner, nicht in die Ablage
    let putBackOnly: Bool

    init(items: [Item], fileIDs: Set<UUID>, heldFiles: [ShelfFile], trashed: [URL: URL] = [:],
         putBackOnly: Bool = false) {
        self.items = items
        self.fileIDs = fileIDs
        self.heldFiles = heldFiles
        self.trashed = trashed
        self.putBackOnly = putBackOnly
    }
}

/// Inhalt der Ablage. Dateien des Nutzers werden referenziert, alles andere
/// (Bilder aus dem Web, temporäre Dateien, Links, Text) liegt als eigene Datei
/// in Application Support (siehe ContentImporter).
final class ShelfStore: ObservableObject {
    @Published private(set) var entries: [ShelfEntry] = [] {
        didSet { if loaded { save() } }
    }
    /// Objekte, die gerade übernommen werden (Kopieren, Herunterladen)
    @Published private(set) var pendingImports = 0
    /// Der Nutzer hat etwas abgelegt oder eingefügt (nicht: Ergebnisse von Aktionen,
    /// Bildschirmfotos, Widerrufen). Für Plugins, die automatisch laufen.
    var onUserDrop: (([ShelfFile]) -> Void)?

    private let baseDir: URL
    private let itemsDir: URL
    private let dbURL: URL
    private let importer: ContentImporter
    private var loaded = false
    /// Einträge, die diese Version nicht lesen kann, als rohes JSON. Sie werden beim
    /// Speichern unverändert mitgeschrieben: So gehen sie nicht verloren, und solange
    /// es sie gibt, wird nicht aufgeräumt (ihre Dateien könnten noch gebraucht werden).
    private var unreadableEntries: [Any] = []

    /// Aus der Ablage genommene eigene Dateien, die erst später gelöscht werden.
    /// Schlägt das Herausziehen fehl, kommen sie von hier zurück.
    private var pendingDeletion: [URL: ShelfFile] = [:]

    /// Widerrufen und Wiederholen für alles, was aus der Ablage genommen wird.
    let undoManager = UndoManager()
    /// Widerrufbare Entfernungen, älteste zuerst. Fällt eine heraus, werden ihre
    /// eigenen Dateien gelöscht.
    private var removals: [ShelfRemoval] = []
    static let undoDepth = 30

    static var acceptedTypes: [NSPasteboard.PasteboardType] {
        var types: [NSPasteboard.PasteboardType] = [.fileURL, .URL, .string]
        types += PasteboardSnapshot.imageTypes.map { $0.0 }
        types.append(.html)
        types.append(.pdf)
        types += NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
        return types
    }

    /// Nur die echte Ablage schreibt ins Diagnoseprotokoll, nicht die Vorführablagen der
    /// Einführung (sonst sähe dort z. B. das Leeren der Vorführung wie echtes Entfernen aus)
    private let logsDiagnostics: Bool
    private var diagnostics: Diagnostics? { logsDiagnostics ? Diagnostics.shared : nil }

    /// Liste der Ablage am üblichen Ort (FolderAccess.askOnceAtLaunch liest sie vor dem Start)
    static var defaultDatabaseURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BarDrop", isDirectory: true)
            .appendingPathComponent("shelf.json")
    }

    /// `baseDirectory` nur für Tests und die Vorführung der Einführung;
    /// normal: ~/Library/Application Support/BarDrop
    init(baseDirectory: URL? = nil) {
        logsDiagnostics = baseDirectory == nil
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        baseDir = baseDirectory ?? support.appendingPathComponent("BarDrop", isDirectory: true)
        itemsDir = baseDir.appendingPathComponent("Items", isDirectory: true)
        dbURL = baseDir.appendingPathComponent("shelf.json")
        try? FileManager.default.createDirectory(at: itemsDir, withIntermediateDirectories: true)
        importer = ContentImporter(storage: itemsDir, convertImages: AppSettings.shared.convertWebImages)
        load()
        importer.onCopyFinished = { [weak self] id, copy in self?.copyFinished(id, copy) }
    }

    /// Eine schon gezeigte Datei ist fertig kopiert: Verweis gegen die Kopie tauschen.
    /// Liegt sie nicht mehr in der Ablage, wird die Kopie wieder gelöscht.
    private func copyFinished(_ id: UUID, _ copy: URL?) {
        guard let copy else {
            Log.importing.error("Kopie fehlgeschlagen, Datei bleibt als Verweis")
            diagnostics?.failure("store", "Kopie fehlgeschlagen, Datei bleibt als Verweis")
            return
        }
        var updated = entries
        for e in updated.indices {
            guard let f = updated[e].files.firstIndex(where: { $0.id == id }) else { continue }
            var file = ShelfFile(copy: copy, of: updated[e].files[f].url)
            file.id = id     // Auswahl und Kachel bleiben dieselben
            // Die Kachel ist schon zu sehen: beim Austausch nicht erneut einblenden
            Thumbnails.shownOnce.insert(copy.path)
            updated[e].files[f] = file
            insertWithoutAnimation { $0 = updated }
            return
        }
        let fm = FileManager.default
        try? fm.removeItem(at: copy)
        let dir = copy.deletingLastPathComponent()
        if dir.path.hasPrefix(itemsDir.path), (try? fm.contentsOfDirectory(atPath: dir.path))?.isEmpty == true {
            try? fm.removeItem(at: dir)
        }
    }

    // MARK: Persistenz

    private func load() {
        defer { loaded = true }
        guard let data = try? Data(contentsOf: dbURL) else { return }
        let decoded: [LossyEntry]
        do {
            decoded = try JSONDecoder().decode([LossyEntry].self, from: data)
        } catch {
            // Liste unlesbar: zur Sicherheit aufheben und nichts aufräumen
            let backup = baseDir.appendingPathComponent("shelf-unlesbar-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: dbURL, to: backup)
            Log.store.error("Liste unlesbar, gesichert: \(error.localizedDescription, privacy: .public)")
            diagnostics?.failure("store", "Liste unlesbar, gesichert", error)
            return
        }
        let broken = decoded.filter { $0.entry == nil }.count
        if broken > 0 {
            Log.store.error("\(broken, privacy: .public) beschädigte Einträge übersprungen")
            diagnostics?.failure("store", "\(broken) beschädigte Einträge übersprungen")
            // Rohdaten aufheben, damit das nächste Speichern sie nicht verwirft
            if let raw = try? JSONSerialization.jsonObject(with: data) as? [Any], raw.count == decoded.count {
                unreadableEntries = zip(raw, decoded).filter { $0.1.entry == nil }.map { $0.0 }
            }
        }

        entries = decoded.compactMap(\.entry).compactMap { entry in
            var e = entry
            e.files = e.files.compactMap(Self.locate)
            return e.files.isEmpty ? nil : e
        }
        // Nur aufräumen, wenn alles lesbar war: sonst gehörten die Dateien vielleicht
        // zu einem Eintrag, der gerade nicht gelesen werden konnte. Dasselbe gilt, solange
        // eine früher unlesbare Liste als Sicherung daneben liegt.
        let backups = unreadableBackups
        if broken == 0 && backups.isEmpty {
            removeOrphanedItems()
            save()      // wiedergefundene Orte und neue Lesezeichen festhalten
        } else if broken == 0 {
            for backup in backups {
                Log.store.notice("Aufräumen übersprungen, unlesbare Liste gesichert: \(backup.lastPathComponent, privacy: .public) (\(backup.path, privacy: .private))")
            }
            save()      // wie bisher: wiedergefundene Orte festhalten, nur ohne Aufräumen
        }
        sanitizeExistingItemsOnce()
        Outbox.shared.cleanUp()
    }

    /// Findet eine Datei: am gespeicherten Ort oder über das Lesezeichen (verschoben, umbenannt).
    private static func locate(_ file: ShelfFile) -> ShelfFile? {
        if FileManager.default.fileExists(atPath: file.url.path) {
            var f = file
            if !f.owned && f.bookmark == nil { f.bookmark = ShelfFile.makeBookmark(f.url) }
            return f
        }
        guard !file.owned else { return nil }
        guard let moved = file.resolvedURL() else {
            // Laufwerk nicht angeschlossen: Eintrag behalten statt endgültig zu verlieren
            return file.offlineVolumeName != nil ? file : nil
        }
        var f = file
        f.url = moved
        f.bookmark = ShelfFile.makeBookmark(moved) ?? file.bookmark
        Log.store.info("Datei wiedergefunden: \(moved.lastPathComponent, privacy: .private)")
        return f
    }

    /// Dateien aus älteren Versionen einmalig neu schreiben (Fehler −8060).
    private func sanitizeExistingItemsOnce() {
        let key = "sanitizedOwnedFilesV1"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        for file in entries.flatMap(\.files) where file.owned {
            FileSanitizer.recreate(file.url)
        }
        UserDefaults.standard.set(true, forKey: key)
    }

    /// Löscht gespeicherte Objekte, die zu keinem Eintrag mehr gehören (z. B. nach einem Absturz).
    private func removeOrphanedItems() {
        let fm = FileManager.default
        let used = Set(entries.flatMap { $0.files.filter(\.owned).map { $0.url.deletingLastPathComponent().lastPathComponent } })
        for dir in (try? fm.contentsOfDirectory(atPath: itemsDir.path)) ?? [] where !used.contains(dir) {
            try? fm.removeItem(at: itemsDir.appendingPathComponent(dir))
        }
    }

    /// Gesicherte, unlesbare Listen daneben (`shelf-unlesbar-….json`)
    private var unreadableBackups: [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: baseDir.path)) ?? []
        return names.filter { $0.hasPrefix("shelf-unlesbar-") }.sorted().map { baseDir.appendingPathComponent($0) }
    }

    private func save() {
        do {
            var data = try JSONEncoder().encode(entries)
            // Unlesbare Einträge unverändert hinten anhängen. Die lesbaren bleiben Byte für
            // Byte so, wie JSONEncoder sie schreibt.
            if !unreadableEntries.isEmpty {
                let extra = try JSONSerialization.data(withJSONObject: unreadableEntries)
                if entries.isEmpty {
                    data = extra
                } else {
                    data.removeLast()                    // "]"
                    data.append(UInt8(ascii: ","))
                    data.append(extra.dropFirst())       // ohne "["
                }
            }
            try data.write(to: dbURL, options: .atomic)
        } catch {
            Log.store.error("Speichern fehlgeschlagen: \(error.localizedDescription, privacy: .public)")
            diagnostics?.failure("store", "Speichern fehlgeschlagen", error)
        }
    }

    // MARK: Ändern

    /// Fügt neu abgelegte Objekte hinzu. Ab der eingestellten Anzahl werden sie
    /// zu einem Stapel zusammengefasst, sonst als einzelne Einträge abgelegt.
    func add(_ files: [ShelfFile]) {
        let existing = Set(entries.flatMap { $0.files.map(\.url.standardizedFileURL) })
        let fresh = files.filter { $0.owned || !existing.contains($0.url.standardizedFileURL) }
        guard !fresh.isEmpty else { return }
        let settings = AppSettings.shared
        let newEntries = settings.stackMultiple && fresh.count >= settings.stackThreshold
            ? [ShelfEntry(files: fresh)]
            : fresh.map { ShelfEntry(files: [$0]) }
        // Ohne Animation: Neue Objekte kommen oft erst nach einem Download an, wenn die
        // Ablage keinen Fokus mehr hat. Dann bliebe eine Einblend-Animation unsichtbar am
        // Anfang hängen, bis sich die Ablage neu öffnet.
        insertWithoutAnimation { $0.insert(contentsOf: newEntries, at: 0) }
    }

    /// Legt Objekte auf einen vorhandenen Eintrag: Er wird zum Stapel bzw. ergänzt.
    func append(_ files: [ShelfFile], to entryID: UUID) {
        guard let idx = entries.firstIndex(where: { $0.id == entryID }) else { return add(files) }
        let existing = Set(entries[idx].files.map(\.url.standardizedFileURL))
        let fresh = files.filter { $0.owned || !existing.contains($0.url.standardizedFileURL) }
        guard !fresh.isEmpty else { return }
        // Bereits anderswo in der Ablage liegende Dateien dorthin verschieben statt doppelt führen
        let freshURLs = Set(fresh.map(\.url.standardizedFileURL))
        var updated = entries
        for i in updated.indices where i != idx {
            updated[i].files.removeAll { freshURLs.contains($0.url.standardizedFileURL) }
        }
        updated[idx].files += fresh
        let targetID = updated[idx].id
        updated.removeAll { $0.files.isEmpty && $0.id != targetID }
        insertWithoutAnimation { $0 = updated }
    }

    /// Ändert die Einträge ohne Animation (siehe `add`).
    private func insertWithoutAnimation(_ change: (inout [ShelfEntry]) -> Void) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { change(&entries) }
    }

    /// Fasst mehrere Einträge zu einem Stapel zusammen. Liegt `target` dabei,
    /// entsteht der Stapel an dessen Stelle und mit dessen Dateien vorn.
    func merge(_ ids: Set<UUID>, into target: UUID? = nil) {
        var all = ids
        if let target { all.insert(target) }
        var members = entries.filter { all.contains($0.id) }
        if let target, let t = members.firstIndex(where: { $0.id == target }) {
            members.insert(members.remove(at: t), at: 0)
        }
        let anchorID = target ?? members.first?.id
        guard members.count > 1, let first = entries.firstIndex(where: { $0.id == anchorID }) else { return }
        let ids = all
        var stack = ShelfEntry(files: members.flatMap(\.files))
        if let target { stack.id = target }
        stack.added = members.map(\.added).max() ?? Date()
        let before = entries[..<first].filter { ids.contains($0.id) }.count
        var updated = entries
        updated.removeAll { ids.contains($0.id) }
        updated.insert(stack, at: min(first - before, updated.count))
        withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) { entries = updated }
    }

    /// Löst mehrere Dateien aus einem Stapel und legt sie direkt dahinter ab.
    func detach(_ fileIDs: Set<UUID>, from entryID: UUID) {
        guard let idx = entries.firstIndex(where: { $0.id == entryID }) else { return }
        var updated = entries
        let moved = updated[idx].files.filter { fileIDs.contains($0.id) }
        guard !moved.isEmpty else { return }
        updated[idx].files.removeAll { fileIDs.contains($0.id) }
        updated.insert(contentsOf: moved.map { ShelfEntry(files: [$0]) }, at: idx + 1)
        if updated[idx].files.isEmpty { updated.remove(at: idx) }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) { entries = updated }
    }

    /// Entfernt mehrere Dateien aus einem Stapel (widerrufbar).
    /// Ein Objekt ohne Ausblenden aus der Ablage nehmen, widerrufbar (abgebrochenes Plugin
    /// mit „Original ersetzen“: Sein Platzhalter stand schon an dieser Stelle)
    func removeQuietly(_ fileID: UUID) {
        takeOut([fileID], undoable: true, animated: false)
    }

    func removeFiles(_ fileIDs: Set<UUID>, from entryID: UUID) {
        guard let entry = entries.first(where: { $0.id == entryID }) else { return }
        let ids = Set(entry.files.map(\.id)).intersection(fileIDs)
        takeOut(ids, undoable: true)
    }

    /// Entfernt Einträge, die älter als `interval` Sekunden sind. Nicht widerrufbar: Das
    /// passiert von selbst und soll ⌘Z nicht belegen. Eigene Dateien werden erst nach
    /// 15 Minuten gelöscht.
    func removeExpired(olderThan interval: TimeInterval) {
        guard interval > 0 else { return }
        let cutoff = Date().addingTimeInterval(-interval)
        let expired = entries.filter { $0.added < cutoff }.flatMap(\.files).map(\.id)
        if !expired.isEmpty { takeOut(Set(expired), undoable: false, deleteOwnedAfter: 15 * 60) }
    }

    /// Entfernt alles (widerrufbar).
    func removeAll() {
        takeOut(Set(entries.flatMap(\.files).map(\.id)), undoable: true)
    }

    /// Entfernt Einträge ohne Möglichkeit zum Widerrufen (z. B. die Beispieldatei der Einführung).
    func discard(_ ids: Set<UUID>) {
        let files = entries.filter { ids.contains($0.id) }.flatMap(\.files).map(\.id)
        takeOut(Set(files), undoable: false)
    }

    func unstack(_ id: UUID) {
        guard let idx = entries.firstIndex(where: { $0.id == id }), entries[idx].isStack else { return }
        let singles = entries[idx].files.map { ShelfEntry(files: [$0]) }
        withAnimation(.spring(response: 0.42, dampingFraction: 0.8)) {
            entries.replaceSubrange(idx...idx, with: singles)
        }
    }

    /// Eine Datei wurde verschoben (z. B. über eine Ordner-Aktion): Verweis aktualisieren.
    /// Die Datei gehört danach dem Nutzer und wird beim Entfernen nicht gelöscht.
    func relocate(_ old: URL, to new: URL) {
        let key = old.standardizedFileURL
        // Eine eigene Kopie hat ihren Speicherordner verlassen: leeren Ordner gleich löschen
        let oldDir = key.deletingLastPathComponent()
        if oldDir.path.hasPrefix(itemsDir.standardizedFileURL.path + "/"),
           (try? FileManager.default.contentsOfDirectory(atPath: oldDir.path))?.isEmpty == true {
            try? FileManager.default.removeItem(at: oldDir)
        }
        for e in entries.indices {
            for f in entries[e].files.indices where entries[e].files[f].url.standardizedFileURL == key {
                entries[e].files[f].url = new
                entries[e].files[f].owned = false
                entries[e].files[f].bookmark = ShelfFile.makeBookmark(new)
            }
        }
    }

    /// Entfernt Einträge (widerrufbar).
    func remove(_ ids: Set<UUID>) {
        let files = entries.filter { ids.contains($0.id) }.flatMap(\.files).map(\.id)
        takeOut(Set(files), undoable: true)
    }

    /// Nimmt Dateien aus der Ablage, z. B. nach einer Schnellaktion oder dem Herausziehen.
    /// Von BarDrop selbst gespeicherte Dateien werden erst nach `delay` gelöscht, damit
    /// AirDrop, Mail & Co. sie noch lesen können, und nie, solange sie gerade kopiert werden.
    /// Bis dahin lässt sich das Entfernen widerrufen.
    func removeFiles(at urls: [URL], deleteOwnedAfter delay: TimeInterval) {
        let keys = Set(urls.map(\.standardizedFileURL))
        guard !keys.isEmpty else { return }
        let ids = entries.flatMap(\.files).filter { keys.contains($0.url.standardizedFileURL) }.map(\.id)
        takeOut(Set(ids), undoable: true, deleteOwnedAfter: delay)
    }

    /// Nimmt Dateien aus der Ablage, die es an ihrem Ort nicht mehr gibt (z. B. nach dem
    /// Papierkorb). Nicht widerrufbar, denn zurückholen lassen sie sich nur im Finder.
    func forgetFiles(at urls: [URL]) {
        let keys = Set(urls.map(\.standardizedFileURL))
        guard !keys.isEmpty else { return }
        let ids = entries.flatMap(\.files).filter { keys.contains($0.url.standardizedFileURL) }.map(\.id)
        takeOut(Set(ids), undoable: false)
    }

    /// Legt Dateien wie der Finder in den Papierkorb und nimmt sie aus der Ablage.
    /// ⌘Z legt sie an ihren alten Ort zurück und wieder in die Ablage. `completion`
    /// liefert, wie viele Dateien im Papierkorb gelandet sind.
    /// `intoShelf`: ⌘Z legt Dateien, die nicht in der Ablage lagen, auch in die Ablage
    /// (aus dem Finder auf die Aktion gezogen). Aus einem angehefteten Ordner nicht: Dort
    /// kommen sie nur an ihren Platz zurück.
    func moveToTrash(_ urls: [URL], intoShelf: Bool = true, completion: @escaping (Int) -> Void = { _ in }) {
        guard !urls.isEmpty else { return completion(0) }
        NSWorkspace.shared.recycle(urls) { [weak self] trashed, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    Log.store.error("Papierkorb fehlgeschlagen: \(error.localizedDescription, privacy: .public)")
                }
                self.diagnostics?.record("trash", "\(trashed.count) of \(urls.count) files=\(Diagnostics.anon(urls))")
                if let error { self.diagnostics?.failure("trash", "Papierkorb fehlgeschlagen", error) }
                let mapping = Dictionary(trashed.map { ($0.key.standardizedFileURL, $0.value) },
                                         uniquingKeysWith: { first, _ in first })
                let shelfFiles = self.entries.flatMap(\.files)
                let ids = shelfFiles.filter { mapping[$0.url.standardizedFileURL] != nil }.map(\.id)
                // Direkt aus dem Finder auf die Aktion gezogen: ⌘Z legt sie zurück und
                // ebenfalls in die Ablage (oben, wie neu abgelegt)
                let inShelf = Set(shelfFiles.map(\.url.standardizedFileURL))
                let outside = mapping.keys.filter { !inShelf.contains($0) }.sorted { $0.path < $1.path }
                let extra = outside.map { url -> ShelfRemoval.Item in
                    var file = ShelfFile(url: url, owned: false)
                    file.bookmark = nil
                    return ShelfRemoval.Item(index: 0, before: ShelfEntry(files: [file]))
                }
                if !intoShelf {
                    // Was in der Ablage lag, ist weg wie jede Datei im Papierkorb; Widerrufen
                    // legt alles nur an den alten Ort zurück
                    if !ids.isEmpty { self.takeOut(Set(ids), undoable: false) }
                    if !mapping.isEmpty { self.registerPutBack(mapping) }
                } else if !ids.isEmpty || !extra.isEmpty {
                    self.takeOut(Set(ids), undoable: true, trashed: mapping, extraItems: extra)
                }
                completion(mapping.count)
            }
        }
    }

    // MARK: Entfernen und Widerrufen

    /// Gemeinsamer Weg für alles, was aus der Ablage genommen wird.
    ///
    /// Widerrufbar: Eigene Dateien bleiben auf der Platte, bis das Widerrufen verfällt
    /// (`undoDepth` neuere Entfernungen, Beenden der App) oder `delay` abgelaufen ist.
    /// Nicht widerrufbar: Eigene Dateien werden sofort gelöscht.
    @discardableResult
    private func takeOut(_ fileIDs: Set<UUID>, undoable: Bool, deleteOwnedAfter delay: TimeInterval? = nil,
                         trashed: [URL: URL] = [:], extraItems: [ShelfRemoval.Item] = [],
                         animated: Bool = true) -> ShelfRemoval? {
        guard !fileIDs.isEmpty || !extraItems.isEmpty else { return nil }
        var items: [ShelfRemoval.Item] = []
        var removed: [ShelfFile] = []
        var updated: [ShelfEntry] = []
        for (index, entry) in entries.enumerated() {
            let gone = entry.files.filter { fileIDs.contains($0.id) }
            guard !gone.isEmpty else {
                updated.append(entry)
                continue
            }
            items.append(ShelfRemoval.Item(index: index, before: entry))
            removed += gone
            var rest = entry
            rest.files.removeAll { fileIDs.contains($0.id) }
            if !rest.files.isEmpty { updated.append(rest) }
        }
        guard !removed.isEmpty || !extraItems.isEmpty else { return nil }
        diagnostics?.record("store", "takeOut \(removed.count) undoable=\(undoable) delay=\(delay.map { String(Int($0)) } ?? "–") trashed=\(trashed.count) extra=\(extraItems.count)")
        if !removed.isEmpty {
            if animated {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.88)) { entries = updated }
            } else {
                insertWithoutAnimation { $0 = updated }
            }
        }
        items += extraItems
        let extraFiles = extraItems.flatMap(\.before.files)

        // Im Papierkorb liegende eigene Dateien gehören jetzt dem Papierkorb: nichts löschen
        let owned = removed.filter { $0.owned && trashed[$0.url.standardizedFileURL] == nil }
        guard undoable else {
            if let delay {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.deleteOwnedFiles(owned)
                }
            } else {
                deleteOwnedFiles(owned)
            }
            return nil
        }
        for file in owned { pendingDeletion[file.url.standardizedFileURL] = file }
        if let delay, !owned.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                let due = owned.filter { self.pendingDeletion.removeValue(forKey: $0.url.standardizedFileURL) != nil }
                self.deleteOwnedFiles(due)
            }
        }
        let removal = ShelfRemoval(items: items, fileIDs: Set((removed + extraFiles).map(\.id)),
                                   heldFiles: delay == nil ? owned : [], trashed: trashed)
        removals.append(removal)
        undoManager.registerUndo(withTarget: removal) { [weak self] removal in
            self?.undo(removal)
        }
        if trashed.isEmpty {
            undoManager.setActionName(removed.count == 1 ? L("Remove", "Entfernen") : L("Remove \(removed.count) Items", "\(removed.count) Objekte entfernen"))
        } else {
            undoManager.setActionName(L("Move to Trash", "In den Papierkorb legen"))
        }
        while removals.count > Self.undoDepth {
            expire(removals.removeFirst())
        }
        return removal
    }

    /// Papierkorb aus einem angehefteten Ordner: widerrufbar wie im Finder („Zurücklegen“)
    private func registerPutBack(_ trashed: [URL: URL]) {
        let removal = ShelfRemoval(items: [], fileIDs: [], heldFiles: [], trashed: trashed, putBackOnly: true)
        removals.append(removal)
        undoManager.registerUndo(withTarget: removal) { [weak self] removal in
            self?.undo(removal)
        }
        undoManager.setActionName(L("Move to Trash", "In den Papierkorb legen"))
        while removals.count > Self.undoDepth {
            expire(removals.removeFirst())
        }
    }

    /// Wie viele Dateien das letzte Widerrufen in ihren Ordner zurückgelegt hat
    /// (Papierkorb aus einem angehefteten Ordner) und wo sie jetzt liegen
    private(set) var lastPutBack: [URL] = []

    /// Legt entfernte Dateien zurück an ihren alten Platz. Registriert das Wiederholen.
    private func undo(_ removal: ShelfRemoval) {
        diagnostics?.record("store", "undo files=\(removal.fileIDs.count) trashed=\(removal.trashed.count) putBackOnly=\(removal.putBackOnly)")
        removals.removeAll { $0 === removal }
        let putBack = putBackFromTrash(removal.trashed)
        if removal.putBackOnly {
            lastPutBack = putBack
            guard !putBack.isEmpty else { return }
            // Wiederholen legt sie erneut in den Papierkorb
            undoManager.registerUndo(withTarget: self) { store in
                store.moveToTrash(putBack, intoShelf: false)
                Sounds.trash()
            }
            undoManager.setActionName(L("Move to Trash", "In den Papierkorb legen"))
            return
        }
        let present = Set(entries.flatMap { $0.files.map(\.id) })
        var updated = entries
        var restored = Set<UUID>()
        for item in removal.items.sorted(by: { $0.index < $1.index }) {
            let back: [ShelfFile] = item.before.files.compactMap { file in
                guard removal.fileIDs.contains(file.id), !present.contains(file.id) else { return nil }
                if file.owned { pendingDeletion.removeValue(forKey: file.url.standardizedFileURL) }
                return Self.locate(file)
            }
            guard !back.isEmpty else { continue }
            restored.formUnion(back.map(\.id))
            // Zurückgeholt zählt wie neu abgelegt: sonst nähme „Automatisch entfernen“
            // ein altes Objekt gleich wieder weg, dann ohne Widerrufen
            if let idx = updated.firstIndex(where: { $0.id == item.before.id }) {
                // Eintrag gibt es noch (Stapel): Dateien an ihre alte Stelle im Stapel
                var files = updated[idx].files
                for file in back {
                    let pos = item.before.files.firstIndex { $0.id == file.id } ?? files.count
                    files.insert(file, at: min(pos, files.count))
                }
                updated[idx].files = files
                updated[idx].added = Date()
            } else {
                var entry = item.before
                entry.files = back
                entry.added = Date()
                updated.insert(entry, at: min(item.index, updated.count))
            }
        }
        guard !restored.isEmpty else { return }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) { entries = updated }
        lastRestoredFileIDs = restored
        if removal.trashed.isEmpty {
            undoManager.registerUndo(withTarget: self) { store in
                store.takeOut(restored, undoable: true)
            }
        } else {
            // Wiederholen legt die Dateien erneut in den Papierkorb
            let urls = updated.flatMap(\.files).filter { restored.contains($0.id) }.map(\.url)
            undoManager.registerUndo(withTarget: self) { store in
                store.moveToTrash(urls)
                Sounds.trash()
            }
            undoManager.setActionName(L("Move to Trash", "In den Papierkorb legen"))
        }
    }

    /// Legt Dateien aus dem Papierkorb an ihren alten Ort zurück, wie „Zurücklegen“ im
    /// Finder. Schon im Finder zurückgelegte oder endgültig gelöschte bleiben, wie sie sind.
    @discardableResult
    private func putBackFromTrash(_ trashed: [URL: URL]) -> [URL] {
        let fm = FileManager.default
        var back: [URL] = []
        for (original, inTrash) in trashed {
            guard fm.fileExists(atPath: inTrash.path), !fm.fileExists(atPath: original.path) else { continue }
            do {
                try fm.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: inTrash, to: original)
                back.append(original)
            } catch {
                Log.store.error("Zurücklegen fehlgeschlagen: \(error.localizedDescription, privacy: .public)")
                diagnostics?.failure("store", "Zurücklegen fehlgeschlagen", error)
            }
        }
        return back
    }

    /// Dateien, die das letzte Widerrufen zurückgebracht hat (für die Auswahl).
    private(set) var lastRestoredFileIDs: Set<UUID> = []

    /// Widerruft das letzte Entfernen und liefert, was zurückgekommen ist. Leer, wenn die
    /// Dateien inzwischen weg sind (z. B. Bilder aus dem Web, Minuten nach dem Herausziehen).
    func undoLast() -> Set<UUID> {
        lastRestoredFileIDs = []
        lastPutBack = []
        undoManager.undo()
        return lastRestoredFileIDs
    }

    /// Widerrufen ist für diese Entfernung nicht mehr möglich: aufgehobene Dateien löschen.
    private func expire(_ removal: ShelfRemoval) {
        undoManager.removeAllActions(withTarget: removal)
        let due = removal.heldFiles.filter { pendingDeletion.removeValue(forKey: $0.url.standardizedFileURL) != nil }
        deleteOwnedFiles(due)
    }

    /// Beim Beenden: Widerrufen verfällt, aufgehobene Dateien werden gelöscht.
    func discardUndoHistory() {
        let all = removals
        removals.removeAll()
        all.forEach(expire)
        undoManager.removeAllActions()
    }

    /// Holt eine eigene Datei zurück, die gerade aus der Ablage genommen wurde
    /// (z. B. wenn das Herausziehen fehlgeschlagen ist).
    func restore(_ url: URL) {
        guard let file = pendingDeletion.removeValue(forKey: url.standardizedFileURL),
              FileManager.default.fileExists(atPath: file.url.path) else { return }
        Log.store.info("Objekt nach Fehler zurückgeholt")
        insertWithoutAnimation { $0.insert(ShelfEntry(files: [file]), at: 0) }
    }

    /// Prüft, ob alle Dateien noch da sind. Verschobene Dateien des Nutzers werden über
    /// ihr Lesezeichen wiedergefunden, verschwundene aus der Ablage genommen.
    func pruneMissingFiles() {
        var changed = false
        var updated: [ShelfEntry] = []
        for var e in entries {
            let before = e.files
            e.files = e.files.compactMap(Self.locate)
            if e.files != before { changed = true }
            if !e.files.isEmpty { updated.append(e) }
        }
        if changed {
            diagnostics?.record("store", "prune: missing or moved files updated")
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { entries = updated }
        }
    }

    /// Löscht eigene Dateien, aber erst, wenn sie gerade nirgendwohin kopiert werden.
    private func deleteOwnedFiles(_ files: [ShelfFile]) {
        let itemsPath = itemsDir.path
        for file in files where file.owned {
            DragExporter.shared.whenIdle(file.url) {
                let fm = FileManager.default
                try? fm.removeItem(at: file.url)
                let dir = file.url.deletingLastPathComponent()
                if dir.path.hasPrefix(itemsPath),
                   (try? fm.contentsOfDirectory(atPath: dir.path))?.isEmpty == true {
                    try? fm.removeItem(at: dir)
                }
            }
        }
    }

    // MARK: Aufnehmen

    /// Übernimmt den Inhalt eines Pasteboards (Drag & Drop oder Zwischenablage).
    /// Mit `target` landen die Objekte auf diesem Eintrag (Stapel bilden bzw. ergänzen).
    /// `completion` liefert die Dateien, die daraus entstanden sind.
    func ingest(from pb: NSPasteboard, into target: UUID? = nil, byUser: Bool = false,
                completion: (([URL]) -> Void)? = nil) {
        importer.convertImages = AppSettings.shared.convertWebImages
        importer.alwaysCopy = AppSettings.shared.copyAllFiles
        pendingImports += 1
        let started = Date()
        diagnostics?.record("import", "start types=\(pb.types?.map(\.rawValue).prefix(12).joined(separator: ",") ?? "–") target=\(target != nil) copy=\(AppSettings.shared.copyAllFiles)")
        // Bloßes Ablegen: Dateien gleich zeigen, auch wenn sie noch kopiert werden.
        // Arbeitet danach eine Aktion mit ihnen, braucht sie die fertigen Kopien.
        let showWhileCopying = target == nil && completion == nil
        importer.importContent(of: pb, showWhileCopying: showWhileCopying) { [weak self] files in
            guard let self else { return }
            self.pendingImports = max(0, self.pendingImports - 1)
            self.diagnostics?.record("import", "done \(files.count) in \(Int(Date().timeIntervalSince(started) * 1000)) ms owned=\(files.filter(\.owned).count) files=\(Diagnostics.anon(files.map(\.url)))")
            guard !files.isEmpty else {
                completion?([])
                return
            }
            if let target { self.append(files, to: target) } else { self.add(files) }
            completion?(files.map(\.url))
            if byUser {
                // Nur, was wirklich in der Ablage gelandet ist (schon vorhandene Dateien nicht)
                let present = Set(self.entries.flatMap(\.files).map(\.id))
                let landed = files.filter { present.contains($0.id) }
                if !landed.isEmpty { self.onUserDrop?(landed) }
            }
        }
    }

    /// Fügt den Inhalt der allgemeinen Zwischenablage hinzu.
    func pasteFromClipboard() {
        ingest(from: .general, byUser: true)
    }

    // MARK: Ergebnisse von Plugins

    /// Eintrag und Stelle einer Datei in der Ablage
    func position(of fileID: UUID) -> (entry: Int, file: Int)? {
        for (e, entry) in entries.enumerated() {
            if let f = entry.files.firstIndex(where: { $0.id == fileID }) { return (e, f) }
        }
        return nil
    }

    /// Übernimmt fertige Dateien eines Plugins in den eigenen Speicher (noch nicht in die
    /// Ablage, damit ihre Vorschau schon entstehen kann).
    func adoptResults(_ urls: [URL]) -> [ShelfFile] {
        let fm = FileManager.default
        var files: [ShelfFile] = []
        for url in urls {
            let dir = itemsDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                let target = dir.appendingPathComponent(url.lastPathComponent)
                try fm.moveItem(at: url, to: target)
                files.append(ShelfFile(url: target, owned: true))
            } catch {
                try? fm.removeItem(at: dir)
                diagnostics?.failure("plugin", "Ergebnis übernehmen fehlgeschlagen", error)
            }
        }
        return files
    }

    /// Entpackter Inhalt eines Archivs neben das Archiv: mehrere Dateien als ein Stapel, eine
    /// einzeln. Liegt das Archiv in einem Stapel, kommt der Inhalt dort hinter das Archiv.
    func insertUnpacked(_ files: [ShelfFile], nextTo fileID: UUID?) {
        guard !files.isEmpty else { return }
        var updated = entries
        if let fileID, let pos = position(of: fileID) {
            if updated[pos.entry].isStack {
                updated[pos.entry].files.insert(contentsOf: files, at: pos.file + 1)
            } else {
                updated.insert(ShelfEntry(files: files), at: pos.entry + 1)
            }
        } else {
            updated.insert(ShelfEntry(files: files), at: 0)
        }
        insertWithoutAnimation { $0 = updated }
    }

    /// Legt übernommene Dateien eines Plugins direkt neben das Original (in der angezeigten
    /// Reihenfolge dahinter; in einem Stapel hinter die Datei im Stapel). Mit `replacing`
    /// wird das Original aus der Ablage genommen (widerrufbar). Liegt das Original nicht
    /// mehr in der Ablage, kommen sie nach vorn.
    func insertResults(_ files: [ShelfFile], nextTo fileID: UUID, replacing: Bool) {
        guard !files.isEmpty else { return }
        guard let pos = position(of: fileID) else {
            insertWithoutAnimation { $0.insert(contentsOf: files.map { ShelfEntry(files: [$0]) }, at: 0) }
            return
        }
        var updated = entries
        if updated[pos.entry].isStack {
            updated[pos.entry].files.insert(contentsOf: files, at: pos.file + 1)
        } else {
            // Gespeichert und gezeigt wird neueste zuerst: „dahinter“ ist der nächste Platz
            updated.insert(contentsOf: files.map { ShelfEntry(files: [$0]) }, at: pos.entry + 1)
        }
        insertWithoutAnimation { $0 = updated }
        if replacing {
            // Ohne Ausblenden: Das Ergebnis steht sofort an der Stelle des Originals
            takeOut([fileID], undoable: true, animated: false)
        }
    }
}
