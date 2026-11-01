import AppKit
import Combine
import SwiftUI

/// Hell oder dunkel für die eigenen Kacheln (Einstellungen → Aussehen → Symbole). Automatisch
/// folgt dem Erscheinungsbild von macOS, nicht dem der App: Das Fenster der Ablage ist immer
/// dunkel, die App-Symbole daneben aber hell oder dunkel je nach System.
final class IconAppearance: ObservableObject {
    static let shared = IconAppearance()
    @Published private(set) var isDark: Bool
    private var observers: [NSObjectProtocol] = []
    private var styleChange: AnyCancellable?

    private init() {
        isDark = Self.resolve(AppSettings.shared.iconStyle)
        styleChange = AppSettings.shared.$iconStyle.dropFirst().sink { [weak self] style in
            self?.update(Self.resolve(style))
        }
        // Wechsel des Erscheinungsbilds (auch der automatische am Abend)
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main) { [weak self] _ in
                self?.update(Self.resolve(AppSettings.shared.iconStyle))
            })
    }

    private func update(_ dark: Bool) {
        if dark != isDark { isDark = dark }
    }

    static func resolve(_ style: IconStyle) -> Bool {
        switch style {
        case .light: return false
        case .dark: return true
        case .automatic: return systemIsDark
        }
    }

    /// Erscheinungsbild von macOS, jedes Mal frisch aus den globalen Einstellungen
    static var systemIsDark: Bool {
        CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
        return (CFPreferencesCopyAppValue("AppleInterfaceStyle" as CFString, kCFPreferencesAnyApplication) as? String) == "Dark"
    }
}

private struct ColorfulIconsKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Plugin-Symbole bleiben hier farbig, unabhängig von Aussehen → Symbole (Einstellungen,
    /// Galerie, Dialoge). Teilen, AirDrop und die Cloud sehen dagegen überall so aus wie in
    /// der Ablage (Nutzer, 30.10.2026; vorher waren in den Einstellungen alle farbig)
    var colorfulIcons: Bool {
        get { self[ColorfulIconsKey.self] }
        set { self[ColorfulIconsKey.self] = newValue }
    }
}

/// Form der App-Symbole von macOS 26, nachgemessen an den Symbolen des Systems (Rechner,
/// Notizen bei 256 pt, 29.10.2026): Die Kachel nimmt 824 von 1024 Punkten ein (80,5 %), die
/// Ecken sind „continuous“ mit 26 % der Kachel. Vorher hatten Teilen, AirDrop und die Cloud
/// 22,5 % und wirkten eckiger als die Apps daneben (Nutzer).
enum AppIconShape {
    static let bodyFraction: CGFloat = 824.0 / 1024.0
    static let cornerFraction: CGFloat = 0.26

    static func shape(_ size: CGFloat) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: size * cornerFraction, style: .continuous)
    }
}

