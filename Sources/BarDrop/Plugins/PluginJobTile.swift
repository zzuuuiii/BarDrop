import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Platzhalter für ein laufendes Plugin, direkt neben dem Original (bei „Original ersetzen“
/// an seiner Stelle): eine sichtbare, aber durchsichtige Vorschau, die mit dem Fortschritt
/// deckend wird, und darunter, zwischen Bild und Namen, ein schmaler Balken mit dem
/// Fortschritt. Gezeigt wird die Datei, die entsteht: ihr Vorschaubild, sobald sie fertig
/// geschrieben ist, solange sie noch wächst das Symbol ihrer Art, und bis es sie gibt die
/// Datei, an der das Plugin arbeitet. Meldet das Plugin keinen Fortschritt, „atmet“ die
/// Vorschau ruhig, und im blauen Balken wandert ein Streifen. Scheitert der Lauf, rüttelt der
/// Platzhalter kurz, bevor er verschwindet.
///
/// Auswählen wie eine Kachel (Klick, ⌘- bzw. ⇧-Klick, Lasso, Pfeiltasten); ⌫ bricht ab.
/// Wie bei Downloads im Finder und im App Store: Fährt der Zeiger darüber, wird das Zeichen
/// in der Mitte zum Knopf für Anhalten bzw. Fortsetzen, und oben rechts erscheint ein
/// kleines x zum Abbrechen. Der Rechtsklick bietet dasselbe zusätzlich an.
struct PluginJobTile: View {
    @ObservedObject var job: PluginJob
    @ObservedObject var ui: ShelfUIModel
    @Environment(\.shelfDemo) private var shelfDemo
    let actions: ShelfActions
    var iconSize: CGFloat = 64
    @State private var hovering = false

    /// So lange bleibt ein gescheiterter Platzhalter stehen (Rütteln), bevor er verschwindet
    static let failureDuration: TimeInterval = 0.55

    private var showsControls: Bool { hovering && !shelfDemo }

    var body: some View {
        TileLabel(title: job.isStarted ? (job.label ?? job.title) : L("Waiting", "Wartet"),
                  isSelected: ui.jobSelection.contains(job.id), isKey: ui.isKey || ui.level == .expanded,
                  iconSize: iconSize) {
            PluginPreview(job: job, size: iconSize, hovering: showsControls)
        }
        .overlay(Group { if !shelfDemo {
            PluginJobMenuArea(ui: ui, menu: { actions.menu(for: job) },
                              onClick: { modifiers in actions.selectJob(job, modifiers: modifiers) })
        } })
        // Über der Fläche für den Rechtsklick, damit die Knöpfe Klicks bekommen
        .overlay(alignment: .top) { if showsControls { controls } }
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.12)) { hovering = inside }
        }
        .help(job.percent.map { "\(job.title): " + Format.percent($0) } ?? job.title)
        .modifier(Shake(amount: job.failed && !AnimationStyle.reduceMotion ? 1 : 0))
        .animation(.linear(duration: 0.45), value: job.failed)
        .transition(.opacity)
    }

    /// Knöpfe genau über dem Vorschaubild (gleiche Lage wie das Symbol in TileLabel)
    private var controls: some View {
        let box = TileMetrics.box(iconSize)
        let cancelSize = max(16, (iconSize * 0.24).rounded())
        return ZStack {
            if job.isStarted {
                // Nur so groß wie das Zeichen in der Mitte: Ein Klick daneben wählt aus
                Button {
                    if job.paused { job.resume() } else { job.pause() }
                } label: {
                    Circle().fill(Color.clear)
                        .frame(width: iconSize * 0.38, height: iconSize * 0.38)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(job.paused ? L("Resume", "Fortsetzen") : L("Pause", "Anhalten"))
                .accessibilityLabel(job.paused ? L("Resume", "Fortsetzen") : L("Pause", "Anhalten"))
            }
            Button {
                actions.plugins.cancel(job)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: cancelSize))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Color.black.opacity(0.85), Color(white: 0.78))
                    .background(Circle().fill(Color.black).padding(1))
            }
            .buttonStyle(.plain)
            .help(L("Cancel", "Abbrechen"))
            .accessibilityLabel(L("Cancel", "Abbrechen"))
            .offset(x: iconSize * 0.46, y: -iconSize * 0.46)
            .transition(.scale(scale: 0.6).combined(with: .opacity))
        }
        .frame(width: box, height: box)
        .padding(.top, 6)
    }
}

