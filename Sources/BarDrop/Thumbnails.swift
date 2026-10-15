import AppKit
import SwiftUI
import QuickLookThumbnailing

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

    private static func key(_ url: URL, size: CGFloat) -> String {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?
            .timeIntervalSince1970 ?? 0
        return "\(url.standardizedFileURL.path)|\(Int(size))|\(Int(modified))"
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
    static func icon(_ url: URL) -> NSImage {
        let key = url.standardizedFileURL.path as NSString
        if let icon = icons.object(forKey: key) { return icon }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icons.setObject(icon, forKey: key)
        return icon
    }

    static func load(_ url: URL, size: CGFloat, completion: @escaping (NSImage?) -> Void) {
        let k = key(url, size: size)
        if let img = cache.object(forKey: k as NSString) {
            completion(img)
            return
        }
        if pending[k] != nil {
            pending[k]?.append(completion)
            return
        }
        pending[k] = [completion]
        let request = QLThumbnailGenerator.Request(fileAt: url,
                                                   size: CGSize(width: size, height: size),
                                                   scale: scale,
                                                   representationTypes: .all)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
            let image = rep?.nsImage
            // Nur echte Vorschaubilder merken. Ein bloßes Symbol kommt z. B., solange
            // eine frisch abgelegte Datei noch geschrieben wird; dann später erneut versuchen.
            let final = rep?.type == .thumbnail
            DispatchQueue.main.async {
                if let image, final { cache.setObject(image, forKey: k as NSString) }
                let waiting = pending.removeValue(forKey: k) ?? []
                waiting.forEach { $0(image) }
            }
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

struct ThumbnailView: View {
    let url: URL
    let size: CGFloat
    @State private var image: NSImage?
    /// Echte Vorschau (Bild, PDF, Video …) statt Symbol: bekommt runde Ecken wie im Finder.
    /// Wird beim Laden gemerkt statt beim Zeichnen geprüft (das kostet Dateizugriffe).
    @State private var isPreview = false

    var body: some View {
        Image(nsImage: image ?? Thumbnails.icon(url))
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: isPreview ? max(3, size * 0.07) : 0, style: .continuous))
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.35), radius: 3, x: 0, y: 1)
            // Neu laden, wenn sich die Datei ändert (z. B. nach dem Verschieben)
            .task(id: url) {
                image = Thumbnails.cached(url, size: size)
                isPreview = image != nil
                guard image == nil else { return }
                // Frisch abgelegte Dateien werden eventuell noch geschrieben oder geladen:
                // ein paar Mal nachsehen, bis Quick Look ein echtes Vorschaubild liefert.
                for delay in [0.0, 0.3, 0.8, 1.5, 3.0, 6.0] {
                    if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
                    if Task.isCancelled { return }
                    if let loaded = await Thumbnails.load(url, size: size) { image = loaded }
                    if Thumbnails.cached(url, size: size) != nil {
                        isPreview = true
                        return
                    }
                }
            }
    }
}
