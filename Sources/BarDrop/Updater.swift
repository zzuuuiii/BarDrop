import AppKit
import CryptoKit

/// Sucht auf GitHub nach einer neuen Version und installiert sie auf Wunsch:
/// DMG laden, Prüfsumme vergleichen, App ersetzen, neu starten.
///
/// Ohne fremde Bibliothek und ohne Schlüssel: Die DMG kommt per HTTPS aus den
/// Releases dieses Repositorys, und GitHub liefert zu jeder Datei eine SHA-256-
/// Prüfsumme mit, gegen die der Download geprüft wird.
final class Updater: ObservableObject {
    static let shared = Updater()

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(String)
        case installing
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    private struct Release {
        let version: String
        let dmg: URL
        let sha256: String?
        let page: URL
    }

    private let latestURL = URL(string: "https://api.github.com/repos/zzuuuiii/BarDrop/releases/latest")!
    private let releasesPage = URL(string: "https://github.com/zzuuuiii/BarDrop/releases/latest")!
    private var release: Release?
    private var timer: Timer?

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Prüft kurz nach dem Start und danach alle sechs Stunden, wenn eingeschaltet.
    func start() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.automaticCheck() }
        let timer = Timer(timeInterval: 6 * 3600, repeats: true) { [weak self] _ in self?.automaticCheck() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func automaticCheck() {
        guard AppSettings.shared.autoUpdateCheck else { return }
        check(interactive: false)
    }

    // MARK: Suchen

    /// `interactive`: vom Nutzer ausgelöst; dann gibt es auch eine Antwort, wenn alles aktuell ist.
    func check(interactive: Bool) {
        if case .installing = state { return }
        if case .checking = state { return }
        state = .checking
        var request = URLRequest(url: latestURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            DispatchQueue.main.async { self?.handle(data: data, error: error, interactive: interactive) }
        }.resume()
    }

    private func handle(data: Data?, error: Error?, interactive: Bool) {
        guard let data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let assets = json["assets"] as? [[String: Any]],
              let asset = assets.first(where: { ($0["name"] as? String) == "BarDrop.dmg" }),
              let link = asset["browser_download_url"] as? String,
              let dmg = URL(string: link) else {
            Log.edge.error("Update-Suche fehlgeschlagen: \(error?.localizedDescription ?? "keine Antwort", privacy: .public)")
            state = .failed(L("Couldn’t reach GitHub.", "Keine Verbindung zu GitHub."))
            if interactive {
                showMessage(L("Update check failed", "Suche nach Updates fehlgeschlagen"),
                            L("Couldn’t reach GitHub. Please try again later.", "Keine Verbindung zu GitHub. Versuch es später noch einmal."))
            }
            return
        }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let digest = (asset["digest"] as? String).flatMap { $0.hasPrefix("sha256:") ? String($0.dropFirst(7)) : nil }
        let page = (json["html_url"] as? String).flatMap(URL.init(string:)) ?? releasesPage

        guard Self.isNewer(version, than: currentVersion) else {
            state = .upToDate
            if interactive {
                showMessage(L("BarDrop is up to date", "BarDrop ist aktuell"),
                            L("Version \(currentVersion) is the latest.", "Version \(currentVersion) ist die neueste."))
            }
            return
        }
        release = Release(version: version, dmg: dmg, sha256: digest, page: page)
        state = .available(version)
        if interactive || AppSettings.shared.skippedUpdateVersion != version {
            offer(version, interactive: interactive)
        }
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0
            let r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    // MARK: Anbieten

    private func offer(_ version: String, interactive: Bool) {
        let alert = NSAlert()
        alert.messageText = L("BarDrop \(version) is available", "BarDrop \(version) ist verfügbar")
        alert.informativeText = L("You have \(currentVersion). BarDrop is replaced and then restarts; the shelf keeps its items.",
                                  "Installiert ist \(currentVersion). BarDrop wird ersetzt und startet danach neu, der Inhalt der Ablage bleibt erhalten.")
        alert.addButton(withTitle: L("Install", "Installieren"))
        alert.addButton(withTitle: L("Later", "Später"))
        if !interactive { alert.addButton(withTitle: L("Skip This Version", "Diese Version überspringen")) }
        alert.icon = NSApp.applicationIconImage
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            install()
        case .alertThirdButtonReturn:
            AppSettings.shared.skippedUpdateVersion = version
        default:
            break
        }
    }

    // MARK: Installieren

    func install() {
        guard let release else { return check(interactive: true) }
        let target = Bundle.main.bundleURL
        guard target.pathExtension == "app" else { return }
        if target.path.contains("/AppTranslocation/") || target.path.hasPrefix("/Volumes/") {
            showMessage(L("Move to Applications first", "Erst in „Programme“ bewegen"),
                        L("BarDrop is running straight from the download. Move BarDrop to the Applications folder first and open it from there.",
                          "BarDrop läuft gerade direkt aus dem Download. Zieh BarDrop zuerst in den Ordner „Programme“ und starte es von dort."))
            return
        }
        state = .installing
        URLSession.shared.downloadTask(with: release.dmg) { [weak self] location, _, error in
            guard let self else { return }
            guard let location else {
                return self.fail(L("Download failed: \(error?.localizedDescription ?? "unknown")",
                                  "Download fehlgeschlagen: \(error?.localizedDescription ?? "unbekannt")"), release)
            }
            do {
                let work = FileManager.default.temporaryDirectory
                    .appendingPathComponent("BarDropUpdate-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
                let dmg = work.appendingPathComponent("BarDrop.dmg")
                try FileManager.default.moveItem(at: location, to: dmg)
                try self.prepare(dmg: dmg, in: work, target: target, release: release)
            } catch {
                self.fail(error.localizedDescription, release)
            }
        }.resume()
    }

    private struct UpdateError: LocalizedError {
        let errorDescription: String?
        init(_ text: String) { errorDescription = text }
    }

    /// Prüft die DMG, legt die neue App neben die alte und startet den Austausch.
    private func prepare(dmg: URL, in work: URL, target: URL, release: Release) throws {
        if let expected = release.sha256 {
            let data = try Data(contentsOf: dmg)
            let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard actual == expected.lowercased() else { throw UpdateError(L("The DMG’s checksum doesn’t match.", "Die Prüfsumme der DMG stimmt nicht.")) }
        }

        let mount = work.appendingPathComponent("mnt", isDirectory: true)
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        guard Self.run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-noautoopen", "-readonly",
                                            "-mountpoint", mount.path]) else {
            throw UpdateError(L("The DMG couldn’t be opened.", "Die DMG ließ sich nicht öffnen."))
        }
        defer { _ = Self.run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }

        guard let app = (try? FileManager.default.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil))?
            .first(where: { $0.pathExtension == "app" }) else {
            throw UpdateError(L("The DMG contains no app.", "In der DMG ist keine App."))
        }
        let staged = target.deletingLastPathComponent().appendingPathComponent(".BarDrop-Update.app")
        try? FileManager.default.removeItem(at: staged)
        guard Self.run("/usr/bin/ditto", [app.path, staged.path]) else {
            throw UpdateError(L("No permission to write to the folder “\(target.deletingLastPathComponent().lastPathComponent)”.",
                                "Keine Schreibrechte im Ordner „\(target.deletingLastPathComponent().lastPathComponent)“."))
        }

        // Austausch erst, wenn BarDrop beendet ist; danach neu starten
        let script = """
        while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
        rm -rf "$2" && mv "$3" "$2"
        xattr -dr com.apple.quarantine "$2" 2>/dev/null
        open "$2"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "sh", "\(ProcessInfo.processInfo.processIdentifier)",
                             target.path, staged.path]
        try process.run()
        Log.edge.info("Update auf \(release.version, privacy: .public) wird installiert")
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }

    private static func run(_ tool: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func fail(_ message: String, _ release: Release) {
        Log.edge.error("Update fehlgeschlagen: \(message, privacy: .public)")
        DispatchQueue.main.async {
            self.state = .failed(message)
            let alert = NSAlert()
            alert.messageText = L("The update couldn’t be installed", "Update konnte nicht installiert werden")
            alert.informativeText = L("\(message) You can also download the new version yourself.",
                                      "\(message) Du kannst die neue Version auch selbst laden.")
            alert.addButton(withTitle: L("Open Download", "Download öffnen"))
            alert.addButton(withTitle: L("Cancel", "Abbrechen"))
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(release.page) }
        }
    }

    private func showMessage(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.icon = NSApp.applicationIconImage
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
