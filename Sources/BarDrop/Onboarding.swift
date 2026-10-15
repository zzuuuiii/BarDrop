import AppKit
import SwiftUI
import Combine
import ServiceManagement
import Carbon

// MARK: Ablauf

/// Einführung beim ersten Start. Zuerst drei Schritte zum Mitmachen: etwas ablegen,
/// es zurückholen, den Kurzbefehl drücken. Jeder erkennt von selbst, wenn er geschafft
/// ist. Danach drei kurze Tipps zu Aktionen, Ordnung und Einstellungen. Am Ende
/// verschwindet sie samt Beispieldatei und taucht nur auf Wunsch wieder auf.
final class OnboardingModel: ObservableObject {
    enum Step: Int {
        case welcome, drop, retrieve, shortcut, actions, organize, customize, done
    }

    @Published private(set) var step: Step = .welcome
    /// Der aktuelle Schritt wurde geschafft (Häkchen, gleich geht es weiter).
    @Published private(set) var stepDone = false
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

    /// Schritte zum Mitmachen.
    var practiceSteps: [Step] { [.drop, .retrieve, .shortcut] }
    /// Tipps zum Lesen, ohne Aufgabe
    var tipSteps: [Step] { [.actions, .organize, .customize] }

    private var order: [Step] { [.welcome] + practiceSteps + tipSteps + [.done] }

    /// Tipps überspringen: direkt zum Ende
    func skipToDone() {
        withAnimation(.spring(response: 0.5, dampingFraction: 0.86)) {
            stepDone = false
            step = .done
        }
    }

    func advance() {
        guard let i = order.firstIndex(of: step), i + 1 < order.count else {
            onFinish(true)
            return
        }
        let animation: Animation = AnimationStyle.reduceMotion
            ? .easeInOut(duration: 0.2)
            : .spring(response: 0.5, dampingFraction: 0.86)
        withAnimation(animation) {
            stepDone = false
            step = order[i + 1]
        }
    }

    /// Ein Schritt wurde gemacht: Häkchen zeigen, kurz stehen lassen, weiter.
    func complete(_ done: Step) {
        guard step == done, !stepDone else { return }
        Haptics.tap()
        withAnimation(.spring(response: 0.45, dampingFraction: 0.7)) { stepDone = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { [weak self] in
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
    /// Beim Schritt „Zurückholen“ war die Ablage schon einmal zu
    private var sawHidden = false
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

        ui.$level
            .sink { [weak self] level in self?.levelChanged(level) }
            .store(in: &subscriptions)
    }

    private func prepare(_ step: OnboardingModel.Step) {
        switch step {
        case .drop:
            baseline = Set(store.entries.map(\.id))
        case .retrieve:
            sawHidden = ui.level == .hidden
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

    private func levelChanged(_ level: ShelfUIModel.Level) {
        guard model.step == .retrieve else { return }
        if level == .hidden { sawHidden = true }
        if level == .expanded && sawHidden { model.complete(.retrieve) }
    }

    // MARK: Ende

    private func finish(completed: Bool) {
        guard !finished else { return }
        finished = true
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

    static let size = NSSize(width: 480, height: 580)

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.size),
                              styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = L("Welcome to BarDrop", "Willkommen bei BarDrop")
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.backgroundColor = .windowBackgroundColor
        window.level = .floating
        window.collectionBehavior = [.moveToActiveSpace]
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.delegate = self
        let root = OnboardingView(model: model, openSettings: { [weak self] in
            self?.openSettings()
        })
        window.contentView = NSHostingView(rootView: root)
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

private enum OB {
    static let title = Font.system(size: 28, weight: .bold)
    static let body = Font.system(size: 15)
    static let secondary = Color.secondary
}

struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    /// Sprache umschalten aktualisiert alle Texte sofort
    @ObservedObject private var settings = AppSettings.shared
    var openSettings: () -> Void

    private var edgeWord: String {
        model.settings.edge == .right ? L("right", "rechten") : L("left", "linken")
    }

    var body: some View {
        ZStack {
            background

            VStack(spacing: 0) {
                hero
                    .frame(height: 230)
                    .padding(.top, 56)

                texts
                    .padding(.top, 26)
                    .padding(.horizontal, 56)

                Spacer(minLength: 12)

                footer
                    .padding(.horizontal, 40)
                    .padding(.bottom, 32)
            }
        }
        .frame(width: OnboardingController.size.width, height: OnboardingController.size.height)
    }

    // MARK: Hintergrund

    private var background: some View {
        Color(nsColor: .windowBackgroundColor)
            .ignoresSafeArea()
    }

    // MARK: Bild oben

    @ViewBuilder
    private var hero: some View {
        ZStack {
            switch model.step {
            case .welcome:
                AppIconHero()
            case .drop:
                if model.stepDone {
                    CheckBadge()
                } else {
                    SampleCard(url: model.sampleURL, edge: model.settings.edge,
                               onDragStarted: model.onSampleDragStarted)
                }
            case .retrieve:
                MiniScreen(edge: model.settings.edge, done: model.stepDone)
            case .shortcut:
                KeyCaps(settings: model.settings, pressed: model.stepDone)
            case .actions:
                ActionsHero(settings: model.settings)
            case .organize:
                OrganizeHero()
            case .customize:
                CustomizeHero()
            case .done:
                CheckBadge(large: true)
            }
        }
        .id(model.step.rawValue * 10 + (model.stepDone ? 1 : 0))
        .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.96)),
                                removal: .opacity))
        .frame(maxWidth: .infinity)
    }

