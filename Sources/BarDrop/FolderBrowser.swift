import AppKit
import CryptoKit
import SwiftUI

/// Inhalt eines angehefteten Ordners, in der Ablage gezeigt wie ein geöffneter Stapel.
///
/// Die Dateien bleiben, wo sie sind: Verschieben, Papierkorb und Hineinziehen wirken wie
/// im Finder auf den echten Ordner. Ändert sich der Ordner (Finder, Downloads, eigene
/// Aktionen), zieht die Ansicht sofort nach.
final class FolderBrowser: ObservableObject {
    /// Steht in `ShelfUIModel.openStack`, solange ein Ordner offen ist
    static let entryID = UUID(uuidString: "B0D0F01D-0000-4000-8000-000000000001")!

    /// Angehefteter Ordner, mit dem es losging
    @Published private(set) var root: URL?
    /// Gerade gezeigter Ordner: der angeheftete oder ein Unterordner davon
    @Published private(set) var folder: URL?
    /// Inhalt, neueste zuerst (wie die Ablage)
    @Published private(set) var files: [ShelfFile] = []
    /// Wird noch gelesen (großer Ordner, Netzlaufwerk): noch nicht „leer“ zeigen
    @Published private(set) var isLoading = false
    /// macOS lässt BarDrop den Ordner nicht lesen (Schreibtisch, Dokumente, Downloads, iCloud
    /// Drive brauchen eine Erlaubnis). Vorher schloss sich die Ansicht dann still, und man sah
    /// statt des Ordners die Ablage. Jetzt bleibt er offen und sagt, was fehlt.
    @Published private(set) var accessDenied = false

    /// Der Ordner ist verschwunden (gelöscht, Laufwerk abgezogen): Ansicht schließen
    var onVanished: () -> Void = {}

    private var watcher: DispatchSourceFileSystemObject?
    private var reloadWork: DispatchWorkItem?
    private var generation = 0
    private let queue = DispatchQueue(label: "io.github.zzuuuiii.bardrop.folder", qos: .userInitiated)

    var isOpen: Bool { folder != nil }

    /// Der Inhalt als Eintrag, damit die Ansicht des Stapels ihn zeigen kann
    var entry: ShelfEntry {
        var entry = ShelfEntry(files: files)
        entry.id = Self.entryID
        return entry
    }

    var name: String { folder.map { Self.displayName($0) } ?? "" }

    /// In einem Unterordner des angehefteten Ordners
    var isNested: Bool {
        guard let folder, let root else { return false }
        return folder.standardizedFileURL != root.standardizedFileURL
    }

    /// Name des Ordners, zu dem „Zurück“ führt; nil: zurück zur Ablage
    var parentName: String? {
        guard isNested, let folder else { return nil }
        return Self.displayName(folder.deletingLastPathComponent())
    }

    static func displayName(_ url: URL) -> String {
        // Der Verlauf heißt wie seine Aktion, in der gewählten Sprache
        if url.standardizedFileURL == ClipboardHistory.shared.folder.standardizedFileURL {
            return L("Clipboard", "Zwischenablage")
        }
        return FileManager.default.displayName(atPath: url.path)
    }

    /// Ordner, in die man hineingehen kann (keine Pakete wie Apps)
    static func isBrowsable(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        return values?.isDirectory == true && values?.isPackage != true
    }

    func open(_ url: URL) {
        root = url
        show(url)
    }

    /// In einen Unterordner hineingehen
    func enter(_ url: URL) {
        guard isOpen else { return }
        show(url)
    }

    /// Eine Ebene hoch; false, wenn schon der angeheftete Ordner zu sehen ist
    @discardableResult
    func goUp() -> Bool {
        guard isNested, let folder else { return false }
        show(folder.deletingLastPathComponent())
        return true
    }

    func close() {
        stopWatching()
        reloadWork?.cancel()
        generation += 1
        root = nil
        folder = nil
        files = []
        isLoading = false
        accessDenied = false
    }

    /// Der Inhalt wurde seit dem Öffnen noch nicht gelesen: Er erscheint dann ohne
    /// Animation, wie ein Stapel. Mit Feder wuchs der Inhalt sichtbar, das sah aus, als
    /// würde gescrollt, und je nach Ausgangslage anders als beim angehefteten Ordner.
    private var firstLoad = true

    private func show(_ url: URL) {
        folder = url
        files = []
        isLoading = true
        accessDenied = false
        firstLoad = true
        stopWatching()
        reloadWork?.cancel()
        generation += 1
        let current = generation
        // Gelesen wird im Hintergrund: Fragt macOS erst nach der Erlaubnis (Downloads,
        // Schreibtisch …), wartete sonst die ganze Ablage auf die Antwort und fror ein
        // (Protokoll: 2,4 s ohne ein Bild). Auf der eigenen Platte kurz auf das Ergebnis
        // warten, dann ist der Inhalt wie bei einem Stapel schon beim Überblenden da.
        let box = FolderReadBox()
        let finished = DispatchSemaphore(value: 0)
        queue.async { [weak self] in
            box.result = Self.read(url)
            finished.signal()
            DispatchQueue.main.async {
                guard let self, !box.applied, let result = box.result else { return }
                box.applied = true
                self.applyFirstRead(result, of: url, generation: current)
            }
        }
        if Self.isLocal(url), finished.wait(timeout: .now() + 0.12) == .success, let result = box.result {
            box.applied = true
            applyFirstRead(result, of: url, generation: current)
        }
    }

