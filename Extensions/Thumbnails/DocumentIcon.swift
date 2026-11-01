import AppKit
import UniformTypeIdentifiers

/// Zeichnet das Symbol einer .bdrop-Datei: leeres Dokumentblatt von macOS, darauf die
/// Kachel des Plugins und darunter grau „BDROP“. Die Kachel ist gebaut wie PluginIconView
/// in BarDrop (Verlauf von 18 % heller oben zur Farbe unten, Ecken 26 %, weißes Zeichen halb
/// so groß, leichte Schatten).
enum DocumentIcon {
    static let fallbackSymbol = "puzzlepiece.extension.fill"
    static let fallbackTint = NSColor(srgbRed: 0.45, green: 0.45, blue: 0.5, alpha: 1)
    /// Grau und Lage der Schrift wie das „BDROP“, das macOS vorher auf das Blatt schrieb
    /// (gemessen am Systemsymbol in 512 px: Großbuchstaben 40 px hoch, Grundlinie 72 px über
    /// dem Rand, #B6B6B6)
    static let label = "BDROP"
    static let labelColor = NSColor(srgbRed: 182 / 255, green: 182 / 255, blue: 182 / 255, alpha: 1)

    static func draw(_ icon: PluginArchive.Icon?, in context: CGContext, size: CGSize) {
        let side = min(size.width, size.height)
        let canvas = CGRect(x: (size.width - side) / 2, y: (size.height - side) / 2, width: side, height: side)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        // Das Blatt vom System: sieht so aus wie bei allen anderen Dateien auf diesem Mac
        NSWorkspace.shared.icon(for: .data).draw(in: canvas)
        // Oberkante der Kachel deutlich unter dem Schatten der umgeknickten Ecke
        // (Nutzer: lag vorher knapp darauf)
        drawTile(icon, center: CGPoint(x: canvas.midX, y: canvas.minY + side * 0.473),
                 size: (side * 0.33).rounded(), in: context)
        // Ganz klein wäre die Schrift nur ein grauer Strich
        if side >= 64 {
            drawLabel(in: context, centerX: canvas.midX, baseline: canvas.minY + side * 0.14, side: side)
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func drawLabel(in context: CGContext, centerX: CGFloat, baseline: CGFloat, side: CGFloat) {
        let font = NSFont.systemFont(ofSize: side * 0.111, weight: .regular)
        let text = NSAttributedString(string: label, attributes: [.font: font, .foregroundColor: labelColor])
        let line = CTLineCreateWithAttributedString(text)
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        context.saveGState()
        context.textPosition = CGPoint(x: centerX - width / 2, y: baseline)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    private static func drawTile(_ icon: PluginArchive.Icon?, center: CGPoint, size: CGFloat, in context: CGContext) {
        let k = size / 22
        let rect = CGRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size)
        let shape = CGPath(roundedRect: rect, cornerWidth: size * 0.26, cornerHeight: size * 0.26, transform: nil)
        let tint = icon?.color.flatMap(parse) ?? fallbackTint
        let top = tint.blended(withFraction: 0.18, of: .white) ?? tint

        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -0.7 * k), blur: 2.2 * k,
                          color: NSColor.black.withAlphaComponent(0.28).cgColor)
        context.addPath(shape)
        context.setFillColor(tint.cgColor)
        context.fillPath()
        context.restoreGState()

        context.saveGState()
        context.addPath(shape)
        context.clip()
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                     colors: [top.cgColor, tint.cgColor] as CFArray, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: CGPoint(x: rect.midX, y: rect.maxY),
                                       end: CGPoint(x: rect.midX, y: rect.minY), options: [])
        }
        context.restoreGState()

        let config = NSImage.SymbolConfiguration(pointSize: size * 0.5, weight: .semibold)
        let symbol = icon.flatMap { NSImage(systemSymbolName: $0.symbol, accessibilityDescription: nil) }
            ?? NSImage(systemSymbolName: fallbackSymbol, accessibilityDescription: nil)
        guard let glyph = symbol?.withSymbolConfiguration(config) else { return }
        let g = glyph.size
        let glyphRect = CGRect(x: center.x - g.width / 2, y: center.y - g.height / 2, width: g.width, height: g.height)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -0.5 * k), blur: 1.2 * k,
                          color: NSColor.black.withAlphaComponent(0.22).cgColor)
        // Einfarbig weiß wie .foregroundStyle(.white): Ausgesparte Teile (das Dreieck in
        // play.rectangle.fill) bleiben durchsichtig. paletteColors färbte sie mit weiß
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        glyph.draw(in: glyphRect)
        context.setBlendMode(.sourceIn)
        context.setFillColor(NSColor.white.cgColor)
        context.fill(glyphRect)
        context.endTransparencyLayer()
        context.restoreGState()
    }

    /// #RRGGBB wie PluginManifest.Icon.parse
    static func parse(_ hex: String) -> NSColor? {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = Int(s, radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                       green: CGFloat((value >> 8) & 0xFF) / 255,
                       blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
}
