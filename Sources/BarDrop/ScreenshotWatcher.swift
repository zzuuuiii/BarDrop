import AppKit
import Combine
import UniformTypeIdentifiers

/// Legt neue Bildschirmfotos automatisch in die Ablage (Einstellung „Neue Bildschirmfotos“).
/// Zwei Wege, damit es auch klappt, wenn Spotlight den Ort nicht oder verspätet indiziert:
/// der Ordner, den macOS für Bildschirmfotos verwendet (Bildschirmfoto-App → Optionen),
/// wird direkt beobachtet, und Spotlight meldet Dateien, die macOS als Bildschirmfoto
/// kennzeichnet. Läuft nur, solange die Einstellung an ist.
final class ScreenshotWatcher {
    private let store: ShelfStore
    private let onAdded: () -> Void
    private var query: NSMetadataQuery?
    private var observers: [NSObjectProtocol] = []
    private var settingObserver: AnyCancellable?
    /// Schon übernommene Dateien, damit keine doppelt landet
    private var seen = Set<String>()
    private let pasteboard = NSPasteboard(name: NSPasteboard.Name("io.github.zzuuuiii.bardrop.screenshots"))
    /// Beobachteter Ordner und Zeitpunkt des Starts (ältere Dateien zählen nicht)
    private var folderSource: DispatchSourceFileSystemObject?
    private var watchedFolder: URL?
    private var startedAt = Date()
    /// Prüft regelmäßig, ob der Ort für Bildschirmfotos umgestellt wurde
    private var folderCheck: Timer?
    /// Zuletzt nicht lesbarer Ordner (schon gemeldet)
    private var unreadableFolder: URL?

    init(store: ShelfStore, onAdded: @escaping () -> Void) {
        self.store = store
        self.onAdded = onAdded
        settingObserver = AppSettings.shared.$addScreenshots
            .removeDuplicates()
            .sink { [weak self] on in
                DispatchQueue.main.async { on ? self?.start() : self?.stop() }
            }
    }

    deinit { stop() }

