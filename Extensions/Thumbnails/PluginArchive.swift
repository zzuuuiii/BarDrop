import Compression
import Foundation

/// Liest das Symbol aus der manifest.json einer .bdrop-Datei (ZIP), ohne sie zu entpacken.
/// Die Erweiterung läuft in der Sandbox; ein Hilfsprogramm wie unzip käme dort nicht an
/// die Datei. Darum hier ein kleiner Leser für das Inhaltsverzeichnis des Archivs.
enum PluginArchive {
    struct Icon {
        var symbol: String
        var color: String?
    }

    /// Wie in BarDrop (PluginPackage.maxPackageSize): Plugins sind Skripte
    private static let maxPackageSize = 5 * 1024 * 1024
    private static let maxManifestSize = 256 * 1024

    static func icon(of file: URL) -> Icon? {
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe),
              data.count <= maxPackageSize,
              let manifest = manifestData(in: data),
              let json = try? JSONSerialization.jsonObject(with: manifest) as? [String: Any],
              let icon = json["icon"] as? [String: Any],
              let symbol = icon["symbol"] as? String else { return nil }
        return Icon(symbol: symbol, color: icon["color"] as? String)
    }

    /// manifest.json direkt im Archiv oder in genau einem Ordner darin (so entsteht es
    /// beim Komprimieren im Finder), wie PluginPackage.locateRoot
    static func manifestData(in zip: Data) -> Data? {
        let bytes = [UInt8](zip)
        guard let entries = centralDirectory(bytes) else { return nil }
        let candidates = entries.filter { entry in
            let parts = entry.name.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.last == "manifest.json", !entry.name.hasPrefix("__MACOSX/") else { return false }
            return parts.count <= 2
        }
        // Liegt eines direkt im Archiv, gilt es
        guard let entry = candidates.min(by: { $0.name.count < $1.name.count }) else { return nil }
        return contents(of: entry, in: bytes)
    }

    private struct Entry {
        var name: String
        var method: UInt16
        var compressedSize: Int
        var size: Int
        var localHeader: Int
    }

    private static func u16(_ b: [UInt8], _ i: Int) -> Int {
        guard i + 2 <= b.count else { return 0 }
        return Int(b[i]) | Int(b[i + 1]) << 8
    }

    private static func u32(_ b: [UInt8], _ i: Int) -> Int {
        guard i + 4 <= b.count else { return 0 }
        return Int(b[i]) | Int(b[i + 1]) << 8 | Int(b[i + 2]) << 16 | Int(b[i + 3]) << 24
    }

    private static func centralDirectory(_ b: [UInt8]) -> [Entry]? {
        // Ende des Inhaltsverzeichnisses: höchstens 64 KB Kommentar dahinter
        guard b.count >= 22 else { return nil }
        var end = -1
        var i = b.count - 22
        while i >= max(0, b.count - 22 - 65_535) {
            if u32(b, i) == 0x0605_4B50 { end = i; break }
            i -= 1
        }
        guard end >= 0 else { return nil }
        let count = u16(b, end + 10)
        var p = u32(b, end + 16)
        var entries: [Entry] = []
        for _ in 0..<count {
            guard p + 46 <= b.count, u32(b, p) == 0x0201_4B50 else { return nil }
            let nameLength = u16(b, p + 28)
            let extra = u16(b, p + 30)
            let comment = u16(b, p + 32)
            guard p + 46 + nameLength <= b.count else { return nil }
            let name = String(decoding: b[(p + 46)..<(p + 46 + nameLength)], as: UTF8.self)
            entries.append(Entry(name: name, method: UInt16(u16(b, p + 10)),
                                 compressedSize: u32(b, p + 20), size: u32(b, p + 24),
                                 localHeader: u32(b, p + 42)))
            p += 46 + nameLength + extra + comment
        }
        return entries
    }

    private static func contents(of entry: Entry, in b: [UInt8]) -> Data? {
        let h = entry.localHeader
        guard entry.size <= maxManifestSize, h + 30 <= b.count, u32(b, h) == 0x0403_4B50 else { return nil }
        let start = h + 30 + u16(b, h + 26) + u16(b, h + 28)
        guard start + entry.compressedSize <= b.count else { return nil }
        let raw = Array(b[start..<(start + entry.compressedSize)])
        switch entry.method {
        case 0:
            return Data(raw)
        case 8:
            // Deflate ohne zlib-Kopf, genau das erwartet COMPRESSION_ZLIB
            var out = [UInt8](repeating: 0, count: max(entry.size, 1))
            let written = compression_decode_buffer(&out, out.count, raw, raw.count, nil, COMPRESSION_ZLIB)
            guard written == entry.size else { return nil }
            return Data(out.prefix(written))
        default:
            return nil
        }
    }
}
