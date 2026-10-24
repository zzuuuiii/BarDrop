import SwiftUI
import AppKit

// MARK: Einstellungen im Stil von Klack
//
// Eigene Bausteine statt des Systemformulars, damit das Fenster auf jeder
// macOS-Version gleich aussieht: graue Fläche, darauf Karten mit Zeilen und
// feinen Trennlinien, kurze Überschriften, längliche Schalter, schlichte
// Auswahlmenüs mit ⌃⌄. Maße und Farben sind von Klack abgenommen.

enum SettingsTheme {
    // Dunkel: Farben von Klack abgenommen. Hell: Systemfarben von macOS, damit Kontraste,
    // Flächen und Linien wie in Apples eigenen Fenstern wirken. Seitenleiste und Inhalt
    // liegen leicht durchscheinend über dem Schreibtisch, Karten und Auswahllisten ebenfalls,
    // aber deutlich weniger (siehe `cardOpacity`).
    /// Deckkraft von Seitenleiste und Inhalt über dem Schreibtisch (dunkel): etwas
    /// durchscheinender als früher (70 %), aber Text und Karten bleiben auf jedem Hintergrund ruhig
    /// (Nutzerwunsch 24.10.2026: Hintergrund und Karten etwas durchscheinender, 64 → 58 %)
    static let backdropOpacity = 0.58
    /// Seitenleiste und Inhalt über dem Schreibtisch (Farben von Klack). Dunkel wie bisher zu 64 % deckend;
    /// hell wie bei Apple: Seitenleiste leicht durchscheinend, Inhalt fast deckend, damit
    /// ein dunkler Schreibtisch die helle Fläche nicht grau eintrübt
    /// Hell erst beim Zeichnen auflösen: `withAlphaComponent` auf einer Systemfarbe legt sie
    /// sonst auf das Aussehen beim Start fest, und im hellen Modus blieb der Hintergrund dunkel.
    static let sidebarBackdrop = dynamic(dark: rgb(0.161, 0.165, 0.169, backdropOpacity),
                                         light: systemColor(.windowBackgroundColor, alpha: 0.8))
    static let contentBackdrop = dynamic(dark: rgb(0.192, 0.196, 0.2, backdropOpacity),
                                         light: systemColor(.windowBackgroundColor, alpha: 0.9))
    /// Deckkraft der Karten. Sie liegen auf dem Inhalt, der selbst zu 64 % deckt: Bei 50 %
    /// scheint durch eine Karte etwa 18 % des Schreibtischs, daneben 36 %. Sichtbar
    /// durchscheinend, aber deutlich weniger als der Hintergrund. (Mit 88 % waren es nur 4 %,
    /// davon war nichts zu sehen.)
    /// Seit 24.10.2026 40 %: Der Schreibtisch scheint durch die Karten sichtbar durch
    static let cardOpacity = 0.40
    /// Auswahllisten liegen direkt über dem (unscharfen) Schreibtisch: etwas mehr Durchsicht
    /// als die Karten, aber weniger als der Hintergrund
    static let menuOpacity = 0.72
    /// Karten. Dunkel heller als der Inhalt darunter, wie bei Klack (dort im Bildschirmfoto
    /// Inhalt 85, Karte 94 von 255). Vorher war die Karte dunkler als der Inhalt; die
    /// Durchsicht (`cardOpacity`) bleibt gleich, nur die Farbe ist heller
    /// Hell ebenso wie bei Klack (Inhalt 230, Karte 244): leicht grau statt reinweiß, gleiche Durchsicht
    /// Dunkel seit 24.10.2026 ein weißer Hauch statt eines festen Graus: Über einem hellen
    /// Schreibtisch wurde der Hintergrund so hell wie die Karte, Flächen und Ränder waren nicht
    /// mehr zu sehen (Nutzer). Weiß darüber ist auf jedem Hintergrund heller als die Umgebung
    static let card = dynamic(dark: NSColor.white.withAlphaComponent(0.075),
                              light: rgb(0.97, 0.97, 0.97, 0.78))
    /// Fläche der Auswahllisten
    static let menu = dynamic(dark: rgb(0.184, 0.188, 0.188, menuOpacity),
                              light: systemColor(.controlBackgroundColor, alpha: 0.9))
    /// Deckend, für Flächen über anderen Inhalten (angehobene Zeile beim Umsortieren)
    static let cardSolid = dynamic(dark: rgb(0.227, 0.231, 0.231), light: rgb(0.96, 0.96, 0.96))
    /// Gewählter Eintrag der Seitenleiste
    static let selectedRow = dynamic(dark: rgb(0.212, 0.212, 0.216), light: .unemphasizedSelectedContentBackgroundColor)
    /// Rand der Karten
    static let cardBorder = dynamic(dark: NSColor.white.withAlphaComponent(0.11), light: .separatorColor)
    /// Trennlinien zwischen Zeilen, Leiste der Regler
    static let separator = dynamic(dark: NSColor.white.withAlphaComponent(0.09), light: .separatorColor)
    /// Senkrechte Linie zwischen Seitenleiste und Inhalt
    static let divider = dynamic(dark: rgb(0.247, 0.251, 0.255), light: .separatorColor)
    /// Ausgeschalteter Schalter, Mulde der Regler
    static let switchOff = dynamic(dark: rgb(0.255, 0.259, 0.259), light: .quaternaryLabelColor)
    /// Rasterpunkte unter den Reglern
    static let tick = dynamic(dark: rgb(0.388, 0.388, 0.392), light: .tertiaryLabelColor)