    private func start() {
        guard query == nil else { return }
        startedAt = Date()
        watchFolder()
        // Wird der Ort in der Bildschirmfoto-App umgestellt, solange BarDrop läuft, sonst
        // bliebe der alte Ordner beobachtet und neue Bildschirmfotos kämen nie an
        folderCheck = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.followFolderChange()
        }
        // Mit Spielraum: macOS legt das Aufwecken dann mit anderem zusammen (Energie im Leerlauf)
        folderCheck?.tolerance = 1
        let query = NSMetadataQuery()
        // Nur, was ab jetzt aufgenommen wird
        query.predicate = NSPredicate(format: "kMDItemIsScreenCapture == 1 AND kMDItemFSCreationDate >= %@",
                                      Date() as NSDate)
        query.searchScopes = [NSMetadataQueryLocalComputerScope]
        query.notificationBatchingInterval = 0.3
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: query, queue: .main) { [weak self] _ in
                // Was beim Start schon da ist, gilt als gesehen
                self?.markAllSeen()
            },
            center.addObserver(forName: .NSMetadataQueryDidUpdate, object: query, queue: .main) { [weak self] note in
                // macOS schreibt Bildschirmfotos erst unter verstecktem Namen und benennt sie
                // dann um: Spotlight meldet sie dann oft als geändert statt als neu
                let added = note.userInfo?[NSMetadataQueryUpdateAddedItemsKey] as? [NSMetadataItem] ?? []
                let changed = note.userInfo?[NSMetadataQueryUpdateChangedItemsKey] as? [NSMetadataItem] ?? []
                Diagnostics.shared.record("screenshots", "Spotlight meldet neu=\(added.count) geändert=\(changed.count)")
                self?.take(added + changed)
            }
        ]
        self.query = query
        if !query.start() {
            Log.importing.error("Bildschirmfotos: Spotlight-Abfrage ließ sich nicht starten")
            Diagnostics.shared.failure("screenshots", "Spotlight-Abfrage ließ sich nicht starten")
            // Nur Spotlight aufgeben: Der Ordner wird weiter beobachtet (das ist der zweite Weg).
            // `query` bleibt gesetzt, damit `start` den Ordner nicht ein zweites Mal öffnet.
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
        }
    }

    private func stop() {
        if let watchedFolder { FolderAccess.shared.forget(watchedFolder) }
        query?.stop()
        query = nil
        folderCheck?.invalidate()
        folderCheck = nil
        folderSource?.cancel()
        folderSource = nil
        watchedFolder = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }

    private func markAllSeen() {
        guard let query else { return }
        query.disableUpdates()
        for case let item as NSMetadataItem in query.results {
            if let path = item.value(forAttribute: NSMetadataItemPathKey) as? String { seen.insert(path) }
        }
        query.enableUpdates()
    }

    private func take(_ items: [NSMetadataItem]) {
        let paths = items.compactMap { $0.value(forAttribute: NSMetadataItemPathKey) as? String }
        add(paths.map { URL(fileURLWithPath: $0) })
    }

    // MARK: Ordner der Bildschirmfotos

    /// Wo macOS Bildschirmfotos speichert: eingestellter Ort, sonst der Schreibtisch
    static func screenshotFolder() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        if let location = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location"),
           !location.isEmpty {
            let url = URL(fileURLWithPath: (location as NSString).expandingTildeInPath, isDirectory: true)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue { return url }
        }
        return home.appendingPathComponent("Desktop", isDirectory: true)
    }

    /// Beobachtet den Ordner der Bildschirmfotos auf neue Dateien
    private func watchFolder() {
        let folder = Self.screenshotFolder()
        let fd = open(folder.path, O_EVTONLY)
        // Gleich einmal lesen: Fragt macOS nach dem Zugriff, dann jetzt, und fehlt er,
        // zeigen die Einstellungen es an
        _ = FolderAccess.shared.contents(of: folder, keys: [], area: "screenshots")
        guard fd >= 0 else {
            // Die Prüfung alle 5 Sekunden versucht es erneut: nur einmal je Ordner melden
            guard folder != unreadableFolder else { return }
            unreadableFolder = folder
            Log.importing.error("Bildschirmfotos: Ordner nicht lesbar (\(folder.path, privacy: .private))")
            Diagnostics.shared.failure("screenshots", "Ordner nicht lesbar \(Diagnostics.anon(folder)) errno=\(errno) \(String(cString: strerror(errno)))")
            return
        }
        watchedFolder = folder
        unreadableFolder = nil
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in self?.folderChanged() }
        source.setCancelHandler { close(fd) }
        folderSource = source
        source.resume()
        Log.importing.info("Bildschirmfotos: beobachte Ordner")
        Diagnostics.shared.record("screenshots", "beobachte Ordner \(Diagnostics.anon(folder))")
    }

    /// Ort der Bildschirmfotos umgestellt: den neuen Ordner beobachten
    private func followFolderChange() {
        let folder = Self.screenshotFolder()
        guard folder.standardizedFileURL != watchedFolder?.standardizedFileURL else { return }
        Diagnostics.shared.record("screenshots", "Ort umgestellt")
        folderSource?.cancel()
        folderSource = nil
        watchedFolder = nil
        watchFolder()
    }

    /// Etwas im Ordner hat sich geändert: kurz danach nachsehen (macOS setzt die Kennzeichnung
    /// als Bildschirmfoto erst nach dem Umbenennen)
    private func folderChanged() {
        for delay in [0.3, 1.2, 3.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.scanFolder() }
        }
    }

    private func scanFolder() {
        guard let folder = watchedFolder else { return }
        let keys: [URLResourceKey] = [.creationDateKey, .isRegularFileKey]
        // Ohne Zugriff auf den Ordner (Datenschutz von macOS, etwa nach einem Update von
        // BarDrop) meldet der Ordner zwar Änderungen, lässt sich aber nicht lesen. Früher
        // ging das still unter, und Bildschirmfotos kamen nie an.
        guard let files = FolderAccess.shared.contents(of: folder, keys: keys, area: "screenshots") else { return }
        let fresh = files.filter { url in
            guard !seen.contains(url.path),
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let created = values.creationDate, created >= startedAt.addingTimeInterval(-1) else { return false }
            return Self.isScreenCapture(url) || Self.namedLikeScreenshot(url)
        }
        if !fresh.isEmpty {
            Diagnostics.shared.record("screenshots", "im Ordner neu=\(fresh.count) gekennzeichnet=\(fresh.filter(Self.isScreenCapture).count)")
        }
        add(fresh)
    }

    /// Von macOS als Bildschirmfoto gekennzeichnet (dasselbe Merkmal, das Spotlight liest)
    static func isScreenCapture(_ url: URL) -> Bool {
        let name = "com.apple.metadata:kMDItemIsScreenCapture"
        return getxattr(url.path, name, nil, 0, 0, 0) > 0
    }

    /// Ersatz, falls macOS die Kennzeichnung nicht (mehr) setzt: Bild oder Aufnahme, deren Name
    /// wie ein Bildschirmfoto beginnt (eingestellter Name oder die üblichen von macOS)
    static func namedLikeScreenshot(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        var prefixes = ["Bildschirmfoto", "Bildschirmaufnahme", "Screenshot", "Screen Recording"]
        if let custom = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "name"), !custom.isEmpty {
            prefixes.append(custom)
        }
        guard prefixes.contains(where: { name.hasPrefix($0) }),
              let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        return type.conforms(to: .image) || type.conforms(to: .movie)
    }

    // MARK: Übernehmen

    private func add(_ candidates: [URL]) {
        let urls = candidates.filter { url in
            guard !seen.contains(url.path), FileManager.default.fileExists(atPath: url.path) else { return false }
            seen.insert(url.path)
            return true
        }
        guard !urls.isEmpty, AppSettings.shared.addScreenshots else { return }
        Diagnostics.shared.record("screenshots", "übernehme \(urls.count)")
        Log.importing.info("\(urls.count, privacy: .public) Bildschirmfoto(s) übernommen")
        // Derselbe Weg wie beim Ablegen aus dem Finder
        pasteboard.clearContents()
        pasteboard.writeObjects(urls as [NSURL])
        store.ingest(from: pasteboard) { [weak self] files in
            if !files.isEmpty { self?.onAdded() }
        }
    }
}
