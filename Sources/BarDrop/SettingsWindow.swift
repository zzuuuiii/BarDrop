import SwiftUI
import AppKit
import Carbon

// MARK: Fenster

/// Einstellungsfenster im Stil von Klack: ein einheitliches Grau, links die
/// Bereiche mit farbigen Symbolen, rechts Titel und Karten.
enum SettingsWindowFactory {
    static let size = NSSize(width: 680, height: 700)

    static func make(settings: AppSettings, store: ShelfStore, showOnboarding: @escaping () -> Void) -> NSWindow {
        let window = SettingsNSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // Leere Symbolleiste: höhere Titelleiste, die Ampel sitzt auf Höhe der Überschrift
        window.toolbar = NSToolbar(identifier: "BarDropSettings")
        // Ab macOS 26 kompakt: Unter der hohen Titelleiste legte macOS beim Scrollen ein Glas,
        // das bis etwa 63 pt reichte und die erste Zeile anschnitt. Kompakt endet es mit der
        // Überschrift (SettingsRoot.detail), die dafür auf Höhe der Ampel steht
        if #available(macOS 26.0, *) {
            window.toolbarStyle = .unifiedCompact
        } else {
            window.toolbarStyle = .unified
        }
        window.titlebarSeparatorStyle = .none
        window.title = "BarDrop"
        // Nur an der Titelleiste verschiebbar: Sonst bewegt das Ziehen an Reglern
        // oder Aktionszeilen das ganze Fenster mit
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false
        // Alle drei Ampelknöpfe wie bei anderen Apps; Vergrößern ist ausgegraut, weil
        // das Fenster eine feste Größe hat (wie bei den Systemeinstellungen)
        window.standardWindowButton(.miniaturizeButton)?.isHidden = false
        window.standardWindowButton(.zoomButton)?.isHidden = false
        // Leicht durchscheinend wie bei Klack: Fenster selbst ohne Farbe,
        // die Flächen zeichnet SettingsRoot über einer Unschärfe.
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = NSHostingView(rootView: SettingsRoot(settings: settings, store: store,
                                                                  showOnboarding: showOnboarding))
        window.setContentSize(size)
        window.center()
        return window
    }
}

/// Fenster der Einstellungen: ↑ und ↓ wechseln den Bereich in der Seitenleiste. Nur Tasten,
/// die nichts anderes verwendet hat (Textfeld, Regler, Aufnahme des Kurzbefehls), kommen hier an.
final class SettingsNSWindow: NSWindow {
    /// Knöpfe der Inhaltsansicht, die in der hohen Titelleiste liegen (Zurück auf den
    /// Unterseiten). Die Titelleiste mit Symbolleiste nimmt dort sonst jeden Klick zum
    /// Verschieben des Fensters, der Knopf bekam ihn nie. Rahmen in den Koordinaten der
    /// Inhaltsansicht (oben links), wie SwiftUI sie liefert.
    static var titlebarButtons: [String: (frame: CGRect, action: () -> Void)] = [:] {
        didSet {
            for case let window as SettingsNSWindow in NSApp.windows { window.updateDragBlockers() }
        }
    }
    private var pressedButton: String?

    /// Fenster verschiebbar oder nicht (aus, solange der Zeiger auf dem Zurück-Knopf steht)
    static func setMovable(_ movable: Bool) {
        for case let window as SettingsNSWindow in NSApp.windows where window.isMovable != movable {
            window.isMovable = movable
        }
    }
    /// Flächen über den Knöpfen in der Titelleiste, an denen das Fenster nicht verschoben wird.
    /// `sendEvent` allein reichte nicht: macOS verschiebt das Fenster an der Titelleiste selbst
    /// (außerhalb der App), sobald man zieht. Am Zurück-Knopf ließ sich so das Fenster
    /// verschieben (Nutzer, 24.10.2026). Ansichten mit `mouseDownCanMoveWindow == false` nimmt
    /// macOS aus diesem Bereich aus
    private var dragBlockers: [String: NSView] = [:]

    private final class NoDragView: NSView {
        override var mouseDownCanMoveWindow: Bool { false }
        // Klicks gehen weiter an sendEvent (dort wird der Knopf ausgelöst)
        override func mouseDown(with event: NSEvent) {}
    }