    // Bedienelemente (dunkel unverändert, hell mit Systemfarben)
    /// Knopf der Schalter und Regler: hell weiß wie bei macOS
    static let knob = dynamic(dark: rgb(0.9, 0.9, 0.9), light: .white)
    static let knobOn = dynamic(dark: rgb(0.86, 0.91, 0.99), light: .white)
    static let sliderKnob = dynamic(dark: rgb(0.92, 0.92, 0.92), light: .white)
    /// Mulde der Umschalter
    static let segmentTrough = dynamic(dark: NSColor.black.withAlphaComponent(0.18), light: .quaternaryLabelColor)
    /// Gewählte Kapsel der Umschalter ab macOS 26: dunkel in der Farbe des Inhalts rechts
    /// (Nutzerwunsch 24.10.2026, vorher wirkte sie zu dunkel), hell weiß
    /// Dunkel deutlich heller als die Mulde (`segmentWell`), sonst war die Wahl nicht zu erkennen
    static let segmentChosen = dynamic(dark: NSColor.white.withAlphaComponent(0.24), light: .white)
    /// Mulde der Umschalter ab macOS 26: dunkel eingelassen, hell grau wie bei Apple
    static let segmentWell = dynamic(dark: NSColor.black.withAlphaComponent(0.16), light: NSColor.black.withAlphaComponent(0.06))
    /// Gewählte Möglichkeit eines Umschalters: hell weiß wie bei macOS
    static let segmentKnob = dynamic(dark: rgb(0.255, 0.259, 0.259), light: .controlColor)
    /// Graue Knöpfe hell: weiß mit feinem Rand wie macOS-Knöpfe (dunkel siehe KlackButtonStyle)
    static let buttonLight = Color(nsColor: .controlColor)
    static let buttonLightHover = Color(nsColor: rgb(0.96, 0.96, 0.96))
    static let buttonLightPressed = Color(nsColor: rgb(0.9, 0.9, 0.9))
    /// Rand der Knöpfe: nur hell (dunkel ohne Rand wie bisher)
    static let buttonBorder = dynamic(dark: .clear, light: .separatorColor)
    /// Tasten (Kurzbefehl, Tastenkürzel): dunkel eingelassen, hell als weiße Taste
    static let keyActive = dynamic(dark: NSColor.black.withAlphaComponent(0.42), light: .controlColor)
    static let keyInactive = dynamic(dark: NSColor.black.withAlphaComponent(0.24), light: .quaternaryLabelColor)
    static let keyHover = dynamic(dark: NSColor.black.withAlphaComponent(0.2),
                                  light: NSColor.black.withAlphaComponent(0.06))
    static let keyBorder = dynamic(dark: NSColor.white.withAlphaComponent(0.06), light: .separatorColor)
    static let keyBorderInactive = dynamic(dark: NSColor.white.withAlphaComponent(0.04), light: .clear)
    static let shortcutKey = dynamic(dark: NSColor.black.withAlphaComponent(0.22), light: NSColor.black.withAlphaComponent(0.05))
    /// Schatten der Knöpfe: nur hell, wie bei macOS
    static let controlShadow = dynamic(dark: .clear, light: NSColor.black.withAlphaComponent(0.12))

    static let rowHeight: CGFloat = 45
    static let cardRadius: CGFloat = 11
    static let rowPadding: CGFloat = 12

    private static func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> NSColor {
        NSColor(srgbRed: r, green: g, blue: b, alpha: a)
    }

    /// Systemfarbe mit eigener Deckkraft, im hellen Aussehen aufgelöst
    private static func systemColor(_ color: NSColor, alpha: CGFloat) -> NSColor {
        var resolved = color
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.sRGB) ?? color
        }
        return resolved.withAlphaComponent(alpha)
    }

    private static func dynamic(dark: NSColor, light: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

/// Eine Seite der Einstellungen: senkrecht scrollend, Abschnitte untereinander.
/// `footer` steht immer ganz unten auf der Seite (Knöpfe wie „Importieren“), auch wenn der
/// Inhalt kürzer ist als das Fenster; bei langem Inhalt darunter.
struct SettingsPage<Content: View, Footer: View>: View {
    let content: Content
    let footer: Footer
    /// Unterseiten (Plugins): Wechselt der Wert, kommt neuer Inhalt und die Seite springt nach
    /// oben. Die Bildlaufansicht selbst bleibt dieselbe: Eine neue (vorher `.id` an der ganzen
    /// Seite) verlor ab macOS 26 die Leiste der Titelzeile unter der Überschrift (Nutzer)
    var page: AnyHashable?
    init(page: AnyHashable? = nil, @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
        self.page = page
        self.content = content()
        self.footer = footer()
    }

    /// Sichtbare Höhe der Seite (ohne die Leiste mit der Überschrift darüber)
    @State private var visibleHeight: CGFloat = 0

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                content
                if Footer.self != EmptyView.self {
                    Spacer(minLength: 0)
                    footer
                }
            }
            .id(page)
            .padding(.leading, 20)
            .padding(.trailing, 18)
            .padding(.top, 4)
            .padding(.bottom, Footer.self == EmptyView.self ? 24 : 16)
            .frame(maxWidth: .infinity, minHeight: visibleHeight, alignment: .topLeading)
        }
        .onChange(of: page) { _, new in proxy.scrollTo(new, anchor: .top) }
        }
        // Nicht mit GeometryReader umschließen: Das trennte die Seite von der Leiste darüber
        .onGeometryChange(for: CGFloat.self) { $0.size.height - $0.safeAreaInsets.top - $0.safeAreaInsets.bottom } action: {
            visibleHeight = max(0, $0)
        }
        .scrollIndicators(.automatic)
        // Bis macOS 15 scrollt nichts unter die Überschrift der Seite, ab macOS 26 läuft der
        // Inhalt wie in Apples Apps unter sie (SettingsRoot.detail)
        .modifier(HardTopEdge())
    }
}

extension SettingsPage where Footer == EmptyView {
    init(page: AnyHashable? = nil, @ViewBuilder content: () -> Content) {
        self.init(page: page, content: content, footer: { EmptyView() })
    }
}