/// Vorschau, durchsichtig je nach Fortschritt: das Ergebnis, sobald es da ist, sonst die
/// Datei, an der das Plugin arbeitet
private struct PluginPreview: View {
    @ObservedObject var job: PluginJob
    let size: CGFloat
    /// Zeiger darüber: In der Mitte steht, was ein Klick tut (Anhalten oder Fortsetzen)
    var hovering = false
    @State private var breathing = false

    static let barHeight: CGFloat = 4

    /// Abstand vom unteren Rand des Bildes bis zur Mitte des Balkens: die Hälfte der Lücke
    /// bis zum Namen. Die Lücke ergibt sich aus TileLabel: 2 pt Rahmen um das Bild, der Rand
    /// der Fläche, 4 pt Abstand im Stapel und 1 pt Rand des Namens.
    static func barOffset(_ size: CGFloat) -> CGFloat {
        let boxMargin = (TileMetrics.box(size) - size - 4) / 2
        let gap = 2 + boxMargin + 4 + 1
        return (gap / 2 + barHeight / 2).rounded()
    }

    /// Am Anfang gut zu sehen, aber deutlich durchsichtig
    private static let startOpacity = 0.3
    /// Mit Fortschritt beginnt die Deckkraft in der Mitte des Atmens (0,3 bis 0,6): Kommt der
    /// erste Fortschritt, springt die Vorschau nicht erst zurück und flackert
    private static let progressOpacity = 0.45

    /// Atmet, solange der Lauf arbeitet: auch mit Fortschritt und auch, wenn schon das
    /// Ergebnis zu sehen ist (vorher stand das Bild dann still, als wäre nichts los)
    private var breathes: Bool {
        job.isStarted && !job.paused && !AnimationStyle.reduceMotion
    }

    /// Grund-Deckkraft: mit dem Fortschritt deckender
    private var opacity: Double {
        let base: Double
        if !job.isStarted {
            base = Self.startOpacity
        } else if let progress = job.progress {
            base = Self.progressOpacity + (1 - Self.progressOpacity) * progress
        } else {
            base = 0.6
        }
        // Angehalten etwas blasser, aber nie fast unsichtbar
        return job.paused ? max(base * 0.75, Self.startOpacity) : base
    }

    /// Das Atmen als eigener Faktor darüber: Fortschritt und Atmen haben je ihre eigene
    /// Animation und unterbrechen sich nicht gegenseitig
    private var breath: Double { breathes && !breathing ? 0.55 : 1 }

    /// Welches Bild: das fertige Ergebnis, sonst das Symbol der Datei, die gerade entsteht,
    /// sonst die Datei, an der das Plugin arbeitet
    private var pictureKey: String {
        if let url = job.resultPreview { return "result:" + url.path }
        if let type = job.resultType { return "type:" + type.identifier }
        return "source:" + job.item.url.path
    }

    @ViewBuilder
    private var picture: some View {
        if let url = job.resultPreview {
            ThumbnailView(url: url, size: size)
        } else if let type = job.resultType {
            Image(nsImage: Self.icon(for: type))
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .shadow(color: .black.opacity(0.35), radius: 3, x: 0, y: 1)
        } else {
            ThumbnailView(url: job.item.url, size: size)
        }
    }

    /// Symbole je Dateiart einmal holen: Bei jedem Neuzeichnen ein neues Bild vom System
    /// zu holen, ließ das Symbol flackern
    private static var icons: [String: NSImage] = [:]

    static func icon(for type: UTType) -> NSImage {
        if let icon = icons[type.identifier] { return icon }
        let icon = NSWorkspace.shared.icon(for: type)
        icons[type.identifier] = icon
        return icon
    }