    /// Ab macOS 26 ein echter Knopf von AppKit aus Liquid Glass in der Titelleiste: Er reagiert
    /// beim Drücken und Ziehen wie Glas (der nachgebaute aus SwiftUI bekam keine Ereignisse, weil
    /// das Fenster die Klicks abfangen musste; Nutzer: „reagiert nicht wie Liquid Glass“) und
    /// verschiebt das Fenster nicht
    @available(macOS 26.0, *)
    private final class GlassTitlebarButton: NSButton {
        var key = ""
        override var mouseDownCanMoveWindow: Bool { false }

        static func make(key: String) -> GlassTitlebarButton {
            let button = GlassTitlebarButton(frame: .zero)
            button.key = key
            button.bezelStyle = .glass
            button.borderShape = .circle
            button.title = ""
            let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
            button.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: L("Back", "Zurück"))?
                .withSymbolConfiguration(config)
            button.imagePosition = .imageOnly
            button.toolTip = L("Back", "Zurück")
            button.target = button
            button.action = #selector(pressed)
            return button
        }

        @objc private func pressed() { SettingsNSWindow.titlebarButtons[key]?.action() }
    }

    /// Echte Knöpfe statt Sperrflächen (ab macOS 26)
    static var usesNativeTitlebarButtons: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    fileprivate func updateDragBlockers() {
        // Die Titelleiste liegt über der Inhaltsansicht; die Sperrflächen gehören in sie hinein.
        // Der echte Glasknopf (macOS 26) kommt ganz nach oben in den Fensterrahmen: In der
        // Titelleiste selbst lag er unter der Symbolleiste und war nicht zu sehen (Nutzer)
        guard let content = contentView,
              let titlebar = Self.usesNativeTitlebarButtons ? content.superview
                  : standardWindowButton(.closeButton)?.superview else { return }
        for (key, view) in dragBlockers where Self.titlebarButtons[key] == nil {
            view.removeFromSuperview()
            dragBlockers[key] = nil
        }
        for (key, button) in Self.titlebarButtons {
            // Rahmen kommt oben links (SwiftUI). Die Inhaltsansicht (NSHostingView) zählt selbst
            // von oben; nur wenn nicht, umdrehen. Vorher wurde immer umgedreht, und Sperrfläche
            // bzw. Glasknopf landeten unten im Fenster statt auf dem Zurück-Knopf
            let local = content.isFlipped ? button.frame
                : NSRect(x: button.frame.minX, y: content.bounds.height - button.frame.maxY,
                         width: button.frame.width, height: button.frame.height)
            let frame = titlebar.convert(local, from: content)
            let view = dragBlockers[key] ?? {
                let v: NSView
                if #available(macOS 26.0, *) {
                    v = GlassTitlebarButton.make(key: key)
                } else {
                    v = NoDragView(frame: frame)
                }
                titlebar.addSubview(v, positioned: .above, relativeTo: nil)
                dragBlockers[key] = v
                return v
            }()
            // Der gemeldete Rahmen ist um 4 pt größer (Trefferfläche); der Knopf selbst nicht
            let target = Self.usesNativeTitlebarButtons ? frame.insetBy(dx: 4, dy: 4) : frame
            if view.frame != target { view.frame = target }
        }
    }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown where !Self.usesNativeTitlebarButtons:
            if let key = titlebarButton(at: event) {
                pressedButton = key
                isMovable = false
                return
            }
        case .leftMouseDragged where pressedButton != nil:
            return
        case .leftMouseUp where pressedButton != nil:
            let key = pressedButton
            pressedButton = nil
            // Steht der Zeiger noch auf dem Knopf, bleibt das Fenster fest (onHover gibt es frei)
            isMovable = titlebarButton(at: event) == nil
            // Wie bei jedem Knopf: nur auslösen, wenn der Zeiger noch darauf steht
            if titlebarButton(at: event) == key, let key { Self.titlebarButtons[key]?.action() }
            return
        default:
            break
        }
        super.sendEvent(event)
    }

    private func titlebarButton(at event: NSEvent) -> String? {
        guard let content = contentView else { return nil }
        let point = CGPoint(x: event.locationInWindow.x, y: content.bounds.height - event.locationInWindow.y)
        return Self.titlebarButtons.first { $0.value.frame.contains(point) }?.key
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let step: Int? = switch event.keyCode {
        case 126: -1    // ↑
        case 125: 1     // ↓
        default: nil
        }
        guard let step, modifiers.isEmpty else {
            super.keyDown(with: event)
            return
        }
        SettingsNavigation.shared.move(by: step)
    }
}