/// Ab macOS 26 liegt die Überschrift der Seite als Leiste über dem Inhalt (`safeAreaBar` in
/// SettingsRoot.detail), der Inhalt läuft beim Scrollen unter ihr durch. Den Übergang dort legt
/// die Titelleiste des Fensters selbst darunter (Glas wie in den Systemeinstellungen). Ein
/// zusätzlicher Übergang von SwiftUI lag schon in Ruhe über dem oberen Rand der ersten Karte
/// und machte die Leiste breiter, darum ist er aus. Bis macOS 15 wird wie bisher zugeschnitten.
private struct HardTopEdge: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            // Nicht zuschneiden: Der Rahmen der Bildlaufansicht endet unter der Überschrift, mit
            // `.clipped()` lief nichts darunter, und dort stand ein Streifen
            content.scrollEdgeEffectHidden(true, for: .top)
        } else {
            content.clipped()
        }
    }
}

/// Abschnitt: Überschrift (optional mit Info und Knöpfen), Karte, darunter ein Hinweis.
struct SettingsSection<Content: View, Trailing: View>: View {
    let title: String?
    var info: String?
    var note: String?
    var noteColor: Color = .secondary
    let trailing: () -> Trailing
    let content: Content

    init(_ title: String? = nil, info: String? = nil, note: String? = nil, noteColor: Color = .secondary,
         @ViewBuilder trailing: @escaping () -> Trailing,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.info = info
        self.note = note
        self.noteColor = noteColor
        self.trailing = trailing
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if title != nil || info != nil {
                SettingsHeader(title ?? "", info: info, trailing: trailing)
                    .padding(.horizontal, 8)
            }
            SettingsCard { content }
            if let note, !note.isEmpty {
                SectionNote(note, color: noteColor)
                    .padding(.horizontal, 8)
            }
        }
    }
}

extension SettingsSection where Trailing == EmptyView {
    init(_ title: String? = nil, info: String? = nil, note: String? = nil, noteColor: Color = .secondary,
         @ViewBuilder content: () -> Content) {
        self.init(title, info: info, note: note, noteColor: noteColor,
                  trailing: { EmptyView() }, content: content)
    }
}

/// Karte mit feinen Linien zwischen den Zeilen.
struct SettingsCard<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        _VariadicView.Tree(DividedRows()) { content }
            .background(
                RoundedRectangle(cornerRadius: SettingsTheme.cardRadius, style: .continuous)
                    .fill(SettingsTheme.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: SettingsTheme.cardRadius, style: .continuous)
                    .strokeBorder(SettingsTheme.cardBorder, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: SettingsTheme.cardRadius, style: .continuous))
    }
}

/// Setzt zwischen die Zeilen einer Karte je eine feine Linie.
private struct DividedRows: _VariadicView_MultiViewRoot {
    func body(children: _VariadicView.Children) -> some View {
        let last = children.last?.id
        VStack(spacing: 0) {
            ForEach(children) { child in
                child
                if child.id != last {
                    Rectangle()
                        .fill(SettingsTheme.separator)
                        .frame(height: 1)
                }
            }
        }
    }
}

/// Zeile: Bezeichnung links (optional mit Info), Bedienelement rechts.
struct SettingsRow<Control: View>: View {
    let title: String
    var subtitle: String?
    var info: String?
    let control: Control

    init(_ title: String, subtitle: String? = nil, info: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.subtitle = subtitle
        self.info = info
        self.control = control()
    }

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 13.5))
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                if let info { InfoButton(info) }
            }
            Spacer(minLength: 8)
            control
        }
        .padding(.horizontal, SettingsTheme.rowPadding)
        .frame(minHeight: SettingsTheme.rowHeight)
    }
}

/// Zeile mit Schalter.
struct ToggleRow: View {
    let title: String
    var info: String?
    @Binding var isOn: Bool

    init(_ title: String, info: String? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.info = info
        self._isOn = isOn
    }

    var body: some View {
        SettingsRow(title, info: info) {
            KlackSwitch(isOn: $isOn)
        }
        .contentShape(Rectangle())
    }
}

/// Länglicher Schalter wie bei Klack: 48 × 24, Knopf als Kapsel.
struct KlackSwitch: View {
    @Binding var isOn: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        if #available(macOS 26.0, *) {
            // Ab macOS 26 der Schalter des Systems: Beim Umschalten und Ziehen wird sein Knopf
            // zu Liquid Glass, genau wie in den Systemeinstellungen
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
        } else {
            klack
        }
    }

    private var klack: some View {
        Button {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) { isOn.toggle() }
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? Color(nsColor: .controlAccentColor) : SettingsTheme.switchOff)
                Capsule()
                    .fill(isOn ? SettingsTheme.knobOn : SettingsTheme.knob)
                    .frame(width: 27, height: 18)
                    .shadow(color: .black.opacity(0.18), radius: 1, y: 0.5)
                    .padding(.horizontal, 3)
            }
            .frame(width: 48, height: 24)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.45)
        .accessibilityElement()
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(isOn ? L("On", "Ein") : L("Off", "Aus"))
    }
}

/// Zeile mit Auswahl: aktueller Wert und ⌃⌄, ein Klick öffnet das Menü.
struct PickerRow<Value: Hashable>: View {
    let title: String
    var info: String?
    @Binding var selection: Value
    let options: [(Value, String)]
    /// Immer als Menü, auch bei zwei Möglichkeiten (lange Namen, die als Umschalter die
    /// Beschriftung der Zeile zusammendrücken würden)
    var menu = false

    init(_ title: String, info: String? = nil, selection: Binding<Value>, options: [(Value, String)],
         menu: Bool = false) {
        self.title = title
        self.info = info
        self._selection = selection
        self.options = options
        self.menu = menu
    }

    /// Eine Regel für alle Seiten (Nutzerwunsch 24.10.2026): bis zu drei kurze Möglichkeiten
    /// stehen als Umschalter in der Zeile, sonst ein Menü. Kurz heißt: jede höchstens
    /// `shortLength` Zeichen. Die Grenze ist so gewählt, dass keine Zeile nur in einer Sprache
    /// kippt (vorher war z. B. „Reihenfolge“ nur auf Deutsch ein Menü).
    static var shortLength: Int { 12 }

