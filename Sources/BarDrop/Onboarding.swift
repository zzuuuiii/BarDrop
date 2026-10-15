import AppKit
import SwiftUI
import Combine
import ServiceManagement
import Carbon

// MARK: Ablauf

/// Einführung beim ersten Start, aufgebaut wie die Einstellungen: links die Schritte,
/// rechts der jeweilige Inhalt in Karten. Drei Schritte zum Mitmachen (ablegen,
/// zurückholen, Kurzbefehl) erkennen von selbst, wann sie geschafft sind, und haken
/// sich in der Seitenleiste ab. Zum Schluss eine Übersicht, was BarDrop sonst kann.
final class OnboardingModel: ObservableObject {
    enum Step: Int, CaseIterable, Identifiable {
        case welcome, drop, retrieve, shortcut, features
        var id: Int { rawValue }
    }

    @Published private(set) var step: Step = .welcome
    /// Geschaffte Schritte (Häkchen in der Seitenleiste)
    @Published private(set) var completed: Set<Step> = []
    @Published var launchAtLogin = true

    let settings: AppSettings
    let sampleURL: URL?
    var onFinish: (_ completed: Bool) -> Void = { _ in }
    /// Ziehen der Beispieldatei hat begonnen: Die Ablage muss davon erfahren, denn
    /// Ziehen aus dem eigenen Fenster melden die Ereignisse des Systems nicht.
    var onSampleDragStarted: () -> Void = {}

    init(settings: AppSettings, sampleURL: URL?) {
        self.settings = settings
        self.sampleURL = sampleURL
    }

    /// Schritte zum Mitmachen
    static let practice: [Step] = [.drop, .retrieve, .shortcut]

    /// Der aktuelle Schritt ist geschafft
    var stepDone: Bool { completed.contains(step) }

    func go(to step: Step) {
        withAnimation(.easeOut(duration: 0.18)) { self.step = step }
    }

    func advance() {
        guard let next = Step(rawValue: step.rawValue + 1) else {
            onFinish(true)
            return
        }
        go(to: next)
    }

    /// Ein Schritt wurde gemacht: abhaken, kurz stehen lassen, weiter.
    func complete(_ done: Step) {
        guard step == done, !completed.contains(done) else { return }
        Haptics.tap()
        withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) { _ = completed.insert(done) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self, self.step == done else { return }
            self.advance()
        }
    }
}

final class OnboardingController: NSObject, NSWindowDelegate {
    private let store: ShelfStore
    private let ui: ShelfUIModel
    private let settings: AppSettings
    private let model: OnboardingModel
    private var window: NSWindow?
    private var subscriptions: Set<AnyCancellable> = []

    /// Einträge vor dem Schritt „Ablegen“
    private var baseline: Set<UUID> = []
    /// Einträge mit der Beispieldatei: werden am Ende wieder entfernt
    private var sampleEntries: Set<UUID> = []
    private var finished = false

    /// Wird nach dem Schließen aufgerufen, damit der Besitzer loslassen kann.
    var onClose: () -> Void = {}
    /// Öffnet am Ende auf Wunsch die Einstellungen.
    var openSettings: () -> Void = {}
    /// Weckt die Ablage, damit sie das Ziehen der Beispieldatei bemerkt.
    var wakeShelf: () -> Void = {} {
        didSet { model.onSampleDragStarted = wakeShelf }
    }

    var isVisible: Bool { window?.isVisible == true }

    init(store: ShelfStore, ui: ShelfUIModel, settings: AppSettings) {
        self.store = store
        self.ui = ui
        self.settings = settings
        self.model = OnboardingModel(settings: settings, sampleURL: Self.makeSample())
        super.init()
        model.onFinish = { [weak self] completed in self?.finish(completed: completed) }
        observe()
    }

