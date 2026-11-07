import AppKit
import Combine

/// Legt mit AirDrop empfangene Dateien automatisch in die Ablage (Einstellung „AirDrop-Dateien
/// hinzufügen“) und nimmt sie dabei aus „Downloads“ heraus. AirDrop legt sie in den Ordner Downloads und kennzeichnet
/// sie wie jeden Download mit der Quarantäne von macOS; als Absender steht dort der Dienst
/// von AirDrop („sharingd“). Nur so erkannte Dateien kommen in die Ablage, andere Downloads
/// nicht. Läuft nur, solange die Einstellung an ist.
///
/// Seit 07.11.2026 auch „Neue Downloads“ (Nutzer): Fertig geladene Dateien aus dem Browser
/// kommen als Verweis in die Ablage und bleiben in „Downloads“. Erkannt am Zeitstempel der
/// Quarantäne: nur, was gerade erst geladen wurde. So kommt nichts zurück, was BarDrop selbst
/// in „Downloads“ legt (Aktion „Downloads“), auch wenn es früher einmal geladen wurde.
final class AirDropWatcher {
    private let store: ShelfStore
    private let onAdded: () -> Void
    private var settingObserver: AnyCancellable?
    private var source: DispatchSourceFileSystemObject?
    private var folder: URL?
    private var startedAt = Date()
    /// Schon übernommen oder als fremd erkannt
    private var seen = Set<String>()
    /// Größe und Zeitpunkt beim ersten Nachsehen mit dieser Größe: übernommen wird erst, wenn
    /// sie eine Weile gleich bleibt
    private var sizes: [String: (size: Int64, since: Date)] = [:]
    private let pasteboard = NSPasteboard(name: NSPasteboard.Name("io.github.zzuuuiii.bardrop.downloads"))

    init(store: ShelfStore, onAdded: @escaping () -> Void) {
        self.store = store
        self.onAdded = onAdded
        settingObserver = AppSettings.shared.$addAirDrop
            .combineLatest(AppSettings.shared.$addDownloads)
            .map { $0 || $1 }
            .removeDuplicates()
            .sink { [weak self] on in
                DispatchQueue.main.async { on ? self?.start() : self?.stop() }
            }
    }

    deinit { stop() }