/// Grund einer Kachel: hell mit dem übergebenen Verlauf, dunkel 1:1 wie die App-Symbole im
/// dunklen Symbolstil von macOS (Nutzer, 29.10.2026). Nachgemessen am Rechner bei 512 pt
/// und Nachrichten (Kachel 410 pt): Grund neutral grau von 11,8 % oben bis 6,3 % unten; eine
/// Lichtkante oben (am Rand etwa 55 % über dem Grund, nach 3 % der Kante verklungen) und eine
/// schwächere unten; an den Seiten nur ein Hauch.
struct AppIconBackground: View {
    let size: CGFloat
    let dark: Bool
    let light: LinearGradient
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let shape = AppIconShape.shape(size)
        if dark {
            shape
                .fill(LinearGradient(colors: [Color(white: 0.122), Color(white: 0.056)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(rim(shape))
                .frame(width: size, height: size)
        } else {
            shape
                .fill(light)
                .overlay(shape.strokeBorder(Color.black.opacity(0.1), lineWidth: max(0.5, size / 60)))
                .frame(width: size, height: size)
        }
    }

    /// Lichtkante wie bei macOS: Sie folgt dem Rand und ist so hell, wie der Rand nach oben
    /// zeigt (Licht von oben), also auch in den oberen Ecken, dazu schwächer unten und in den
    /// unteren Ecken (Nutzer, 29.10.2026: „oben in den Ecken mehr Glanz“). Nachgemessen am
    /// Symbol von Nachrichten in Leistengröße (34 pt, 2x), je Winkel vom Mittelpunkt aus
    /// (`RimCompare` im Test-Gerüst). Kleine Symbole von macOS haben eine viel zartere Kante als
    /// große (34 pt: 49 neben 30 im Grund, 512 pt: 178): Stärke und Breite hängen darum von der
    /// Größe in Bildpunkten ab, nie unter zwei Bildpunkten Breite.
    private func rim(_ shape: RoundedRectangle) -> some View {
        let pixels = size * displayScale
        let large = max(0, min(1, (pixels - 60) / 240))
        let px = 1 / displayScale
        // Ein Schein knapp innerhalb des Rands; der äußerste Bildpunkt bleibt dunkler (bei 96 pt
        // gemessen: 23 am Rand, 55 zwei Punkte weiter innen)
        let wide = max(size * 0.028, 2.2 * px)
        // Nachgemessen neben Rechner und Nachrichten in der Aktionsleiste (40 pt, 2x, macOS 27,
        // 30.10.2026): oben und unten heller als vorher, seitlich keine dunkle Linie mehr. Mit
        // der alten Linie wirkten die Kacheln wie ausgeschnitten (Nutzer: „da fehlt der Rand“)
        let wideAlpha = 0.11 + 0.04 * large
        return ZStack {
            shape.strokeBorder(Self.light(wideAlpha), lineWidth: wide)
            // Außen nur ein Hauch dunkler, damit die Kachel auf hellem Grund nicht ausläuft
            shape.strokeBorder(Color.black.opacity(0.12 + 0.1 * large), lineWidth: max(size * 0.008, 0.7 * px))
        }
    }

    /// Helligkeit der Kante je Richtung, gemessen (Winkel wie in der Mathematik: 90° oben,
    /// 0° rechts, -90° unten); links wie rechts
    private static let edgeLight: [(angle: Double, light: Double)] = [
        (90, 1), (75, 0.95), (60, 0.9), (52, 0.6), (45, 0.4), (38, 0.25), (30, 0.06), (15, 0),
        (0, 0.1), (-30, 0.15), (-45, 0.4), (-60, 0.95), (-75, 0.75), (-90, 0.55)
    ]

    /// Weiß mit der Helligkeit je Richtung als Kreisverlauf um die Mitte der Kachel. SwiftUI zählt
    /// die Winkel im Uhrzeigersinn ab rechts, also unten 90°, oben 270°
    private static func light(_ alpha: Double) -> AngularGradient {
        var stops: [Gradient.Stop] = []
        for (angle, light) in edgeLight {
            let right = (-angle + 360).truncatingRemainder(dividingBy: 360)   // rechte Hälfte
            let left = (180 + angle + 360).truncatingRemainder(dividingBy: 360) // gespiegelt
            for location in Set([right, left]) {
                stops.append(.init(color: .white.opacity(alpha * light), location: location / 360))
            }
        }
        stops.sort { $0.location < $1.location }
        // Rundum geschlossen: 0 und 1 mit demselben Wert (rechts, 0°)
        let east = Color.white.opacity(alpha * 0.1)
        return AngularGradient(stops: [.init(color: east, location: 0)] + stops.filter { $0.location > 0 && $0.location < 1 }
                                   + [.init(color: east, location: 1)],
                               center: .center)
    }
}

extension View {
    /// Schatten unter einer Kachel wie unter App-Symbolen (weich, leicht nach unten)
    func appIconShadow(size: CGFloat) -> some View {
        shadow(color: .black.opacity(0.3), radius: size * 0.04, y: size * 0.02)
    }
}

/// Kachel mit einem SF-Symbol im Stil der App-Symbole: hell ein farbiger Verlauf mit weißem
/// Zeichen, dunkel der dunkle Grund mit dem Zeichen in der Farbe (so färbt macOS App-Symbole
/// im dunklen Stil um). `size` ist die Kante der Kachel selbst.
struct SymbolIconTile: View {
    let symbol: String
    let colors: [Color]
    let size: CGFloat
    var weight: Font.Weight = .bold
    var glyphScale: CGFloat = 0.49
    var glyphOffset: CGFloat = 0
    @ObservedObject private var appearance = IconAppearance.shared
    @Environment(\.colorfulIcons) private var colorful

    var body: some View {
        let dark = appearance.isDark && !colorful
        let shape = AppIconShape.shape(size)
        AppIconBackground(size: size, dark: dark,
                          light: LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom))
            .overlay {
                // Glanz an der Oberkante wie bei den hellen App-Symbolen
                if !dark {
                    shape.fill(LinearGradient(colors: [Color.white.opacity(0.22), Color.white.opacity(0)],
                                              startPoint: .top, endPoint: .center))
                }
            }
            .overlay(glyph(dark: dark))
            .appIconShadow(size: size)
    }

    @ViewBuilder
    private func glyph(dark: Bool) -> some View {
        let image = Image(systemName: symbol)
            .font(.system(size: size * glyphScale, weight: weight))
            .offset(y: size * glyphOffset)
        if dark {
            // Etwas heller als der Verlauf, damit das Zeichen auf Schwarz so kräftig wirkt wie
            // die farbigen Teile der App-Symbole im dunklen Stil
            image.foregroundStyle(LinearGradient(colors: colors.map { Self.lifted($0) }, startPoint: .top, endPoint: .bottom))
        } else {
            image.foregroundStyle(.white)
                .shadow(color: .black.opacity(0.18), radius: max(0.5, size / 30), y: max(0.3, size / 60))
        }
    }

    private static func lifted(_ color: Color) -> Color {
        let base = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
        return Color(nsColor: base.blended(withFraction: 0.12, of: .white) ?? base)
    }
}

/// AirDrop im dunklen Stil, 1:1 nach der Vorlage des Nutzers (29.10.2026, Bild 250 pt
/// nachgemessen; Farben auf Wunsch weniger türkis, im Blau des Teilen-Zeichens): außen eine
/// tiefblaue Scheibe (Radius 40 % der Kachel), darüber eine hellere
/// (24,5 %), oben je mit heller Kante; in der Mitte der leuchtende Punkt (9,4 %). Ein Keil von
/// der Punktmitte nach unten (je Seite 31°) schneidet die beiden Scheiben aus, der Punkt liegt
/// darüber. Gezeichnet statt aus dem Systemsymbol ausgeschnitten: Dort waren die Ringe nur
/// schwach zu erkennen.
struct AirDropDarkGlyph: View {
    /// Kante der Kachel
    let size: CGFloat