    // MARK: Text

    private var heading: String {
        switch model.step {
        case .welcome: return L("Welcome to BarDrop", "Willkommen bei BarDrop")
        case .drop: return model.stepDone ? L("Dropped", "Abgelegt") : L("Drop something", "Leg etwas ab")
        case .retrieve: return model.stepDone ? L("Exactly", "Genau so") : L("Get it back", "Hol es zurück")
        case .shortcut: return model.stepDone ? L("Perfect", "Perfekt") : L("From anywhere", "Von überall")
        case .actions: return L("Send it on", "Direkt weitergeben")
        case .organize: return L("Keep it tidy", "Ordnung halten")
        case .customize: return L("Make it yours", "Ganz nach deinem Geschmack")
        case .done: return L("All set", "Alles bereit")
        }
    }

    private var message: String {
        let s = model.settings
        let middle = s.adaptiveZoneFraction != nil ? L(" around the middle", ", etwa auf halber Höhe,") : ""
        switch model.step {
        case .welcome:
            return L("A shelf that waits invisibly at the edge of your screen. Try it in three short steps, then get a few tips.",
                     "Eine Ablage, die unsichtbar am Bildschirmrand wartet. Probier es in drei kurzen Schritten aus, danach gibt es ein paar Tipps.")
        case .drop:
            return model.stepDone
                ? L("The image is now in the shelf.", "Das Bild liegt jetzt in der Ablage.")
                : L("Drag the image to the \(edgeWord) edge of the screen. As soon as the shelf opens, let go.",
                    "Zieh das Bild an den \(edgeWord) Bildschirmrand. Sobald sich die Ablage öffnet, lass es los.")
        case .retrieve:
            if model.stepDone {
                return L("That’s how you get everything back out: just drag it out of the shelf.",
                         "So holst du alles wieder heraus: einfach aus der Ablage ziehen.")
            }
            let open = s.openMode == .click ? L("and click the handle", "und klick auf den Griff")
                                            : L("and wait a moment", "und warte einen Moment")
            return L("Move the pointer to the \(edgeWord) edge\(middle) \(open). The shelf opens.",
                     "Fahr mit dem Zeiger an den \(edgeWord) Rand\(middle) \(open). Die Ablage öffnet sich.")
        case .shortcut:
            return model.stepDone
                ? L("The same shortcut closes the shelf again.", "Derselbe Kurzbefehl schließt die Ablage wieder.")
                : L("Press \(s.hotKeyDescription) to open the shelf anytime, even without a mouse.",
                    "Drück \(s.hotKeyDescription), um die Ablage jederzeit zu öffnen, auch ohne Maus.")
        case .actions:
            return L("Drag items onto an action at the bottom of the shelf to send them with AirDrop, attach them to an email or move them to a folder. Or select them and click the action.",
                     "Zieh Objekte auf eine Aktion unten in der Ablage, um sie per AirDrop zu senden, an eine E-Mail zu hängen oder in einen Ordner zu verschieben. Oder wähl sie aus und klick auf die Aktion.")
        case .organize:
            return L("Press Space to preview an item. Select several and right-click to group them as a stack. Removed something by mistake? ⌘Z brings it back.",
                     "Mit der Leertaste siehst du ein Objekt in der Übersicht. Wähl mehrere aus und gruppier sie per Rechtsklick zu einem Stapel. Versehentlich entfernt? ⌘Z holt es zurück.")
        case .customize:
            return L("Screen edge, size, delay, the look of the strip, your actions and the language: all in Settings. Right-click an empty spot in the shelf to get there.",
                     "Bildschirmrand, Größe, Wartezeit, das Aussehen des Streifens, deine Aktionen und die Sprache: alles in den Einstellungen. Du erreichst sie per Rechtsklick auf eine leere Stelle der Ablage.")
        case .done:
            return L("BarDrop is waiting at the edge. You can watch this introduction again anytime in Settings → About BarDrop.",
                     "BarDrop wartet am Rand. Diese Einführung kannst du jederzeit unter Einstellungen → Über BarDrop noch einmal ansehen.")
        }
    }