    private var inline: Bool {
        if menu { return false }
        return (2...3).contains(options.count) && options.allSatisfy { $0.1.count <= Self.shortLength }
    }

    var body: some View {
        SettingsRow(title, info: info) {
            if inline {
                SegmentedValue(selection: $selection, options: options)
            } else {
                PopupValue(selection: $selection, options: options)
            }
        }
    }
}

/// Umschalter mit wenigen Möglichkeiten: dunkle Mulde wie bei den Tasten, die gewählte
/// Möglichkeit als heller Knopf, der weich hinübergleitet.
///
/// Der Knopf ist eine einzige Fläche, die zur gewählten Möglichkeit gleitet. Früher sprang
/// er mit `matchedGeometryEffect` von einer Möglichkeit zur anderen; änderte sich dabei viel
/// zugleich (Einführung: Rand wechselt, Vorführung und Ablage ziehen um), blieb er teils
/// stehen, bis der nächste Klick die Ansicht neu zeichnete. Jede Möglichkeit ist so breit
/// wie in fetter Schrift, damit nichts verrutscht, wenn sich die Wahl ändert.
struct SegmentedValue<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(Value, String)]
    @Environment(\.isEnabled) private var isEnabled
    @State private var frames: [Int: CGRect] = [:]
    /// Gerade angeklickt: Der Knopf zeigt die Wahl sofort, auch wenn das Übernehmen erst
    /// einen Moment später ankommt
    @State private var chosen: Value?
    /// Lage der Linse beim Drücken und Ziehen (ab macOS 26)
    @State private var lensX: CGFloat?
    /// Losgelassen: Die Linse legt sich auf die gewählte Möglichkeit, bevor sie zur Kapsel wird
    @State private var settling = false

    private var shown: Value { chosen ?? selection }
    private var selectedIndex: Int? { options.firstIndex { $0.0 == shown } }
    private static var space: String { "segmented" }

    var body: some View {
        if #available(macOS 26.0, *) {
            glass
        } else {
            klack
        }
    }

    /// Wie der Umschalter der Uhr ab macOS 26: Die Wahl ist eine graue Kapsel. Beim Drücken
    /// wird sie zu einer Linse aus Liquid Glass, die man über die Möglichkeiten ziehen kann;
    /// beim Loslassen rastet sie auf der nächsten ein. Apples NSSegmentedControl macht das nur
    /// in der Symbolleiste, im Fenster bleibt es starr; darum hier nachgebaut mit `glassEffect`.
    @available(macOS 26.0, *)
    private var glass: some View {
        let space = Self.space
        return HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                let selected = index == (lensIndex ?? selectedIndex)
                ZStack {
                    // Platz für die fette Schrift, damit die Breite gleich bleibt
                    Text(option.1).font(.system(size: 12.5, weight: .semibold)).hidden()
                    Text(option.1)
                        .font(.system(size: 12.5, weight: selected ? .semibold : .regular))
                        .foregroundStyle(Color.primary)
                }
                .lineLimit(1)
                .fixedSize()
                // Unter der Linse wie durch eine Lupe etwas größer, wie in der Uhr
                .scaleEffect(lensX != nil && !settling && index == lensIndex ? 1.08 : 1)
                .animation(.spring(response: 0.25, dampingFraction: 0.8), value: lensIndex)
                .padding(.horizontal, 12)
                .frame(height: 24)
                .background(
                    GeometryReader { g in
                        Color.clear.preference(key: SegmentFramesKey.self,
                                               value: [index: g.frame(in: .named(space))])
                    }
                )
            }
        }
        // Linse unter der Schrift: Darüber brach das kleine Glas die Schrift doppelt und
        // verschwommen. Die Schrift unter ihr wird stattdessen etwas größer (wie eine Lupe)
        .background(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                restingKnob
                lens
            }
        }
        .coordinateSpace(name: space)
        .onPreferenceChange(SegmentFramesKey.self) { frames = $0 }
        .padding(2)
        // Grau wie ein ausgeschalteter Schalter des Systems, ohne Rand
        .background(Capsule().fill(SettingsTheme.segmentWell))
        .contentShape(Capsule())
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named(space))
                .onChanged { g in
                    guard isEnabled, !settling else { return }
                    if lensX == nil {
                        // Linse nur beim Ziehen oder Drücken auf die gewählte Möglichkeit; ein
                        // einfacher Klick auf eine andere lässt nur die Kapsel hinübergleiten
                        // (sonst flog die Linse erst von der alten Wahl herüber)
                        let onSelected = nearest(to: g.startLocation.x) == selectedIndex
                        guard onSelected || abs(g.translation.width) > 4,
                              let index = selectedIndex, let frame = frames[index] else { return }
                        // Die Linse wächst aus der gewählten Kapsel heraus: erst dort zeigen, den
                        // Zeiger erst im nächsten Ereignis verfolgen. Beides in einem Durchlauf
                        // ließ die Linse von links hereinfliegen
                        lensX = frame.midX
                        return
                    }
                    withAnimation(.interactiveSpring(response: 0.18, dampingFraction: 0.86)) {
                        lensX = g.location.x
                    }
                }
                .onEnded { g in
                    guard isEnabled, let index = nearest(to: g.location.x), let frame = frames[index] else {
                        lensX = nil
                        return
                    }
                    if lensX == nil {
                        // Einfacher Klick: Die Kapsel gleitet zur neuen Wahl
                        guard options[index].0 != selection else { return }
                        let value = options[index].0
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) { chosen = value }
                        DispatchQueue.main.async {
                            selection = value
                            chosen = nil
                        }
                        return
                    }
                    // Kein eigener Impuls: Der Klick auf dem Trackpad ist schon einer.
                    // Erst die Markierung, dann (im nächsten Durchlauf) die Einstellung, wie bei klack
                    if options[index].0 != selection {
                        chosen = options[index].0
                        let value = options[index].0
                        DispatchQueue.main.async {
                            selection = value
                            chosen = nil
                        }
                    }
                    // Die Linse gleitet auf die Möglichkeit und nimmt ihre Größe an, dann wird
                    // sie zur Kapsel; vorher sprang die Kapsel von der alten Stelle herüber
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                        lensX = frame.midX
                        settling = true
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        withAnimation(.easeOut(duration: 0.18)) {
                            lensX = nil
                            settling = false
                        }
                    }
                }
        )
        .opacity(isEnabled ? 1 : 0.45)
        .accessibilityRepresentation {
            Picker("", selection: $selection) {
                ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                    Text(option.1).tag(option.0)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    /// Kapsel unter der gewählten Möglichkeit (in Ruhe): grau, wie der Nutzer es lieber mag.
    /// Die blaue Fassung (wie eingeschaltete Schalter) liegt im Commit mit dem Tag „umschalter-blau“
    @available(macOS 26.0, *)
    @ViewBuilder
    private var restingKnob: some View {
        if let index = selectedIndex, let frame = frames[index] {
            Capsule()
                .fill(SettingsTheme.segmentChosen)
                // Hell ein feiner Schatten wie bei Apples Umschaltern: Weiß hob sich sonst kaum
                // von der hellgrauen Leiste ab (dunkel ohne Schatten, `controlShadow`)
                .shadow(color: SettingsTheme.controlShadow, radius: 1.5, y: 0.5)
                .frame(width: frame.width, height: frame.height)
                .offset(x: frame.minX, y: frame.minY)
                .opacity(lensX == nil ? 1 : 0)
                // Weich überblenden: Sprang die Kapsel beim Drücken weg, während die Linse erst
                // aufging, flackerte es (Nutzer: „bugt ein wenig“)
                .animation(.easeOut(duration: 0.12), value: lensX == nil)
                .allowsHitTesting(false)
        }
    }

    /// Linse beim Drücken und Ziehen: etwas größer als die Möglichkeit, folgt dem Zeiger
    /// innerhalb des Umschalters
    @available(macOS 26.0, *)
    @ViewBuilder
    private var lens: some View {
        if let x = lensX, let first = frames[0], let last = frames[options.count - 1] {
            let width = lensWidth(at: x)
            let center = min(max(x, first.minX + width / 2), last.maxX - width / 2)
            // Beim Ziehen etwas größer als die Möglichkeit (ragt knapp über die Leiste; weiter
            // hinaus zeigte das Glas darunter einen Spiegel der Schrift), beim Einrasten genau so groß
            let growX: CGFloat = settling ? 0 : 8
            let growY: CGFloat = settling ? 0 : 6
            Color.clear
                .frame(width: width + growX, height: first.height + growY)
                // Leicht dunkel getönt: Auf der grauen Leiste wirkte klares Glas weiß beschlagen,
                // die Linse der Uhr ist klar und dunkel
                .glassEffect(.clear.tint(Color.black.opacity(0.25)), in: Capsule())
                // Feine dunkle Außenkante wie bei der Linse der Uhr
                .overlay(Capsule().strokeBorder(Color.black.opacity(settling ? 0 : 0.35), lineWidth: 0.5))
                .offset(x: center - (width + growX) / 2, y: first.minY - growY / 2)
                .allowsHitTesting(false)
                // Nur überblenden: Mit Verkleinern schrumpfte die Linse beim Loslassen sichtbar
                // unter die Kapsel und sprang dann zurück
                .transition(.opacity)
        }
    }

    /// Mitte der Linse beim Ziehen (nil: nicht gedrückt)
    private var lensIndex: Int? { lensX.flatMap { nearest(to: $0) } }

    /// Breite der Linse: zwischen zwei Möglichkeiten weich von der einen zur anderen, statt beim
    /// Überfahren einer kurzen („Fest“) plötzlich klein zu werden
    private func lensWidth(at x: CGFloat) -> CGFloat {
        let sorted = frames.sorted { $0.key < $1.key }.map(\.value)
        guard let first = sorted.first, let last = sorted.last else { return 0 }
        if x <= first.midX { return first.width }
        if x >= last.midX { return last.width }
        for (a, b) in zip(sorted, sorted.dropFirst()) where x >= a.midX && x <= b.midX {
            let t = (x - a.midX) / max(1, b.midX - a.midX)
            return a.width + (b.width - a.width) * t
        }
        return first.width
    }

    private func nearest(to x: CGFloat) -> Int? {
        frames.min { abs($0.value.midX - x) < abs($1.value.midX - x) }?.key
    }

    private var klack: some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                let selected = index == selectedIndex
                Button {
                    guard !selected else { return }
                    // Kein eigener Impuls: Der Klick auf dem Trackpad ist schon einer,
                    // zusammen fühlte es sich doppelt an.
                    // Erst die Markierung, dann (im nächsten Durchlauf) die Einstellung: In der
                    // Einführung zog beim Wechsel des Rands die ganze Ablage um, und die
                    // Markierung blieb stehen, bis man ein zweites Mal klickte
                    chosen = option.0
                    let value = option.0
                    DispatchQueue.main.async {
                        selection = value
                        chosen = nil
                    }
                } label: {
                    ZStack {
                        // Platz für die fette Schrift, damit die Breite gleich bleibt
                        Text(option.1).font(.system(size: 12.5, weight: .semibold)).hidden()
                        Text(option.1)
                            .font(.system(size: 12.5, weight: selected ? .semibold : .regular))
                            .foregroundStyle(selected ? Color.primary : Color.secondary)
                    }
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(
                    GeometryReader { g in
                        Color.clear.preference(key: SegmentFramesKey.self,
                                               value: [index: g.frame(in: .named(Self.space))])
                    }
                )
            }
        }
        .background(alignment: .topLeading) { knob }
        .coordinateSpace(name: Self.space)
        .onPreferenceChange(SegmentFramesKey.self) { frames = $0 }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(SettingsTheme.segmentTrough)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(SettingsTheme.separator, lineWidth: 1)
        )
        .opacity(isEnabled ? 1 : 0.45)
    }

    @ViewBuilder
    private var knob: some View {
        if let index = selectedIndex, let frame = frames[index] {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(SettingsTheme.segmentKnob)
                .shadow(color: .black.opacity(0.25), radius: 1.5, y: 1)
                .frame(width: frame.width, height: frame.height)
                .offset(x: frame.minX, y: frame.minY)
                .animation(.spring(response: 0.28, dampingFraction: 0.82), value: index)
                .allowsHitTesting(false)
        }
    }
}

