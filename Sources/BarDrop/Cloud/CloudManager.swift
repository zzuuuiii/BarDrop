import AppKit

/// Verbindet die Cloud-Dienste mit der Ablage: Ein Upload ist ein Lauf mit Platzhalter wie
/// bei Plugins (`PluginRunner.runNative`), danach steht der Link in der Zwischenablage
/// und/oder als .webloc neben dem Original.
final class CloudManager: ObservableObject {
    static let shared = CloudManager()
    private let settings = CloudSettings.shared
    /// Läuft gerade eine Anmeldung (Knopf zeigt einen Ladekreis)
    @Published private(set) var connecting: CloudService?
    /// Letzter Fehler beim Verbinden, je Dienst
    @Published var connectErrors: [CloudService: String] = [:]

    private init() {}

    var connected: [CloudService] { CloudService.allCases.filter { $0.provider.isConnected } }

    /// Im Rechtsklick steht jeder verbundene Dienst; die Einstellung je Dienst gibt es nicht
    /// mehr (Nutzer, 30.10.2026: überflüssig)
    var contextMenuServices: [CloudService] { connected }

    @MainActor
    func connect(_ service: CloudService) async {
        connecting = service
        connectErrors[service] = nil
        defer { connecting = nil }
        do {
            try await service.provider.connect()
        } catch {
            connectErrors[service] = (error as? CloudError).map { $0.message + ($0.hint.map { " " + $0 } ?? "") }
                ?? error.localizedDescription
        }
        objectWillChange.send()
    }

    func disconnect(_ service: CloudService) {
        service.provider.disconnect()
        // Aktionen des Dienstes aus der Leiste nehmen
        let app = AppSettings.shared
        app.quickActions.removeAll { $0.kind == .cloud && $0.path == service.rawValue }
        objectWillChange.send()
    }

    /// Name und Symbol des Platzhalters: ein „Plugin“, das nur in BarDrop selbst lebt
    private var identities: [CloudService: InstalledPlugin] = [:]

    private func identity(_ service: CloudService) -> InstalledPlugin? {
        if let known = identities[service] { return known }
        let manifest: [String: Any] = [
            "schema": 1, "id": "bardrop.cloud.\(service.rawValue)",
            "name": service.title, "version": "1.0.0", "script": "main.js",
            "icon": ["symbol": service.symbol, "color": service.icon.color ?? "#0A84FF"],
            "match": ["types": ["public.item"]]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: manifest),
              let decoded = try? JSONDecoder().decode(PluginManifest.self, from: data) else { return nil }
        let plugin = InstalledPlugin(manifest: decoded, directory: FileManager.default.temporaryDirectory,
                                     script: "", fingerprint: "native", isStandard: true)
        identities[service] = plugin
        return plugin
    }