    private static func rgb(_ r: Double, _ g: Double, _ b: Double) -> Color {
        Color(red: r / 255, green: g / 255, blue: b / 255)
    }

    var body: some View {
        let center = CGPoint(x: size / 2, y: size * 0.5)
        let dot = size * 0.094
        ZStack {
            ZStack {
                disc(size * 0.40, top: Self.rgb(14, 66, 132), bottom: Self.rgb(6, 48, 104), edge: Self.rgb(42, 92, 160), center: center)
                disc(size * 0.245, top: Self.rgb(8, 104, 214), bottom: Self.rgb(2, 86, 184), edge: Self.rgb(76, 150, 240), center: center)
            }
            .mask(Self.cutout(size: size, apex: center).fill(style: FillStyle(eoFill: true)))
            // Punkt: oben hell, unten tiefer, mit leichtem Schatten auf der Scheibe darunter
            Circle()
                .fill(LinearGradient(colors: [Self.rgb(70, 172, 255), Self.rgb(10, 118, 250)], startPoint: .top, endPoint: .bottom))
                .overlay(Circle().strokeBorder(LinearGradient(colors: [Self.rgb(140, 205, 255), .clear],
                                                              startPoint: .top, endPoint: .center),
                                               lineWidth: max(0.5, size / 80)))
                .frame(width: dot * 2, height: dot * 2)
                .shadow(color: .black.opacity(0.35), radius: size * 0.015)
                .position(center)
        }
        .frame(width: size, height: size)
    }

    private func disc(_ radius: CGFloat, top: Color, bottom: Color, edge: Color, center: CGPoint) -> some View {
        Circle()
            .fill(LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom))
            .overlay(Circle().strokeBorder(LinearGradient(colors: [edge, edge.opacity(0.5)], startPoint: .top, endPoint: .bottom),
                                           lineWidth: max(0.5, size / 90)))
            .frame(width: radius * 2, height: radius * 2)
            .position(center)
    }

    /// Ganze Fläche minus Keil nach unten (Spitze in der Punktmitte, je Seite 31°)
    static func cutout(size: CGFloat, apex: CGPoint) -> Path {
        var path = Path(CGRect(x: 0, y: 0, width: size, height: size))
        let spread = (size - apex.y) * 0.6
        path.move(to: apex)
        path.addLine(to: CGPoint(x: apex.x - spread, y: size))
        path.addLine(to: CGPoint(x: apex.x + spread, y: size))
        path.closeSubpath()
        return path
    }
}
