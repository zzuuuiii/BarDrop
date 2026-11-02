import AppKit
import SwiftUI
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// Vorschaubilder über Quick Look, mit Zwischenspeicher (nach boring.notch, ThumbnailService):
/// Größe und Änderungsdatum gehören zum Schlüssel, gleichzeitige Anfragen für dasselbe
/// Bild werden zu einer zusammengefasst.
enum Thumbnails {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 400
        return cache
    }()
    /// Laufende Anfragen und wer auf sie wartet (nur auf dem Hauptthread)
    private static var pending: [String: [(NSImage?) -> Void]] = [:]
    /// Kennung der laufenden Anfrage je Schlüssel (für das Sicherheitsnetz in `load`)
    private static var pendingToken: [String: UUID] = [:]
    /// Schlüssel, für die schon das scharfe Vorschaubild im Speicher liegt (Hauptthread)
    private static var sharp = Set<String>()

    /// Liegt das scharfe Vorschaubild schon vor (nicht nur das schnelle)?
    static func isSharp(_ url: URL, size: CGFloat) -> Bool {
        // Nur, solange das Bild noch im Zwischenspeicher liegt (er kann es verdrängt haben)
        let k = key(url, size: size)
        return sharp.contains(k) && cache.object(forKey: k as NSString) != nil
    }

    private static func key(_ url: URL, size: CGFloat) -> String {
        let path = url.standardizedFileURL.path
        return "\(path)|\(Int(size))|\(Int(modified(path, url)))"
    }

    /// Änderungsdatum, eine halbe Sekunde lang gemerkt: Jede Kachel fragt bei jedem Neuzeichnen
    /// nach (beim Laden vieler Bilder alle 30 ms), das waren bei 300 Dateien tausende
    /// Dateizugriffe pro Sekunde auf dem Hauptthread
    private static var modifiedDates: [String: (value: TimeInterval, checked: TimeInterval)] = [:]
    private static let modifiedLock = NSLock()

    private static func modified(_ path: String, _ url: URL) -> TimeInterval {
        let now = ProcessInfo.processInfo.systemUptime
        modifiedLock.lock()
        let known = modifiedDates[path]
        modifiedLock.unlock()
        if let known, now - known.checked < 0.5 { return known.value }
        let value = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?
            .timeIntervalSince1970 ?? 0
        // Frisch geschriebene Dateien nicht merken: Ihr Datum ändert sich noch, und mit dem alten
        // Schlüssel galt „kein Vorschaubild möglich“ länger, die Kachel zeigte kurz das weiße
        // Blatt (Nutzer, 01.11.2026)
        guard Date().timeIntervalSince1970 - value > 10 else { return value }
        modifiedLock.lock()
        if modifiedDates.count > 4000 { modifiedDates.removeAll() }
        modifiedDates[path] = (value, now)
        modifiedLock.unlock()
        return value
    }

    /// Schärfster Bildschirm (nicht `NSScreen.main`, das wechselt mit dem aktiven Fenster)
    private static var scale: CGFloat {
        NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
    }

    static func cached(_ url: URL, size: CGFloat) -> NSImage? {
        cache.object(forKey: key(url, size: size) as NSString)
    }

    private static let icons: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 400
        return cache
    }()

    /// Beim Öffnen der Ablage neu laden: Eine Datei kann inzwischen durch eine andere
    /// gleichen Namens ersetzt worden sein.
    static func forgetIcons() {
        icons.removeAllObjects()
    }

    /// Finder-Symbol, zwischengespeichert: Es wird beim Zeichnen jeder Kachel gebraucht,
    /// auch in jedem Bild der Öffnen-Animation, und kostet sonst jedes Mal einen Dateizugriff.
    ///
    /// Gewöhnliche Dateien bekommen das Symbol ihres Typs (ZIP, PDF, Bild …): Das steht sofort
    /// fest. Das Symbol der Datei selbst ist bei einer frisch geschriebenen Datei oft noch das
    /// weiße Standardblatt und springt erst danach um.
    static func icon(_ url: URL) -> NSImage {
        let key = url.standardizedFileURL.path as NSString
        if let icon = icons.object(forKey: key) { return icon }
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isPackageKey])
        let icon: NSImage
        if values?.isRegularFile == true, values?.isPackage != true, !url.pathExtension.isEmpty,
           let type = UTType(filenameExtension: url.pathExtension) {
            icon = NSWorkspace.shared.icon(for: type)
        } else {
            icon = NSWorkspace.shared.icon(forFile: url.path)
        }
        icons.setObject(icon, forKey: key)
        return icon
    }

    /// Dateien, deren Kachel schon einmal gezeigt wurde (nur auf dem Hauptthread)
    static var shownOnce = Set<String>()

    /// Eine Kachel zeigt jetzt ihr Symbol oder Vorschaubild (Hauptthread). Die Ablage
    /// zeichnet sich daraufhin neu, auch wenn sie gerade keinen Fokus hat.
    static let didChange = Notification.Name("BarDropThumbnailDidChange")

    /// Dateien, für die Quick Look kein Vorschaubild erzeugen kann (z. B. Links als .webloc,
    /// Programme, Disk-Images), und bis wann das gilt. Der Schlüssel enthält das
    /// Änderungsdatum: Ändert sich die Datei, wird es erneut versucht. Ohne diese Liste
    /// fragte jede Kachel bei jedem Erscheinen siebenmal vergeblich nach (im Diagnoseprotokoll
    /// dieselbe Datei rund 350-mal), und das bremste Öffnen und Scrollen.
    private static var unavailable: [String: Date] = [:]
    /// „Keine Vorschau für Cloud-Datei“: Wird die Datei geladen, gibt es eins, darum nicht für immer
    private static let cloudRetry: TimeInterval = 10 * 60

    private static func isUnavailable(_ key: String) -> Bool {
        guard let until = unavailable[key] else { return false }
        if until > Date() { return true }
        unavailable.removeValue(forKey: key)
        return false
    }

    /// Quick Look liefert für diese Datei gerade kein Vorschaubild (Hauptthread)
    static func isUnavailable(_ url: URL, size: CGFloat) -> Bool {
        isUnavailable(key(url, size: size))
    }

    static func load(_ url: URL, size: CGFloat, completion: @escaping (NSImage?) -> Void) {
        let k = key(url, size: size)
        if let img = cache.object(forKey: k as NSString) {
            completion(img)
            return
        }
        if isUnavailable(k) {
            completion(nil)
            return
        }
        if pending[k] != nil {
            pending[k]?.append(completion)
            return
        }
        pending[k] = [completion]
        let token = UUID()
        pendingToken[k] = token
        // Sicherheitsnetz: Meldet Quick Look sich nicht mehr, warten Anfragen nicht ewig. Nur
        // für diese Anfrage; eine spätere für dieselbe Datei hat ihr eigenes
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
            guard pendingToken[k] == token else { return }
            pendingToken[k] = nil
            pending.removeValue(forKey: k)?.forEach { $0(cache.object(forKey: k as NSString)) }
        }
        let request = QLThumbnailGenerator.Request(fileAt: url,
                                                   size: CGSize(width: size, height: size),
                                                   scale: scale,
                                                   representationTypes: .all)
        // Wie der Finder in Stufen: erst ein schnelles Vorschaubild in niedriger Auflösung
        // (kommt oft sofort), dann das scharfe. So erscheint gleich das Bild der Datei statt
        // zuerst das allgemeine Symbol ihres Typs.
        let requested = Date()
        QLThumbnailGenerator.shared.generateRepresentations(for: request) { rep, type, error in
            let image = rep?.nsImage
            DispatchQueue.main.async {
                if Diagnostics.shared.isEnabled {
                    let stage = [0: "icon", 1: "low", 2: "sharp"][type.rawValue] ?? "\(type.rawValue)"
                    let uti = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType?.identifier ?? "?"
                    let base = "\(Diagnostics.anon(url)) stage=\(stage) uti=\(uti) image=\(image != nil) ms=\(Int(Date().timeIntervalSince(requested) * 1000))"
                    if let error {
                        // Für die schnelle Stufe hat Quick Look oft nichts zwischengespeichert: normal
                        let harmless = type == .lowQualityThumbnail && (error as NSError).code == 2
                        // Links, Dateien ohne Endung & Co.: Quick Look hat für diese Art Datei kein
                        // Bild, gezeigt wird ihr Symbol. Auch normal, kein Fehler
                        let noPreviewKind = (error as NSError).domain == QLThumbnailError.errorDomain
                            && (error as NSError).code == QLThumbnailError.Code.generationFailed.rawValue
                            && !ThumbnailView.expectsPreview(url)
                        // Cloud-Datei noch nicht geladen: Symbol, nach 10 Minuten neuer Versuch
                        let cloudOnly = (error as NSError).domain == QLThumbnailError.errorDomain
                            && (error as NSError).code == QLThumbnailError.noCloudThumbnail.rawValue
                        if harmless {
                            Diagnostics.shared.record("thumb", base + " (normal: keine schnelle Vorschau zwischengespeichert)")
                        } else if noPreviewKind {
                            Diagnostics.shared.record("thumb", base + " (normal: für diese Art Datei gibt es kein Vorschaubild, Symbol)")
                        } else if cloudOnly {
                            Diagnostics.shared.record("thumb", base + " (normal: Cloud-Datei noch nicht geladen, Symbol)")
                        } else {
                            Diagnostics.shared.failure("thumb", "Vorschau " + base, error)
                        }
                    } else {
                        Diagnostics.shared.record("thumb", base)
                    }
                }
                // Die scharfe Stufe ist gescheitert, weil Quick Look für diese Datei keins
                // erzeugen kann: nicht weiter fragen. generationFailed (Code 0) gilt, bis sich
                // die Datei ändert; noCloudThumbnail (Code 3) 10 Minuten, sie kann inzwischen
                // geladen sein
                if type == .thumbnail, image == nil, let error = error as NSError?,
                   error.domain == QLThumbnailError.errorDomain {
                    // Wie `prefetched` begrenzt; neu gefragt wird dann höchstens einmal
                    if unavailable.count > 5000 { unavailable.removeAll() }
                    if error.code == QLThumbnailError.Code.generationFailed.rawValue {
                        unavailable[k] = .distantFuture
                    } else if error.code == QLThumbnailError.noCloudThumbnail.rawValue {
                        unavailable[k] = Date().addingTimeInterval(cloudRetry)
                    }
                }
                // Nur echte Vorschaubilder merken. Ein bloßes Symbol kommt z. B., solange
                // eine frisch abgelegte Datei noch geschrieben wird; dann später erneut versuchen.
                if let image, type != .icon {
                    // Das scharfe Bild ersetzt das schnelle; umgekehrt nie
                    if type == .thumbnail || cache.object(forKey: k as NSString) == nil {
                        cache.setObject(image, forKey: k as NSString)
                        ThumbnailEvents.shared.changed()
                    }
                    if type == .thumbnail {
                        if sharp.count > 5000 { sharp.removeAll() }
                        sharp.insert(k)
                    }
                }
                // Wartende bekommen das erste echte Bild, spätestens die letzte Stufe
                guard (image != nil && type != .icon) || type == .thumbnail,
                      let waiting = pending.removeValue(forKey: k) else { return }
                pendingToken[k] = nil
                waiting.forEach { $0(type == .icon ? nil : image) }
            }
        }
    }

    /// Vorschaubilder neu abgelegter Dateien gleich laden, nicht erst, wenn ihre Kachel
    /// erscheint. Laut Diagnoseprotokoll startete SwiftUI das Laden in der offenen Ablage
    /// nicht, solange eine andere App vorn war: Ein Bild aus dem Web blieb unsichtbar, bis
    /// die Ablage schloss. Frische Dateien liefern zuerst oft nur ein Symbol: dann noch
    /// zweimal nachsehen.
    private static var prefetched = Set<String>()

    static func prefetch(_ urls: [URL], size: CGFloat) {
        for url in urls {
            let k = key(url, size: size)
            guard !prefetched.contains(k), cache.object(forKey: k as NSString) == nil else { continue }
            // Nicht endlos wachsen lassen: Wer erneut auftaucht, wird eben noch einmal geladen
            if prefetched.count > 5000 { prefetched.removeAll() }
            prefetched.insert(k)
            func attempt(_ left: Int) {
                load(url, size: size) { image in
                    guard image == nil, left > 0, !isUnavailable(k) else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { attempt(left - 1) }
                }
            }
            attempt(2)
        }
    }

    /// Wie `load`, zum Abwarten.
    static func load(_ url: URL, size: CGFloat) async -> NSImage? {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                load(url, size: size) { continuation.resume(returning: $0) }
            }
        }
    }
}

