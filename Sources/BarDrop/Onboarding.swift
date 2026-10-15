import AppKit
import SwiftUI
import Combine
import ServiceManagement
import Carbon

// MARK: Ablauf

/// Einführung beim ersten Start, gestaltet wie die offene Ablage selbst: schwarze Form,
/// dieselben Kacheln, Schriften und Übergänge. Drei Schritte zum Mitmachen (ablegen,
/// zurückholen, Kurzbefehl) erkennen von selbst, wann sie geschafft sind. Zum Schluss
/// zeigt sie als Kacheln, was BarDrop sonst kann.
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

    static let size = NSSize(width: 380, height: 560)

    /// Fenster in der Form der offenen Ablage: schwarz, abgerundet, ohne Titelleiste.
    /// Lässt sich am Hintergrund verschieben.
    private func makeWindow() -> NSWindow {
        let window = IntroWindow(contentRect: NSRect(origin: .zero, size: Self.size),
                                 styleMask: [.borderless, .fullSizeContentView],
                                 backing: .buffered, defer: false)
        window.title = L("Welcome to BarDrop", "Willkommen bei BarDrop")
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .floating
        window.collectionBehavior = [.moveToActiveSpace]
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

/// Randloses Fenster, das trotzdem Tastatureingaben bekommt (Eingabetaste, Escape)
final class IntroWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

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
}

/// Farben und Schriften der offenen Ablage
private enum Intro {
    static let primary = Color.white.opacity(0.92)
    static let secondary = Color.white.opacity(0.6)
    static let tertiary = Color.white.opacity(0.42)
    static let fill = Color.white.opacity(0.07)
    static let hover = Color.white.opacity(0.14)
    static let cornerRadius: CGFloat = 28
}

struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    /// Sprache umschalten aktualisiert alle Texte sofort
    @ObservedObject private var settings = AppSettings.shared
    var openSettings: () -> Void
    /// Erscheint wie die Ablage: weich mit Unschärfe
    @State private var appeared = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Intro.cornerRadius, style: .continuous)
        ZStack {
            shape.fill(Color.black)
            shape.strokeBorder(Color.white.opacity(0.2), lineWidth: 1)

            if appeared {
                VStack(spacing: 0) {
                    header
                        .padding(.horizontal, 18)
                        .frame(height: 30)
                        .padding(.top, 12)
                        .padding(.bottom, 4)

                    ZStack {
                        page
                            .id(model.step)
                            .transition(.blurFade(settings.animationStyle.blur))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    footer
                        .padding(.horizontal, 14)
                        .padding(.top, 6)
                        .padding(.bottom, 14)
                }
                .transition(.blurFade(settings.animationStyle.blur))
            }
        }
        .clipShape(shape)
        .environment(\.colorScheme, .dark)
        .onAppear {
            withAnimation(.easeOut(duration: 0.28)) { appeared = true }
        }
    }

    // MARK: Kopf wie in der Ablage

    private var header: some View {
        HStack(spacing: 8) {
            Text("BarDrop")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Intro.primary)
            Spacer(minLength: 8)
            Text(L("\(model.step.rawValue + 1) of \(OnboardingModel.Step.allCases.count)",
                   "\(model.step.rawValue + 1) von \(OnboardingModel.Step.allCases.count)"))
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.5))
            CloseButton { model.onFinish(false) }
        }
    }

    // MARK: Seiten

    @ViewBuilder
    private var page: some View {
        switch model.step {
        case .welcome: welcome
        case .drop: dropStep
        case .retrieve: retrieveStep
        case .shortcut: shortcutStep
        case .features: FeatureTiles(settings: model.settings)
        }
    }

    private var welcome: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 8)
            Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                .resizable()
                .interpolation(.high)
                .frame(width: 96, height: 96)
                .shadow(color: .black.opacity(0.5), radius: 14, y: 8)
            Text(L("Welcome to BarDrop", "Willkommen bei BarDrop"))
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Intro.primary)
                .padding(.top, 16)
            Text(L("A place for files at the edge of your screen. Drag something there and it stays at hand until you need it.",
                   "Ein Platz für Dateien am Rand deines Bildschirms. Zieh etwas dorthin, und es bleibt griffbereit, bis du es brauchst."))
                .font(.system(size: 12))
                .foregroundStyle(Intro.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
            Spacer(minLength: 16)

            VStack(spacing: 0) {
                IntroRow(L("Language", "Sprache")) {
                    IntroSegments(selection: $settings.language,
                                  options: AppLanguage.allCases.map { ($0, $0.title) })
                }
                Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1).padding(.horizontal, 12)
                IntroRow(L("Open at login", "Beim Anmelden öffnen")) {
                    Toggle("", isOn: $model.launchAtLogin)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .labelsHidden()
                }
            }
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Intro.fill))

            Text(L("Next, try it out in three short steps.", "Danach probierst du es in drei kurzen Schritten aus."))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Intro.tertiary)
                .padding(.top, 10)
        }
        .padding(.horizontal, 20)
    }

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

    /// Aufbau der Schritte zum Mitmachen: oben die Bühne, darunter Titel und Anleitung,
    /// die nach dem Schaffen zur Bestätigung wird
    private func practice<Stage: View>(instruction: String, done: String,
                                       @ViewBuilder stage: () -> Stage) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 8)
            stage()
                .frame(maxWidth: .infinity)
                .frame(height: 230)
            Spacer(minLength: 12)
            HStack(spacing: 6) {
                if model.stepDone {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.white, .green)
                        .transition(.scale.combined(with: .opacity))
                }
                Text(model.step.title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Intro.primary)
            }
            Text(model.stepDone ? done : instruction)
                .font(.system(size: 12))
                .foregroundStyle(Intro.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: 48, alignment: .top)
                .padding(.top, 6)
                .id(model.stepDone)
                .transition(.opacity)
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 24)
    }

    // MARK: Unten

    private var footer: some View {
        HStack(spacing: 8) {
            StepDots(current: model.step)
                .padding(.leading, 6)
            Spacer()
            switch model.step {
            case .welcome:
                Button(L("Skip", "Überspringen")) { model.onFinish(false) }
                    .buttonStyle(IntroButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button(L("Let’s go", "Los geht’s")) { model.advance() }
                    .buttonStyle(IntroButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
            case .features:
                Button(L("Settings", "Einstellungen")) {
                    openSettings()
                    model.advance()
                }
                .buttonStyle(IntroButtonStyle())
                Button(L("Done", "Fertig")) { model.advance() }
                    .buttonStyle(IntroButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
            default:
                Button(model.stepDone ? L("Continue", "Weiter") : L("Skip", "Überspringen")) { model.advance() }
                    .buttonStyle(IntroButtonStyle(prominent: model.stepDone))
                    .keyboardShortcut(model.stepDone ? .defaultAction : .cancelAction)
            }
        }
    }
}

/// Knöpfe im Ton der Ablage: hell auf Schwarz
private struct IntroButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        IntroButtonBody(configuration: configuration, prominent: prominent)
    }

    private struct IntroButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let prominent: Bool
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 12.5, weight: prominent ? .semibold : .medium))
                .foregroundStyle(prominent ? Color.black : Intro.primary)
                .padding(.horizontal, 14)
                .frame(height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(prominent ? Color.white.opacity(configuration.isPressed ? 0.8 : hovering ? 0.95 : 0.9)
                              : Color.white.opacity(configuration.isPressed ? 0.2 : hovering ? 0.14 : 0.08))
                )
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }
}

