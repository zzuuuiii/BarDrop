import AppKit
import Combine

/// Legt neue Bildschirmfotos automatisch in die Ablage (Einstellung „Bildschirmfotos
/// aufnehmen“). Fragt dazu Spotlight nach Dateien, die macOS als Bildschirmfoto
/// kennzeichnet: Das klappt an jedem Speicherort, den man für Bildschirmfotos
/// eingestellt hat, ohne Ordner selbst zu überwachen. Läuft nur, solange die
/// Einstellung an ist.
final class ScreenshotWatcher {
    private let store: ShelfStore
    private let onAdded: () -> Void
    private var query: NSMetadataQuery?
    private var observers: [NSObjectProtocol] = []
    private var settingObserver: AnyCancellable?
    /// Schon übernommene Dateien, damit keine doppelt landet
    private var seen = Set<String>()
    private let pasteboard = NSPasteboard(name: NSPasteboard.Name("io.github.zzuuuiii.bardrop.screenshots"))

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
                let added = note.userInfo?[NSMetadataQueryUpdateAddedItemsKey] as? [NSMetadataItem] ?? []
                self?.take(added)
            }
        ]
        self.query = query
        if !query.start() {
            Log.importing.error("Bildschirmfotos: Spotlight-Abfrage ließ sich nicht starten")
            stop()
        }
    }

    private func stop() {
        query?.stop()
        query = nil
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
        let urls = items.compactMap { item -> URL? in
            guard let path = item.value(forAttribute: NSMetadataItemPathKey) as? String,
                  !seen.contains(path),
                  FileManager.default.fileExists(atPath: path) else { return nil }
            seen.insert(path)
            return URL(fileURLWithPath: path)
        }
        guard !urls.isEmpty, AppSettings.shared.addScreenshots else { return }
        Log.importing.info("\(urls.count, privacy: .public) Bildschirmfoto(s) übernommen")
        // Derselbe Weg wie beim Ablegen aus dem Finder
        pasteboard.clearContents()
        pasteboard.writeObjects(urls as [NSURL])
        store.ingest(from: pasteboard) { [weak self] files in
            if !files.isEmpty { self?.onAdded() }
        }
    }
}
