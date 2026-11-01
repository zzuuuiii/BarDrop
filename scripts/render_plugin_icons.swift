// Zeichnet das Symbol jedes Plugins der Galerie als Bild für die Website:
//
//     swift scripts/render_plugin_icons.swift katalog
//
// Läuft in .github/workflows/plugin-gallery.yml auf einem Mac (nur dort gibt es die SF-Symbole),
// nach dem Bauen der Galerie. `katalog` ist ein Arbeitsordner des Zweigs `plugin-katalog`.
//
// Pro Plugin entsteht `icons/<id>.png`: nur das Zeichen, schwarz auf durchsichtig, 128 × 128,
// in derselben Strichstärke wie in der App (semibold). Die Website nutzt es als Maske und färbt
// es selbst (Textfarbe, beim Darüberfahren die Farbe des Plugins). Gibt es das Symbol auf macOS
// nicht, nimmt sie wie die App das Puzzleteil. `icons/icons.json` merkt sich, welches Symbol
// gezeichnet wurde: Unveränderte werden nicht neu geschrieben, Bilder entfernter Plugins gelöscht.
import AppKit

let args = CommandLine.arguments
guard args.count == 2 else {
    FileHandle.standardError.write("Aufruf: swift scripts/render_plugin_icons.swift <katalog>\n".data(using: .utf8)!)
    exit(2)
}
let katalog = URL(fileURLWithPath: args[1])
let iconsDir = katalog.appendingPathComponent("icons")
let stateFile = iconsDir.appendingPathComponent("icons.json")
let fallback = "puzzlepiece.extension.fill"   // wie PluginIconView.fallbackSymbol
let side = 128

struct Catalog: Decodable {
    struct Entry: Decodable {
        struct Icon: Decodable { var symbol: String }
        var id: String
        var icon: Icon?
        var removed: Bool?
    }
    var plugins: [Entry]
}

let data = try Data(contentsOf: katalog.appendingPathComponent("index.json"))
let catalog = try JSONDecoder().decode(Catalog.self, from: data)
try FileManager.default.createDirectory(at: iconsDir, withIntermediateDirectories: true)
let previous = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: stateFile))) ?? [:]

// Nur Zeichen, die in Plugin-IDs vorkommen (wie PluginLink), damit der Dateiname sicher ist
func safe(_ id: String) -> Bool {
    !id.isEmpty && id.count <= 200 && id.unicodeScalars.allSatisfy {
        ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || "._-".unicodeScalars.contains($0)
    }
}

func render(_ symbol: String) -> Data? {
    let config = NSImage.SymbolConfiguration(pointSize: 100, weight: .semibold)
    guard let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config),
          let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0)
    else { return nil }
    // In die Fläche einpassen, Seitenverhältnis bleibt, mittig
    let size = glyph.size, box = CGFloat(side) - 8
    let scale = min(box / size.width, box / size.height)
    let w = size.width * scale, h = size.height * scale
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    glyph.draw(in: NSRect(x: (CGFloat(side) - w) / 2, y: (CGFloat(side) - h) / 2, width: w, height: h))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

var state: [String: String] = [:]
var written = 0
for entry in catalog.plugins where entry.removed != true && safe(entry.id) {
    let wanted = entry.icon?.symbol ?? fallback
    let symbol = NSImage(systemSymbolName: wanted, accessibilityDescription: nil) != nil ? wanted : fallback
    if symbol != wanted { print("::warning title=Symbol::\(entry.id): „\(wanted)“ gibt es auf diesem macOS nicht, gezeichnet wird das Puzzleteil") }
    let file = iconsDir.appendingPathComponent("\(entry.id).png")
    state[entry.id] = symbol
    if previous[entry.id] == symbol, FileManager.default.fileExists(atPath: file.path) { continue }
    guard let png = render(symbol) else {
        print("::error title=Symbol::\(entry.id): „\(symbol)“ ließ sich nicht zeichnen")
        state[entry.id] = nil
        continue
    }
    try png.write(to: file)
    written += 1
}
// Bilder von Plugins, die es nicht mehr gibt
for name in (try? FileManager.default.contentsOfDirectory(atPath: iconsDir.path)) ?? []
where name.hasSuffix(".png") && state[String(name.dropLast(4))] == nil {
    try? FileManager.default.removeItem(at: iconsDir.appendingPathComponent(name))
}
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
try encoder.encode(state).write(to: stateFile)
print("Symbole: \(state.count) Plugins, \(written) neu gezeichnet")