    /// „Schritt 1 von 3“ bzw. „Tipp 1 von 3“ über der Überschrift.
    private var stepLabel: String? {
        if let i = model.practiceSteps.firstIndex(of: model.step) {
            return L("Step \(i + 1) of \(model.practiceSteps.count)", "Schritt \(i + 1) von \(model.practiceSteps.count)")
        }
        if let i = model.tipSteps.firstIndex(of: model.step) {
            return L("Tip \(i + 1) of \(model.tipSteps.count)", "Tipp \(i + 1) von \(model.tipSteps.count)")
        }
        return nil
    }

    private var texts: some View {
        VStack(spacing: 10) {
            Text(stepLabel ?? " ")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .opacity(stepLabel == nil ? 0 : 1)
            Text(heading)
                .font(OB.title)
                .foregroundStyle(.primary)
            Text(message)
                .font(OB.body)
                .foregroundStyle(OB.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .frame(maxWidth: 360)
                .fixedSize(horizontal: false, vertical: true)
        }
        .id("text-\(model.step.rawValue)-\(model.stepDone)")
        .transition(.opacity)
        .frame(maxWidth: .infinity)
    }

    // MARK: Unten

    /// Immer derselbe Aufbau: ein großer Knopf, darunter eine leise Zweitaktion.
    /// So springt beim Weiterblättern nichts.
    private var footer: some View {
        VStack(spacing: 14) {
            if model.step == .done {
                HStack {
                    Text(L("Open at login", "Beim Anmelden öffnen"))
                        .font(.system(size: 13))
                    Spacer()
                    Toggle("", isOn: $model.launchAtLogin)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                )
                .frame(maxWidth: 320)
                .padding(.bottom, 6)
            }

            if model.step == .welcome {
                Picker("", selection: $settings.language) {
                    ForEach(AppLanguage.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 200)
                .padding(.bottom, 4)
            }

            switch model.step {
            case .welcome:
                PrimaryButton(title: L("Let’s go", "Los geht’s")) { model.advance() }
                secondary(L("Skip", "Überspringen")) { model.onFinish(false) }
            case .actions, .organize, .customize:
                PrimaryButton(title: L("Continue", "Weiter")) { model.advance() }
                secondary(L("Skip tips", "Tipps überspringen")) { model.skipToDone() }
            case .done:
                PrimaryButton(title: L("Done", "Fertig")) { model.advance() }
                secondary(L("Open Settings", "Einstellungen öffnen")) {
                    openSettings()
                    model.advance()
                }
            default:
                PrimaryButton(title: L("Continue", "Weiter")) { model.advance() }
                    .disabled(!model.stepDone)
                secondary(L("Skip", "Überspringen")) { model.advance() }
                    .opacity(model.stepDone ? 0 : 1)
            }
        }
    }

    private func secondary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(QuietButtonStyle())
    }
}

// MARK: Bausteine

private struct PrimaryButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .frame(minWidth: 220)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .keyboardShortcut(.defaultAction)
    }
}

private struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Color.secondary.opacity(configuration.isPressed ? 0.6 : 1))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
    }
}

/// App-Symbol.
private struct AppIconHero: View {
    var body: some View {
        Image(nsImage: NSApp.applicationIconImage ?? NSImage())
            .resizable()
            .interpolation(.high)
            .frame(width: 144, height: 144)
            .shadow(color: .black.opacity(0.18), radius: 14, y: 8)
    }
}

/// Häkchen, wenn ein Schritt geschafft ist.
private struct CheckBadge: View {
    var large = false
    @State private var shown = false

    var body: some View {
        Image(systemName: "checkmark.circle.fill")
            .font(.system(size: large ? 96 : 84, weight: .regular))
            .foregroundStyle(.white, .green)
            .scaleEffect(shown ? 1 : 0.5)
            .opacity(shown ? 1 : 0)
            .onAppear {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.6).delay(0.05)) { shown = true }
            }
    }
}

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

/// Kleiner Bildschirm: Der Zeiger fährt an den Rand, die Ablage öffnet sich.
private struct MiniScreen: View {
    let edge: ScreenEdge
    let done: Bool

    private let width: CGFloat = 300
    private let height: CGFloat = 186

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: AnimationStyle.reduceMotion || done)) { context in
            let t = AnimationStyle.reduceMotion || done
                ? 1.8
                : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3.8)
            scene(t: t)
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.2), radius: 16, y: 8)
    }

    /// Weicher Übergang zwischen zwei Zeitpunkten (0 … 1).
    private func ramp(_ t: Double, _ a: Double, _ b: Double) -> CGFloat {
        let x = min(max((t - a) / (b - a), 0), 1)
        return CGFloat(x * x * (3 - 2 * x))
    }

    private func scene(t: Double) -> some View {
        // Ablauf: Zeiger zum Rand, Ablage auf, Zeiger auf die Ablage, wieder weg, Ablage zu
        let open = ramp(t, 0.95, 1.3) * (1 - ramp(t, 2.75, 3.05))
        let toEdge = ramp(t, 0.1, 0.95) * (1 - ramp(t, 2.55, 3.2))
        let onto = ramp(t, 1.35, 1.75) * (1 - ramp(t, 2.4, 2.7))

        let shelfW = 4 + 92 * open
        let shelfH = 44 + 74 * open
        let fillet = 3 + 5 * open
        let start = width * 0.42
        let edgeX = width - 6
        let cursorFromEdge = start + (edgeX - start) * toEdge - 46 * onto
        let cursorX = edge == .right ? cursorFromEdge : width - cursorFromEdge

        return ZStack(alignment: edge == .right ? .trailing : .leading) {
            LinearGradient(colors: [Color(red: 0.2, green: 0.24, blue: 0.42),
                                    Color(red: 0.07, green: 0.07, blue: 0.13)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack {
                Rectangle().fill(Color.white.opacity(0.12)).frame(height: 10)
                Spacer()
            }

            ZStack(alignment: edge == .right ? .trailing : .leading) {
                EdgeBlobShape(edge: edge, cornerRadius: 3 + 11 * open, fillet: fillet, filletStretch: 1.25)
                    .fill(Color.black)
                HStack(spacing: 6) {
                    ForEach(0..<2, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.white.opacity(0.22))
                            .frame(width: 26, height: 26)
                    }
                }
                .opacity(Double(ramp(Double(open), 0.6, 1)))
                .frame(width: shelfW)
            }
            .frame(width: shelfW, height: shelfH + 2 * fillet)

            Image(systemName: "cursorarrow")
                .font(.system(size: 17))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
                .position(x: cursorX, y: height / 2 + 6)
                .opacity(done ? 0 : 1)
        }
        .frame(width: width, height: height)
    }
}

