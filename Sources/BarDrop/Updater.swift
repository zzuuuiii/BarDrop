import AppKit
import CoreServices
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

    /// Neueste reguläre Version (GitHub zählt Vorabversionen hier nicht mit)
    private let latestURL = URL(string: "https://api.github.com/repos/zzuuuiii/BarDrop/releases/latest")!
    /// Alle Versionen, auch Betas
    private let listURL = URL(string: "https://api.github.com/repos/zzuuuiii/BarDrop/releases?per_page=20")!
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
        // Beta-Kanal: auch Vorabversionen; sonst nur reguläre Versionen
        var request = URLRequest(url: AppSettings.shared.betaUpdates ? listURL : latestURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            DispatchQueue.main.async { self?.handle(data: data, error: error, interactive: interactive) }
        }.resume()
    }

    private func handle(data: Data?, error: Error?, interactive: Bool) {
        guard let data,
              let json = Self.newestRelease(in: data),
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

    /// Eine einzelne Version (reguläre) oder aus einer Liste die höchste mit DMG (Beta-Kanal)
    private static func newestRelease(in data: Data) -> [String: Any]? {
        let object = try? JSONSerialization.jsonObject(with: data)
        if let single = object as? [String: Any] { return single }
        guard let list = object as? [[String: Any]] else { return nil }
        func version(_ r: [String: Any]) -> String {
            let tag = r["tag_name"] as? String ?? "0"
            return tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        }
        return list
            .filter { ($0["draft"] as? Bool) != true }
            .filter { (($0["assets"] as? [[String: Any]]) ?? []).contains { ($0["name"] as? String) == "BarDrop.dmg" } }
            .max { isNewer(version($1), than: version($0)) }
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
        alert.informativeText = L("You have version \(currentVersion). BarDrop will be replaced and restart; your items stay in the shelf.",
                                  "Installiert ist Version \(currentVersion). BarDrop wird ersetzt und startet neu, die Objekte bleiben in der Ablage.")
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
            showMessage(L("Move BarDrop to Applications first", "BarDrop zuerst in „Programme“ bewegen"),
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
        // Ohne Prüfsumme lässt sich die DMG nicht prüfen: dann lieber nicht installieren
        guard let expected = release.sha256 else {
            throw UpdateError(L("The download couldn’t be verified.", "Der Download ließ sich nicht prüfen."))
        }
        let data = try Data(contentsOf: dmg)
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actual == expected.lowercased() else { throw UpdateError(L("The DMG’s checksum doesn’t match.", "Die Prüfsumme der DMG stimmt nicht.")) }

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

        // Austausch sofort, noch während BarDrop läuft: Das laufende Programm ist schon
        // geladen, und ein Fehler lässt sich hier noch melden und rückgängig machen.
        let backup = target.deletingLastPathComponent().appendingPathComponent(Self.backupName)
        try? FileManager.default.removeItem(at: backup)
        do {
            try FileManager.default.moveItem(at: target, to: backup)
        } catch {
            try? FileManager.default.removeItem(at: staged)
            throw UpdateError(L("BarDrop couldn’t be replaced.", "BarDrop ließ sich nicht ersetzen."))
        }
        do {
            try FileManager.default.moveItem(at: staged, to: target)
        } catch {
            try? FileManager.default.moveItem(at: backup, to: target)
            try? FileManager.default.removeItem(at: staged)
            throw UpdateError(L("BarDrop couldn’t be replaced.", "BarDrop ließ sich nicht ersetzen."))
        }
        _ = Self.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", target.path])
        Log.edge.info("Update auf \(release.version, privacy: .public) installiert, Neustart")
        DispatchQueue.main.async { Self.relaunch(target) }
    }

    /// Alte Fassung neben der App, bis die neue gestartet ist
    private static let backupName = ".BarDrop-Old.app"
    /// Startargument der neuen Fassung: Prozessnummer der alten, auf deren Ende sie wartet
    static let afterUpdateArgument = "--bardrop-after-update"

    /// Neue Fassung über die Startdienste öffnen, nicht als Unterprozess: Ein Unterprozess
    /// kann mit der alten App zusammen beendet werden, dann startete nichts mehr.
    /// Die neue Fassung wartet, bis diese hier beendet ist, und richtet sich erst dann ein.
    private static func relaunch(_ app: URL) {
        LSRegisterURL(app as CFURL, true)
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        config.activates = false
        config.arguments = [afterUpdateArgument, "\(ProcessInfo.processInfo.processIdentifier)"]
        NSWorkspace.shared.openApplication(at: app, configuration: config) { _, error in
            if let error {
                // Rückfall: kleines Skript wartet auf das Ende und öffnet dann die App
                Log.edge.error("Neustart über Startdienste fehlgeschlagen: \(error.localizedDescription, privacy: .public)")
                let script = """
                while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
                sleep 0.5
                open "$2"
                """
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/sh")
                process.arguments = ["-c", script, "sh", "\(ProcessInfo.processInfo.processIdentifier)", app.path]
                try? process.run()
            }
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    /// Beim Start nach einem Update: auf das Ende der alten Fassung warten (höchstens
    /// zehn Sekunden), dann weitermachen. Ohne Update sofort.
    static func waitForPreviousVersion(then proceed: @escaping () -> Void) {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: afterUpdateArgument), i + 1 < args.count,
              let pid = pid_t(args[i + 1]), pid > 0 else { return proceed() }
        let deadline = Date().addingTimeInterval(10)
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { timer in
            if kill(pid, 0) != 0 || Date() > deadline {
                timer.invalidate()
                proceed()
            }
        }
    }

    /// Reste eines Updates neben der App entfernen
    static func cleanUpAfterUpdate() {
        let folder = Bundle.main.bundleURL.deletingLastPathComponent()
        DispatchQueue.global(qos: .utility).async {
            for name in [backupName, ".BarDrop-Update.app"] {
                let url = folder.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: url.path) { try? FileManager.default.removeItem(at: url) }
            }
        }
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