/// Kleiner Schließknopf oben rechts
private struct CloseButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white.opacity(hovering ? 0.9 : 0.55))
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.white.opacity(hovering ? 0.16 : 0.08)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(L("Close", "Schließen"))
    }
}

/// Zeile in einer hellen Fläche: Bezeichnung links, Bedienelement rechts
private struct IntroRow<Control: View>: View {
    let title: String
    let control: Control
    init(_ title: String, @ViewBuilder control: () -> Control) {
        self.title = title
        self.control = control()
    }

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 12.5))
                .foregroundStyle(Intro.primary)
            Spacer(minLength: 8)
            control
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
    }
}

/// Umschalter mit wenigen Möglichkeiten, im Ton der Ablage
private struct IntroSegments<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(Value, String)]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let selected = option.0 == selection
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { selection = option.0 }
                } label: {
                    Text(option.1)
                        .font(.system(size: 11.5, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? Color.black : Intro.secondary)
                        .padding(.horizontal, 10)
                        .frame(height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(selected ? Color.white.opacity(0.9) : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.08)))
    }
}

/// Wie weit man ist: ein Punkt je Schritt, der aktuelle länglich
private struct StepDots: View {
    let current: OnboardingModel.Step

    var body: some View {
        HStack(spacing: 5) {
            ForEach(OnboardingModel.Step.allCases) { step in
                Capsule()
                    .fill(Color.white.opacity(step == current ? 0.9 : step.rawValue < current.rawValue ? 0.45 : 0.18))
                    .frame(width: step == current ? 14 : 5, height: 5)
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

/// Die Tasten des Kurzbefehls als dunkle Kappen
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
                            .font(.system(size: 20, weight: .medium))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        Text(key.0).font(.system(size: 16, weight: .medium))
                        Spacer(minLength: 0)
                        Text(key.1).font(.system(size: 12, weight: .medium))
                    }
                }
                .foregroundStyle(pressed ? Color.black : Intro.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
                .frame(width: 66, height: 66, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(pressed ? Color.white.opacity(0.9) : Color.white.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.white.opacity(pressed ? 0 : 0.1), lineWidth: 1)
                )
                .scaleEffect(pressed ? 0.95 : 1)
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: pressed)
    }
}