    func show() {
        if window == nil { window = makeWindow() }
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    /// Der globale Kurzbefehl wurde gedrückt.
    func hotKeyPressed() {
        model.complete(.shortcut)
    }

    // MARK: Erkennen, dass ein Schritt geschafft ist

    private func observe() {
        model.$step
            .sink { [weak self] step in self?.prepare(step) }
            .store(in: &subscriptions)

        store.$entries
            .receive(on: RunLoop.main)
            .sink { [weak self] entries in self?.entriesChanged(entries) }
            .store(in: &subscriptions)

    }

    private func prepare(_ step: OnboardingModel.Step) {
        switch step {
        case .drop:
            baseline = Set(store.entries.map(\.id))
        default:
            break
        }
    }

    private func entriesChanged(_ entries: [ShelfEntry]) {
        let name = model.sampleURL?.lastPathComponent
        for entry in entries where entry.files.contains(where: { $0.url.lastPathComponent == name }) {
            if !baseline.contains(entry.id) { sampleEntries.insert(entry.id) }
        }
        guard model.step == .drop else { return }
        if entries.contains(where: { !baseline.contains($0.id) }) {
            model.complete(.drop)
        }
    }

    // MARK: Ende

    private func finish(completed: Bool) {
        guard !finished else { return }
        finished = true
        settings.didLaunchBefore = true
        // Die Beispieldatei hat ihren Zweck erfüllt
        let leftovers = sampleEntries.intersection(Set(store.entries.map(\.id)))
        if !leftovers.isEmpty { store.discard(leftovers) }
        if let url = model.sampleURL { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        if completed && model.launchAtLogin && SMAppService.mainApp.status != .enabled {
            do {
                try SMAppService.mainApp.register()
            } catch {
                Log.edge.error("Anmeldeobjekt nicht möglich: \(error.localizedDescription, privacy: .public)")
            }
        }
        subscriptions.removeAll()
        window?.delegate = nil
        window?.close()
        window = nil
        onClose()
    }

    func windowWillClose(_ notification: Notification) {
        // Mit dem Schließknopf beendet: gilt als erledigt, nichts wird nachgefragt
        DispatchQueue.main.async { [weak self] in self?.finish(completed: false) }
    }

    // MARK: Fenster

    static let size = NSSize(width: 520, height: 580)

    /// Fenster wie die Einstellungen: durchscheinend, hohe Titelleiste, Ampel auf Höhe
    /// der Überschrift
    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.size),
                              styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.toolbar = NSToolbar(identifier: "BarDropIntroduction")
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .none
        window.title = L("Welcome to BarDrop", "Willkommen bei BarDrop")
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .floating
        window.collectionBehavior = [.moveToActiveSpace]
        window.standardWindowButton(.zoomButton)?.isHidden = false
        window.delegate = self
        let root = OnboardingView(model: model, openSettings: { [weak self] in
            self?.openSettings()
        })
        window.contentView = NSHostingView(rootView: root)
        window.setContentSize(Self.size)
        return window
    }

    /// Beispielbild zum Ablegen. Liegt in einem temporären Ordner und wird beim
    /// Ablegen wie ein Bild aus dem Web in die Ablage kopiert.
    static func makeSample() -> URL? {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BarDropEinfuehrung-\(UUID().uuidString)", isDirectory: true)
        let url = dir.appendingPathComponent(L("Welcome to BarDrop.png", "Willkommen bei BarDrop.png"))
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        let side: CGFloat = 512
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let card = NSBezierPath(roundedRect: rect, xRadius: side * 0.22, yRadius: side * 0.22)
            NSGradient(colors: [NSColor(white: 0.24, alpha: 1), NSColor(white: 0.03, alpha: 1)])?
                .draw(in: card, angle: -90)
            NSColor(white: 1, alpha: 0.12).setStroke()
            card.lineWidth = 4
            card.stroke()
            if let icon = NSApp.applicationIconImage {
                icon.draw(in: rect.insetBy(dx: side * 0.2, dy: side * 0.2))
            }
            return true
        }
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]),
              (try? png.write(to: url)) != nil else { return nil }
        return url
    }
}

// MARK: Oberfläche

extension OnboardingModel.Step {
    var title: String {
        switch self {
        case .welcome: return L("Welcome", "Willkommen")
        case .drop: return L("Drop", "Ablegen")
        case .retrieve: return L("Get back", "Zurückholen")
        case .shortcut: return L("Shortcut", "Kurzbefehl")
        case .features: return L("Discover more", "Mehr entdecken")
        }
    }