    /// Dateien teilen: hochladen, Link in die Zwischenablage und/oder in die Ablage. Den
    /// Fortschritt zeigt die Datei selbst (`CloudUploads`), kein eigener Platzhalter daneben
    /// (Nutzer, 30.10.2026: die zusätzliche Kachel, die wieder verschwand, wirkte seltsam).
    /// `linkToClipboard`: Link nur in die Zwischenablage (Kopie eines Cloud-Ordners)
    func share(_ files: [ShelfFile], via service: CloudService, actions: ShelfActions, linkToClipboard: Bool = false) {
        let provider = service.provider
        guard provider.isConnected else {
            NSSound.beep()
            actions.announce(L("Not connected", "Nicht verbunden"))
            SettingsNavigation.shared.pane = .cloud
            actions.openSettings()
            return
        }
        guard !files.isEmpty, let identity = identity(service) else { return }
        let target = linkToClipboard ? .clipboard : settings.linkTarget
        let urls = files.map(\.url)
        Diagnostics.shared.record("cloud", "\(service.rawValue) items=\(files.count) target=\(target.rawValue)")
        let uploads = CloudUploads.shared
        uploads.begin(urls)
        actions.plugins.runNative(identity, on: files, placeholder: false) { job, output in
            defer { uploads.end(urls) }
            // Zusammen abgelegte Dateien immer als ein ZIP mit einem Link (Nutzer, 27.10.2026:
            // ohne Einstellung dafür)
            let url: URL
            let name: String
            do {
                let (file, zipName, cleanup) = try await Self.prepare(urls)
                defer { cleanup() }
                name = zipName
                let reporter = JobReporter(job: job)
                url = try await provider.upload(file, name: name) { value, label in
                    reporter.report(value, label: label)
                    if let value { DispatchQueue.main.async { CloudUploads.shared.update(urls, value) } }
                }
            } catch {
                // Ohne Platzhalter gibt es kein Rütteln: Fehler als Meldung in der Ablage
                if !(error is CancellationError) {
                    // Oben rechts nur kurz wie die anderen Meldungen; der ganze Text steht im Protokoll
                    actions.announce((error as? CloudError)?.short ?? L("Couldn’t upload", "Nicht hochgeladen"), duration: 4)
                }
                throw error
            }
            PluginLog.shared.record(identity.id, "ok", "„\(name)“ hochgeladen")
            // Die Kopie von „BarDrop Share“ auf dem Mac gleich mitziehen, falls es sie gibt
            if service.localFolder == nil { await MainActor.run { actions.syncMirror(service) } }
            let links = [(url: url, name: name)]
            if target != .shelf {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(url.absoluteString, forType: .string)
                actions.announce(L("Link copied", "Link kopiert"))
            } else {
                actions.announce(L("Uploaded", "Hochgeladen"))
            }
            guard target != .clipboard else { return [] }
            // Als .webloc wie andere Links in der Ablage, neben dem Original
            return links.compactMap { link in
                let title = (link.name as NSString).deletingPathExtension.replacingOccurrences(of: "/", with: "-")
                let file = ShelfActions.uniqueURL(for: title + ".webloc", in: output)
                let plist = ["URL": link.url.absoluteString]
                guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0),
                      (try? data.write(to: file)) != nil else { return nil }
                return file
            }
        }
    }

    /// Was hochgeladen wird: eine einzelne Datei so, wie sie ist; Ordner und mehrere Dateien
    /// als ZIP („Name und 2 weitere.zip“). `cleanup` räumt das ZIP danach weg.
    private static func prepare(_ urls: [URL]) async throws -> (URL, String, () -> Void) {
        let fm = FileManager.default
        if urls.count == 1, let url = urls.first {
            var isDir: ObjCBool = false
            fm.fileExists(atPath: url.path, isDirectory: &isDir)
            // Pakete (.app, .bdrop als Ordner) sind für den Finder eine Datei, hochladen geht trotzdem nur gepackt
            if !isDir.boolValue { return (url, url.lastPathComponent, {}) }
        }
        let work = fm.temporaryDirectory.appendingPathComponent("bardrop-cloud-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        let cleanup: () -> Void = { try? fm.removeItem(at: work) }
        let first = urls[0]
        let base = (first.lastPathComponent as NSString).deletingPathExtension
        let name = urls.count == 1 ? first.lastPathComponent + ".zip"
            : L("\(base) and \(urls.count - 1) more.zip", "\(base) und \(urls.count - 1) weitere.zip")
        let zip = work.appendingPathComponent(name)
        var arguments = ["-c", "-k", "--sequesterRsrc"]
        if urls.count == 1 {
            arguments += ["--keepParent", first.path, zip.path]
        } else {
            let stage = work.appendingPathComponent("inhalt", isDirectory: true)
            do {
                try fm.createDirectory(at: stage, withIntermediateDirectories: true)
                for url in urls {
                    try fm.copyItem(at: url, to: ShelfActions.uniqueURL(for: url.lastPathComponent, in: stage))
                }
            } catch {
                cleanup()   // sonst bliebe die halbe Kopie im temporären Ordner
                throw error
            }
            arguments += [stage.path, zip.path]
        }
        let status = try await run("/usr/bin/ditto", arguments)
        guard status == 0 else {
            cleanup()
            throw CloudError(message: L("Couldn’t zip the files.", "Dateien ließen sich nicht als ZIP komprimieren."))
        }
        return (zip, name, cleanup)
    }

    /// Meldet Fortschritt aus dem Hochladen (beliebiger Thread) an den Platzhalter (Hauptthread)
    private final class JobReporter: @unchecked Sendable {
        private weak var job: PluginJob?
        init(job: PluginJob) { self.job = job }
        func report(_ value: Double?, label: String?) {
            DispatchQueue.main.async { self.job?.report(value, label: label) }
        }
    }

    private static func run(_ tool: String, _ arguments: [String]) async throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }
}

/// Dateien, die gerade hochgeladen werden, mit Fortschritt 0…1: Ihre Kachel in der Ablage
/// (oder im geöffneten Ordner) zeigt das statt eines eigenen Platzhalters
final class CloudUploads: ObservableObject {
    static let shared = CloudUploads()
    @Published private(set) var progress: [String: Double] = [:]

    func begin(_ urls: [URL]) {
        for url in urls { progress[url.path] = 0 }
    }

    func update(_ urls: [URL], _ value: Double) {
        for url in urls where progress[url.path] != nil { progress[url.path] = value }
    }

    func end(_ urls: [URL]) {
        for url in urls { progress[url.path] = nil }
    }
}
