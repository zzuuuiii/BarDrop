import Foundation

/// Kopie von „BarDrop Share“ auf diesem Mac, für Dienste ohne eigenen Ordner im Finder (nur
/// übers Netz verbunden, keine Dropbox- oder Google-Drive-App). Ein Klick auf die Aktion zeigt
/// sie in der Ablage wie einen Ordner statt die Website des Dienstes (Nutzer, 30.10.2026).
///
/// Liegt unter ~/Library/Caches/BarDrop/Cloud/<Dienst>/BarDrop Share. Jeder Abgleich lädt neue
/// und geänderte Dateien und räumt weg, was es beim Dienst nicht mehr gibt. In den Ordner
/// gezogene Dateien werden hochgeladen (`ShelfActions.fileIntoOpenFolder`), nicht nur kopiert.
final class CloudMirror: @unchecked Sendable {
    static let shared = CloudMirror()
    private init() {}

    /// Größer wird nicht geladen (Speicher und Datenvolumen); steht nur im Protokoll
    private static let sizeLimit: UInt64 = 500 * 1024 * 1024

    /// Läuft schon ein Abgleich (nur auf dem Hauptthread gelesen und geändert)
    private var syncing: Set<CloudService> = []

    private static let base: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("BarDrop/Cloud", isDirectory: true)

