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

    init(url: URL, owned: Bool) {
        self.url = url
        self.owned = owned
        if !owned { bookmark = ShelfFile.makeBookmark(url) }
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

    static func offlineVolumeName(of url: URL) -> String? {
        let parts = url.standardizedFileURL.pathComponents      // ["/", "Volumes", "Stick", …]
        guard parts.count > 3, parts[1] == "Volumes" else { return nil }
        let root = "/Volumes/" + parts[2]
        // Angeschlossen: Der Ordner ist selbst der Einhängepunkt eines Laufwerks
        let mount = try? URL(fileURLWithPath: root, isDirectory: true).resourceValues(forKeys: [.volumeURLKey]).volume
        if let mount, mount.standardizedFileURL.path == root { return nil }
        return parts[2]
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

    init(items: [Item], fileIDs: Set<UUID>, heldFiles: [ShelfFile]) {
        self.items = items
        self.fileIDs = fileIDs
        self.heldFiles = heldFiles
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

    private let baseDir: URL
    private let itemsDir: URL
    private let dbURL: URL
    private let importer: ContentImporter
    private var loaded = false

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

    /// `baseDirectory` nur für Tests; normal: ~/Library/Application Support/BarDrop
    init(baseDirectory: URL? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        baseDir = baseDirectory ?? support.appendingPathComponent("BarDrop", isDirectory: true)
        itemsDir = baseDir.appendingPathComponent("Items", isDirectory: true)
        dbURL = baseDir.appendingPathComponent("shelf.json")
        try? FileManager.default.createDirectory(at: itemsDir, withIntermediateDirectories: true)
        importer = ContentImporter(storage: itemsDir, convertImages: AppSettings.shared.convertWebImages)
        load()
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
            return
        }
        let broken = decoded.filter { $0.entry == nil }.count
        if broken > 0 { Log.store.error("\(broken, privacy: .public) beschädigte Einträge übersprungen") }

        entries = decoded.compactMap(\.entry).compactMap { entry in
            var e = entry
            e.files = e.files.compactMap(Self.locate)
            return e.files.isEmpty ? nil : e
        }
        // Nur aufräumen, wenn alles lesbar war: sonst gehörten die Dateien vielleicht
        // zu einem Eintrag, der gerade nicht gelesen werden konnte.
        if broken == 0 {
            removeOrphanedItems()
            save()      // wiedergefundene Orte und neue Lesezeichen festhalten
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

    private func save() {
        do {
            let data = try JSONEncoder().encode(entries)
            try data.write(to: dbURL, options: .atomic)
        } catch {
            Log.store.error("Speichern fehlgeschlagen: \(error.localizedDescription, privacy: .public)")
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
        withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) {
            entries.insert(contentsOf: newEntries, at: 0)
        }
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
        withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) { entries = updated }
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
    func removeFiles(_ fileIDs: Set<UUID>, from entryID: UUID) {
        guard let entry = entries.first(where: { $0.id == entryID }) else { return }
        let ids = Set(entry.files.map(\.id)).intersection(fileIDs)
        takeOut(ids, undoable: true)
    }

    /// Entfernt Einträge, die älter als `interval` Sekunden sind. Nicht widerrufbar:
    /// Das passiert von selbst, nicht durch eine Handlung des Nutzers.
    func removeExpired(olderThan interval: TimeInterval) {
        guard interval > 0 else { return }
        let cutoff = Date().addingTimeInterval(-interval)
        let expired = entries.filter { $0.added < cutoff }.flatMap(\.files).map(\.id)
        if !expired.isEmpty { takeOut(Set(expired), undoable: false) }
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

    // MARK: Entfernen und Widerrufen

    /// Gemeinsamer Weg für alles, was aus der Ablage genommen wird.
    ///
    /// Widerrufbar: Eigene Dateien bleiben auf der Platte, bis das Widerrufen verfällt
    /// (`undoDepth` neuere Entfernungen, Beenden der App) oder `delay` abgelaufen ist.
    /// Nicht widerrufbar: Eigene Dateien werden sofort gelöscht.
    @discardableResult
    private func takeOut(_ fileIDs: Set<UUID>, undoable: Bool, deleteOwnedAfter delay: TimeInterval? = nil) -> ShelfRemoval? {
        guard !fileIDs.isEmpty else { return nil }
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
        guard !removed.isEmpty else { return nil }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.88)) { entries = updated }

        let owned = removed.filter(\.owned)
        guard undoable else {
            deleteOwnedFiles(owned)
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
        let removal = ShelfRemoval(items: items, fileIDs: Set(removed.map(\.id)),
                                   heldFiles: delay == nil ? owned : [])
        removals.append(removal)
        undoManager.registerUndo(withTarget: removal) { [weak self] removal in
            self?.undo(removal)
        }
        undoManager.setActionName(removed.count == 1 ? L("Remove", "Entfernen") : L("Remove \(removed.count) Items", "\(removed.count) Objekte entfernen"))
        while removals.count > Self.undoDepth {
            expire(removals.removeFirst())
        }
        return removal
    }

    /// Legt entfernte Dateien zurück an ihren alten Platz. Registriert das Wiederholen.
    private func undo(_ removal: ShelfRemoval) {
        removals.removeAll { $0 === removal }
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
            if let idx = updated.firstIndex(where: { $0.id == item.before.id }) {
                // Eintrag gibt es noch (Stapel): Dateien an ihre alte Stelle im Stapel
                var files = updated[idx].files
                for file in back {
                    let pos = item.before.files.firstIndex { $0.id == file.id } ?? files.count
                    files.insert(file, at: min(pos, files.count))
                }
                updated[idx].files = files
            } else {
                var entry = item.before
                entry.files = back
                updated.insert(entry, at: min(item.index, updated.count))
            }
        }
        guard !restored.isEmpty else { return }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) { entries = updated }
        lastRestoredFileIDs = restored
        undoManager.registerUndo(withTarget: self) { store in
            store.takeOut(restored, undoable: true)
        }
    }

    /// Dateien, die das letzte Widerrufen zurückgebracht hat (für die Auswahl).
    private(set) var lastRestoredFileIDs: Set<UUID> = []

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
        withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) {
            entries.insert(ShelfEntry(files: [file]), at: 0)
        }
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
    func ingest(from pb: NSPasteboard, into target: UUID? = nil, completion: (([URL]) -> Void)? = nil) {
        importer.convertImages = AppSettings.shared.convertWebImages
        importer.alwaysCopy = AppSettings.shared.copyAllFiles
        pendingImports += 1
        importer.importContent(of: pb) { [weak self] files in
            guard let self else { return }
            self.pendingImports = max(0, self.pendingImports - 1)
            guard !files.isEmpty else {
                completion?([])
                return
            }
            if let target { self.append(files, to: target) } else { self.add(files) }
            completion?(files.map(\.url))
        }
    }

    /// Fügt den Inhalt der allgemeinen Zwischenablage hinzu.
    func pasteFromClipboard() {
        ingest(from: .general)
    }
}