// MARK: Mehr entdecken

/// Was BarDrop sonst kann, als Kacheln wie in der Ablage. Ein Klick wählt eine Kachel
/// aus, darunter steht, was sie macht und wo man es findet.
private struct FeatureTiles: View {
    let settings: AppSettings
    @State private var selected = "actions"

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
        list.append(Feature(id: "convert", symbol: "arrow.triangle.2.circlepath", tint: Color(red: 0.3, green: 0.75, blue: 0.4),
                            title: L("Convert", "Umwandeln"),
                            text: L("Right-click an item to turn images into JPEG or PDF, resize them and more.",
                                    "Rechtsklick auf ein Objekt, um Bilder in JPEG oder PDF umzuwandeln, zu verkleinern und mehr.")))
        if settings.pinFromShelf {
            list.append(Feature(id: "pin", symbol: "pin.fill", tint: Color(red: 0.95, green: 0.6, blue: 0.1),
                                title: L("Pin", "Anheften"),
                                text: L("Drag a folder or app over the shelf and drop it on “Pin” at the end of the action bar.",
                                        "Zieh einen Ordner oder eine App über die Ablage und lass sie auf „Anheften“ am Ende der Aktionsleiste los.")))
        }
        list.append(Feature(id: "settings", symbol: "gearshape.fill", tint: Color(white: 0.55),
                            title: L("Settings", "Einstellungen"),
                            text: L("Right-click an empty spot in the shelf, press ⌘, there, or simply open BarDrop again.",
                                    "Rechtsklick auf eine leere Stelle der Ablage, dort ⌘, drücken oder BarDrop einfach noch einmal öffnen.")))
        return list
    }

    private let columns = [GridItem(.adaptive(minimum: 84, maximum: 110), spacing: 8)]

    var body: some View {
        let list = features
        let current = list.first { $0.id == selected } ?? list[0]
        VStack(spacing: 0) {
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(list) { feature in
                    TileLabel(title: feature.title, isSelected: feature.id == current.id, isKey: true, iconSize: 46) {
                        FeatureIcon(symbol: feature.symbol, tint: feature.tint, size: 46)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.easeOut(duration: 0.15)) { selected = feature.id }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 4)

            Spacer(minLength: 8)

            VStack(spacing: 6) {
                Text(current.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Intro.primary)
                Text(current.text)
                    .font(.system(size: 12))
                    .foregroundStyle(Intro.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(minHeight: 70, alignment: .top)
            .padding(.horizontal, 24)
            .id(current.id)
            .transition(.opacity)

            Text(L("You can find this introduction again in Settings → About BarDrop.",
                   "Diese Einführung findest du jederzeit unter Einstellungen → Über BarDrop."))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Intro.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .padding(.bottom, 4)
        }
    }
}

/// Symbol im Raster der App-Symbole, wie die eigenen Kacheln der Aktionsleiste
private struct FeatureIcon: View {
    let symbol: String
    let tint: Color
    let size: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
        shape
            .fill(LinearGradient(colors: [tint.opacity(0.75), tint], startPoint: .top, endPoint: .bottom))
            .overlay(shape.fill(LinearGradient(colors: [Color.white.opacity(0.2), Color.white.opacity(0)],
                                               startPoint: .top, endPoint: .center)))
            .overlay(shape.strokeBorder(Color.white.opacity(0.2), lineWidth: 0.5))
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: size * 0.44, weight: .semibold))
                    .foregroundStyle(.white)
            )
            .frame(width: size, height: size)
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
            // Als Kachel, genau wie sie danach in der Ablage liegt
            TileLabel(title: url?.lastPathComponent ?? L("Image", "Bild"), isSelected: false, isKey: true,
                      iconSize: 84) {
                preview
            }
            .frame(width: 130)
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
                        .foregroundStyle(Color.white.opacity(AnimationStyle.reduceMotion ? 0.5 : 0.15 + 0.6 * wave))
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
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(targeted ? Color.white.opacity(0.12) : Color.white.opacity(0.04))
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.white.opacity(targeted ? 0.6 : 0.25),
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
                        .foregroundStyle(Color.white.opacity(targeted ? 0.9 : 0.5))
                    Text(L("Drag the image back here", "Zieh das Bild hierher zurück"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
        }
        .frame(width: 260, height: 180)
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