    /// Der Ordner der Kopie (wird angelegt)
    func folder(for service: CloudService) -> URL {
        let url = Self.base.appendingPathComponent(service.rawValue, isDirectory: true)
            .appendingPathComponent(CloudService.folderName, isDirectory: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }

    /// Dienst, zu dem dieser Ordner als Kopie gehört
    func service(forFolder url: URL) -> CloudService? {
        CloudService.allCases.first { service in
            Self.base.appendingPathComponent(service.rawValue, isDirectory: true)
                .appendingPathComponent(CloudService.folderName, isDirectory: true)
                .standardizedFileURL.path == url.standardizedFileURL.path
        }
    }

    /// Was von jeder Datei schon da ist (Name → Datei beim Dienst mit Kennung und Fassung),
    /// neben dem Ordner
    private func indexURL(_ service: CloudService) -> URL {
        Self.base.appendingPathComponent(service.rawValue, isDirectory: true).appendingPathComponent("index.json")
    }

    private func loadIndex(_ service: CloudService) -> [String: CloudRemoteFile] {
        (try? JSONDecoder().decode([String: CloudRemoteFile].self, from: Data(contentsOf: indexURL(service)))) ?? [:]
    }

    private func saveIndex(_ index: [String: CloudRemoteFile], _ service: CloudService) {
        try? JSONEncoder().encode(index).write(to: indexURL(service))
    }

    /// Mit dem Dienst abgleichen (vom Hauptthread aus). `changed` nach jeder neuen oder
    /// entfernten Datei (Ablage neu laden), `failed` mit einem Text für die Meldung; beide auf
    /// dem Hauptthread
    func sync(_ service: CloudService, changed: @escaping () -> Void, failed: @escaping (String) -> Void) {
        guard !syncing.contains(service) else { return }
        syncing.insert(service)
        let provider = service.provider
        let folder = folder(for: service)
        Task { @MainActor in
            defer { syncing.remove(service) }
            var index = loadIndex(service)
            var downloadError: Error?
            do {
                // Was vor dem Abfragen hochgeladen wurde, bleibt auch, wenn es währenddessen fertig
                // wird: Die Liste des Dienstes kann es dann noch nicht enthalten
                let uploading = Set(CloudUploads.shared.progress.keys)
                let remote = try await provider.listFolder()
                let fm = FileManager.default
                // Weg, was es beim Dienst nicht mehr gibt (nur in der eigenen Kopie). Was gerade
                // hochgeladen wird, ist dort noch nicht angekommen und bleibt
                let names = Set(remote.map(\.name))
                let local = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
                var removed = false
                for name in local where !names.contains(name) && !name.hasPrefix(".") {
                    let url = folder.appendingPathComponent(name)
                    guard CloudUploads.shared.progress[url.path] == nil, !uploading.contains(url.path) else { continue }
                    try? fm.removeItem(at: url)
                    index[name] = nil
                    removed = true
                }
                if removed { changed() }
                for file in remote {
                    // Nur schlichte Dateinamen: Google erlaubt „/“, daraus würde sonst ein Pfad
                    // außerhalb der Kopie (oder ein fehlender Unterordner, der den Abgleich abbricht)
                    guard !file.name.isEmpty, file.name != ".", file.name != "..", !file.name.contains("/") else { continue }
                    let target = folder.appendingPathComponent(file.name)
                    let exists = fm.fileExists(atPath: target.path)
                    if exists, index[file.name]?.version == file.version { continue }
                    // Gerade von hier hochgeladen: dieselbe Datei liegt schon da, nur merken
                    if exists, index[file.name] == nil, OAuthCloudProvider.size(of: target) == file.size {
                        index[file.name] = file
                        continue
                    }
                    guard file.size <= Self.sizeLimit else {
                        Diagnostics.shared.record("cloud", "\(service.rawValue) mirror skip size=\(file.size)")
                        continue
                    }
                    // Erst daneben laden, damit in der Ablage nie eine halbe Datei steht
                    let partial = folder.deletingLastPathComponent().appendingPathComponent(".laden-\(UUID().uuidString)")
                    // Eine Datei, die nicht lädt, hält die übrigen nicht auf; gemeldet wird am Ende
                    do {
                        try await provider.download(file, to: partial)
                        try? fm.removeItem(at: target)
                        try fm.moveItem(at: partial, to: target)
                    } catch {
                        try? fm.removeItem(at: partial)
                        downloadError = downloadError ?? error
                        continue
                    }
                    index[file.name] = file
                    saveIndex(index, service)
                    changed()
                }
                // Kennungen auch für schon vorhandene Dateien aktuell halten (zum Löschen)
                for file in remote where index[file.name] != nil { index[file.name] = file }
                saveIndex(index, service)
                Diagnostics.shared.record("cloud", "\(service.rawValue) mirror files=\(remote.count)")
                if let downloadError { throw downloadError }
            } catch {
                saveIndex(index, service)
                Diagnostics.shared.failure("cloud", "Abgleich \(service.rawValue)", error)
                failed((error as? CloudError)?.message ?? error.localizedDescription)
            }
        }
    }

    /// Dateien in der Kopie gelöscht: auch beim Dienst löschen (Dropbox und OneDrive legen sie
    /// in ihren Papierkorb bzw. die gelöschten Dateien, Google in den Papierkorb), dann hier.
    /// Nutzer, 30.10.2026: vorher blieben sie in der Cloud und kamen beim Abgleich zurück
    func delete(_ urls: [URL], in service: CloudService, done: @escaping (_ deleted: Int, _ error: String?) -> Void) {
        let provider = service.provider
        Task { @MainActor in
            var index = loadIndex(service)
            var deleted = 0
            var failure: String?
            // Gerade erst hochgeladen und noch nicht abgeglichen: steht noch nicht im Index. Dann
            // beim Dienst nachsehen (gleicher Name, wie beim Abgleich), sonst löschte das nur die
            // Kopie hier und die Datei käme beim nächsten Abgleich zurück (Dropbox, Nutzer)
            var remote: [CloudRemoteFile]?
            for url in urls {
                let name = url.lastPathComponent
                do {
                    var file = index[name]
                    if file == nil {
                        if remote == nil { remote = try await provider.listFolder() }
                        file = remote?.first { $0.name == name }
                    }
                    if let file { try await provider.delete(file) }
                    try? FileManager.default.removeItem(at: url)
                    index[name] = nil
                    deleted += 1
                } catch {
                    Diagnostics.shared.failure("cloud", "Löschen \(service.rawValue)", error)
                    failure = (error as? CloudError)?.message ?? error.localizedDescription
                }
            }
            saveIndex(index, service)
            done(deleted, failure)
        }
    }
}