private struct SegmentFramesKey: PreferenceKey {
    static var defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

/// Auswahlmenü wie bei Klack: Wert und ⌃⌄ im Kreis. Das Menü öffnet sich immer
/// am Wert, der gewählte Eintrag liegt genau darüber (wie bei macOS üblich).
struct PopupValue<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(Value, String)]
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false
    @State private var frame: CGRect = .zero

    private var current: String {
        options.first { $0.0 == selection }?.1 ?? ""
    }

    var body: some View {
        Button(action: showMenu) {
            HStack(spacing: 9) {
                Text(current)
                    .font(.system(size: 13.5))
                    .foregroundStyle(.primary)
                // Etwas kräftiger: Im Dunkeln wirkten die Kreise neben den Umschaltern fast deaktiviert
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Color.primary.opacity(0.75))
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Color.primary.opacity(hovering && isEnabled ? 0.14 : 0.08)))
                    .overlay(Circle().strokeBorder(SettingsTheme.separator, lineWidth: 1))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.45)
        .onHover { hovering = $0 }
        .readFrame($frame)
    }

    private func showMenu() {
        let menu = NSMenu()
        var selectedItem: NSMenuItem?
        for (value, title) in options {
            let item = ClosureMenuItem(title) { selection = value }
            if value == selection {
                item.state = .on
                selectedItem = item
            }
            menu.addItem(item)
        }
        MenuPresenter.show(menu, over: frame, selected: selectedItem)
    }
}