    var symbol: String {
        switch self {
        case .welcome: return "hand.wave.fill"
        case .drop: return "tray.and.arrow.down.fill"
        case .retrieve: return "tray.and.arrow.up.fill"
        case .shortcut: return "command"
        case .features: return "sparkles"
        }
    }

    /// Farben wie die Symbole der Einstellungen
    var tint: Color {
        switch self {
        case .welcome: return Color(white: 0.55)
        case .drop: return Color(red: 0.2, green: 0.5, blue: 1.0)
        case .retrieve: return Color(red: 0.95, green: 0.55, blue: 0.15)
        case .shortcut: return Color(red: 0.55, green: 0.35, blue: 0.95)
        case .features: return Color(red: 0.92, green: 0.3, blue: 0.55)
        }
    }
}

/// Farbiges Symbol wie in der Seitenleiste der Einstellungen
private struct StepIcon: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 22

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(LinearGradient(colors: [tint.opacity(0.85), tint], startPoint: .top, endPoint: .bottom))
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
            )
            .frame(width: size, height: size)
    }
}

struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    /// Sprache umschalten aktualisiert alle Texte sofort
    @ObservedObject private var settings = AppSettings.shared
    var openSettings: () -> Void

    /// Eine Spalte, Schritt für Schritt: oben, worum es geht, in der Mitte die Karten
    /// wie in den Einstellungen, unten die Punkte und ein Knopf zum Weitergehen
    var body: some View {
        detail
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(SettingsTheme.content.opacity(SettingsTheme.backdropOpacity))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SettingsBackdrop().ignoresSafeArea())
        .ignoresSafeArea()
    }

    // MARK: Inhalt

    private var detail: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                StepIcon(symbol: model.step.symbol, tint: model.step.tint, size: 24)
                Text(model.step.title)
                    .font(.system(size: 17, weight: .semibold))
            }
            // Neben der Ampel, wie die Überschrift in den Einstellungen
            .padding(.leading, 84)
            .frame(height: 52)
            .padding(.bottom, 4)

            SettingsPage {
                content
            }
            .id(model.step)
            .transition(.opacity)

            footer
                .padding(.horizontal, 20)
                .padding(.bottom, 18)
                .padding(.top, 6)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.step {
        case .welcome: welcome
        case .drop: dropStep
        case .retrieve: retrieveStep
        case .shortcut: shortcutStep
        case .features: FeaturesList(settings: model.settings)
        }
    }

    // MARK: Willkommen

    private var welcome: some View {
        Group {
            SettingsCard {
                HStack(spacing: 16) {
                    Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("BarDrop")
                            .font(.system(size: 17, weight: .semibold))
                        Text(L("A place for files at the edge of your screen. Drag something there and it stays at hand until you need it.",
                               "Ein Platz für Dateien am Rand deines Bildschirms. Zieh etwas dorthin, und es bleibt griffbereit, bis du es brauchst."))
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(16)
            }

            SettingsSection(L("Before you start", "Bevor es losgeht"),
                            note: L("Next, try it out in three short steps.",
                                    "Danach probierst du es in drei kurzen Schritten aus.")) {
                PickerRow(L("Language", "Sprache"), selection: $settings.language,
                          options: AppLanguage.allCases.map { ($0, $0.title) })
                ToggleRow(L("Open at login", "Beim Anmelden öffnen"), isOn: $model.launchAtLogin)
            }
        }
    }

    // MARK: Mitmachen

    private var edgeWord: String {
        model.settings.edge == .right ? L("right", "rechten") : L("left", "linken")
    }

    private var dropStep: some View {
        practice(
            instruction: L("Drag the image to the \(edgeWord) edge of the screen. As soon as the shelf opens, let go.",
                           "Zieh das Bild an den \(edgeWord) Bildschirmrand. Sobald sich die Ablage öffnet, lass es los."),
            done: L("The image is now in the shelf.", "Das Bild liegt jetzt in der Ablage.")
        ) {
            SampleCard(url: model.sampleURL, edge: model.settings.edge,
                       onDragStarted: model.onSampleDragStarted)
                .opacity(model.stepDone ? 0.35 : 1)
        }
    }

    private var retrieveStep: some View {
        let s = model.settings
        let open: String
        if s.openMode == .click {
            open = L(" and click the strip", " und klick auf den Streifen")
        } else if s.openDelay >= AppSettings.clickToOpenMinDelay - 0.01 {
            open = L(" and wait a moment or click the strip", " und warte kurz oder klick auf den Streifen")
        } else {
            open = ""
        }
        // „etwa auf halber Höhe“ als Einschub: das Komma danach nur, wenn noch etwas folgt
        let middle = s.adaptiveZoneFraction != nil
            ? L(" around the middle", open.isEmpty ? ", etwa auf halber Höhe" : ", etwa auf halber Höhe,") : ""
        let gone = s.removeAfterDragOut ? L(" Afterwards it leaves the shelf.", " Danach verschwindet es aus der Ablage.") : ""
        return practice(
            instruction: L("Move the pointer to the \(edgeWord) edge\(middle)\(open). When the shelf opens, drag the image back here.",
                           "Fahr mit dem Zeiger an den \(edgeWord) Rand\(middle)\(open). Wenn sich die Ablage öffnet, zieh das Bild hierher zurück."),
            done: L("That’s how you use anything in the shelf: drag it out into any app.",
                    "So verwendest du alles aus der Ablage: einfach in eine App herausziehen.") + gone
        ) {
            ReturnDropZone(url: model.sampleURL, done: model.stepDone) {
                model.complete(.retrieve)
            }
        }
    }

    private var shortcutStep: some View {
        practice(
            instruction: L("Press \(model.settings.hotKeyDescription) to open the shelf from anywhere, even without a mouse.",
                           "Drück \(model.settings.hotKeyDescription), um die Ablage von überall zu öffnen, auch ohne Maus."),
            done: L("The same shortcut closes it again. You can change it in Settings → Keyboard.",
                    "Derselbe Kurzbefehl schließt sie wieder. Ändern kannst du ihn unter Einstellungen → Tastatur.")
        ) {
            ShortcutKeys(settings: model.settings, pressed: model.stepDone)
        }
    }

    /// Aufbau aller Schritte zum Mitmachen: Anleitung, eine Karte zum Ausprobieren,
    /// darunter, sobald geschafft, eine Bestätigung
    private func practice<Stage: View>(instruction: String, done: String,
                                       @ViewBuilder stage: () -> Stage) -> some View {
        SettingsSection(L("Try it", "Ausprobieren"),
                        note: model.stepDone ? nil : instruction) {
            stage()
                .frame(maxWidth: .infinity)
                .frame(height: 220)
            if model.stepDone {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.white, .green)
                    Text(done)
                        .font(.system(size: 13))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, SettingsTheme.rowPadding)
                .padding(.vertical, 12)
                .transition(.opacity)
            }
        }
    }

    // MARK: Unten

    private var footer: some View {
        HStack(spacing: 10) {
            StepDots(current: model.step)
            Spacer()
            switch model.step {
            case .welcome:
                Button(L("Skip Introduction", "Einführung überspringen")) { model.onFinish(false) }
                    .buttonStyle(KlackButtonStyle())
                Button(L("Let’s go", "Los geht’s")) { model.advance() }
                    .buttonStyle(KlackButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
            case .features:
                Button(L("Open Settings", "Einstellungen öffnen")) {
                    openSettings()
                    model.advance()
                }
                .buttonStyle(KlackButtonStyle())
                Button(L("Done", "Fertig")) { model.advance() }
                    .buttonStyle(KlackButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
            default:
                Button(model.stepDone ? L("Continue", "Weiter") : L("Skip", "Überspringen")) { model.advance() }
                    .buttonStyle(KlackButtonStyle(prominent: model.stepDone))
                    .keyboardShortcut(model.stepDone ? .defaultAction : .cancelAction)
            }
        }
    }
}

/// Wie weit man ist: ein Punkt je Schritt, der aktuelle länglich
private struct StepDots: View {
    let current: OnboardingModel.Step

    var body: some View {
        HStack(spacing: 6) {
            ForEach(OnboardingModel.Step.allCases) { step in
                Capsule()
                    .fill(step == current ? Color(nsColor: .controlAccentColor)
                          : Color.secondary.opacity(step.rawValue < current.rawValue ? 0.55 : 0.25))
                    .frame(width: step == current ? 16 : 6, height: 6)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: current)
        .accessibilityElement()
        .accessibilityLabel(L("Step \(current.rawValue + 1) of \(OnboardingModel.Step.allCases.count)",
                              "Schritt \(current.rawValue + 1) von \(OnboardingModel.Step.allCases.count)"))
    }
}

/// Häkchen auf dem zurückgeholten Bild
private struct CheckBadge: View {
    @State private var shown = false

    var body: some View {
        Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 84, weight: .regular))
            .foregroundStyle(.white, .green)
            .scaleEffect(shown ? 1 : 0.5)
            .opacity(shown ? 1 : 0)
            .onAppear {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.6).delay(0.05)) { shown = true }
            }
    }
}

