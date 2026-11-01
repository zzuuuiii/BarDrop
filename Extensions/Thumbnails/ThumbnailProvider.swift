import AppKit
import QuickLookThumbnailing

/// Symbol einer .bdrop-Datei im Finder: das leere Dokumentblatt von macOS (wie bei DMG)
/// und darauf das Symbol des Plugins in seiner Farbe, so wie es in BarDrop aussieht.
@objc(ThumbnailProvider)
final class ThumbnailProvider: QLThumbnailProvider {
    override func provideThumbnail(for request: QLFileThumbnailRequest,
                                   _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        let icon = PluginArchive.icon(of: request.fileURL)
        let side = min(request.maximumSize.width, request.maximumSize.height)
        let size = CGSize(width: side, height: side)
        let scale = request.scale
        let reply = QLThumbnailReply(contextSize: size) { context in
            // Der Kontext hat Pixel (Größe mal Retina-Faktor), aber keine passende Skalierung:
            // ohne sie füllte das Symbol nur ein Viertel des Bildes
            context.scaleBy(x: scale, y: scale)
            DocumentIcon.draw(icon, in: context, size: size)
            return true
        }
        // Das Bild ist schon ein ganzes Symbol mit Blatt. Ohne diese Angabe legte der Finder
        // ein weißes Quadrat dahinter (Rahmen für Vorschauen von Dokumenten). Nicht
        // öffentlich, darum nur, wenn es die Eigenschaft gibt; 0 = ohne Rahmen
        if reply.responds(to: NSSelectorFromString("setIconFlavor:")) {
            reply.setValue(0, forKey: "iconFlavor")
        }
        handler(reply, nil)
    }
}