/// Merkt sich die Lage einer Ansicht im Fenster (für Menüs, die daran ausgerichtet werden).
private struct FrameReader: ViewModifier {
    @Binding var frame: CGRect
    func body(content: Content) -> some View {
        content.background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { frame = geo.frame(in: .global) }
                    .onChange(of: geo.frame(in: .global)) { _, new in frame = new }
            }
        )
    }
}

extension View {
    func readFrame(_ frame: Binding<CGRect>) -> some View { modifier(FrameReader(frame: frame)) }
}

/// Zeigt ein Menü an einer festen Stelle im Einstellungsfenster statt am Mauszeiger.
enum MenuPresenter {
    /// Auswahl unter dem Wert, rechtsbündig daran (die Werte stehen rechts in der Zeile)
    static func show(_ menu: NSMenu, over frame: CGRect, selected: NSMenuItem?) {
        // Ab macOS 26 das Menü des Systems (Liquid Glass): der gewählte Eintrag über dem Wert,
        // wie bei Auswahlknöpfen von macOS
        if #available(macOS 26.0, *), let view = settingsView {
            matchAppearance(menu, to: view)
            menu.popUp(positioning: selected, at: point(frame.minX, frame.minY, in: view), in: view)
            return
        }
        ChoicePopup.present(menu, anchor: frame, align: .trailing)
    }

    /// Liste unter einem Knopf, linksbündig daran; bei zu wenig Platz nach oben
    static func show(_ menu: NSMenu, below frame: CGRect) {
        if #available(macOS 26.0, *), let view = settingsView {
            matchAppearance(menu, to: view)
            // Reicht der Platz unter dem Knopf nicht (Fenster tief auf dem Bildschirm), geht das
            // Menü nach oben auf; sonst schnitt der Bildschirmrand es ab und es musste scrollen
            var at = point(frame.minX, frame.maxY + 4, in: view)
            if let window = view.window, let screen = window.screen {
                let below = window.convertPoint(toScreen: view.convert(at, to: nil)).y - screen.visibleFrame.minY
                if menu.size.height > below {
                    at = point(frame.minX, frame.minY - 4 - menu.size.height, in: view)
                }
            }
            menu.popUp(positioning: nil, at: at, in: view)
            return
        }
        ChoicePopup.present(menu, anchor: frame, align: .leading)
    }

    /// Inhalt des Einstellungsfensters (die Rahmen kommen von SwiftUI, oben links gemessen)
    private static var settingsView: NSView? {
        NSApp.windows.first { $0 is SettingsNSWindow && $0.isVisible }?.contentView
    }

    /// Das Menü hell oder dunkel wie das Fenster, also wie das System eingestellt ist
    private static func matchAppearance(_ menu: NSMenu, to view: NSView) {
        menu.appearance = view.effectiveAppearance
        menu.items.compactMap(\.submenu).forEach { matchAppearance($0, to: view) }
    }

    private static func point(_ x: CGFloat, _ y: CGFloat, in view: NSView) -> NSPoint {
        NSPoint(x: x, y: view.isFlipped ? y : view.bounds.height - y)
    }
}

/// Regler wie bei Klack: Titel und Wert (in einer Kapsel) in einer Zeile,
/// darunter die Leiste mit Rasterpunkten.
struct SliderRow: View {
    let title: String
    var info: String?
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 0
    var format: (Double) -> String