/// Die Tasten des Kurzbefehls im Stil der Tasten unter Einstellungen → Tastatur
private struct ShortcutKeys: View {
    let settings: AppSettings
    let pressed: Bool

    private var keys: [(String, String)] {
        let m = settings.hotKeyModifiers
        var keys: [(String, String)] = []
        if m & shiftKey != 0 { keys.append(("⇧", "shift")) }
        if m & controlKey != 0 { keys.append(("⌃", "ctrl")) }
        if m & optionKey != 0 { keys.append(("⌥", "opt")) }
        if m & cmdKey != 0 { keys.append(("⌘", "cmd")) }
        keys.append((settings.hotKeyLabel, ""))
        return keys
    }

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                VStack(alignment: .leading, spacing: 0) {
                    if key.1.isEmpty {
                        Text(key.0)
                            .font(.system(size: 22, weight: .medium))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        Text(key.0).font(.system(size: 17, weight: .medium))
                        Spacer(minLength: 0)
                        Text(key.1).font(.system(size: 14, weight: .medium))
                    }
                }
                .foregroundStyle(pressed ? Color.white : Color.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(width: 76, height: 76, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(pressed ? Color.accentColor : Color.black.opacity(0.42))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
                )
                .scaleEffect(pressed ? 0.96 : 1)
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: pressed)
    }
}