/// Welcher Bereich der Einstellungen gezeigt wird
final class SettingsNavigation: ObservableObject {
    static let shared = SettingsNavigation()
    @Published var pane: SettingsPane = .general {
        // Anderer Bereich: Plugins beginnt beim nächsten Mal wieder bei der Liste
        didSet { if pane != oldValue { pluginPage = .list } }
    }
    /// Unterseite von Einstellungen → Plugins (Titelzeile mit Zurück-Knopf)
    @Published var pluginPage: PluginPage = .list {
        didSet { if pluginPage == .list { pluginHistory = [] } }
    }
    /// Woher man kam: „Zurück“ führt dorthin (etwa von einem Plugin zurück zur Galerie)
    private var pluginHistory: [PluginPage] = []

    func openPluginPage(_ page: PluginPage) {
        guard page != pluginPage else { return }
        pluginHistory.append(pluginPage)
        pluginPage = page
    }

    func pluginBack() {
        pluginPage = pluginHistory.popLast() ?? pluginPage.parent
    }

    /// Einen Bereich weiter nach oben oder unten, in der Reihenfolge der Seitenleiste; am
    /// Anfang und Ende bleibt er stehen
    func move(by step: Int) {
        let all = SettingsPane.allCases
        guard let index = all.firstIndex(of: pane) else { return }
        let next = index + step
        guard all.indices.contains(next) else { return }
        pane = all[next]
    }
}

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, opening, appearance, items, actions, plugins, keyboard, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return L("General", "Allgemein")
        case .opening: return L("Opening", "Öffnen")
        case .appearance: return L("Appearance", "Aussehen")
        case .items: return L("Items", "Objekte")
        case .actions: return L("Actions", "Aktionen")
        case .plugins: return L("Plugins", "Plugins")
        case .keyboard: return L("Keyboard", "Tastatur")
        case .about: return L("About BarDrop", "Über BarDrop")
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape.fill"
        case .opening: return "sidebar.right"
        case .appearance: return "paintbrush.fill"
        case .items: return "tray.full.fill"
        case .actions: return "square.grid.2x2.fill"
        case .plugins: return "puzzlepiece.extension.fill"
        case .keyboard: return "command"
        case .about: return "info"
        }
    }

    var tint: Color {
        switch self {
        case .general: return Color(white: 0.55)
        case .opening: return Color(red: 0.2, green: 0.47, blue: 1)
        case .appearance: return Color(red: 0.92, green: 0.3, blue: 0.55)
        case .items: return Color(red: 1, green: 0.58, blue: 0.1)
        case .actions: return Color(red: 0.2, green: 0.78, blue: 0.4)
        case .plugins: return Color(red: 0.0, green: 0.68, blue: 0.82)
        case .keyboard: return Color(red: 0.55, green: 0.35, blue: 0.95)
        case .about: return Color(white: 0.55)
        }
    }
}

/// Farbiges Quadrat mit Symbol, wie in den Systemeinstellungen.
struct PaneIcon: View {
    let pane: SettingsPane
    var size: CGFloat = 22

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(SettingsTheme.iconGradient(pane.tint))
            .overlay(
                Image(systemName: pane.symbol)
                    .font(.system(size: size * 0.52, weight: .semibold))
                    .foregroundStyle(.white)
                    .iconGlyphShadow(size: size)
            )
            .frame(width: size, height: size)
            .iconTileShadow(size: size)
    }
}

struct SettingsRoot: View {
    @ObservedObject var settings: AppSettings
    let store: ShelfStore
    let showOnboarding: () -> Void
    /// Gewählter Bereich; von außen umschaltbar (z. B. nach dem Import eines Plugins)
    @ObservedObject private var navigation: SettingsNavigation

