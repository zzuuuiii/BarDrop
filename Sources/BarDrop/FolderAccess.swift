import AppKit
import Combine

/// Ordner, die BarDrop von selbst beobachtet (Bildschirmfotos, AirDrop), und ob macOS das
/// Lesen erlaubt. Schreibtisch, Dokumente und Downloads sind durch „Dateien und Ordner“
/// geschützt; nach einem Update von BarDrop kann diese Erlaubnis fehlen. Die Einstellungen
/// zeigen dann, welcher Ordner betroffen ist, und führen zur passenden Stelle.
final class FolderAccess: ObservableObject {
    static let shared = FolderAccess()

    /// Ordner ohne Lesezugriff
    @Published private(set) var denied: [URL] = []

    /// Inhalt eines Ordners, nil ohne Zugriff (dann vermerkt und einmal protokolliert)
    func contents(of folder: URL, keys: [URLResourceKey], area: String) -> [URL]? {
        do {
            let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                                    options: [.skipsHiddenFiles])
            setDenied(folder, false, area: area, error: nil)
            return files
        } catch {
            setDenied(folder, true, area: area, error: error as NSError)
            return nil
        }
    }

    /// Ordner wird nicht mehr beobachtet: kein Hinweis mehr dazu
    func forget(_ folder: URL) {
        let key = folder.standardizedFileURL
        if denied.contains(key) { denied.removeAll { $0 == key } }
    }

    func isDenied(_ folder: URL) -> Bool { denied.contains(folder.standardizedFileURL) }

    private func setDenied(_ folder: URL, _ isDenied: Bool, area: String, error: NSError?) {
        let key = folder.standardizedFileURL
        guard denied.contains(key) != isDenied else { return }
        if isDenied {
            denied.append(key)
            let code = error.map { "\($0.domain) \($0.code)" } ?? "-"
            Diagnostics.shared.failure(area, "Ordner nicht lesbar \(Diagnostics.anon(folder)) \(code)")
        } else {
            denied.removeAll { $0 == key }
            Diagnostics.shared.record(area, "Ordner wieder lesbar \(Diagnostics.anon(folder))")
        }
    }

    /// Beim Start, bevor irgendetwas anderes auf Dateien zugreift: In jeden geschützten Ordner
    /// (Schreibtisch, Dokumente, Downloads), den BarDrop gleich braucht, einmal hineinsehen.
    ///
    /// Fehlte die Erlaubnis (neue Fassung, nach einem Update), griffen sonst gleich mehrere
    /// Stellen fast gleichzeitig darauf zu: Ablage (Dateien vom Schreibtisch), Aktionsleiste
    /// (Symbol eines Ordners im Schreibtisch) und die Vorschaubilder in einem eigenen Prozess von
    /// macOS. Die Abfrage „BarDrop möchte auf den Schreibtisch zugreifen“ kam dann doppelt.
    /// Hier wartet der Start, bis sie beantwortet ist; danach kennt macOS die Antwort.
    static func askOnceAtLaunch(store: URL, settings: AppSettings) {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        var paths = settings.quickActions.compactMap(\.path)
        if settings.addScreenshots { paths.append(ScreenshotWatcher.screenshotFolder().path) }
        if settings.addAirDrop, let downloads = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first {
            paths.append(downloads.path)
        }
        // Die Liste der Ablage nur als Text durchsuchen (JSON schreibt „/“ teils als „\/“)
        let shelf = (try? String(contentsOf: store, encoding: .utf8))?.replacingOccurrences(of: "\\/", with: "/") ?? ""
        for name in ["Desktop", "Documents", "Downloads"] {
            let folder = home.appendingPathComponent(name, isDirectory: true).path
            let used = paths.contains { $0 == folder || $0.hasPrefix(folder + "/") } || shelf.contains(folder + "/")
            guard used else { continue }
            let start = Date()
            let result: String
            do {
                result = "ok \(try fm.contentsOfDirectory(atPath: folder).count)"
            } catch {
                let e = error as NSError
                result = "\(e.domain) \(e.code)"
            }
            Diagnostics.shared.record("access", "Start \(name): \(result) nach \(Int(Date().timeIntervalSince(start) * 1000)) ms")
        }
    }

    /// Name des Ordners, wie ihn der Finder zeigt („Schreibtisch“)
    static func displayName(_ folder: URL) -> String {
        FileManager.default.displayName(atPath: folder.path)
    }

    /// Systemeinstellungen → Datenschutz & Sicherheit → Dateien und Ordner
    static func openPrivacySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")!
        NSWorkspace.shared.open(url)
    }
}
