import AppKit
import SwiftUI

/// Die Logos der Dienste auf einer Kachel, wie ihre App-Symbole auf dem Mac (Dropbox,
/// Google Drive und OneDrive zeigen ihr farbiges Logo auf Weiß, im dunklen Symbolstil auf
/// Dunkelgrau). Als Vektoren aus den
/// veröffentlichten SVG-Formen gezeichnet, damit sie in jeder Größe scharf sind
/// (Nutzer, 27.10.2026: echte Logos statt Symbolen).
struct CloudLogoTile: View {
    let service: CloudService
    var size: CGFloat = 26
    @ObservedObject private var iconStyle = IconAppearance.shared

    var body: some View {
        // Hell: das Logo auf Weiß; dunkel: auf dem dunklen Grund der App-Symbole von macOS
        // (Einstellungen → Aussehen → Symbole, Nutzer, 29.10.2026), überall wie in der Ablage
        AppIconBackground(size: size, dark: iconStyle.isDark,
                          light: LinearGradient(colors: [Color(white: 1), Color(white: 0.93)], startPoint: .top, endPoint: .bottom))
            .overlay(CloudLogo(service: service).padding(size * 0.17))
            .frame(width: size, height: size)
            .appIconShadow(size: size)
    }

    /// Als Bild für Menüs (nur auf dem Hauptthread)
    static func image(_ service: CloudService, size: CGFloat = 16) -> NSImage? {
        MainActor.assumeIsolated {
            let renderer = ImageRenderer(content: CloudLogoTile(service: service, size: size - 2).frame(width: size, height: size))
            renderer.scale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
            return renderer.nsImage
        }
    }
}

/// Nur das Logo, eingepasst in den verfügbaren Platz
struct CloudLogo: View {
    let service: CloudService

    var body: some View {
        switch service {
        case .icloud:
            // Die Wolke von iCloud mit ihrem Blauverlauf
            Image(systemName: "icloud.fill")
                .resizable()
                .scaledToFit()
                .foregroundStyle(LinearGradient(colors: [Color(red: 0.36, green: 0.78, blue: 0.98),
                                                         Color(red: 0.0, green: 0.48, blue: 1.0)],
                                                startPoint: .top, endPoint: .bottom))
        case .dropbox:
            SVGShapes(viewBox: CGSize(width: 235, height: 200), layers: [(Self.dropbox, Color(red: 0, green: 0.38, blue: 1))])
        case .googleDrive:
            SVGShapes(viewBox: CGSize(width: 87.3, height: 78), layers: Self.drive)
        case .oneDrive:
            SVGShapes(viewBox: CGSize(width: 100, height: 64), layers: Self.oneDrive)
        }
    }

    /// Fünf Rauten der offenen Box
    private static let dropbox = "M58.86 0L0 37.5l58.86 37.5 58.87-37.5zM176.14 0L117.27 37.5l58.87 37.5L235 37.5zM0 112.5L58.86 150l58.87-37.5-58.87-37.5zM176.14 75l-58.87 37.5 58.87 37.5L235 112.5zM58.86 162.5l58.87 37.5 58.86-37.5-58.86-37.5z"

    /// Das Dreieck aus sechs Flächen in den vier Farben von Google
    private static let drive: [(String, Color)] = [
        ("m6.6 66.85 3.85 6.65c.8 1.4 1.95 2.5 3.3 3.3l13.75-23.8h-27.5c0 1.55.4 3.1 1.2 4.5z", hex(0x0066DA)),
        ("m43.65 25-13.75-23.8c-1.35.8-2.5 1.9-3.3 3.3l-25.4 44a9.06 9.06 0 0 0 -1.2 4.5h27.5z", hex(0x00AC47)),
        ("m73.55 76.8c1.35-.8 2.5-1.9 3.3-3.3l1.6-2.75 7.65-13.25c.8-1.4 1.2-2.95 1.2-4.5h-27.502l5.852 11.5z", hex(0xEA4335)),
        ("m43.65 25 13.75-23.8c-1.35-.8-2.9-1.2-4.5-1.2h-18.5c-1.6 0-3.15.45-4.5 1.2z", hex(0x00832D)),
        ("m59.8 53h-32.3l-13.75 23.8c1.35.8 2.9 1.2 4.5 1.2h50.8c1.6 0 3.15-.45 4.5-1.2z", hex(0x2684FC)),
        ("m73.4 26.5-12.7-22c-.8-1.4-1.95-2.5-3.3-3.3l-13.75 23.8 16.15 28h27.45c0-1.55-.4-3.1-1.2-4.5z", hex(0xFFBA00))
    ]