    var body: some View {
        ZStack {
            // Die Deckkraft liegt um das Bild herum, nicht am Bild selbst: Wechselt das Bild
            // (Ergebnis statt Ausgangsdatei), atmet es ohne Sprung weiter
            ZStack {
                picture
                    .id(pictureKey)
                    .transition(.opacity)
            }
            .opacity(breath)
            .animation(breathes ? .easeInOut(duration: 2.4).repeatForever(autoreverses: true) : .easeOut(duration: 0.4),
                       value: breathing)
            .opacity(opacity)
            .animation(.easeOut(duration: 0.3), value: job.progress)
            .animation(.easeOut(duration: 0.3), value: job.paused)
            centerGlyph
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
        .animation(.easeOut(duration: 0.3), value: pictureKey)
        .frame(width: size, height: size)
        // Genau in der Mitte zwischen Bild und Namen, im Rand der Fläche um das Bild: Die
        // Kachel wird nicht höher, und der Balken klebt weder am Bild noch am Namen
        .overlay(alignment: .bottom) {
            PluginProgressBar(progress: job.isStarted ? job.progress : nil, running: job.isStarted,
                              paused: job.paused, failed: job.failed)
                .frame(width: (size * 0.78).rounded(), height: Self.barHeight)
                .offset(y: Self.barOffset(size))
        }
        .onAppear { breathing = breathes }
        .onChange(of: breathes) { _, now in breathing = now }
    }

    /// Mitte: beim Darüberfahren Anhalten bzw. Fortsetzen, sonst nur, wenn es wartet
    /// oder angehalten ist
    @ViewBuilder
    private var centerGlyph: some View {
        let symbol: String? = hovering && job.isStarted ? (job.paused ? "play.fill" : "pause.fill")
            : !job.isStarted ? "clock"
            : job.paused ? "pause.fill" : nil
        if let symbol {
            Image(systemName: symbol)
                .font(.system(size: size * 0.17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size * 0.38, height: size * 0.38)
                .background(Circle().fill(Color.black.opacity(0.5)))
                .contentTransition(.symbolEffect(.replace))
                .transition(.opacity)
        }
    }
}

/// Schmaler Balken unter dem Bild: füllt sich mit dem Fortschritt. Ohne Anteil wandert ein
/// Lichtstreifen (bei „Bewegung reduzieren“ steht er still); wartet der Lauf, ist er leer.
private struct PluginProgressBar: View {
    let progress: Double?
    let running: Bool
    let paused: Bool
    let failed: Bool
    @State private var sweep = false

    /// Blau wie der Fortschritt im Finder (Akzentfarbe des Systems)
    private var fill: Color {
        failed ? Color(red: 1, green: 0.35, blue: 0.3) : Color(nsColor: .controlAccentColor).opacity(paused ? 0.5 : 1)
    }

    private var sweeps: Bool { running && progress == nil && !paused && !failed && !AnimationStyle.reduceMotion }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.16))
                if failed {
                    Capsule().fill(fill)
                } else if let progress {
                    Capsule().fill(fill)
                        .frame(width: max(3, geo.size.width * max(0, min(1, progress))))
                        .animation(.easeOut(duration: 0.3), value: progress)
                } else if running {
                    Capsule().fill(fill.opacity(0.85))
                        .frame(width: geo.size.width * 0.3)
                        .offset(x: sweep ? geo.size.width * 0.7 : 0)
                        .animation(sweeps ? .easeInOut(duration: 1.4).repeatForever(autoreverses: true) : .easeOut(duration: 0.3),
                                   value: sweep)
                }
            }
        }
        .animation(.easeOut(duration: 0.2), value: failed)
        .onAppear { sweep = sweeps }
        .onChange(of: sweeps) { _, now in sweep = now }
        .accessibilityHidden(true)
    }
}

/// Kurzes Rütteln (links, rechts, auslaufend), wie bei einem falschen Kennwort in macOS
private struct Shake: GeometryEffect {
    var amount: CGFloat
    var animatableData: CGFloat {
        get { amount }
        set { amount = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        let x = 5 * sin(amount * .pi * 6) * (1 - amount * 0.6)
        return ProjectionTransform(CGAffineTransform(translationX: x, y: 0))
    }
}

/// Fläche über dem Platzhalter: Klick wählt aus, Rechtsklick (und ⌃-Klick) öffnet sein Menü
private struct PluginJobMenuArea: NSViewRepresentable {
    let ui: ShelfUIModel
    let menu: () -> NSMenu
    var onClick: (NSEvent.ModifierFlags) -> Void = { _ in }

    func makeNSView(context: Context) -> MenuNSView {
        let view = MenuNSView()
        configure(view)
        return view
    }

    func updateNSView(_ view: MenuNSView, context: Context) { configure(view) }

    private func configure(_ view: MenuNSView) {
        view.ui = ui
        view.menuProvider = menu
        view.onClick = onClick
    }

    final class MenuNSView: NSView {
        weak var ui: ShelfUIModel?
        var menuProvider: () -> NSMenu = { NSMenu() }
        var onClick: (NSEvent.ModifierFlags) -> Void = { _ in }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func rightMouseDown(with event: NSEvent) {
            onClick([])
            show(event)
        }

        override func mouseDown(with event: NSEvent) {
            if event.modifierFlags.contains(.control) {
                onClick([])
                show(event)
            } else {
                onClick(event.modifierFlags)
            }
        }

        private func show(_ event: NSEvent) {
            ui?.menuOpen = true
            ShelfMenu.popUp(menuProvider(), with: event, for: self)
            ui?.menuOpen = false
        }
    }
}
