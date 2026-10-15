import AppKit
import SwiftUI
import Combine
import ServiceManagement
import Carbon

// MARK: Ablauf

/// Einführung beim ersten Start. Zuerst drei Schritte zum Mitmachen: etwas ablegen,
/// es zurückholen, den Kurzbefehl drücken. Jeder erkennt von selbst, wenn er geschafft
/// ist. Danach eine Seite mit allem, was BarDrop sonst noch kann. Am Ende verschwindet
/// sie samt Beispieldatei und taucht nur auf Wunsch wieder auf.
final class OnboardingModel: ObservableObject {
    enum Step: Int {
        case welcome, drop, retrieve, shortcut, features, done
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
    private var order: [Step] { [.welcome] + practiceSteps + [.features, .done] }

    /// Für die Punkte oben: Anzahl der Seiten und die aktuelle
    var pageCount: Int { order.count }
    var pageIndex: Int { order.firstIndex(of: step) ?? 0 }

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

    static let size = NSSize(width: 480, height: 620)

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
                if model.step == .features {
                    VStack(spacing: 18) {
                        ProgressDots(count: model.pageCount, current: model.pageIndex)
                        FeaturesPage(settings: model.settings)
                    }
                        .padding(.top, 44)
                        .padding(.horizontal, 44)
                        .transition(.opacity)
                } else {
                    hero
                        .frame(height: 230)
                        .padding(.top, 56)

                    texts
                        .padding(.top, 26)
                        .padding(.horizontal, 56)
                }

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
                ReturnDropZone(url: model.sampleURL, done: model.stepDone) {
                    model.complete(.retrieve)
                }
            case .shortcut:
                KeyCaps(settings: model.settings, pressed: model.stepDone)
            case .features:
                EmptyView()
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
        case .welcome: return "BarDrop"
        case .drop: return model.stepDone ? L("In the shelf", "In der Ablage") : L("Drop something", "Leg etwas ab")
        case .retrieve: return model.stepDone ? L("Got it back", "Zurückgeholt") : L("Get it back", "Hol es zurück")
        case .shortcut: return model.stepDone ? L("Done", "Geschafft") : L("With a shortcut", "Per Kurzbefehl")
        case .features: return L("What else BarDrop can do", "Was BarDrop noch kann")
        case .done: return L("All set", "Alles bereit")
        }
    }

    private var message: String {
        let s = model.settings
        let nearMiddle = s.adaptiveZoneFraction != nil
        switch model.step {
        case .welcome:
            return L("A place for files at the edge of your screen. Drag something there and it stays at hand until you need it. Try it out in three short steps.",
                     "Ein Platz für Dateien am Rand deines Bildschirms. Zieh etwas dorthin, und es bleibt griffbereit, bis du es brauchst. Probier es in drei kurzen Schritten aus.")
        case .drop:
            return model.stepDone
                ? L("The image is now in the shelf.", "Das Bild liegt jetzt in der Ablage.")
                : L("Drag the image to the \(edgeWord) edge of the screen. As soon as the shelf opens, let go.",
                    "Zieh das Bild an den \(edgeWord) Bildschirmrand. Sobald sich die Ablage öffnet, lass es los.")
        case .retrieve:
            if model.stepDone {
                let gone = s.removeAfterDragOut
                    ? L(" Afterwards it leaves the shelf.", " Danach verschwindet es aus der Ablage.") : ""
                return L("That’s how you use anything in the shelf: drag it out into any app, like Mail, the Finder or a browser.",
                         "So verwendest du alles aus der Ablage: einfach herausziehen, in jede App, etwa Mail, den Finder oder einen Browser.") + gone
            }
            // Passend zur Einstellung „Ablage öffnen“
            let open: String
            if s.openMode == .click {
                open = L(" and click the strip", " und klick auf den Streifen")
            } else if s.openDelay >= AppSettings.clickToOpenMinDelay - 0.01 {
                open = L(" and wait a moment or click the strip", " und warte kurz oder klick auf den Streifen")
            } else {
                open = ""
            }
            // „etwa auf halber Höhe“ als Einschub: das Komma danach nur, wenn noch etwas folgt
            let middle = nearMiddle ? L(" around the middle", open.isEmpty ? ", etwa auf halber Höhe" : ", etwa auf halber Höhe,") : ""
            return L("Move the pointer to the \(edgeWord) edge\(middle)\(open). When the shelf opens, drag the image back here.",
                     "Fahr mit dem Zeiger an den \(edgeWord) Rand\(middle)\(open). Wenn sich die Ablage öffnet, zieh das Bild hierher zurück.")
        case .shortcut:
            return model.stepDone
                ? L("The same shortcut closes the shelf again.", "Derselbe Kurzbefehl schließt die Ablage wieder.")
                : L("Press \(s.hotKeyDescription) to open the shelf anytime, even without a mouse.",
                    "Drück \(s.hotKeyDescription), um die Ablage jederzeit zu öffnen, auch ohne Maus.")
        case .features:
            return ""
        case .done:
            return L("BarDrop is waiting at the edge. You can find this introduction again in Settings → About BarDrop.",
                     "BarDrop wartet am Rand. Diese Einführung findest du jederzeit unter Einstellungen → Über BarDrop.")
        }
    }

    private var texts: some View {
        VStack(spacing: 10) {
            ProgressDots(count: model.pageCount, current: model.pageIndex)
                .padding(.bottom, 2)
            Text(heading)
                .font(OB.title)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: 380)
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
            case .features:
                PrimaryButton(title: L("Continue", "Weiter")) { model.advance() }
                // Platzhalter in Höhe der Zweitaktion, damit nichts springt
                secondary(" ") {}
                    .hidden()
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

// MARK: Was BarDrop noch kann

/// Übersicht der Funktionen wie in Apples „Neu in …“-Fenstern: farbiges Symbol,
/// kurzer Titel, ein Satz. Zeigt nur, was gerade eingeschaltet ist.
private struct FeaturesPage: View {
    let settings: AppSettings

    private struct Feature: Identifiable {
        let id: String
        let symbol: String
        let tint: Color
        let title: String
        let text: String
    }

    private var features: [Feature] {
        var list = [
            Feature(id: "actions", symbol: "paperplane.fill", tint: Color(red: 0.2, green: 0.55, blue: 1.0),
                    title: L("Send it on", "Gleich weitergeben"),
                    text: L("Drag items onto AirDrop, a folder or the Trash at the bottom of the shelf.",
                            "Zieh Objekte unten in der Ablage auf AirDrop, einen Ordner oder den Papierkorb."))
        ]
        if settings.pinFromShelf {
            list.append(Feature(id: "pin", symbol: "pin.fill", tint: Color(red: 0.95, green: 0.6, blue: 0.1),
                                title: L("Pin your folders", "Eigene Ordner anheften"),
                                text: L("Drag a folder or app onto the shelf and drop it on “Pin”.",
                                        "Zieh einen Ordner oder eine App auf die Ablage und lass sie auf „Anheften“ los.")))
        }
        list += [
            Feature(id: "convert", symbol: "arrow.triangle.2.circlepath", tint: Color(red: 0.3, green: 0.75, blue: 0.4),
                    title: L("Convert", "Umwandeln"),
                    text: L("Right-click to turn images into JPEG or PDF, resize them and more.",
                            "Per Rechtsklick Bilder in JPEG oder PDF umwandeln, verkleinern und mehr.")),
            Feature(id: "look", symbol: "eye.fill", tint: Color(red: 0.55, green: 0.4, blue: 0.95),
                    title: L("Take a look", "Kurz reinschauen"),
                    text: L("Space shows a preview. Removed something by mistake? ⌘Z brings it back.",
                            "Die Leertaste zeigt eine Vorschau. Versehentlich entfernt? ⌘Z holt es zurück.")),
            Feature(id: "settings", symbol: "gearshape.fill", tint: Color(white: 0.55),
                    title: L("Make it yours", "Nach deinem Geschmack"),
                    text: L("Right-click the shelf or open BarDrop again to change where and how it opens.",
                            "Rechtsklick auf die Ablage oder BarDrop erneut öffnen, um Ort und Verhalten anzupassen."))
        ]
        return list
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L("What else BarDrop can do", "Was BarDrop noch kann"))
                .font(OB.title)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
                .padding(.bottom, 8)
            ForEach(features) { feature in
                HStack(alignment: .top, spacing: 14) {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(LinearGradient(colors: [feature.tint.opacity(0.85), feature.tint],
                                             startPoint: .top, endPoint: .bottom))
                        .overlay(
                            Image(systemName: feature.symbol)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.white)
                        )
                        .frame(width: 36, height: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(feature.title)
                            .font(.system(size: 14, weight: .semibold))
                        Text(feature.text)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}

/// Punkte, die zeigen, wie weit man in der Einführung ist.
private struct ProgressDots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(i == current ? Color.accentColor : Color.secondary.opacity(i < current ? 0.55 : 0.25))
                    .frame(width: i == current ? 16 : 6, height: 6)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: current)
        .accessibilityElement()
        .accessibilityLabel(L("Page \(current + 1) of \(count)", "Seite \(current + 1) von \(count)"))
    }
}
