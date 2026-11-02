import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Macht Bilder aus dem Web für andere Programme verträglich.
///
/// Browser liefern Bilder oft als WebP, AVIF oder HEIC, ohne Dateiendung
/// („download“) oder mit falscher Endung. Viele Programme melden dann einen
/// Fehler. Hier wird das echte Format erkannt, die Endung korrigiert und,
/// wenn gewünscht, in PNG oder JPEG umgewandelt.
enum ImageNormalizer {
    /// Formate, die praktisch jedes Programm öffnen kann.
    private static let compatible: [UTType] = [.png, .jpeg, .gif]

    /// Gibt die (ggf. neue) Adresse der Datei zurück. Läuft auch im Hintergrund.
    static func normalize(_ url: URL, convert: Bool) -> URL {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let typeID = CGImageSourceGetType(source) as String?,
              let type = UTType(typeID),
              type.conforms(to: .image) else {
            return url
        }

        if compatible.contains(type) || !convert {
            return fixExtension(of: url, for: type)
        }

        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return fixExtension(of: url, for: type)
        }

        // Transparenz erhalten: PNG; sonst JPEG (kleiner, ebenso verträglich)
        let hasAlpha: Bool = {
            switch image.alphaInfo {
            case .none, .noneSkipFirst, .noneSkipLast: return false
            default: return true
            }
        }()
        let target: UTType = hasAlpha ? .png : .jpeg
        let ext = hasAlpha ? "png" : "jpg"
        let destURL = unique(url.deletingPathExtension().appendingPathExtension(ext))

        guard let dest = CGImageDestinationCreateWithURL(destURL as CFURL, target.identifier as CFString, 1, nil) else {
            return fixExtension(of: url, for: type)
        }
        let props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.92]
        // Aus der Quelle übernehmen statt nur die Pixel: So bleiben Ausrichtung (Hochformat aus
        // HEIC kam sonst quer heraus) und Farbprofil erhalten
        CGImageDestinationAddImageFromSource(dest, source, 0, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            try? FileManager.default.removeItem(at: destURL)
            return fixExtension(of: url, for: type)
        }
        try? FileManager.default.removeItem(at: url)
        return destURL
    }

    /// Korrigiert eine fehlende oder falsche Dateiendung.
    private static func fixExtension(of url: URL, for type: UTType) -> URL {
        let current = url.pathExtension.lowercased()
        if let current = UTType(filenameExtension: current), current == type { return url }
        if type == .jpeg, ["jpg", "jpeg"].contains(current) { return url }
        guard let ext = type.preferredFilenameExtension else { return url }
        let base = current.isEmpty || UTType(filenameExtension: current) == nil
            ? url : url.deletingPathExtension()
        let renamed = unique(base.appendingPathExtension(ext))
        do {
            try FileManager.default.moveItem(at: url, to: renamed)
            return renamed
        } catch {
            return url
        }
    }

    /// Freier Name neben `url` („Name 2.png“), wie überall in BarDrop
    private static func unique(_ url: URL) -> URL {
        ShelfActions.uniqueURL(for: url.lastPathComponent, in: url.deletingLastPathComponent())
    }
}
