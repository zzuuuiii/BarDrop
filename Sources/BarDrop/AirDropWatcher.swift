import AppKit
import Combine

/// Legt mit AirDrop empfangene Dateien automatisch in die Ablage (Einstellung „AirDrop-Dateien
/// hinzufügen“) und nimmt sie dabei aus „Downloads“ heraus. AirDrop legt sie in den Ordner Downloads und kennzeichnet
/// sie wie jeden Download mit der Quarantäne von macOS; als Absender steht dort der Dienst
/// von AirDrop („sharingd“). Nur so erkannte Dateien kommen in die Ablage, andere Downloads
/// nicht. Läuft nur, solange die Einstellung an ist.
final class AirDropWatcher {
    private let store: ShelfStore
    private let onAdded: () -> Void
    private var settingObserver: AnyCancellable?
    private var source: DispatchSourceFileSystemObject?
    private var folder: URL?
    private var startedAt = Date()
    /// Schon übernommen oder als fremd erkannt
    private var seen = Set<String>()
    /// Größe beim letzten Nachsehen: übernommen wird erst, wenn sie gleich bleibt
    private var sizes: [String: Int64] = [:]

    init(store: ShelfStore, onAdded: @escaping () -> Void) {
        self.store = store
        self.onAdded = onAdded
        settingObserver = AppSettings.shared.$addAirDrop
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
            guard let agent = Self.quarantineAgent(url) else { continue }
            guard Self.isAirDrop(agent: agent) else {
                seen.insert(url.path)
                continue
            }
            let size = values.isDirectory == true ? -1 : Int64(values.fileSize ?? 0)
            if sizes[url.path] == size {
                ready.append(url)
            } else {
                sizes[url.path] = size
            }
        }
        guard !ready.isEmpty else { return }
        ready.forEach { seen.insert($0.path); sizes[$0.path] = nil }
        guard AppSettings.shared.addAirDrop else { return }
        Diagnostics.shared.record("airdrop", "übernehme \(ready.count)")
        // Nur in die Ablage, nicht auch in „Downloads“: BarDrop nimmt die Dateien heraus und
        // behält sie selbst (wie Ergebnisse von Plugins). Herausziehen legt sie dann ab, wo
        // man will; Entfernen löscht sie wie andere eigene Objekte erst nach dem Widerrufen.
        let adopted = store.adoptResults(ready)
        guard !adopted.isEmpty else { return }
        store.add(adopted)
        onAdded()
    }

    /// Absender aus der Quarantäne von macOS („0083;65f1…;sharingd;“ → „sharingd“)
    static func quarantineAgent(_ url: URL) -> String? {
        let name = "com.apple.quarantine"
        let length = getxattr(url.path, name, nil, 0, 0, 0)
        guard length > 0 else { return nil }
        var data = Data(count: length)
        let read = data.withUnsafeMutableBytes { getxattr(url.path, name, $0.baseAddress, length, 0, 0) }
        guard read > 0, let text = String(data: data.prefix(read), encoding: .utf8) else { return nil }
        return agent(fromQuarantine: text)
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