// MARK: Mehr entdecken

/// Was BarDrop sonst kann, als Karten wie in den Einstellungen. Zeigt nur, was
/// gerade eingeschaltet ist, und sagt jeweils, wo man es findet.
private struct FeaturesList: View {
    let settings: AppSettings

    private struct Feature: Identifiable {
        let id: String
        let symbol: String
        let tint: Color
        let title: String
        let text: String
    }

    private var everyday: [Feature] {
        var list = [
            Feature(id: "actions", symbol: "paperplane.fill", tint: Color(red: 0.2, green: 0.55, blue: 1.0),
                    title: L("Actions", "Aktionen"),
                    text: L("Drag items onto AirDrop, a folder or the Trash at the bottom of the shelf.",
                            "Zieh Objekte unten in der Ablage auf AirDrop, einen Ordner oder den Papierkorb.")),
            Feature(id: "look", symbol: "eye.fill", tint: Color(red: 0.55, green: 0.4, blue: 0.95),
                    title: L("Quick Look", "Übersicht"),
                    text: L("Select an item and press Space for a preview.",
                            "Wähl ein Objekt aus und drück die Leertaste für eine Vorschau.")),
            Feature(id: "undo", symbol: "arrow.uturn.backward", tint: Color(white: 0.5),
                    title: L("Undo", "Widerrufen"),
                    text: L("Removed something by mistake? ⌘Z brings it back.",
                            "Versehentlich entfernt? ⌘Z holt es zurück."))
        ]
        if settings.stackMultiple {
            list.append(Feature(id: "stack", symbol: "square.stack.fill", tint: Color(red: 0.3, green: 0.7, blue: 0.75),
                                title: L("Stacks", "Stapel"),
                                text: L("Several files dropped at once land together in a stack.",
                                        "Mehrere Dateien auf einmal landen zusammen in einem Stapel.")))
        }
        return list
    }