/// Meldet neue Vorschaubilder an die Kacheln: Sie zeigen ein Bild aus dem Zwischenspeicher,
/// sobald es da ist, auch wenn ihr eigenes Laden (noch) nicht gestartet ist
final class ThumbnailEvents: ObservableObject {
    static let shared = ThumbnailEvents()
    @Published private(set) var revision = 0
    private var scheduled = false

    /// Viele Bilder auf einmal (großer Ordner): höchstens alle 30 ms neu zeichnen
    func changed() {
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            guard let self else { return }
            self.scheduled = false
            self.revision &+= 1
            NotificationCenter.default.post(name: Thumbnails.didChange, object: nil)
        }
    }
}

struct ThumbnailView: View {
    let url: URL
    let size: CGFloat
    @ObservedObject private var events = ThumbnailEvents.shared
    @State private var image: NSImage?
    /// Echte Vorschau (Bild, PDF, Video …) statt Symbol: bekommt runde Ecken wie im Finder.
    /// Wird beim Laden gemerkt statt beim Zeichnen geprüft (das kostet Dateizugriffe).
    @State private var isPreview = false
    /// Frisch abgelegt: kurz warten, ob gleich ein Vorschaubild kommt, statt erst das
    /// Symbol und dann das Bild zu zeigen (das flackert)
    @State private var ready: Bool