/// Tasten für den Kurzbefehl.
private struct KeyCaps: View {
    let settings: AppSettings
    let pressed: Bool

    private var keys: [(String, String)] {
        let m = settings.hotKeyModifiers
        var keys: [(String, String)] = []
        if m & controlKey != 0 { keys.append(("⌃", "control")) }
        if m & optionKey != 0 { keys.append(("⌥", "option")) }
        if m & shiftKey != 0 { keys.append(("⇧", "shift")) }
        if m & cmdKey != 0 { keys.append(("⌘", "command")) }
        keys.append((settings.hotKeyLabel, ""))
        return keys
    }

    var body: some View {
        HStack(spacing: 12) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                KeyCap(symbol: key.0, label: key.1, pressed: pressed)
            }
        }
    }
}

private struct KeyCap: View {
    let symbol: String
    let label: String
    let pressed: Bool

    var body: some View {
        VStack(spacing: 4) {
            Text(symbol)
                .font(.system(size: 30, weight: .medium, design: .rounded))
                .foregroundStyle(pressed ? Color.white : Color.primary)
            if !label.isEmpty {
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(pressed ? Color.white.opacity(0.8) : Color.secondary)
            }
        }
        .frame(width: 84, height: 84)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(pressed ? Color.accentColor : Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(pressed ? 0 : 0.14), lineWidth: 1)
        )
        .shadow(color: .black.opacity(pressed ? 0.05 : 0.15), radius: pressed ? 1 : 5, y: pressed ? 0 : 3)
        .scaleEffect(pressed ? 0.95 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: pressed)
    }
}

// MARK: Bilder der Tipps

/// Kleine Ablage mit Aktionsleiste: Ein Objekt gleitet auf die erste Aktion.
private struct ActionsHero: View {
    let settings: AppSettings

    private var actions: [QuickAction] {
        let list = settings.quickActions.isEmpty ? QuickAction.defaults : settings.quickActions
        return Array(list.prefix(4))
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: AnimationStyle.reduceMotion)) { context in
            let t = AnimationStyle.reduceMotion ? 1.4 : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3.2)
            scene(t: t)
        }
        .frame(width: 260, height: 210)
    }

    private func ramp(_ t: Double, _ a: Double, _ b: Double) -> CGFloat {
        let x = min(max((t - a) / (b - a), 0), 1)
        return CGFloat(x * x * (3 - 2 * x))
    }

    private func scene(t: Double) -> some View {
        // Objekt hebt sich, gleitet zur Aktion, die Aktion leuchtet, Objekt verschwindet
        let move = ramp(t, 0.5, 1.4)
        let over = ramp(t, 1.25, 1.45) * (1 - ramp(t, 2.2, 2.5))
        let fade = 1 - ramp(t, 1.6, 1.9)
        let back = ramp(t, 2.7, 3.1)
        let actionWidth: CGFloat = 220 / CGFloat(max(actions.count, 1))
        let targetX = -110 + actionWidth / 2
        let tileX = -62 + (targetX + 62) * move
        let tileY = -34 + (62 + 34) * move
        // Nach dem Ablegen: Objekt taucht an seinem Platz wieder auf, die Schleife beginnt neu
        let reset = t >= 2.6

        return ZStack {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(Color.black)
                .overlay(
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.25), radius: 14, y: 8)

            // Kacheln
            HStack(spacing: 14) {
                ForEach(0..<3, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.white.opacity(i == 0 ? 0 : 0.16))
                        .frame(width: 42, height: 42)
                }
            }
            .offset(y: -34)

            // Aktionsleiste
            HStack(spacing: 0) {
                ForEach(Array(actions.enumerated()), id: \.offset) { i, action in
                    VStack(spacing: 4) {
                        QuickActionIcon(action: action, size: 28)
                            .scaleEffect(i == 0 ? 1 + 0.12 * over : 1)
                        Text(action.title)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(1)
                    }
                    .frame(width: actionWidth)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.white.opacity(i == 0 ? 0.14 * over : 0))
                    )
                }
            }
            .frame(width: 220)
            .offset(y: 62)

            // Das gezogene Objekt
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.36, green: 0.62, blue: 1), Color(red: 0.2, green: 0.4, blue: 0.95)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(Image(systemName: "photo").font(.system(size: 16, weight: .semibold)).foregroundStyle(.white))
                .frame(width: 42, height: 42)
                .scaleEffect(reset ? 1 : 1 + 0.32 * (move - move * move) - 0.4 * (1 - fade))
                .shadow(color: .black.opacity(reset ? 0 : 0.4 * move), radius: 6, y: 3)
                .offset(x: reset ? -62 : tileX, y: reset ? -34 : tileY)
                .opacity(Double(reset ? back : fade))
        }
        .frame(width: 260, height: 190)
    }
}