    /// Die Wolke von OneDrive aus vier Blautönen wie im Logo: hinten links dunkel, hinten
    /// rechts mittel, vorn unten links und rechts heller
    private static let oneDrive: [(String, Color)] = [
        (circle(32, 32, 17), hex(0x0364B8)),
        (circle(57, 27, 23), hex(0x0078D4)),
        (capsule(8, 34, 72, 60), hex(0x1490DF)),
        (capsule(44, 36, 92, 60), hex(0x28A8EA))
    ]

    private static func circle(_ x: Double, _ y: Double, _ r: Double) -> String {
        "M\(x - r) \(y) a\(r) \(r) 0 1 0 \(2 * r) 0 a\(r) \(r) 0 1 0 \(-2 * r) 0z"
    }

    private static func capsule(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> String {
        let r = (y1 - y0) / 2
        return "M\(x0 + r) \(y0) H\(x1 - r) A\(r) \(r) 0 0 1 \(x1 - r) \(y1) H\(x0 + r) A\(r) \(r) 0 0 1 \(x0 + r) \(y0) Z"
    }

    private static func hex(_ value: Int) -> Color {
        Color(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
              blue: Double(value & 0xFF) / 255)
    }
}

/// Mehrere SVG-Pfade in ihren Farben, gemeinsam auf den Platz eingepasst
private struct SVGShapes: View {
    let viewBox: CGSize
    let layers: [(String, Color)]

    var body: some View {
        GeometryReader { geometry in
            let scale = min(geometry.size.width / viewBox.width, geometry.size.height / viewBox.height)
            let offset = CGPoint(x: (geometry.size.width - viewBox.width * scale) / 2,
                                 y: (geometry.size.height - viewBox.height * scale) / 2)
            ZStack {
                ForEach(Array(layers.enumerated()), id: \.offset) { _, layer in
                    Path(SVGPath.parse(layer.0))
                        .applying(CGAffineTransform(translationX: offset.x, y: offset.y).scaledBy(x: scale, y: scale))
                        .fill(layer.1)
                }
            }
        }
    }
}

/// Kleiner Leser für SVG-Pfade (M L H V C S Q T A Z, groß und klein). Reicht für die Logos
/// oben; Bögen werden als echte Ellipsenbögen gezeichnet.
enum SVGPath {
    static func parse(_ text: String) -> CGPath {
        let path = CGMutablePath()
        var tokens = tokenize(text)[...]
        var command: Character = "M"
        var current = CGPoint.zero
        var start = CGPoint.zero
        var lastControl: CGPoint?

        func number() -> CGFloat {
            if case .number(let value)? = tokens.first { tokens.removeFirst(); return value }
            return 0
        }
        func flag() -> Bool { number() != 0 }

        while !tokens.isEmpty {
            if case .command(let c) = tokens.first! {
                command = c
                tokens.removeFirst()
            }
            let relative = command.isLowercase
            let base = relative ? current : .zero
            switch command.uppercased().first! {
            case "M":
                current = CGPoint(x: base.x + number(), y: base.y + number())
                path.move(to: current)
                start = current
                // Weitere Zahlenpaare nach M gelten als L
                command = relative ? "l" : "L"
                lastControl = nil
            case "L":
                current = CGPoint(x: base.x + number(), y: base.y + number())
                path.addLine(to: current)
                lastControl = nil
            case "H":
                current.x = (relative ? current.x : 0) + number()
                path.addLine(to: current)
                lastControl = nil
            case "V":
                current.y = (relative ? current.y : 0) + number()
                path.addLine(to: current)
                lastControl = nil
            case "C":
                let c1 = CGPoint(x: base.x + number(), y: base.y + number())
                let c2 = CGPoint(x: base.x + number(), y: base.y + number())
                current = CGPoint(x: base.x + number(), y: base.y + number())
                path.addCurve(to: current, control1: c1, control2: c2)
                lastControl = c2
            case "S":
                let c1 = lastControl.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                let c2 = CGPoint(x: base.x + number(), y: base.y + number())
                current = CGPoint(x: base.x + number(), y: base.y + number())
                path.addCurve(to: current, control1: c1, control2: c2)
                lastControl = c2
            case "Q":
                let c = CGPoint(x: base.x + number(), y: base.y + number())
                current = CGPoint(x: base.x + number(), y: base.y + number())
                path.addQuadCurve(to: current, control: c)
                lastControl = c
            case "T":
                let c = lastControl.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                current = CGPoint(x: base.x + number(), y: base.y + number())
                path.addQuadCurve(to: current, control: c)
                lastControl = c
            case "A":
                let rx = number(), ry = number(), rotation = number()
                let large = flag(), sweep = flag()
                let end = CGPoint(x: base.x + number(), y: base.y + number())
                addArc(path, from: current, to: end, rx: rx, ry: ry, angle: rotation, large: large, sweep: sweep)
                current = end
                lastControl = nil
            case "Z":
                path.closeSubpath()
                current = start
                lastControl = nil
            default:
                tokens.removeFirst()
            }
        }
        return path
    }