    init(_ title: String, info: String? = nil, value: Binding<Double>, range: ClosedRange<Double>, step: Double = 0,
         format: @escaping (Double) -> String) {
        self.title = title
        self.info = info
        self._value = value
        self.range = range
        self.step = step
        self.format = format
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                HStack(spacing: 6) {
                    Text(title).font(.system(size: 13.5))
                    if let info { InfoButton(info) }
                }
                Spacer()
                Text(format(value))
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.03)))
                    .overlay(Capsule().strokeBorder(SettingsTheme.separator, lineWidth: 1))
            }
            KlackSlider(value: $value, range: range, step: step)
        }
        .padding(.horizontal, SettingsTheme.rowPadding)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    static func percent(_ v: Double) -> String { Format.percent(Int((v * 100).rounded())) }
    static func points(_ v: Double) -> String { "\(Int(v.rounded())) pt" }
}

/// Leiste mit blauem Anteil, weißem Knopf und Rasterpunkten darunter. Rastet in
/// Schritten ein und gibt bei jedem Schritt einen leichten Impuls auf dem Trackpad.
struct KlackSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 0
    @Environment(\.isEnabled) private var isEnabled

    private let knobWidth: CGFloat = 22
    private let knobHeight: CGFloat = 16
    private let track: CGFloat = 6
    /// Höchstens so viele Rasterpunkte, damit es nicht zu dicht wird
    private let maxTicks = 20

    /// Werte der Rasterpunkte: jeder Schritt, bei vielen Schritten jeder n-te
    private var tickFractions: [CGFloat] {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return [] }
        let unit = step > 0 ? step : span / 10
        let count = Int((span / unit).rounded())
        guard count > 0 else { return [] }
        // Gleichmäßig verteilt wie bei macOS: bei vielen Schritten weniger Punkte, aber nie
        // ein zusätzlicher Punkt dicht am Ende (60 bis 200 in 4er-Schritten ergab zwei enge
        // Punkte rechts)
        let every = max(1, Int((Double(count) / Double(maxTicks)).rounded(.up)))
        let intervals = every == 1 ? count : max(1, Int((Double(count) / Double(every)).rounded()))
        return (0...intervals).map { CGFloat(Double($0) / Double(intervals)) }
    }

    var body: some View {
        if #available(macOS 26.0, *) {
            // Ab macOS 26 der Regler des Systems: Beim Ziehen wird sein Knopf zu Liquid Glass.
            // Rastpunkte und Einrasten bleiben wie bisher (dieselben Punkte, nur dort halten)
            SystemSlider(value: value, range: range, ticks: tickFractions.count, snaps: step > 0, set: set)
                .opacity(isEnabled ? 1 : 0.45)
        } else {
            klack
        }
    }

    private var klack: some View {
        GeometryReader { geo in
            let usable = max(1, geo.size.width - knobWidth)
            let fraction = CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
            let x = usable * min(max(fraction, 0), 1)
            ZStack(alignment: .topLeading) {
                // Rasterpunkte
                ForEach(Array(tickFractions.enumerated()), id: \.offset) { _, f in
                    Circle()
                        .fill(SettingsTheme.tick)
                        .frame(width: 2.5, height: 2.5)
                        .offset(x: knobWidth / 2 + usable * f - 1.25, y: knobHeight + 5)
                }
                // Leiste und Anteil
                Capsule()
                    .fill(SettingsTheme.separator)
                    .frame(height: track)
                    .offset(y: (knobHeight - track) / 2)
                Capsule()
                    .fill(Color(nsColor: .controlAccentColor))
                    .frame(width: x + knobWidth / 2, height: track)
                    .offset(y: (knobHeight - track) / 2)
                // Knopf
                Capsule()
                    .fill(SettingsTheme.sliderKnob)
                    .frame(width: knobWidth, height: knobHeight)
                    .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
                    .offset(x: x)
            }
            .frame(width: geo.size.width, height: knobHeight + 10, alignment: .topLeading)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        let f = Double(min(max((g.location.x - knobWidth / 2) / usable, 0), 1))
                        set(range.lowerBound + f * (range.upperBound - range.lowerBound))
                    }
            )
        }
        .frame(height: knobHeight + 10)
        .opacity(isEnabled ? 1 : 0.45)
    }

    private func set(_ raw: Double) {
        // Mit Schritten: genau auf den sichtbaren Punkten einrasten, nie dazwischen
        let v: Double
        if step > 0 {
            let span = range.upperBound - range.lowerBound
            let stops = tickFractions.map { range.lowerBound + Double($0) * span }
            let nearest = stops.min(by: { abs($0 - raw) < abs($1 - raw) }) ?? raw
            v = (nearest / step).rounded() * step       // ohne Rundungsfehler speichern
        } else {
            v = raw
        }
        let clamped = min(max(v, range.lowerBound), range.upperBound)
        guard abs(clamped - value) > 1e-9 else { return }
        value = clamped
        // Jeder neue Schritt: ein leichter Impuls, wie beim Einrasten
        if step > 0 { Haptics.tap() }
    }
}

/// Regler von AppKit (NSSlider) mit Rastpunkten darunter. Mit `snaps` hält er nur auf den
/// Punkten; jeder neue Wert geht über `set` (Runden auf den Schritt, Impuls beim Einrasten).
@available(macOS 26.0, *)
private struct SystemSlider: NSViewRepresentable {
    let value: Double
    let range: ClosedRange<Double>
    let ticks: Int
    let snaps: Bool
    let set: (Double) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSSlider {
        let slider = NSSlider(value: value, minValue: range.lowerBound, maxValue: range.upperBound,
                              target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        slider.isContinuous = true
        slider.tickMarkPosition = .below
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return slider
    }

    func updateNSView(_ slider: NSSlider, context: Context) {
        context.coordinator.set = set
        if slider.minValue != range.lowerBound { slider.minValue = range.lowerBound }
        if slider.maxValue != range.upperBound { slider.maxValue = range.upperBound }
        if slider.numberOfTickMarks != ticks { slider.numberOfTickMarks = ticks }
        slider.allowsTickMarkValuesOnly = snaps
        slider.isEnabled = context.environment.isEnabled
        if abs(slider.doubleValue - value) > 1e-9 { slider.doubleValue = value }
    }

    final class Coordinator: NSObject {
        var set: (Double) -> Void = { _ in }
        @objc func changed(_ sender: NSSlider) { set(sender.doubleValue) }
    }
}

/// Grauer Knopf wie „Check Updates…“ bei Klack.
struct KlackButtonStyle: ButtonStyle {
    var prominent = false
    var destructive = false