/// Übersicht der wichtigsten Handgriffe.
private struct OrganizeHero: View {
    var body: some View {
        VStack(spacing: 0) {
            row(keys: [L("space", "Leertaste")], text: L("Quick Look", "Übersicht"))
            Divider().padding(.leading, 14)
            row(keys: [L("right-click", "Rechtsklick")], text: L("Group as Stack", "Als Stapel zusammenfassen"))
            Divider().padding(.leading, 14)
            row(keys: ["⌘", "Z"], text: L("Undo", "Widerrufen"))
            Divider().padding(.leading, 14)
            row(keys: ["⌘", "A"], text: L("Select all", "Alle auswählen"))
        }
        .frame(width: 320)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.12), radius: 12, y: 6)
    }

    private func row(keys: [String], text: String) -> some View {
        HStack(spacing: 6) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                Text(key)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .padding(.horizontal, 8)
                    .frame(minWidth: 26, minHeight: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.primary.opacity(0.07))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                    )
            }
            Spacer()
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
    }
}

/// Was sich einstellen lässt, mit Symbolen wie in den Einstellungen.
private struct CustomizeHero: View {
    private struct Item: Identifiable {
        let id: Int
        let symbol: String
        let color: Color
        let title: String
    }

    private var items: [Item] {
        [
            Item(id: 0, symbol: "sidebar.right", color: Color(red: 0.2, green: 0.47, blue: 1), title: L("Edge and size", "Rand und Größe")),
            Item(id: 1, symbol: "timer", color: Color(red: 1, green: 0.58, blue: 0.1), title: L("Delay", "Wartezeit")),
            Item(id: 2, symbol: "square.grid.2x2.fill", color: Color(red: 0.2, green: 0.78, blue: 0.4), title: L("Actions", "Aktionen")),
            Item(id: 3, symbol: "globe", color: Color(red: 0.55, green: 0.35, blue: 0.95), title: L("Language", "Sprache"))
        ]
    }

    var body: some View {
        LazyVGrid(columns: [GridItem(.fixed(150), spacing: 12), GridItem(.fixed(150), spacing: 12)], spacing: 12) {
            ForEach(items) { item in
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(item.color.gradient)
                        .overlay(Image(systemName: item.symbol)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.white))
                        .frame(width: 28, height: 28)
                    Text(item.title)
                        .font(.system(size: 13, weight: .medium))
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .frame(height: 54)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.08), radius: 6, y: 3)
            }
        }
        .frame(width: 320)
    }
}