    private var pane: SettingsPane {
        get { navigation.pane }
        nonmutating set { navigation.pane = newValue }
    }

    init(settings: AppSettings, store: ShelfStore, showOnboarding: @escaping () -> Void, pane: SettingsPane? = nil,
         navigation: SettingsNavigation = .shared) {
        self.settings = settings
        self.store = store
        self.showOnboarding = showOnboarding
        self.navigation = navigation
        if let pane { navigation.pane = pane }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 244)
                .frame(maxHeight: .infinity)
                .background(SettingsTheme.sidebarBackdrop)
            Rectangle()
                .fill(SettingsTheme.divider)
                .frame(width: 1)
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(SettingsTheme.contentBackdrop)
        }
        // Füllt das ganze Fenster, auch den Bereich unter der Titelleiste. Eine feste
        // Höhe würde nach oben verschoben und ließe unten einen leeren Streifen frei.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SettingsBackdrop().ignoresSafeArea())
        .ignoresSafeArea()
    }

    // MARK: Seitenleiste

    /// Abstand der Bereiche nach oben: Ab macOS 26 ist die Titelleiste kompakt und die Ampel
    /// 6 pt höher, die Bereiche rücken mit, damit der Abstand zur Ampel gleich bleibt
    private static var sidebarTop: CGFloat {
        if #available(macOS 26.0, *) { return 50 }
        return 56
    }

    private var sidebar: some View {
        ZStack(alignment: .top) {
            Color.clear
            // Alle Bereiche in einer Gruppe, „Über BarDrop“ ganz unten ohne eigene Überschrift
            VStack(alignment: .leading, spacing: 0) {
                row(.general)
                row(.opening)
                row(.appearance)
                row(.items)
                row(.actions)
                row(.plugins)
                row(.keyboard)
                Spacer(minLength: 12)
                row(.about)
            }
            .padding(.horizontal, 13)
            .padding(.top, Self.sidebarTop)
            .padding(.bottom, 13)
        }
    }

    private func row(_ item: SettingsPane) -> some View {
        SidebarRow(item: item, selected: pane == item,
                   badge: item == .about && updateAvailable, beta: item == .plugins) {
            // Nochmals auf den gewählten Bereich: zurück zu seiner Startseite
            if pane == item {
                if navigation.pluginPage != .list {
                    withAnimation(.easeInOut(duration: 0.18)) { navigation.pluginPage = .list }
                }
            } else {
                pane = item
            }
        }
    }

    @ObservedObject private var updater = Updater.shared

    /// Neue Version verfügbar (regulär oder, mit Beta-Versionen, Beta): dezenter Hinweis
    /// an „Über BarDrop“ wie bei Softwareupdate in den Systemeinstellungen
    private var updateAvailable: Bool {
        if case .available = updater.state { return true }
        return false
    }

    // MARK: Inhalt

    @ViewBuilder
    private var detail: some View {
        if #available(macOS 26.0, *) {
            // Wie in Apples Apps: Die Überschrift liegt als Leiste über dem Inhalt, der beim
            // Scrollen unter ihr durchläuft. Das System legt dort seinen Übergang (Liquid Glass)
            // darunter, statt dass der Inhalt an einer harten Kante endet.
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .safeAreaBar(edge: .top, spacing: 0) {
                    // Symbol und Titel mittig in der 50 pt hohen Leiste, etwa auf Höhe der Ampel
                    // (kompakte Titelleiste); schmal, das Glas darunter endet mit ihr
                    headerTitle
                        .padding(.leading, 18)
                        .frame(height: 50)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                header
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var header: some View {
        headerTitle
            .padding(.leading, 18)
            .frame(height: 52)
            .padding(.bottom, 4)
    }

    private var headerTitle: some View {
        Group {
            if pane == .plugins && navigation.pluginPage != .list {
                // Unterseite wie in den Systemeinstellungen: Zurück-Knopf und eigener Titel
                PluginPageHeader(navigation: navigation)
            } else {
                HStack(spacing: 10) {
                    PaneIcon(pane: pane, size: 24)
                    Text(pane.title)
                        .font(.system(size: 17, weight: .semibold))
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch pane {
        case .general: GeneralSettings(settings: settings)
        case .opening: OpeningSettings(settings: settings)
        case .appearance: AppearanceSettings(settings: settings)
        case .items: ItemSettings(settings: settings, store: store)
        case .actions: ActionSettings(settings: settings)
        case .plugins: PluginSettings(settings: settings)
        case .keyboard: KeyboardSettings(settings: settings)
        case .about: AboutSettings(settings: settings, store: store, showOnboarding: showOnboarding)
        }
    }
}

/// Eintrag der Seitenleiste: hell hinterlegt, wenn gewählt, dezent beim Darüberfahren.
private struct SidebarRow: View {
    let item: SettingsPane
    let selected: Bool
    /// Rote Plakette wie in den Systemeinstellungen (Update verfügbar)
    var badge = false
    /// Kennzeichen „BETA“ hinter dem Namen (Bereich noch in Erprobung)
    var beta = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                PaneIcon(pane: item)
                Text(item.title)
                    .font(.system(size: 14))
                    .foregroundStyle(.primary)
                if beta { BetaBadge() }
                Spacer(minLength: 0)
                if badge {
                    Text("1")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(minWidth: 18, minHeight: 18)
                        .background(Circle().fill(Color(nsColor: .systemRed)))
                        .accessibilityLabel(L("Update available", "Update verfügbar"))
                        .help(L("Update available", "Update verfügbar"))
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 42)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? SettingsTheme.selectedRow : Color.primary.opacity(hovering ? 0.04 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// Ruhige graue Kapsel mit „BETA“, mittig zur Zeile (kein harter Kontrast)
struct BetaBadge: View {
    var body: some View {
        Text("BETA")
            .font(.system(size: 9, weight: .bold))
            .tracking(0.4)
            .foregroundStyle(Color.primary.opacity(0.62))
            .padding(.horizontal, 5.5)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.primary.opacity(0.10)))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
            // Mittig wirkt die Kapsel erst auf der Mitte der Kleinbuchstaben des Namens daneben,
            // nicht auf der Mitte der Zeile (die liegt auf Höhe der Großbuchstaben): gemessen
            // an „Plugins“ 1,5 pt tiefer, 1 pt gleicht die Großbuchstaben mit aus
            .offset(y: 1)
            .accessibilityLabel("Beta")
    }
}

// MARK: Über BarDrop

struct AboutSettings: View {
    @ObservedObject var settings: AppSettings
    var store: ShelfStore? = nil
    @ObservedObject private var updater = Updater.shared
    let showOnboarding: () -> Void

    /// Diagnoseprotokoll ein: erst nach dem Hinweis, was erfasst wird
    private var diagnostics: Binding<Bool> {
        Binding(get: { settings.diagnosticsEnabled },
                set: { on in
                    if on {
                        guard Self.confirmDiagnostics() else { return }
                        settings.diagnosticsEnabled = true
                        Diagnostics.shared.record("app", "Diagnoseprotokoll eingeschaltet")
                    } else {
                        settings.diagnosticsEnabled = false
                        Diagnostics.shared.clear()
                    }
                })
    }

    static func confirmDiagnostics() -> Bool {
        let alert = NSAlert()
        alert.messageText = L("Turn on the diagnostic log?", "Diagnoseprotokoll einschalten?")
        alert.informativeText = L("BarDrop will record in detail what happens in the app: drops, previews, the shelf at the edge, keyboard focus, actions, the introduction and errors. It also records your settings, Mac model and macOS version. File and folder names, paths and contents aren’t recorded; files appear only as an anonymous code with their type. The log stays on this Mac and is never sent. “Save Log” creates a text file you can share yourself, for example to report a bug.",
                                  "BarDrop hält dann ausführlich fest, was in der App passiert: Ablegen, Vorschaubilder, die Ablage am Rand, Tastaturfokus, Aktionen, die Einführung und Fehler, dazu deine Einstellungen sowie Mac-Modell und macOS-Version. Datei- und Ordnernamen, Pfade und Inhalte werden nicht erfasst; Dateien erscheinen nur als anonyme Kennung mit ihrem Typ. Das Protokoll bleibt auf diesem Mac und wird nie verschickt. Mit „Protokoll sichern“ entsteht eine Textdatei, die du selbst weitergeben kannst, etwa um einen Fehler zu melden.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("Turn On", "Einschalten"))
        alert.addButton(withTitle: L("Cancel", "Abbrechen"))
        alert.icon = NSApp.applicationIconImage
        return alert.runModal() == .alertFirstButtonReturn
    }

    private var version: String {
        Updater.shared.currentVersion
    }

    /// Commit, aus dem die App gebaut ist (build_app.sh trägt ihn ein); nil ohne Angabe
    static var commit: String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "BarDropCommit") as? String,
              !value.isEmpty, !value.hasPrefix("__") else { return nil }
        return value
    }

    /// „1.29.0-beta.2“ lesbar als „1.29.0 Beta 2“
    static func readable(_ version: String) -> String {
        version.replacingOccurrences(of: "-beta.", with: " Beta ")
    }

    /// Info zur Zeile „Softwareupdate“ nur, wenn es etwas zu erklären gibt (Nutzer: Info-Knöpfe
    /// nur, wo man sie braucht)
    private var updateNote: String? {
        switch updater.state {
        case .available(let v):
            // Von selbst nur mit „Automatisch aktualisieren“ und erst zwei Tage nach dem Erscheinen
            guard settings.autoUpdateCheck else {
                return L("Version \(Self.readable(v)) is available. Your items stay in the shelf when you update.",
                         "Version \(Self.readable(v)) ist verfügbar. Beim Aktualisieren bleiben die Objekte in der Ablage.")
            }
            return L("Version \(Self.readable(v)) is available. Two days after its release, BarDrop installs it once you haven’t used it for 15 minutes. You can also update now. Your items stay in the shelf.",
                     "Version \(Self.readable(v)) ist verfügbar. Zwei Tage nach dem Erscheinen installiert BarDrop sie, sobald du es 15 Minuten nicht benutzt. Du kannst auch gleich aktualisieren. Die Objekte bleiben in der Ablage.")
        // Feste Meldung statt der gespeicherten: bleibt in der gewählten Sprache
        case .failed: return L("The update didn’t work. Try again later.",
                               "Das Update hat nicht geklappt. Versuch es später noch einmal.")
        default: return nil
        }
    }

    /// Kurzer Stand für die Zeile „Softwareupdate“
    private var updateStatus: String {
        switch updater.state {
        case .upToDate: return L("Up to date", "Aktuell")
        case .available(let v): return L("\(Self.readable(v)) available", "\(Self.readable(v)) verfügbar")
        case .failed: return L("Update failed", "Update fehlgeschlagen")
        default: return L("Updates", "Updates")
        }
    }

    @State private var showInspirations = false

    var body: some View {
        SettingsPage {
            SettingsSection(L("Software update", "Softwareupdate")) {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                        .resizable()
                        .frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("BarDrop")
                            .font(.system(size: 15, weight: .semibold))
                        HStack(spacing: 5) {
                            Text(L("Version \(Self.readable(version))", "Version \(Self.readable(version))"))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .fixedSize()
                            ReleaseNotesButton()
                        }
                        // Bei Beta-Versionen: aus welchem Commit diese App gebaut ist
                        if settings.betaUpdates, let commit = Self.commit {
                            Text("Commit \(commit)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .textSelection(.enabled)
                                .lineLimit(1)
                                .fixedSize()
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, SettingsTheme.rowPadding)
                .padding(.vertical, 12)
                // Eigene Zeile, damit weder Version noch Knopf je gekürzt werden. Der Stand steht
                // als Titel, die Erklärung im Info-Knopf (vorher grauer Text unter der Karte)
                SettingsRow(updateStatus, info: updateNote) {
                    updateControl.fixedSize()
                }
                ToggleRow(L("Update automatically", "Automatisch aktualisieren"),
                          info: L("New versions are installed in the background two days after their release, once BarDrop hasn’t been used for 15 minutes.",
                                  "Neue Versionen werden zwei Tage nach dem Erscheinen im Hintergrund installiert, sobald BarDrop 15 Minuten nicht benutzt wurde."),
                          isOn: $settings.autoUpdateCheck)
                ToggleRow(L("Beta versions", "Beta-Versionen"), isOn: $settings.betaUpdates)
                if settings.betaUpdates {
                    ToggleRow(L("Diagnostic log", "Diagnoseprotokoll"),
                              info: L("Records in detail and anonymously what happens in BarDrop, to help find bugs. Stays on this Mac until you save it.",
                                      "Hält ausführlich und anonym fest, was in BarDrop passiert, um Fehler zu finden. Bleibt auf diesem Mac, bis du es sicherst."),
                              isOn: diagnostics)
                    if settings.diagnosticsEnabled {
                        SettingsRow(L("Log file", "Protokolldatei")) {
                            Button(L("Save Log", "Protokoll sichern")) { Diagnostics.shared.saveReport(store: store) }
                                .buttonStyle(KlackButtonStyle())
                        }
                    }
                }
            }

            SettingsSection(L("Credits", "Dank und Quellen")) {
                // Eingeklappt: nur die Namen. Ein Klick klappt die Einträge mit Links auf.
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { showInspirations.toggle() }
                } label: {
                    SettingsRow(L("Inspired by", "Inspiriert von")) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(showInspirations ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if showInspirations {
                    LinkRow(title: "Alcove", detail: L("Inspiration for the shape and motion of the shelf", "Vorbild für Form und Bewegung der Ablage"),
                            url: "https://tryalcove.com")
                    LinkRow(title: "Klack", detail: L("Inspiration for the layout and design of the settings", "Vorbild für Aufbau und Gestaltung der Einstellungen"),
                            url: "https://tryklack.com")
                    LinkRow(title: "boring.notch", detail: L("Code for web images and thumbnails", "Code für Bilder aus dem Web und Vorschaubilder"),
                            url: "https://github.com/TheBoredTeam/boring.notch")
                    LinkRow(title: "perch", detail: L("Code for dragging out and iCloud files", "Code für Herausziehen und iCloud-Dateien"),
                            url: "https://github.com/hausfold/perch")
                }
                LinkRow(title: L("Source code", "Quellcode"), detail: "github.com/zzuuuiii/BarDrop",
                        url: "https://github.com/zzuuuiii/BarDrop")
            }

            SettingsSection(L("Help", "Hilfe")) {
                SettingsRow(L("Introduction", "Einführung")) {
                    Button(L("Show", "Zeigen"), action: showOnboarding)
                        .buttonStyle(KlackButtonStyle())
                }
            }
        }
    }

    /// Knopf oben rechts: suchen, Fortschritt oder installieren
    @ViewBuilder
    private var updateControl: some View {
        switch updater.state {
        case .checking:
            ProgressView().controlSize(.small)
        case .installing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(L("Installing", "Wird installiert")).foregroundStyle(.secondary)
            }
        case .available(let v):
            // Kurz, damit es neben Symbol und Version passt; die Version steht darunter
            Button(L("Update", "Aktualisieren")) { updater.install() }
                .help(L("Update to \(Self.readable(v))", "Auf \(Self.readable(v)) aktualisieren"))
                .buttonStyle(KlackButtonStyle(prominent: true))
        default:
            Button(L("Check for Updates", "Nach Updates suchen")) { updater.check(interactive: true) }
                .buttonStyle(KlackButtonStyle())
        }
    }
}

private struct LinkRow: View {
    let title: String
    let detail: String
    let url: String

    var body: some View {
        // Info-Knopf nur, wo man ihn braucht (Nutzer): hier reicht der Name, was das Projekt
        // beigetragen hat, steht beim Darüberfahren
        SettingsRow(title) {
            Link(destination: URL(string: url)!) {
                Image(systemName: "arrow.up.right.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }
            .help(detail)
        }
    }
}

// MARK: Kurzbefehl

/// Meldet, ob der globale Kurzbefehl registriert werden konnte.
final class HotKeyStatus: ObservableObject {
    static let shared = HotKeyStatus()
    @Published var available = true
}

/// Tasten wie auf der Tastatur: Sondertasten antippen schaltet sie an oder ab,
/// ein Klick auf die letzte Taste wartet auf eine neue.
struct HotKeyEditor: View {
    @ObservedObject var settings: AppSettings
    @State private var recording = false
    @State private var monitor: Any?

    private struct Modifier {
        let flag: Int
        let symbol: String
        let name: String
    }

    private let modifiers: [Modifier] = [
        Modifier(flag: shiftKey, symbol: "⇧", name: "shift"),
        Modifier(flag: controlKey, symbol: "⌃", name: "ctrl"),
        Modifier(flag: optionKey, symbol: "⌥", name: "opt"),
        Modifier(flag: cmdKey, symbol: "⌘", name: "cmd")
    ]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(modifiers, id: \.flag) { mod in
                let on = settings.hotKeyModifiers & mod.flag != 0
                SettingsKeyCap(symbol: mod.symbol, name: mod.name, active: on, wide: false) {
                    toggle(mod.flag)
                }
            }
            SettingsKeyCap(symbol: recording ? "…" : settings.hotKeyLabel, name: recording ? L("key", "Taste") : "",
                           active: true, wide: true, highlighted: recording) {
                recording ? stopRecording() : startRecording()
            }
        }
        .onDisappear { stopRecording() }
    }

    private func toggle(_ flag: Int) {
        let new = settings.hotKeyModifiers ^ flag
        // Mindestens eine Sondertaste, sonst würde eine einfache Taste überall abgefangen
        guard new & (controlKey | optionKey | cmdKey | shiftKey) != 0, new != shiftKey else {
            NSSound.beep()
            return
        }
        // Kein zusätzlicher Impuls: Der Klick auf dem Trackpad ist schon der eine Impuls
        settings.hotKeyModifiers = new
    }

    private func startRecording() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {               // esc: abbrechen
                stopRecording()
                return nil
            }
            settings.hotKeyCode = Int(event.keyCode)
            settings.hotKeyLabel = Self.label(for: event)
            Haptics.tap()   // per Taste aufgenommen: kein Klick, daher ein leichter Impuls
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    static func label(for event: NSEvent) -> String {
        if let special = specialKeys[Int(event.keyCode)] { return special }
        let chars = event.charactersIgnoringModifiers?.uppercased() ?? ""
        // Tasten ohne druckbares Zeichen (Funktionstasten liefern Zeichen aus dem
        // privaten Bereich von Unicode, die nicht darstellbar sind)
        let printable = chars.unicodeScalars.allSatisfy { !(0xF700...0xF8FF).contains($0.value) && !CharacterSet.controlCharacters.contains($0) }
        return chars.isEmpty || !printable ? "#\(event.keyCode)" : chars
    }

    private static let specialKeys: [Int: String] = [
        49: "␣", 36: "↩", 76: "⌤", 48: "⇥", 51: "⌫", 117: "⌦",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20"
    ]
}

/// Taste wie bei Klack: dunkel eingelassen, Symbol oben, Name unten.
/// Aktive Tasten sind dunkler und hell beschriftet, inaktive blass.
private struct SettingsKeyCap: View {
    let symbol: String
    let name: String
    let active: Bool
    let wide: Bool
    var highlighted = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                if wide && name.isEmpty {
                    Text(symbol)
                        .font(.system(size: 17, weight: .medium))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Text(symbol).font(.system(size: 14, weight: .medium))
                    Spacer(minLength: 0)
                    Text(name).font(.system(size: 13, weight: .medium))
                }
            }
            .foregroundStyle(active ? Color.primary : Color.secondary.opacity(0.7))
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: wide ? 62 : .infinity, alignment: .leading)
            .frame(width: wide ? 62 : nil, height: 60)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(highlighted ? Color.accentColor.opacity(0.3)
                          : active ? SettingsTheme.keyActive : hovering ? SettingsTheme.keyHover : SettingsTheme.keyInactive)
                    .shadow(color: active ? SettingsTheme.controlShadow : .clear, radius: 0.5, y: 0.5)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(active ? SettingsTheme.keyBorder : SettingsTheme.keyBorderInactive, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: active)
    }
}