    private enum Token { case command(Character), number(CGFloat) }

    private static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var buffer = ""
        func flush() {
            if let value = Double(buffer) { tokens.append(.number(CGFloat(value))) }
            buffer = ""
        }
        for char in text {
            if char.isLetter && char != "e" {
                flush()
                tokens.append(.command(char))
            } else if char == "-" && !buffer.isEmpty && buffer.last != "e" {
                flush()
                buffer = "-"
            } else if char == "." && buffer.contains(".") {
                // „.5.4“ sind zwei Zahlen
                flush()
                buffer = "."
            } else if char == "," || char.isWhitespace {
                flush()
            } else {
                buffer.append(char)
            }
        }
        flush()
        return tokens
    }

    /// Ellipsenbogen nach SVG (Endpunkt-Form) als Bézierkurven
    private static func addArc(_ path: CGMutablePath, from p1: CGPoint, to p2: CGPoint,
                               rx: CGFloat, ry: CGFloat, angle: CGFloat, large: Bool, sweep: Bool) {
        var rx = abs(rx), ry = abs(ry)
        guard rx > 0, ry > 0, p1 != p2 else { return path.addLine(to: p2) }
        let phi = angle * .pi / 180
        let cosPhi = cos(phi), sinPhi = sin(phi)
        let dx = (p1.x - p2.x) / 2, dy = (p1.y - p2.y) / 2
        let x1 = cosPhi * dx + sinPhi * dy, y1 = -sinPhi * dx + cosPhi * dy
        let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if lambda > 1 { rx *= sqrt(lambda); ry *= sqrt(lambda) }
        let num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let den = rx * rx * y1 * y1 + ry * ry * x1 * x1
        var coef = sqrt(max(0, num / den))
        if large == sweep { coef = -coef }
        let cx1 = coef * rx * y1 / ry, cy1 = -coef * ry * x1 / rx
        let cx = cosPhi * cx1 - sinPhi * cy1 + (p1.x + p2.x) / 2
        let cy = sinPhi * cx1 + cosPhi * cy1 + (p1.y + p2.y) / 2
        func angleOf(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let sign: CGFloat = ux * vy - uy * vx < 0 ? -1 : 1
            let dot = (ux * vx + uy * vy) / (sqrt(ux * ux + uy * uy) * sqrt(vx * vx + vy * vy))
            return sign * acos(min(1, max(-1, dot)))
        }
        let theta1 = angleOf(1, 0, (x1 - cx1) / rx, (y1 - cy1) / ry)
        var delta = angleOf((x1 - cx1) / rx, (y1 - cy1) / ry, (-x1 - cx1) / rx, (-y1 - cy1) / ry)
        if !sweep && delta > 0 { delta -= 2 * .pi }
        if sweep && delta < 0 { delta += 2 * .pi }
        // In Stücke bis 90°, je eine Bézierkurve
        let segments = Int(ceil(abs(delta) / (.pi / 2)))
        let step = delta / CGFloat(segments)
        let t = 4 / 3 * tan(step / 4)
        var theta = theta1
        for _ in 0..<segments {
            let cos1 = cos(theta), sin1 = sin(theta), cos2 = cos(theta + step), sin2 = sin(theta + step)
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: cx + rx * x * cosPhi - ry * y * sinPhi, y: cy + rx * x * sinPhi + ry * y * cosPhi)
            }
            path.addCurve(to: point(cos2, sin2),
                          control1: point(cos1 - t * sin1, sin1 + t * cos1),
                          control2: point(cos2 + t * sin2, sin2 - t * cos2))
            theta += step
        }
    }
}