    static var downloadsFolder: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
    }

    private func start() {
        guard source == nil else { return }
        startedAt = Date()
        let folder = Self.downloadsFolder
        // Gleich einmal lesen: Fragt macOS nach dem Zugriff, dann jetzt
        _ = FolderAccess.shared.contents(of: folder, keys: [], area: "airdrop")
        let fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else {
            Diagnostics.shared.failure("airdrop", "Ordner nicht lesbar \(Diagnostics.anon(folder)) errno=\(errno)")
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in self?.folderChanged() }
        source.setCancelHandler { close(fd) }
        self.source = source
        self.folder = folder
        source.resume()
        Diagnostics.shared.record("airdrop", "beobachte Ordner \(Diagnostics.anon(folder))")
    }

    private func stop() {
        source?.cancel()
        source = nil
        if let folder { FolderAccess.shared.forget(folder) }
        folder = nil
        sizes = [:]
    }

    /// AirDrop schreibt größere Dateien eine Weile: mehrmals nachsehen
    private func folderChanged() {
        for delay in [0.5, 1.5, 4.0, 10.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.scan() }
        }
    }

    private func scan() {
        guard let folder else { return }
        let keys: [URLResourceKey] = [.creationDateKey, .addedToDirectoryDateKey, .fileSizeKey, .isDirectoryKey]
        guard let files = FolderAccess.shared.contents(of: folder, keys: keys, area: "airdrop") else { return }
        var ready: [URL] = []
        for url in files where !seen.contains(url.path) {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            // Nur, was seit dem Einschalten ankommt
            let arrived = values.addedToDirectoryDate ?? values.creationDate ?? .distantPast
            guard arrived >= startedAt.addingTimeInterval(-1) else { continue }
            // Halb geladene Downloads aus dem Browser übergehen; die Quarantäne entscheidet
            if PluginRuntime.partialExtensions.contains(url.pathExtension.lowercased()) { continue }
            guard let quarantine = Self.quarantine(url), let agent = Self.agent(fromQuarantine: quarantine) else { continue }
            let airDrop = Self.isAirDrop(agent: agent) && AppSettings.shared.addAirDrop
            // Andere Downloads nur, wenn „Neue Downloads“ an ist und sie eben erst geladen wurden
            let download = !airDrop && AppSettings.shared.addDownloads
                && (Self.quarantineDate(quarantine).map { $0 >= startedAt.addingTimeInterval(-5) && Date().timeIntervalSince($0) < 600 } ?? false)
            guard airDrop || download else {
                seen.insert(url.path)
                continue
            }
            let size = values.isDirectory == true ? Self.folderSize(url) : Int64(values.fileSize ?? 0)
            // Jedes Ereignis plant eigene Durchgänge, zwei davon liegen oft nur Millisekunden
            // auseinander: Gleiche Größe zählt erst, wenn seitdem mindestens eine Sekunde verging
            if let last = sizes[url.path], last.size == size {
                if Date().timeIntervalSince(last.since) >= 1 { ready.append(url) }
            } else {
                sizes[url.path] = (size, Date())
            }
        }
        guard !ready.isEmpty else { return }
        ready.forEach { seen.insert($0.path); sizes[$0.path] = nil }
        // Downloads bleiben in „Downloads“: wie aus dem Finder abgelegt (Original oder Kopie
        // nach Einstellung)
        let downloads = ready.filter { url in
            !(Self.quarantineAgent(url).map(Self.isAirDrop) ?? false) || !AppSettings.shared.addAirDrop
        }
        if !downloads.isEmpty, AppSettings.shared.addDownloads {
            Diagnostics.shared.record("downloads", "übernehme \(downloads.count)")
            pasteboard.clearContents()
            pasteboard.writeObjects(downloads as [NSURL])
            store.ingest(from: pasteboard) { [weak self] files in
                if !files.isEmpty { self?.onAdded() }
            }
        }
        let received = ready.filter { !downloads.contains($0) }
        guard !received.isEmpty, AppSettings.shared.addAirDrop else { return }
        Diagnostics.shared.record("airdrop", "übernehme \(received.count)")
        // Nur in die Ablage, nicht auch in „Downloads“: BarDrop nimmt die Dateien heraus und
        // behält sie selbst (wie Ergebnisse von Plugins). Herausziehen legt sie dann ab, wo
        // man will; Entfernen löscht sie wie andere eigene Objekte erst nach dem Widerrufen.
        let adopted = store.adoptResults(received)
        guard !adopted.isEmpty else { return }
        store.add(adopted)
        onAdded()
    }

    /// Gesamtgröße eines empfangenen Ordners: Seine eigene Größe ändert sich nicht, während
    /// AirDrop ihn noch füllt
    static func folderSize(_ url: URL) -> Int64 {
        let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])
        var total: Int64 = 0
        while let file = files?.nextObject() as? URL {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return total
    }

    /// Absender aus der Quarantäne von macOS („0083;65f1…;sharingd;“ → „sharingd“)
    static func quarantineAgent(_ url: URL) -> String? {
        quarantine(url).flatMap(agent(fromQuarantine:))
    }

    /// Zeitpunkt des Ladens aus der Quarantäne (zweites Feld, Sekunden seit 1970 als Hexzahl)
    static func quarantineDate(_ text: String) -> Date? {
        let parts = text.split(separator: ";", omittingEmptySubsequences: false)
        guard parts.count >= 2, let seconds = UInt64(parts[1], radix: 16) else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    /// Inhalt der Quarantäne von macOS
    static func quarantine(_ url: URL) -> String? {
        let name = "com.apple.quarantine"
        let length = getxattr(url.path, name, nil, 0, 0, 0)
        guard length > 0 else { return nil }
        var data = Data(count: length)
        let read = data.withUnsafeMutableBytes { getxattr(url.path, name, $0.baseAddress, length, 0, 0) }
        guard read > 0, let text = String(data: data.prefix(read), encoding: .utf8) else { return nil }
        return text
    }

    static func agent(fromQuarantine text: String) -> String? {
        let parts = text.split(separator: ";", omittingEmptySubsequences: false)
        guard parts.count >= 3 else { return nil }
        let agent = parts[2].trimmingCharacters(in: .whitespaces)
        return agent.isEmpty ? nil : agent
    }

    static func isAirDrop(agent: String) -> Bool {
        let lower = agent.lowercased()
        return lower == "sharingd" || lower.contains("airdrop")
    }
}