    /// Erstes Lesen eines gezeigten Ordners übernehmen
    private func applyFirstRead(_ result: Result<[ShelfFile], Error>, of url: URL, generation current: Int) {
        guard generation == current, folder == url else { return }
        switch result {
        case .success(let listed):
            watch(url)
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { files = listed }
            isLoading = false
            firstLoad = false
            Diagnostics.shared.record("folder", "open items=\(listed.count) local=\(Self.isLocal(url))")
        case .failure(let error) where Self.isDenied(error):
            denied(error)
        case .failure(let error):
            Diagnostics.shared.failure("folder", "Ordner nicht lesbar, geschlossen", error)
            vanished()
        }
    }

    private func denied(_ error: Error) {
        reloadWork?.cancel()
        generation += 1
        files = []
        isLoading = false
        accessDenied = true
        Diagnostics.shared.failure("folder", "Kein Zugriff auf den Ordner", error)
    }

    /// Keine Erlaubnis (nicht: Ordner fehlt)
    static func isDenied(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain && ns.code == NSFileReadNoPermissionError { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain {
            return underlying.code == Int(EPERM) || underlying.code == Int(EACCES)
        }
        return ns.domain == NSPOSIXErrorDomain && (ns.code == Int(EPERM) || ns.code == Int(EACCES))
    }

    /// Die Systemeinstellungen bei „Dateien und Ordner“ öffnen, wo man BarDrop den Zugriff erlaubt
    static func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders") {
            NSWorkspace.shared.open(url)
        }
    }

    private static func isLocal(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.volumeIsLocalKey]))?.volumeIsLocal == true
    }

    /// Neu lesen; mehrere Änderungen kurz hintereinander zählen als eine
    func reload(after delay: TimeInterval = 0.15) {
        reloadWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.load() }
        reloadWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func load() {
        guard let folder else { return }
        generation += 1
        let current = generation
        queue.async { [weak self] in
            let result = Self.read(folder)
            DispatchQueue.main.async {
                guard let self, self.generation == current, self.folder == folder else { return }
                self.isLoading = false
                let listed: [ShelfFile]
                switch result {
                case .success(let files):
                    listed = files
                    if self.accessDenied { self.accessDenied = false }
                    // Kam ein Neuladen dem ersten Lesen zuvor (oder war der Zugriff vorher
                    // verweigert), hat noch niemand den Ordner beobachtet: Er änderte sich
                    // dann nie mehr von selbst
                    if self.watcher == nil { self.watch(folder) }
                case .failure(let error) where Self.isDenied(error):
                    return self.denied(error)
                case .failure(let error):
                    Diagnostics.shared.failure("folder", "Ordner nicht lesbar, geschlossen", error)
                    return self.vanished()
                }
                let first = self.firstLoad
                self.firstLoad = false
                guard listed != self.files else { return }
                if first {
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { self.files = listed }
                } else {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.88)) { self.files = listed }
                }
            }
        }
    }

    /// Gezeigter Ordner ist weg: zum nächsten noch vorhandenen darüber, sonst schließen
    private func vanished() {
        var candidate = folder?.deletingLastPathComponent()
        while isNested, let next = candidate, root.map({ next.path.hasPrefix($0.path) }) == true {
            if Self.isBrowsable(next) { return show(next) }
            candidate = next.deletingLastPathComponent()
        }
        close()
        onVanished()
    }

    /// Sichtbare Objekte des Ordners, neueste zuerst: wann sie in den Ordner kamen (wie
    /// „Hinzugefügt am“ im Finder), sonst erstellt bzw. geändert. nil: nicht lesbar.
    static func list(_ folder: URL) -> [ShelfFile]? {
        try? read(folder).get()
    }

    /// Wie `list`, mit dem Grund, falls der Ordner nicht lesbar ist
    static func read(_ folder: URL) -> Result<[ShelfFile], Error> {
        let keys: [URLResourceKey] = [.addedToDirectoryDateKey, .creationDateKey, .contentModificationDateKey]
        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants])
        } catch {
            return .failure(error)
        }
        let dated = urls.map { url -> (url: URL, date: Date) in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return (url, values?.addedToDirectoryDate ?? values?.creationDate
                         ?? values?.contentModificationDate ?? .distantPast)
        }
        return .success(dated
            .sorted { a, b in
                if a.date != b.date { return a.date > b.date }
                return a.url.lastPathComponent.localizedStandardCompare(b.url.lastPathComponent) == .orderedAscending
            }
            .map { ShelfFile(listed: $0.url, id: id(for: $0.url)) })
    }

    /// Feste Kennung je Pfad: Auswahl und Kacheln bleiben beim Neulesen dieselben
    static func id(for url: URL) -> UUID {
        let digest = SHA256.hash(data: Data(url.standardizedFileURL.path.utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return bytes.withUnsafeBytes { UUID(uuid: $0.load(as: uuid_t.self)) }
    }

    // MARK: Beobachten

    private func watch(_ url: URL) {
        stopWatching()
        let descriptor = Darwin.open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename, .link, .attrib, .extend, .revoke],
            queue: .main)
        source.setEventHandler { [weak self] in self?.reload() }
        source.setCancelHandler { Darwin.close(descriptor) }
        source.resume()
        watcher = source
    }

    private func stopWatching() {
        watcher?.cancel()
        watcher = nil
    }

    deinit { watcher?.cancel() }
}

/// Ergebnis des ersten Lesens, zwischen Hintergrund und Hauptthread
private final class FolderReadBox {
    var result: Result<[ShelfFile], Error>?
    var applied = false
}