    init(url: URL, size: CGFloat) {
        self.url = url
        self.size = size
        let cached = Thumbnails.cached(url, size: size)
        _image = State(initialValue: cached)
        _isPreview = State(initialValue: cached != nil)
        _ready = State(initialValue: cached != nil || Thumbnails.shownOnce.contains(url.path))
    }

    var body: some View {
        // Schon im Zwischenspeicher (vorab geladen), auch wenn das eigene Laden noch nicht lief
        let shown = image ?? Thumbnails.cached(url, size: size)
        let preview = isPreview || (image == nil && shown != nil)
        Image(nsImage: shown ?? Thumbnails.icon(url))
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: preview ? max(3, size * 0.07) : 0, style: .continuous))
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.35), radius: 3, x: 0, y: 1)
            .opacity(ready || shown != nil || Thumbnails.isUnavailable(url, size: size) ? 1 : 0)
            // Spätestens nach kurzer Zeit das Symbol zeigen, falls Quick Look länger braucht.
            // Bilder, PDFs und Videos bekommen fast immer gleich ein Vorschaubild: etwas länger
            // darauf warten, statt erst das Symbol und dann das Bild zu zeigen (das flackerte)
            .task(id: url) {
                guard !ready else { return }
                try? await Task.sleep(nanoseconds: Self.expectsPreview(url) ? 1_200_000_000 : 350_000_000)
                reveal()
            }
            // Neu laden, wenn sich die Datei ändert (z. B. nach dem Verschieben)
            .task(id: url) {
                image = Thumbnails.cached(url, size: size)
                isPreview = image != nil
                guard image == nil else { return reveal() }
                // Frisch abgelegte Dateien werden eventuell noch geschrieben oder geladen:
                // ein paar Mal nachsehen, bis Quick Look ein echtes Vorschaubild liefert.
                for delay in [0.0, 0.15, 0.3, 0.6, 1.5, 3.0, 6.0] {
                    if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
                    if Task.isCancelled { return }
                    // Quick Look kann für diese Datei kein Bild machen: Symbol zeigen, nicht weiter fragen
                    if Thumbnails.isUnavailable(url, size: size) { return reveal() }
                    // Nur echte Vorschaubilder übernehmen; ein bloßes Symbol von Quick Look ist
                    // bei frischen Dateien oft das weiße Standardblatt
                    _ = await Thumbnails.load(url, size: size)
                    if let found = Thumbnails.cached(url, size: size) {
                        let wasShown = ready
                        image = found
                        isPreview = true
                        reveal()
                        // War die Kachel schon zu sehen, kam nur das Bild dazu
                        if wasShown { NotificationCenter.default.post(name: Thumbnails.didChange, object: nil) }
                        // Erst das schnelle Bild: kurz darauf das scharfe übernehmen
                        for _ in 0..<12 where !Thumbnails.isSharp(url, size: size) {
                            try? await Task.sleep(nanoseconds: 250_000_000)
                            if Task.isCancelled { return }
                        }
                        if let sharp = Thumbnails.cached(url, size: size), sharp !== found {
                            image = sharp
                            NotificationCenter.default.post(name: Thumbnails.didChange, object: nil)
                        }
                        return
                    }
                    // Erster Versuch ohne echtes Vorschaubild: Symbol zeigen, außer bei Dateien,
                    // für die gleich noch ein Vorschaubild kommt (siehe oben)
                    if delay == 0 && !Self.expectsPreview(url) { reveal() }
                }
            }
    }

    /// Dateien, für die Quick Look in aller Regel ein echtes Vorschaubild liefert
    static func expectsPreview(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return [UTType.image, .pdf, .movie, .presentation].contains { type.conforms(to: $0) }
    }

    private func reveal() {
        // Nicht endlos wachsen lassen: Danach wartet eine Kachel nur einmal mehr kurz
        if Thumbnails.shownOnce.count > 5000 { Thumbnails.shownOnce.removeAll() }
        Thumbnails.shownOnce.insert(url.path)
        guard !ready else { return }
        Diagnostics.shared.record("tile", "reveal \(Diagnostics.anon(url)) preview=\(isPreview) exists=\(FileManager.default.fileExists(atPath: url.path))")
        // Ohne Animation: Kommt die Datei erst nach einem Download an (Bilder aus dem
        // Web), hat die Ablage oft keinen Fokus mehr. Eine Einblendung bliebe dann bei
        // Deckkraft null hängen, und die Kachel wäre bis zum nächsten Öffnen unsichtbar.
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { ready = true }
        NotificationCenter.default.post(name: Thumbnails.didChange, object: nil)
    }
}