    func makeBody(configuration: Configuration) -> some View {
        KlackButtonBody(configuration: configuration, prominent: prominent, destructive: destructive)
    }

    private struct KlackButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let prominent: Bool
        let destructive: Bool
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.colorScheme) private var colorScheme
        @State private var hovering = false

        /// Dunkel wie bei Klack (unverändert), hell wie die Knöpfe von macOS
        private var background: Color {
            if colorScheme == .dark {
                return Color.primary.opacity(configuration.isPressed ? 0.2 : hovering ? 0.15 : 0.11)
            }
            return configuration.isPressed ? SettingsTheme.buttonLightPressed
                : hovering ? SettingsTheme.buttonLightHover : SettingsTheme.buttonLight
        }

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(prominent ? Color.white : destructive ? Color.red : Color.primary)
                .padding(.horizontal, 12)
                .frame(height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(prominent ? Color(nsColor: .controlAccentColor) : background)
                        .shadow(color: prominent ? .clear : SettingsTheme.controlShadow, radius: 0.5, y: 0.5)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(prominent ? Color.clear : SettingsTheme.buttonBorder, lineWidth: 0.5)
                )
                .opacity(isEnabled ? (configuration.isPressed && prominent ? 0.85 : 1) : 0.45)
                .onHover { hovering = $0 }
        }
    }
}

/// Runder Knopf nur mit Symbol (Zurück in der Titelleiste): dieselbe Fläche, derselbe Rand
/// und dieselbe Schriftfarbe wie `KlackButtonStyle`, damit er zu den anderen Knöpfen passt
struct KlackCircleButtonStyle: ButtonStyle {
    var size: CGFloat = 28

    func makeBody(configuration: Configuration) -> some View {
        CircleBody(configuration: configuration, size: size)
    }

    private struct CircleBody: View {
        let configuration: ButtonStyleConfiguration
        let size: CGFloat
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.colorScheme) private var colorScheme
        @State private var hovering = false

        private var background: Color {
            if colorScheme == .dark {
                return Color.primary.opacity(configuration.isPressed ? 0.2 : hovering ? 0.15 : 0.11)
            }
            return configuration.isPressed ? SettingsTheme.buttonLightPressed
                : hovering ? SettingsTheme.buttonLightHover : SettingsTheme.buttonLight
        }

        var body: some View {
            configuration.label
                .foregroundStyle(Color.primary)
                .frame(width: size, height: size)
                .background(Circle().fill(background).shadow(color: SettingsTheme.controlShadow, radius: 0.5, y: 0.5))
                .overlay(Circle().strokeBorder(SettingsTheme.buttonBorder, lineWidth: 0.5))
                .contentShape(Circle())
                .opacity(isEnabled ? 1 : 0.45)
                .onHover { hovering = $0 }
        }
    }
}

/// Überschrift eines Abschnitts: Titel links, rechts optional Info und weitere Knöpfe.
struct SettingsHeader<Trailing: View>: View {
    let title: String
    var info: String?
    let trailing: () -> Trailing

    init(_ title: String, info: String? = nil, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        self.info = info
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if let info { InfoButton(info) }
            trailing()
        }
    }
}

extension SettingsHeader where Trailing == EmptyView {
    init(_ title: String, info: String? = nil) {
        self.init(title, info: info) { EmptyView() }
    }
}

/// Kleines rundes Info-Symbol; ein Klick zeigt die Erklärung.
struct InfoButton: View {
    let text: String
    @State private var shown = false
    @State private var hovering = false

    init(_ text: String) { self.text = text }

    var body: some View {
        Button {
            shown.toggle()
        } label: {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(Color.secondary.opacity(hovering ? 0.95 : 0.6))
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 280, alignment: .leading)
                .padding(12)
        }
        .accessibilityLabel("Info")
    }
}

/// Erklärtext unter einer Karte: immer linksbündig.
struct SectionNote: View {
    let text: String
    var color: Color = .secondary
    init(_ text: String, color: Color = .secondary) {
        self.text = text
        self.color = color
    }
    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(color)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Unschärfe des Schreibtischs hinter dem Fenster; darüber liegen die Farben
/// von Seitenleiste und Inhalt leicht durchscheinend.
struct SettingsBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}


extension SettingsTheme {
    /// Leichter Verlauf für farbige Symbolkacheln wie in den Systemeinstellungen: oben eine
    /// Spur heller, unten die Farbe selbst
    static func iconGradient(_ tint: Color) -> LinearGradient {
        let base = NSColor(tint).usingColorSpace(.sRGB) ?? NSColor(tint)
        let top = base.blended(withFraction: 0.18, of: .white) ?? base
        return LinearGradient(colors: [Color(nsColor: top), tint], startPoint: .top, endPoint: .bottom)
    }
}

extension View {
    /// Leichter Schatten unter einer farbigen Symbolkachel wie in den Systemeinstellungen.
    /// `size`: Kantenlänge der Kachel, der Schatten wächst mit.
    func iconTileShadow(size: CGFloat) -> some View {
        let k = size / 22
        return shadow(color: .black.opacity(0.28), radius: 1.1 * k, y: 0.7 * k)
    }

    /// Hauch von Schatten unter dem weißen Zeichen auf der Kachel
    func iconGlyphShadow(size: CGFloat) -> some View {
        let k = size / 22
        return shadow(color: .black.opacity(0.22), radius: 0.6 * k, y: 0.5 * k)
    }
}