    private var more: [Feature] {
        var list = [
            Feature(id: "convert", symbol: "arrow.triangle.2.circlepath", tint: Color(red: 0.3, green: 0.75, blue: 0.4),
                    title: L("Convert", "Umwandeln"),
                    text: L("Right-click an item to turn images into JPEG or PDF, resize them and more.",
                            "Rechtsklick auf ein Objekt, um Bilder in JPEG oder PDF umzuwandeln, zu verkleinern und mehr."))
        ]
        if settings.pinFromShelf {
            list.append(Feature(id: "pin", symbol: "pin.fill", tint: Color(red: 0.95, green: 0.6, blue: 0.1),
                                title: L("Pin folders and apps", "Ordner und Apps anheften"),
                                text: L("Drag one over the shelf and drop it on “Pin” at the end of the action bar.",
                                        "Zieh sie über die Ablage und lass sie auf „Anheften“ am Ende der Aktionsleiste los.")))
        }
        list.append(Feature(id: "settings", symbol: "gearshape.fill", tint: Color(white: 0.55),
                            title: L("Settings", "Einstellungen"),
                            text: L("Right-click an empty spot in the shelf, press ⌘, there, or simply open BarDrop again.",
                                    "Rechtsklick auf eine leere Stelle der Ablage, dort ⌘, drücken oder BarDrop einfach noch einmal öffnen.")))
        return list
    }

    var body: some View {
        Group {
            SettingsSection(L("Every day", "Im Alltag")) {
                ForEach(everyday) { row($0) }
            }
            SettingsSection(L("When you need it", "Wenn du es brauchst"),
                            note: L("You can find this introduction again in Settings → About BarDrop.",
                                    "Diese Einführung findest du jederzeit unter Einstellungen → Über BarDrop.")) {
                ForEach(more) { row($0) }
            }
        }
    }

    private func row(_ feature: Feature) -> some View {
        HStack(spacing: 12) {
            StepIcon(symbol: feature.symbol, tint: feature.tint, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(feature.title)
                    .font(.system(size: 13.5))
                Text(feature.text)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, SettingsTheme.rowPadding)
        .padding(.vertical, 10)
    }
}

// MARK: Bausteine zum Mitmachen

/// Echtes Bild zum Herausziehen, mit Pfeilen in Richtung Rand.
private struct SampleCard: View {
    let url: URL?
    let edge: ScreenEdge
    var onDragStarted: () -> Void = {}

    var body: some View {
        HStack(spacing: 22) {
            if edge == .left { arrows }
            VStack(spacing: 10) {
                preview
                    .frame(width: 108, height: 108)
                    .shadow(color: .black.opacity(0.25), radius: 10, y: 6)
                Text(url?.lastPathComponent ?? L("Image", "Bild"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .overlay(
                Group {
                    if let url { SampleDragArea(url: url, onDragStarted: onDragStarted) }
                }
            )
            .help(L("Drag to the edge", "Zum Rand ziehen"))
            if edge == .right { arrows }
        }
    }

    @ViewBuilder
    private var preview: some View {
        if let url, let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
        } else {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color.secondary.opacity(0.15))
        }
    }

    /// Drei Pfeile, die nacheinander aufleuchten.
    private var arrows: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: AnimationStyle.reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2) {
                ForEach(0..<3, id: \.self) { i in
                    let order = edge == .right ? Double(i) : Double(2 - i)
                    let wave = 0.5 + 0.5 * sin((t * 3.2) - order * 0.9)
                    Image(systemName: edge == .right ? "chevron.right" : "chevron.left")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color.secondary.opacity(AnimationStyle.reduceMotion ? 0.6 : 0.2 + 0.8 * wave))
                }
            }
        }
    }
}

/// Fläche, aus der sich die Beispieldatei wie aus dem Finder herausziehen lässt.
private struct SampleDragArea: NSViewRepresentable {
    let url: URL
    var onDragStarted: () -> Void

    func makeNSView(context: Context) -> SampleDragView {
        let view = SampleDragView()
        view.url = url
        view.onDragStarted = onDragStarted
        return view
    }

