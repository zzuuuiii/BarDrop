import AppKit
import SwiftUI
import Combine
import ServiceManagement
import Carbon

// MARK: Ablauf

/// Einführung beim ersten Start. Sie erklärt nichts, was man lesen muss, sondern
/// lässt jeden Schritt einmal selbst machen: etwas ablegen, es zurückholen, den
/// Kurzbefehl drücken. Jeder Schritt erkennt von selbst, wenn er geschafft ist.
/// Danach verschwindet sie samt Beispieldatei und taucht nie wieder auf.
final class OnboardingModel: ObservableObject {
    enum Step: Int {
        case welcome, drop, retrieve, shortcut, done
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

    private var order: [Step] { [.welcome] + practiceSteps + [.done] }

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
        case .done: return L("All set", "Alles bereit")
        }
    }

    private var message: String {
        let s = model.settings
        let middle = s.adaptiveZoneFraction != nil ? L(" around the middle", ", etwa auf halber Höhe,") : ""
        switch model.step {
        case .welcome:
            return L("A shelf that waits invisibly at the edge of your screen. Try it in three short steps.",
                     "Eine Ablage, die unsichtbar am Bildschirmrand wartet. Probier es in drei kurzen Schritten aus.")
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
        case .done:
            return L("BarDrop is waiting at the edge. Right-click the shelf for Settings, and press ⌘Z to bring back anything you removed.",
                     "BarDrop wartet am Rand. Einstellungen findest du per Rechtsklick in die Ablage, und mit ⌘Z holst du Entferntes zurück.")
        }
    }

    /// „Schritt 1 von 3“ über der Überschrift, nur bei den Schritten zum Mitmachen.
    private var stepLabel: String? {
        guard let i = model.practiceSteps.firstIndex(of: model.step) else { return nil }
        return L("Step \(i + 1) of \(model.practiceSteps.count)", "Schritt \(i + 1) von \(model.practiceSteps.count)")
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

            switch model.step {
            case .welcome:
                PrimaryButton(title: L("Let’s go", "Los geht’s")) { model.advance() }
                secondary(L("Skip", "Überspringen")) { model.onFinish(false) }
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