    func updateNSView(_ view: SampleDragView, context: Context) {
        view.url = url
        view.onDragStarted = onDragStarted
    }
}

final class SampleDragView: NSView, NSDraggingSource {
    var url: URL?
    var onDragStarted: () -> Void = {}
    private var downEvent: NSEvent?

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        downEvent = event
    }

    override func mouseUp(with event: NSEvent) {
        downEvent = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down = downEvent, let url else { return }
        downEvent = nil
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let image = NSImage(contentsOf: url) ?? NSWorkspace.shared.icon(forFile: url.path)
        let side: CGFloat = 84
        let point = convert(down.locationInWindow, from: nil)
        item.setDraggingFrame(NSRect(x: point.x - side / 2, y: point.y - side / 2, width: side, height: side),
                              contents: image)
        let session = beginDraggingSession(with: [item], event: down, source: self)
        // Nicht abgelegt: einfach verschwinden statt zur Karte zurückzuschnellen
        session.animatesToStartingPositionsOnCancelOrFail = false
        onDragStarted()
    }

    func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        // Takt der Ablage wach halten, solange gezogen wird
        onDragStarted()
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }
}

/// Fläche, in die das Bild aus der Ablage zurückgezogen wird. Nimmt nur Objekte an,
/// die aus der Ablage kommen, damit man genau das Herausziehen übt.
private struct ReturnDropZone: View {
    let url: URL?
    let done: Bool
    let onDrop: () -> Void
    @State private var targeted = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(targeted ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04))
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(targeted ? Color.accentColor : Color.secondary.opacity(0.45),
                              style: StrokeStyle(lineWidth: 2, dash: done ? [] : [7, 6]))
                .opacity(done ? 0 : 1)

            if done {
                ZStack(alignment: .bottomTrailing) {
                    preview
                        .frame(width: 108, height: 108)
                        .shadow(color: .black.opacity(0.25), radius: 10, y: 6)
                    CheckBadge()
                        .scaleEffect(0.42)
                        .frame(width: 40, height: 40)
                        .offset(x: 14, y: 14)
                }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "tray.and.arrow.down")
                        .font(.system(size: 34, weight: .regular))
                        .foregroundStyle(targeted ? Color.accentColor : Color.secondary)
                    Text(L("Drag the image back here", "Zieh das Bild hierher zurück"))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 280, height: 180)
        .scaleEffect(targeted ? 1.03 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: targeted)
        .overlay(
            ReturnDropTarget(enabled: !done, targeted: $targeted, onDrop: onDrop)
        )
    }

    @ViewBuilder
    private var preview: some View {
        if let url, let image = NSImage(contentsOf: url) {
            Image(nsImage: image).resizable().interpolation(.high)
        } else {
            RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Color.secondary.opacity(0.15))
        }
    }
}

private struct ReturnDropTarget: NSViewRepresentable {
    let enabled: Bool
    @Binding var targeted: Bool
    let onDrop: () -> Void

    func makeNSView(context: Context) -> ReturnDropView {
        let view = ReturnDropView()
        configure(view)
        return view
    }

    func updateNSView(_ view: ReturnDropView, context: Context) { configure(view) }

    private func configure(_ view: ReturnDropView) {
        view.enabled = enabled
        view.onTargeted = { value in if targeted != value { targeted = value } }
        view.onDrop = onDrop
    }
}

final class ReturnDropView: NSView {
    var enabled = true
    var onTargeted: (Bool) -> Void = { _ in }
    var onDrop: () -> Void = {}

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes(ShelfStore.acceptedTypes)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// Nur Objekte aus der Ablage
    private func accepts(_ sender: NSDraggingInfo) -> Bool {
        enabled && sender.draggingSource is DragSourceNSView
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard accepts(sender) else { return [] }
        onTargeted(true)
        Haptics.tap()
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        accepts(sender) ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { onTargeted(false) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard accepts(sender) else { return false }
        onTargeted(false)
        Haptics.drop()
        DispatchQueue.main.async { self.onDrop() }
        return true
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) { onTargeted(false) }
}

