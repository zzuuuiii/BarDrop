import AppKit
import SwiftUI
import Combine
import ServiceManagement
import Carbon

// MARK: Ablauf

/// Einführung beim ersten Start, aufgebaut wie eine Produktvorstellung: je Schritt eine
/// bewegte Szene mit der echten Ablage, eine Überschrift, ein Satz. Im Mittelpunkt steht
/// jeweils eine Übung (ablegen, herausziehen, Kurzbefehl), die von selbst erkennt, wann sie
/// geschafft ist. Farben, Schalter und Knöpfe wie in den Einstellungen.
final class OnboardingModel: ObservableObject {
    enum Step: Int, CaseIterable, Identifiable {
        // Erst ablegen (danach weiß man, wo die Ablage sitzt), dann mit dem Zeiger öffnen,
        // wieder herausziehen, eine Aktion; der Tastaturkurzbefehl nach der Maus. Zuletzt vom
        // Rand abziehen, zum Ausprobieren wie auf der Website (Nutzer, 31.10.2026): Nur in
        // diesem Schritt lässt sich die Ablage abziehen (IntroGate.allowsTear)
        case welcome, drop, hover, takeOut, retrieve, shortcut, detach, features
        var id: Int { rawValue }
    }

    @Published private(set) var step: Step = .welcome
    /// Geschaffte Schritte (Häkchen in der Seitenleiste)
    @Published private(set) var completed: Set<Step> = []
    /// Beim ersten Start vorgeschlagen; wird die Einführung später erneut geöffnet,
    /// zeigt der Schalter den tatsächlichen Zustand
    @Published var launchAtLogin: Bool
    /// Die Einführung läuft nicht zum ersten Mal (z. B. über Einstellungen → Über geöffnet)
    let isRerun: Bool

    let settings: AppSettings
    /// Beispieldatei; wird umbenannt, wenn auf der ersten Seite die Sprache wechselt
    @Published var sampleURL: URL?
    var onFinish: (_ completed: Bool) -> Void = { _ in }
    /// Ziehen der Beispieldatei hat begonnen: Die Ablage muss davon erfahren, denn
    /// Ziehen aus dem eigenen Fenster melden die Ereignisse des Systems nicht.
    var onSampleDragStarted: () -> Void = {}

    init(settings: AppSettings, sampleURL: URL?) {
        self.settings = settings
        self.sampleURL = sampleURL
        isRerun = settings.didLaunchBefore
        launchAtLogin = settings.didLaunchBefore ? LoginItem.isOn : true
    }

    enum LoginItemChange: Equatable { case register, unregister }

    /// Was beim Abschluss mit „Beim Anmelden öffnen“ geschieht. Nur „Fertig“ ändert etwas
    /// (Überspringen und Schließen nie); abgemeldet wird nur bei einem erneuten Durchlauf,
    /// beim ersten Start bleibt es beim Anmelden auf Wunsch.
    static func loginItemChange(completed: Bool, wanted: Bool, isRerun: Bool, enabled: Bool) -> LoginItemChange? {
        guard completed else { return nil }
        if wanted && !enabled { return .register }
        // Seit 1.30.0 Beta 21 ist BarDrop ab dem ersten Start angemeldet: Wer es in der
        // Einführung ausschaltet und auf „Fertig“ klickt, wird abgemeldet
        if !wanted && enabled { return .unregister }
        return nil
    }

    /// Schritte zum Mitmachen
    static let practice: [Step] = [.drop, .hover, .takeOut, .retrieve, .shortcut, .detach]

    /// Herausziehen: Das Foto liegt auf dem kleinen Schreibtisch der Übung
    @Published var onDesk = false

    /// Vom Rand abziehen: Die echte Ablage schwebt gerade frei
    @Published var shelfFloating = false
    /// Schwebende Ablage zurück an den Rand (esc im Fenster der Einführung)
    var onReturnShelf: () -> Void = {}

    /// Das Foto kam aus der Ablage auf dem Schreibtisch der Übung an
    func deskReceived() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { onDesk = true }
        complete(.takeOut)
    }

    /// Der aktuelle Schritt ist geschafft
    var stepDone: Bool { completed.contains(step) }

    func go(to step: Step) {
        visit &+= 1
        withAnimation(.easeOut(duration: 0.18)) { self.step = step }
    }

    /// Zählt jeden Seitenwechsel: Ein verzögertes Weiter gilt nur für den Besuch, in dem der
    /// Schritt geschafft wurde. Sonst sprang die Seite nach „Weiter“ und gleich „Zurück“
    /// noch einmal von selbst weiter
    private var visit = 0

    /// Einen Schritt zurück
    func back() {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        go(to: previous)
    }

    func advance() {
        // Mit „Los geht’s“ ist die erste Seite erledigt: ihr Punkt wird grün wie die der
        // Übungen, sonst blieb er als einziger grau (Nutzer, 31.10.2026)
        if step == .welcome { completed.insert(.welcome) }
        guard let next = Step(rawValue: step.rawValue + 1) else {
            onFinish(true)
            return
        }
        go(to: next)
    }

    /// Ein Schritt wurde gemacht: abhaken, kurz stehen lassen, weiter.
    func complete(_ done: Step) {
        Diagnostics.shared.record("intro", "complete \(done) current=\(step)")
        guard step == done, !completed.contains(done) else { return }
        if done == .drop {
            // Ablegen: ohne Bestätigung gleich weiter. Erst beim Weitergehen als geschafft
            // markieren: Sonst blitzten kurz „Weiter“ und die leere Karte auf. Den Impuls gab
            // es schon, als das Foto die Ablage erreichte.
            let visit = visit
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                guard let self, self.visit == visit, self.step == done, !self.completed.contains(done) else { return }
                self.completed.insert(done)
                self.advance()
            }
            return
        }
        Haptics.tap()
        withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) { _ = completed.insert(done) }
        // Abgezogen: nicht von selbst weiter. Man soll mit der schwebenden Ablage spielen und
        // sie zurückholen können; weiter geht es mit „Weiter“
        if done == .detach { return }
        // Der Hinweis auf ⌘Z nach dem Papierkorb braucht etwas länger zum Lesen
        let pause = done == .retrieve ? 3.2 : 1.4
        let visit = visit
        DispatchQueue.main.asyncAfter(deadline: .now() + pause) { [weak self] in
            guard let self, self.visit == visit, self.step == done else { return }
            self.advance()
        }
    }
}

final class OnboardingController: NSObject, NSWindowDelegate {
    private let store: ShelfStore
    private let ui: ShelfUIModel
    private let settings: AppSettings
    /// Ohne „private“, damit Tests den Ablauf steuern können
    let model: OnboardingModel
    private var window: NSWindow?
    /// Abgedunkelter Hintergrund auf allen Bildschirmen: Klicks daneben öffnen keine andere
    /// App, die Einführung bleibt vorn, bis man sie beendet
    private var backdrops: [IntroBackdrop] = []
    /// Abdunkeln auch am Rand der Ablage, ohne dort Zeiger und Ziehen abzufangen
    private var bandShades: [IntroBandShade] = []
    private var screenObserver: NSObjectProtocol?
    private var edgeSubscription: AnyCancellable?
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
    /// Zeigt die Ablage am Rand, solange die Einführung sie braucht: offen (Willkommen,
    /// damit man sieht, wo sie ist), als Streifen (Übungen) oder gar nicht (nil).
    var showGuide: (ShelfUIModel.Level?) -> Void = { _ in }
    /// Schwebende Ablage mit der normalen Bewegung zurück an den Rand
    var returnShelfToEdge: () -> Void = {} {
        didSet { model.onReturnShelf = returnShelfToEdge }
    }

    /// Bildschirm mit der Ablage: Dort erscheint auch das Fenster der Einführung
    var shelfScreen: () -> NSScreen? = { nil }

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
        showBackdrop()
        if let window { Self.centerExactly(window, on: shelfScreen()) }
        window?.makeKeyAndOrderFront(nil)
        if let window { observeWindow(window) }
        // Beim ersten Start kann die Aktivierung von BarDrop später ankommen (macOS
        // aktiviert kooperativ). Das Fenster liegt dann zwar über allem, hat aber keinen
        // Fokus: kurz danach noch einmal nachfassen
        for delay in [0.3, 1.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, let window = self.window, window.isVisible, !window.isKeyWindow,
                      NSApp.modalWindow == nil else { return }
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
            }
        }
        updateCutout()
        // Erst jetzt ist die Ablage verbunden: den aktuellen Schritt zeigen (Willkommen: offen)
        prepare(model.step)
    }

    // MARK: Hintergrund

    /// Über dem Dock, damit auch dort kein Klick eine App öffnet. Das Fenster der Einführung
    /// liegt darüber, die Ablage (Statusleistenebene) noch höher: Ablegen und Herausziehen
    /// am Bildschirmrand funktionieren wie immer.
    static let backdropLevel: NSWindow.Level = {
        let dock = Int(CGWindowLevelForKey(.dockWindow))
        // Nie über Menüs und nie so hoch, dass die Ablage nicht mehr darüber passt
        let level = min(dock + 1, NSWindow.Level.popUpMenu.rawValue - 3)
        Log.app.info("Einführung: Dock-Ebene \(dock, privacy: .public), Hintergrund \(level, privacy: .public), Menüleiste \(NSWindow.Level.statusBar.rawValue, privacy: .public)")
        return NSWindow.Level(rawValue: level)
    }()

    private func showBackdrop() {
        let fresh = backdrops.isEmpty
        backdrops.forEach { $0.orderOut(nil) }
        bandShades.forEach { $0.orderOut(nil) }
        backdrops = NSScreen.screens.map { screen in
            let backdrop = IntroBackdrop(screen: screen, edge: settings.edge,
                                         shelfWidth: CGFloat(settings.shelfWidth))
            backdrop.onMove = { [weak self] in self?.wakeShelf() }
            backdrop.onClick = { [weak self] in self?.bringToFront() }
            backdrop.alphaValue = fresh ? 0 : 1
            backdrop.orderFrontRegardless()
            return backdrop
        }
        bandShades = NSScreen.screens.map { screen in
            let shade = IntroBandShade(screen: screen, edge: settings.edge,
                                       shelfWidth: CGFloat(settings.shelfWidth))
            shade.onMove = { [weak self] in self?.wakeShelf() }
            shade.alphaValue = fresh ? 0 : 1
            shade.orderFrontRegardless()
            return shade
        }
        updateCutout()
        if fresh {
            // Ruhig abdunkeln, nicht wie geschnitten: etwas länger und weich an- und auslaufend
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.6
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                backdrops.forEach { $0.animator().alphaValue = 1 }
                bandShades.forEach { $0.animator().alphaValue = 1 }
            }
        }
        if edgeSubscription == nil {
            // Rand auf der ersten Seite gewechselt: der freie Bereich wandert mit
            edgeSubscription = settings.$edge.removeDuplicates().receive(on: DispatchQueue.main)
                .sink { [weak self] edge in
                    guard let self else { return }
                    let width = CGFloat(self.settings.shelfWidth)
                    self.backdrops.forEach { $0.update(edge: edge, shelfWidth: width) }
                    self.bandShades.forEach { $0.update(edge: edge, shelfWidth: width) }
                    self.refreshAfterEdgeChange()
                }
        }
        if screenObserver == nil {
            // Bildschirm angeschlossen oder umgestellt: Hintergrund neu verteilen
            screenObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
            ) { [weak self] _ in
                guard let self, !self.backdrops.isEmpty else { return }
                self.showBackdrop()
            }
        }
    }

    private func hideBackdrop() {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        edgeSubscription = nil
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers = []
        let leaving: [NSWindow] = backdrops + bandShades
        backdrops = []
        bandShades = []
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.35
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            leaving.forEach { $0.animator().alphaValue = 0 }
        }, completionHandler: {
            leaving.forEach { $0.orderOut(nil) }
        })
    }

    /// Hinter dem Fenster nicht abdunkeln (wandert mit, wenn man das Fenster verschiebt)
    private func updateCutout() {
        // Keine Aussparung mehr: Beim Verschieben des Fensters hinkte sie sichtbar hinterher
        backdrops.forEach { $0.setCutout(nil) }
    }

    private var windowObservers: [NSObjectProtocol] = []

    private func observeWindow(_ window: NSWindow) {
        guard windowObservers.isEmpty else { return }
        let center = NotificationCenter.default
        windowObservers = [NSWindow.didMoveNotification, NSWindow.didResizeNotification].map {
            center.addObserver(forName: $0, object: window, queue: .main) { [weak self] _ in self?.updateCutout() }
        }
    }

    /// Nach dem Wechsel des Rands (erste Seite): Die Ablage zieht um und die abgedunkelten
    /// Flächen werden neu verteilt. Dabei blieb das Fenster der Einführung teils ohne Fokus
    /// und zeichnete sich nicht neu: Der Umschalter zeigte noch die alte Seite, und der
    /// nächste Klick ging ins Leere. Darum hier neu zeichnen und den Fokus sichern, auch
    /// noch einmal, nachdem die Ablage umgezogen ist.
    private func refreshAfterEdgeChange() {
        let refresh = { [weak self] in
            guard let self, let window = self.window, window.isVisible else { return }
            if !window.isKeyWindow { window.makeKey() }
            // Die Ansicht selbst neu auslegen lassen (erst das bringt SwiftUI dazu, den neuen
            // Stand zu übernehmen), dann zeichnen
            window.contentView?.needsLayout = true
            window.contentView?.layoutSubtreeIfNeeded()
            window.contentView?.needsDisplay = true
            window.display()
        }
        DispatchQueue.main.async(execute: refresh)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: refresh)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: refresh)
    }

    /// Klick daneben: zurück zur Einführung
    private func bringToFront() {
        NSApp.activate(ignoringOtherApps: true)
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
            .receive(on: RunLoop.main)
            .sink { [weak self] level in self?.levelChanged(level) }
            .store(in: &subscriptions)

        // Übung „Aktionen“: das Foto auf eine Aktion der Leiste gezogen (normal der Papierkorb)
        NotificationCenter.default.publisher(for: ShelfActions.didPerformAction)
            .receive(on: RunLoop.main)
            .sink { [weak self] note in
                guard let self, let urls = note.userInfo?["urls"] as? [URL] else { return }
                let name = self.model.sampleURL?.lastPathComponent
                if urls.contains(where: { $0.lastPathComponent == name }) { self.model.complete(.retrieve) }
            }
            .store(in: &subscriptions)

        // Übung „Vom Rand abziehen“: losgelassen fern der Ränder, die Ablage schwebt
        NotificationCenter.default.publisher(for: EdgeController.didFloat)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.model.step == .detach else { return }
                self.model.shelfFloating = true
                self.model.complete(.detach)
            }
            .store(in: &subscriptions)

        ui.$isTorn
            .receive(on: RunLoop.main)
            .sink { [weak self] torn in
                if !torn, self?.model.shelfFloating == true { self?.model.shelfFloating = false }
            }
            .store(in: &subscriptions)
    }

    private func prepare(_ step: OnboardingModel.Step) {
        let previous = IntroGate.step
        IntroGate.step = step
        Diagnostics.shared.record("intro", "step \(step) sample=\(model.sampleURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false)")
        // Ab „Los geht’s“ steht die Ablage offen am Rand und bleibt beim Ablegen, bei den
        // Aktionen und zum Abziehen offen. Zum Öffnen mit dem Zeiger ist sie zu, das übt man selbst.
        let guide: ShelfUIModel.Level? = [.drop, .takeOut, .retrieve, .detach].contains(step) ? .expanded : nil
        if previous == .detach, step != .detach, model.shelfFloating {
            // Schwebt sie noch, gleitet sie erst zurück an den Rand, statt hinzuspringen
            // (showGuide beendet ein Abziehen sofort)
            returnShelfToEdge()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                guard let self, !self.finished, IntroGate.step == step else { return }
                self.showGuide(guide)
            }
        } else {
            showGuide(guide)
        }
        if step == .drop || step == .takeOut || step == .retrieve { ensureSample() }
        // Herausziehen und Aktionen brauchen das Foto in der Ablage: Wurde „Ablegen“
        // übersprungen oder hat das Herausziehen es mitgenommen, liegt es wieder dort
        if step == .takeOut || step == .retrieve { ensureSampleInShelf() }
        if step == .takeOut { model.onDesk = false }
        if step == .retrieve { TrashState.shared.refresh() }
        // Ist die Ablage schon zu, kommt kein neues „hidden“ mehr: dann gleich scharf, sonst
        // zählte das erste Öffnen nach dem Sprung über die Punkte nicht
        hoverArmed = ui.level == .hidden
        switch step {
        case .drop:
            baseline = Set(store.entries.map(\.id))
            renameSampleForLanguage()
        default:
            break
        }
    }

    /// Schritt „Mit dem Zeiger öffnen“: Erst zählt es, wenn die Ablage zu war
    private var hoverArmed = false

    private func levelChanged(_ level: ShelfUIModel.Level) {
        guard model.step == .hover else { return }
        if level == .hidden { hoverArmed = true }
        if level == .expanded && hoverArmed { model.complete(.hover) }
    }

    /// Das Übungsfoto muss da sein; wurde es woandershin gezogen (z. B. auf den Schreibtisch,
    /// wo der Finder es verschiebt), wird es neu angelegt
    private func ensureSample() {
        if let url = model.sampleURL, FileManager.default.fileExists(atPath: url.path) { return }
        if let fresh = Self.makeSample() { model.sampleURL = fresh }
    }

    private func ensureSampleInShelf() {
        guard let url = model.sampleURL else { return }
        let name = url.lastPathComponent
        guard !store.entries.contains(where: { $0.files.contains { $0.url.lastPathComponent == name } }) else { return }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("BarDropIntro-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
        store.ingest(from: pasteboard) { _ in pasteboard.releaseGlobally() }
    }

    private func entriesChanged(_ entries: [ShelfEntry]) {
        if model.step == .drop || model.step == .takeOut || model.step == .retrieve {
            Diagnostics.shared.record("intro", "entries=\(entries.count) new=\(entries.filter { !baseline.contains($0.id) }.count) step=\(model.step)")
        }
        let name = model.sampleURL?.lastPathComponent
        for entry in entries where entry.files.contains(where: { $0.url.lastPathComponent == name }) {
            if !baseline.contains(entry.id) { sampleEntries.insert(entry.id) }
        }
        switch model.step {
        case .drop:
            if entries.contains(where: { !baseline.contains($0.id) }) {
                model.complete(.drop)
            }
        default:
            break
        }
    }

    /// Die Sprache kann auf der ersten Seite gewechselt worden sein: Die Beispieldatei
    /// bekommt den Namen in der aktuellen Sprache, bevor sie zum ersten Mal zu sehen ist.
    private func renameSampleForLanguage() {
        guard let url = model.sampleURL, url.lastPathComponent != Self.sampleName else { return }
        let renamed = url.deletingLastPathComponent().appendingPathComponent(Self.sampleName)
        if (try? FileManager.default.moveItem(at: url, to: renamed)) != nil {
            model.sampleURL = renamed
        }
    }

    // MARK: Ende

    private func finish(completed: Bool) {
        guard !finished else { return }
        finished = true
        settings.didLaunchBefore = true
        // Die Beispieldatei hat ihren Zweck erfüllt. Nur sie selbst entfernen, nicht was
        // inzwischen dazugelegt wurde (z. B. eigene Dateien, die mit ihr einen Stapel bilden)
        let name = model.sampleURL?.lastPathComponent
        let sampleFiles = store.entries
            .filter { sampleEntries.contains($0.id) }
            .flatMap(\.files)
            .filter { $0.url.lastPathComponent == name }
            .map(\.url)
        if !sampleFiles.isEmpty { store.forgetFiles(at: sampleFiles) }
        if let url = model.sampleURL { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        switch OnboardingModel.loginItemChange(completed: completed, wanted: model.launchAtLogin,
                                               isRerun: model.isRerun,
                                               enabled: SMAppService.mainApp.status == .enabled) {
        case .register:
            do {
                try SMAppService.mainApp.register()
            } catch {
                Log.app.error("Anmeldeobjekt nicht möglich: \(error.localizedDescription, privacy: .public)")
                Diagnostics.shared.failure("login", "Anmeldeobjekt nicht möglich", error)
            }
        case .unregister:
            do {
                try SMAppService.mainApp.unregister()
            } catch {
                Log.app.error("Anmeldeobjekt ließ sich nicht entfernen: \(error.localizedDescription, privacy: .public)")
                Diagnostics.shared.failure("login", "Anmeldeobjekt ließ sich nicht entfernen", error)
            }
        case nil:
            break
        }
        subscriptions.removeAll()
        showGuide(nil)
        hideBackdrop()
        window?.delegate = nil
        window?.close()
        window = nil
        // Mit „Fertig“ beendet: einmal Konfetti über den ganzen Bildschirm, wie am Ende der
        // Vorführung auf der Website (Nutzer, 31.10.2026)
        if completed { ConfettiShower.play() }
        onClose()
    }

    func windowWillClose(_ notification: Notification) {
        // Mit dem Schließknopf beendet: gilt als erledigt, nichts wird nachgefragt
        DispatchQueue.main.async { [weak self] in self?.finish(completed: false) }
    }

    // MARK: Fenster

    /// Aufbau wie die Einstellungen (Seitenleiste 244 pt), so breit, dass die Szene (500 pt)
    /// mit dem Rand der Einstellungsseiten genau hineinpasst. So hoch, dass unter der längsten
    /// Seite kaum Leerraum bleibt (bei 620 pt stand „Weiter“ weit unter dem Inhalt)
    static let size = NSSize(width: OnboardingView.sidebarWidth + 1 + DemoLayout.shown.width + 2 * OnboardingView.pagePadding,
                             height: 500)

    /// Fenster wie die Einstellungen: hohe, durchsichtige Titelleiste, leicht durchscheinend,
    /// feste Größe, mittig. Liegt über dem abgedunkelten Hintergrund (siehe `backdropLevel`), damit man beim Üben zum Rand ziehen kann.
    /// Ohne „private“ für den Test, der das echte Fenster abbildet
    func makeWindow() -> NSWindow {
        let window = IntroWindow(contentRect: NSRect(origin: .zero, size: Self.size),
                                 styleMask: [.titled, .closable, .fullSizeContentView],
                                 backing: .buffered, defer: false)
        // Ohne Minimieren: Der abgedunkelte Hintergrund bliebe sonst ohne Einführung stehen.
        // Der Knopf bleibt sichtbar, aber ausgegraut, wie Vergrößern bei fester Größe.
        window.standardWindowButton(.miniaturizeButton)?.isEnabled = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.toolbar = NSToolbar(identifier: "BarDropIntroduction")
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .none
        window.title = "BarDrop"
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = NSWindow.Level(rawValue: Self.backdropLevel.rawValue + 1)
        window.collectionBehavior = [.moveToActiveSpace]
        window.delegate = self
        let root = OnboardingView(model: model, openSettings: { [weak self] in
            self?.openSettings()
        })
        // Feste Größe: Die Ansicht darf das Fenster nicht verändern. Sonst übernimmt
        // NSHostingView Größenwünsche der Inhalte, und das Fenster kann wachsen.
        // Erster Klick zählt auch, wenn das Fenster gerade nicht vorn ist (sonst musste man
        // z. B. beim Rand zweimal klicken, weil die Ablage beim Umziehen den Fokus abgab)
        let host = FirstClickHostingView(rootView: AnyView(root.frame(width: Self.size.width, height: Self.size.height)
                                                  .ignoresSafeArea()))
        host.sizingOptions = []
        window.contentView = host
        window.contentMinSize = Self.size
        window.contentMaxSize = Self.size
        window.setContentSize(Self.size)
        Self.centerExactly(window)
        return window
    }

    /// Genau in die Mitte des Bildschirms (sichtbarer Bereich ohne Menüleiste und Dock).
    /// `center()` von macOS setzt Fenster bewusst etwas oberhalb der Mitte.
    static func centerExactly(_ window: NSWindow, on preferred: NSScreen? = nil) {
        guard let screen = preferred ?? window.screen ?? NSScreen.main else { return }
        let area = screen.visibleFrame
        let size = window.frame.size
        window.setFrameOrigin(NSPoint(x: (area.midX - size.width / 2).rounded(),
                                      y: (area.midY - size.height / 2).rounded()))
    }

    /// Dieselbe Beispieldatei wie beim Verstellen der Symbolgröße („Foto.jpg“)
    static var sampleName: String { L("Photo.jpg", "Foto.jpg") }

    /// Beispielfoto zum Ablegen. Liegt in einem temporären Ordner und wird beim
    /// Ablegen wie ein Bild aus dem Web in die Ablage kopiert.
    static func makeSample() -> URL? {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BarDropEinfuehrung-\(UUID().uuidString)", isDirectory: true)
        let url = dir.appendingPathComponent(sampleName)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        // Eine ruhige Landschaft: weicher Himmel, Sonne, zwei sanfte Hügel. Vorher kantige Berge
        // und ein See in vielen Farben, das wirkte wie Clipart (Nutzer, 22.11.2026)
        let image = NSImage(size: NSSize(width: 640, height: 480), flipped: false) { rect in
            NSGradient(colors: [NSColor(red: 0.98, green: 0.84, blue: 0.70, alpha: 1),
                                NSColor(red: 0.62, green: 0.76, blue: 0.95, alpha: 1),
                                NSColor(red: 0.38, green: 0.58, blue: 0.92, alpha: 1)])?.draw(in: rect, angle: 90)
            NSGradient(starting: NSColor(red: 1, green: 0.96, blue: 0.86, alpha: 0.9),
                       ending: NSColor(red: 1, green: 0.96, blue: 0.86, alpha: 0))?
                .draw(fromCenter: NSPoint(x: 430, y: 230), radius: 0, toCenter: NSPoint(x: 430, y: 230), radius: 150, options: [])
            NSColor(red: 1, green: 0.97, blue: 0.9, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: 400, y: 200, width: 60, height: 60)).fill()
            func hill(from y0: CGFloat, c1: NSPoint, c2: NSPoint, to y1: CGFloat, _ top: NSColor, _ bottom: NSColor) {
                let path = NSBezierPath()
                path.move(to: NSPoint(x: 0, y: y0))
                path.curve(to: NSPoint(x: 640, y: y1), controlPoint1: c1, controlPoint2: c2)
                path.line(to: NSPoint(x: 640, y: 0))
                path.line(to: .zero)
                path.close()
                NSGradient(starting: top, ending: bottom)?.draw(in: path, angle: -90)
            }
            hill(from: 230, c1: NSPoint(x: 220, y: 330), c2: NSPoint(x: 420, y: 150), to: 210,
                 NSColor(red: 0.45, green: 0.62, blue: 0.55, alpha: 1), NSColor(red: 0.30, green: 0.48, blue: 0.42, alpha: 1))
            hill(from: 120, c1: NSPoint(x: 260, y: 90), c2: NSPoint(x: 420, y: 230), to: 170,
                 NSColor(red: 0.28, green: 0.47, blue: 0.36, alpha: 1), NSColor(red: 0.18, green: 0.34, blue: 0.27, alpha: 1))
            return true
        }
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let jpg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9]),
              (try? jpg.write(to: url)) != nil else { return nil }
        return url
    }
}

// MARK: Oberfläche

/// Fenster der Einführung. Eigene Klasse, damit ⌘W sie wie mit dem Schließknopf beendet
/// (siehe AppDelegate) und sie Tastatureingaben bekommt (Eingabetaste, Escape).
/// Nimmt den ersten Klick an, auch wenn das Fenster nicht aktiv ist
final class FirstClickHostingView: NSHostingView<AnyView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class IntroWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Abgedunkelte Fläche hinter der Einführung über einem Bildschirm, außer dem Streifen am
/// Rand der Ablage (den dunkelt `IntroBandShade` ab). Fängt Klicks ab,
/// nimmt nichts zum Ablegen an (Ziehen geht durch zur Ablage) und wird nie selbst aktiv.
final class IntroBackdrop: NSPanel {
    var onClick: () -> Void = {}

    var onMove: () -> Void = {}
    /// Gleichmäßig abgedunkelt, nahtlos an `IntroBandShade`
    private let shade = CALayer()
    private let screenFrame: CGRect
    /// Abdunkeln abseits des Rands
    static let dim: CGFloat = 0.42

    init(screen: NSScreen, edge: ScreenEdge, shelfWidth: CGFloat) {
        screenFrame = screen.frame
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = OnboardingController.backdropLevel
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        let view = ClickCatcher()
        view.onClick = { [weak self] in self?.onClick() }
        view.onMove = { [weak self] in self?.onMove() }
        view.wantsLayer = true
        shade.frame = CGRect(origin: .zero, size: screen.frame.size)
        shade.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer?.addSublayer(shade)
        contentView = view
        update(edge: edge, shelfWidth: shelfWidth)
    }

    /// Der Streifen am Rand, an dem die Ablage erscheint, gehört nicht zu dieser Fläche:
    /// Dort verhalten sich Zeiger, Hinfahren und Ablegen genau wie sonst.
    func update(edge: ScreenEdge, shelfWidth: CGFloat) {
        setFrame(IntroBandShade.frames(screen: screenFrame, edge: edge, shelfWidth: shelfWidth).rest, display: true)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shade.backgroundColor = NSColor.black.withAlphaComponent(Self.dim).cgColor
        CATransaction.commit()
        setCutout(cutout)
    }

    /// Fenster der Einführung in Bildschirmkoordinaten: Dort ist nicht abgedunkelt, damit
    /// es so durchscheint wie die Einstellungen über dem Schreibtisch
    private var cutout: CGRect?

    func setCutout(_ rect: CGRect?) {
        cutout = rect
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let rect, rect.intersects(frame) else {
            shade.mask = nil
            return
        }
        let local = CGRect(x: rect.minX - frame.minX, y: rect.minY - frame.minY, width: rect.width, height: rect.height)
        let mask = CAShapeLayer()
        let path = CGMutablePath()
        path.addRect(CGRect(origin: .zero, size: frame.size))
        path.addRoundedRect(in: local, cornerWidth: 16, cornerHeight: 16)
        mask.path = path
        mask.fillRule = .evenOdd
        mask.frame = CGRect(origin: .zero, size: frame.size)
        shade.mask = mask
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    private final class ClickCatcher: NSView {
        var onClick: () -> Void = {}
        var onMove: () -> Void = {}

        // Zeigerbewegungen über der Fläche gehen an BarDrop selbst, nicht an andere Apps:
        // Damit die Ablage trotzdem wach bleibt, hier melden
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect],
                                           owner: self, userInfo: nil))
        }

        override func mouseMoved(with event: NSEvent) { onMove() }

        // Gezogenes nimmt der Hintergrund an, legt es aber nirgends ab: Sonst fiele es in die
        // App dahinter, und z. B. der Finder verschöbe das Übungsfoto dorthin
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            registerForDraggedTypes(ShelfStore.acceptedTypes)
        }
        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { onMove(); return [] }
        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { onMove(); return [] }
        override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { false }

        override func mouseDown(with event: NSEvent) { onClick() }
        override func rightMouseDown(with event: NSEvent) { onClick() }
        override func otherMouseDown(with event: NSEvent) { onClick() }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }
}

/// Abdunkeln des Streifens am Rand der Ablage, damit der ganze Bildschirm gleich dunkel
/// ist. Nimmt keine Maus- und Ziehereignisse an: Zeiger, Hinfahren und Ablegen gehen
/// durch zu dem, was darunter liegt, und die Ablage (darüber) bleibt hell.
final class IntroBandShade: NSPanel {
    private let screenFrame: CGRect

    init(screen: NSScreen, edge: ScreenEdge, shelfWidth: CGFloat) {
        screenFrame = screen.frame
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = OnboardingController.backdropLevel
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        // Nimmt Mausereignisse an, damit nichts in die App dahinter gezogen werden kann.
        // Die Ablage liegt darüber und bekommt ihre Ereignisse wie immer.
        ignoresMouseEvents = false
        let view = DropBlocker()
        view.onMove = { [weak self] in self?.onMove() }
        view.wantsLayer = true
        shade.frame = CGRect(origin: .zero, size: screen.frame.size)
        shade.backgroundColor = NSColor.black.withAlphaComponent(IntroBackdrop.dim).cgColor
        view.layer?.addSublayer(shade)
        contentView = view
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        update(edge: edge, shelfWidth: shelfWidth)
    }

    var onMove: () -> Void = {}
    private let shade = CALayer()

    func update(edge: ScreenEdge, shelfWidth: CGFloat) {
        setFrame(Self.frames(screen: screenFrame, edge: edge, shelfWidth: shelfWidth).band, display: true)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shade.frame = CGRect(origin: .zero, size: frame.size)
        CATransaction.commit()
    }

    /// Fängt Gezogenes ab, ohne es abzulegen, und meldet Zeigerbewegungen
    private final class DropBlocker: NSView {
        var onMove: () -> Void = {}
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            registerForDraggedTypes(ShelfStore.acceptedTypes)
        }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect],
                                           owner: self, userInfo: nil))
        }
        override func mouseMoved(with event: NSEvent) { onMove() }
        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { onMove(); return [] }
        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { onMove(); return [] }
        override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { false }
    }

    /// Aufteilung eines Bildschirms: Streifen am Rand (so breit wie das Fenster der Ablage)
    /// und der Rest
    static func frames(screen: CGRect, edge: ScreenEdge, shelfWidth: CGFloat) -> (band: CGRect, rest: CGRect) {
        let width = min(shelfWidth + ShelfMetrics.panelMargin, max(screen.width - 1, 1))
        var band = screen
        band.size.width = width
        var rest = screen
        rest.size.width = screen.width - width
        if edge == .right {
            band.origin.x = screen.maxX - width
        } else {
            rest.origin.x = screen.minX + width
        }
        return (band, rest)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

extension OnboardingModel.Step {
    var title: String {
        switch self {
        case .welcome: return L("Set Up", "Einrichten")
        case .drop: return L("Drop", "Ablegen")
        case .takeOut: return L("Drag Out", "Herausziehen")
        case .retrieve: return L("Actions", "Aktionen")
        case .shortcut: return L("Keyboard Shortcut", "Tastaturkurzbefehl")
        case .detach: return L("Pull Off the Edge", "Vom Rand abziehen")
        case .hover: return L("Open with the Pointer", "Mit dem Zeiger öffnen")
        case .features: return L("More Features", "Weitere Funktionen")
        }
    }

    /// Symbol in der Seitenleiste und über der Seite, wie bei den Bereichen der Einstellungen.
    /// Wo es einen passenden Bereich gibt, dessen Farbe
    var symbol: String {
        switch self {
        case .welcome: return "switch.2"
        case .drop: return "tray.and.arrow.down.fill"
        case .hover: return "cursorarrow"
        case .takeOut: return "tray.and.arrow.up.fill"
        case .retrieve: return SettingsPane.actions.symbol
        case .shortcut: return "command"
        case .detach: return "hand.draw.fill"
        case .features: return "ellipsis"
        }
    }

    var tint: Color {
        switch self {
        case .welcome: return Color(red: 0.2, green: 0.47, blue: 1)
        case .drop: return SettingsPane.items.tint
        case .hover: return SettingsPane.opening.tint
        case .takeOut: return Color(red: 0.0, green: 0.68, blue: 0.82)
        case .retrieve: return SettingsPane.actions.tint
        case .shortcut: return SettingsPane.general.tint
        case .detach: return SettingsPane.appearance.tint
        case .features: return SettingsPane.about.tint
        }
    }
}

struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    /// Sprache, Rand und Einstellungen ändern alle Texte sofort
    @ObservedObject private var settings = AppSettings.shared
    var openSettings: () -> Void

    /// Wie die Einstellungen: Seitenleiste mit den Schritten, rechts Überschrift mit Symbol,
    /// darunter Szene, ein Satz und die Übung als Karte. Vorher eine eigene, mittige
    /// Präsentation mit Punkten unten; sie wirkte neben der App fremd und kantig (Nutzer,
    /// 22.11.2026: „mehr wie das Einstellungsmenü“)
    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: OnboardingView.sidebarWidth)
                .frame(maxHeight: .infinity)
                .background(SettingsTheme.sidebarBackdrop)
            Rectangle()
                .fill(SettingsTheme.divider)
                .frame(width: 1)
            VStack(alignment: .leading, spacing: 0) {
                header
                page
                    .id(model.step)
                    .transition(.opacity)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                footer
                    .padding(.horizontal, 20)
                    .padding(.bottom, 18)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(SettingsTheme.contentBackdrop)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SettingsBackdrop().ignoresSafeArea())
        .ignoresSafeArea()
        .environment(\.colorfulIcons, true)
    }

    /// So breit wie in den Einstellungen
    static let sidebarWidth: CGFloat = 244

    // MARK: Seitenleiste

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(OnboardingModel.Step.allCases) { step in
                StepRow(step: step, selected: model.step == step, done: model.completed.contains(step)) {
                    model.go(to: step)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 13)
        .padding(.top, SettingsRoot.sidebarTop)
        .padding(.bottom, 13)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("Step \(model.step.rawValue + 1) of \(OnboardingModel.Step.allCases.count)",
                              "Schritt \(model.step.rawValue + 1) von \(OnboardingModel.Step.allCases.count)"))
    }

    // MARK: Überschrift

    /// Symbol und Titel wie über den Seiten der Einstellungen, auf Höhe der Fensterknöpfe
    private var header: some View {
        HStack(spacing: 10) {
            SymbolTile(symbol: model.step.symbol, tint: model.step.tint, size: 24)
            Text(model.step.title)
                .font(.system(size: 17, weight: .semibold))
        }
        .padding(.leading, 20)
        .frame(height: SettingsRoot.sidebarTop)
        .frame(maxWidth: .infinity, alignment: .leading)
        .id(model.step)
        .transition(.opacity)
    }

    @ViewBuilder
    private var page: some View {
        switch model.step {
        case .welcome: WelcomePage(model: model, settings: settings)
        case .drop: DropPage(model: model, settings: settings)
        case .takeOut: TakeOutPage(model: model, settings: settings)
        case .retrieve: RetrievePage(model: model, settings: settings)
        case .shortcut: ShortcutPage(model: model, settings: settings)
        case .detach: DetachPage(model: model, settings: settings)
        case .hover: HoverPage(model: model, settings: settings)
        case .features: FeaturesPage(model: model, settings: settings)
        }
    }

    // MARK: Unten: Zurück und Weiter

    private var footer: some View {
        HStack(spacing: 8) {
            switch model.step {
            case .welcome:
                Button(L("Skip", "Überspringen")) { model.onFinish(false) }
                    .buttonStyle(KlackButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(L("Let’s Go", "Los geht’s")) { model.advance() }
                    .buttonStyle(KlackButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
            case .features:
                Button(L("Back", "Zurück")) { model.back() }
                    .buttonStyle(KlackButtonStyle())
                Spacer()
                Button(L("Done", "Fertig")) { model.advance() }
                    .buttonStyle(KlackButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
            default:
                Button(L("Back", "Zurück")) { model.back() }
                    .buttonStyle(KlackButtonStyle())
                Spacer()
                // Schwebt die Ablage, holt esc sie zurück an den Rand, auch wenn das Fenster
                // der Einführung den Fokus hat (wie esc in der Ablage selbst)
                if model.step == .detach && model.shelfFloating {
                    Button("") { model.onReturnShelf() }
                        .keyboardShortcut(.cancelAction)
                        .opacity(0)
                        .frame(width: 0, height: 0)
                        .accessibilityHidden(true)
                }
                // Seiten ohne Übung: gleich „Weiter“
                if model.stepDone || !OnboardingModel.practice.contains(model.step) {
                    Button(L("Continue", "Weiter")) { model.advance() }
                        .buttonStyle(KlackButtonStyle(prominent: true))
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button(L("Skip", "Überspringen")) { model.advance() }
                        .buttonStyle(KlackButtonStyle())
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
    }
}

/// Ein Schritt in der Seitenleiste, wie ein Bereich der Einstellungen. Geschaffte Schritte
/// tragen rechts einen grünen Haken.
private struct StepRow: View {
    let step: OnboardingModel.Step
    let selected: Bool
    let done: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                SymbolTile(symbol: step.symbol, tint: step.tint)
                Text(step.title)
                    .font(.system(size: 14))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if done {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 15))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.green)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                        .accessibilityLabel(L("Done", "Geschafft"))
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 42)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? SettingsTheme.sidebarSelection : Color.primary.opacity(hovering ? 0.04 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.spring(response: 0.4, dampingFraction: 0.75), value: done)
    }
}

// MARK: Aufbau einer Seite

/// Eine Seite wie in den Einstellungen: Szene, darunter die Übung. Alles an einer linken Kante.
private struct PresentationPage<Hero: View, Practice: View>: View {
    @ViewBuilder let hero: () -> Hero
    @ViewBuilder let practice: () -> Practice

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            hero()
                .frame(width: DemoLayout.shown.width, height: DemoLayout.shown.height)
            // Kein erklärender Satz mehr unter der Szene: Sie zeigt es, die Karte sagt in einer
            // Zeile, was zu tun ist (Nutzer, 22.11.2026: „viel zu viel Text“)
            practice()
                .padding(.top, 16)
            Spacer(minLength: 0)
        }
        // Feste Breite: Sonst bricht der Satz nicht um und das Fenster würde breiter
        .frame(width: DemoLayout.shown.width, alignment: .topLeading)
        .padding(.horizontal, OnboardingView.pagePadding)
        .padding(.top, 4)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

extension OnboardingView {
    /// Rand der Seiten wie in den Einstellungen; die Szene füllt die Breite genau
    static let pagePadding: CGFloat = 20
}

/// Die Übung einer Seite als Karte wie in den Einstellungen: links das Objekt, rechts was zu tun ist.
/// Geschafft weicht das Objekt einem grünen Haken (wie in den Systemeinstellungen).
private struct TaskCard<Leading: View>: View {
    let done: Bool
    let instruction: String
    let confirmation: String
    /// Platz links für das Objekt. Breiter für Tastenkappen: Bei vier Sondertasten ragten sie
    /// über die Karte hinaus und lagen auf dem Text (Nutzer, 31.10.2026)
    var leadingWidth: CGFloat = 120
    /// Übung am Rand: ein Pfeil rechts in der Karte zeigt, wohin (links: gespiegelt)
    var pointsTo: ScreenEdge? = nil
    @ViewBuilder let leading: () -> Leading

    static var height: CGFloat { 100 }

    var body: some View {
        // Ohne Überschrift „Probier’s aus“ über jeder Karte: Sie wiederholte sich auf jeder
        // Seite und sagte nichts, was die Karte nicht schon zeigt (Nutzer, 22.11.2026)
        VStack(alignment: .leading, spacing: 0) {
            SettingsCard {
                HStack(spacing: 14) {
                    ZStack {
                        leading()
                            .opacity(done ? 0 : 1)
                            .scaleEffect(done ? 0.85 : 1)
                        if done {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 40, weight: .regular))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, Color.green)
                                .transition(.scale(scale: 0.6).combined(with: .opacity))
                        }
                    }
                    .frame(width: leadingWidth, height: Self.height - 16)
                    Text(done && !confirmation.isEmpty ? confirmation : instruction)
                        .font(.system(size: 15, weight: .medium))
                        .fixedSize(horizontal: false, vertical: true)
                        .id(done)
                        .transition(.opacity)
                    Spacer(minLength: 0)
                    if let pointsTo, !done {
                        Image(systemName: pointsTo == .right ? "arrow.right" : "arrow.left")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                }
                .padding(.leading, 12)
                .padding(.trailing, 16)
                .frame(height: Self.height)
            }
        }
        .frame(width: DemoLayout.shown.width)
        .animation(.spring(response: 0.4, dampingFraction: 0.75), value: done)
    }
}

/// Wort für den gewählten Rand im Satz („an den rechten Rand“)
private func edgeWord(_ settings: AppSettings) -> String {
    settings.edge == .right ? L("right", "rechten") : L("left", "linken")
}

// MARK: Willkommen

private struct WelcomePage: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject var settings: AppSettings

    var body: some View {
        PresentationPage() {
            ShelfStage(scene: .overview)
        } practice: {
            SettingsCard {
                SettingsRow(L("Language", "Sprache")) {
                    SegmentedValue(selection: $settings.language,
                                   options: AppLanguage.allCases.map { ($0, $0.title) })
                }
                SettingsRow(L("Screen edge", "Bildschirmrand")) {
                    SegmentedValue(selection: $settings.edge,
                                   options: ScreenEdge.allCases.map { ($0, $0.title) })
                }
            }
            .frame(width: DemoLayout.shown.width)
        }
    }
}

// MARK: Ablegen

private struct DropPage: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject var settings: AppSettings

    var body: some View {
        PresentationPage() {
            ShelfStage(scene: .drop)
        } practice: {
            TaskCard(done: model.stepDone,
                     instruction: L("Drag the photo to the \(edgeWord(settings)) edge.",
                                    "Zieh das Foto an den \(edgeWord(settings)) Rand."),
                     confirmation: "",
                     pointsTo: settings.edge) {
                SampleTile(url: model.sampleURL, edge: settings.edge, onDragStarted: model.onSampleDragStarted)
            }
        }
    }
}

// MARK: Herausziehen

private struct TakeOutPage: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject var settings: AppSettings

    var body: some View {
        PresentationPage() {
            ShelfStage(scene: .takeOut)
        } practice: {
            TaskCard(done: model.stepDone,
                     instruction: L("Drag the photo from the shelf onto the folder.",
                                    "Zieh das Foto aus der Ablage auf den Ordner."),
                     confirmation: L("Arrived.", "Angekommen.")) {
                FolderTarget(received: model.onDesk) { model.deskReceived() }
            }
        }
    }
}

/// Ein Ordner wie im Finder als Ziel der Übung: Symbol und Name. Liegt das Foto darüber,
/// wird er markiert wie im Finder. Nimmt nur Objekte aus der Ablage an.
private struct FolderTarget: View {
    let received: Bool
    let onDrop: () -> Void
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 4) {
            Image(nsImage: NSWorkspace.shared.icon(for: .folder))
                .resizable()
                .interpolation(.high)
                .frame(width: 72, height: 72)
                .padding(4)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(targeted ? 0.14 : 0))
                )
            Text(L("Projects", "Projekte"))
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(targeted ? Color(nsColor: .selectedContentBackgroundColor) : .clear)
                )
                .foregroundStyle(targeted ? Color.white : Color.primary)
        }
        .animation(.easeOut(duration: 0.12), value: targeted)
        .overlay(ReturnDropTarget(enabled: !received, targeted: $targeted, onDrop: onDrop))
        .help(L("Drag the photo here", "Foto hierher ziehen"))
    }
}

// MARK: Aktionen

private struct RetrievePage: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject var settings: AppSettings

    /// Der Papierkorb liegt in der Leiste (Standard); sonst irgendeine Aktion
    private var hasTrash: Bool { settings.quickActions.contains { $0.kind == .trash } }

    var body: some View {
        PresentationPage() {
            ShelfStage(scene: .dragOut)
        } practice: {
            TaskCard(done: model.stepDone,
                     instruction: hasTrash
                        ? L("Drag the photo onto the Trash.", "Zieh das Foto auf den Papierkorb.")
                        : L("Drag the photo onto an action.", "Zieh das Foto auf eine Aktion."),
                     confirmation: hasTrash ? L("In the Trash. ⌘Z brings it back.", "Im Papierkorb. ⌘Z holt es zurück.")
                                            : L("Done. Actions work with any item.", "Erledigt. Aktionen funktionieren mit jedem Objekt.")) {
                // Immer der leere Papierkorb: Der volle mit bunten Resten wirkte unruhig (Nutzer, 22.11.2026)
                Image(nsImage: NSImage(named: hasTrash ? NSImage.trashEmptyName : NSImage.folderName) ?? NSImage())
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 72, height: 72)
            }
        }
    }
}

// MARK: Tastaturkurzbefehl

private struct ShortcutPage: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject var settings: AppSettings

    /// Tasten so groß wie bisher, bei vielen Sondertasten kleiner, damit sie in die Karte passen
    private var keys: [(symbol: String, name: String)] { ShortcutKeys.keys(settings) }
    private var keySize: CGFloat { min(36, 230 / KeyCaps.width(keys, size: 1)) }

    var body: some View {
        PresentationPage() {
            ShelfStage(scene: .shortcut)
        } practice: {
            TaskCard(done: model.stepDone,
                     instruction: L("Press \(settings.hotKeyDescription).", "Drück \(settings.hotKeyDescription)."),
                     confirmation: L("Works anywhere. ⌘V then puts in what you copied.",
                                     "Geht überall. ⌘V legt dann Kopiertes hinein."),
                     leadingWidth: max(120, KeyCaps.width(keys, size: keySize) + 12)) {
                KeyCaps(keys: keys, size: keySize, pressed: false)
            }
        }
    }
}

// MARK: Vom Rand abziehen

/// Die echte Ablage steht offen am Rand und lässt sich nur in diesem Schritt abziehen
/// (IntroGate.allowsTear). Geschafft ist es, sobald sie frei schwebt.
private struct DetachPage: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject var settings: AppSettings

    var body: some View {
        PresentationPage() {
            ShelfStage(scene: .detach)
        } practice: {
            TaskCard(done: model.stepDone,
                     instruction: L("Grab the shelf at the top and pull it away from the edge.",
                                    "Greif die Ablage oben und zieh sie vom Rand weg."),
                     confirmation: L("To put it back, drag it to an edge or press esc.",
                                     "Zurück an den Rand: hinziehen oder esc drücken.")) {
                Image(systemName: "hand.draw")
                    .font(.system(size: 44, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: Mit dem Zeiger öffnen

private struct HoverPage: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject var settings: AppSettings

    var body: some View {
        PresentationPage() {
            ShelfStage(scene: .hover)
        } practice: {
            TaskCard(done: model.stepDone,
                     instruction: settings.openMode == .click
                        ? L("Move the pointer to the \(edgeWord(settings)) edge and click the strip.",
                            "Fahr an den \(edgeWord(settings)) Rand und klick auf den Streifen.")
                        : L("Move the pointer to the \(edgeWord(settings)) edge.",
                            "Fahr mit dem Zeiger an den \(edgeWord(settings)) Rand."),
                     confirmation: L("That’s how it opens.", "So öffnet sie sich."),
                     pointsTo: settings.edge) {
                Image(systemName: "cursorarrow.motionlines")
                    .font(.system(size: 44, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                    // Die Linien zeigen, woher der Zeiger kommt: am rechten Rand gespiegelt
                    .scaleEffect(x: settings.edge == .right ? -1 : 1)
            }
        }
    }
}

/// Tasten als Kappen wie unter Einstellungen → Tastatur; nach dem Drücken in Akzentfarbe
struct KeyCaps: View {
    let keys: [(symbol: String, name: String)]
    let size: CGFloat
    let pressed: Bool
    @Environment(\.colorScheme) private var colorScheme

    /// Dunkel wie bisher, hell als weiße Tasten wie unter Einstellungen → Tastatur
    private var keyFill: Color {
        colorScheme == .dark ? Color.primary.opacity(0.1) : SettingsTheme.keyActive
    }
    private var keyBorder: Color {
        colorScheme == .dark ? Color.primary.opacity(0.1) : SettingsTheme.keyBorder
    }

    /// Breite der ganzen Reihe (Tasten mit Namen sind breiter, siehe unten)
    static func width(_ keys: [(symbol: String, name: String)], size: CGFloat) -> CGFloat {
        let caps = keys.reduce(0) { $0 + ($1.name.isEmpty ? size : size * 1.2) }
        return caps + size * 0.13 * CGFloat(max(0, keys.count - 1))
    }

    var body: some View {
        HStack(spacing: size * 0.13) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                VStack(alignment: .leading, spacing: 0) {
                    if key.name.isEmpty {
                        Text(key.symbol)
                            .font(.system(size: size * 0.32, weight: .medium))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        Text(key.symbol).font(.system(size: size * 0.24, weight: .medium))
                        Spacer(minLength: 0)
                        Text(key.name).font(.system(size: size * 0.17, weight: .medium))
                    }
                }
                .foregroundStyle(pressed ? Color.white : Color.primary)
                .padding(.horizontal, size * 0.15)
                .padding(.vertical, size * 0.12)
                .frame(width: key.name.isEmpty ? size : size * 1.2, height: size, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: size * 0.16, style: .continuous)
                        .fill(pressed ? Color(nsColor: .controlAccentColor) : keyFill)
                        .shadow(color: .black.opacity(0.18), radius: 1.5, y: 1.5)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.16, style: .continuous)
                        .strokeBorder(keyBorder, lineWidth: 1)
                )
                .scaleEffect(pressed ? 0.96 : 1)
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: pressed)
    }
}

// MARK: Mehr entdecken

private struct FeaturesPage: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject var settings: AppSettings

    /// Jede Funktion trägt das Symbol der Seite in den Einstellungen, auf der man sie
    /// einstellt (Nutzer, 31.10.2026: „Die müssen gleich sein“)
    private struct Feature: Identifiable {
        let id: String
        let pane: SettingsPane
        let title: String
        let text: String
    }

    private var features: [Feature] {
        [
            Feature(id: "keys", pane: .general,
                    title: L("Keys like in the Finder", "Tasten wie im Finder"),
                    text: L("Space, ⌘⌫ and ⌘Z work as you know them", "Leertaste, ⌘⌫ und ⌘Z wie gewohnt")),
            Feature(id: "pin", pane: .actions,
                    title: L("Pin", "Anheften"),
                    text: L("Drag a folder or app onto the action bar", "Ordner oder App auf die Aktionsleiste ziehen")),
            Feature(id: "stacks", pane: .items,
                    title: L("Stacks", "Stapel"),
                    text: L("Several items at once stay together", "Mehrere auf einmal bleiben zusammen")),
            Feature(id: "plugins", pane: .plugins,
                    title: L("Plugins", "Plugins"),
                    text: L("More tools from the gallery", "Mehr Werkzeuge aus der Galerie")),
            Feature(id: "cloud", pane: .cloud,
                    title: L("Cloud", "Cloud"),
                    text: L("Right-click to upload and copy a link", "Per Rechtsklick hochladen und Link kopieren")),
            Feature(id: "screenshots", pane: .items,
                    title: L("Screenshots", "Bildschirmfotos"),
                    text: L("Optional: new ones land in the shelf", "Auf Wunsch neue gleich in der Ablage"))
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Zeilen wie in den Einstellungen, ohne Pfeil: Sie führen nirgendwohin. Vorher
            // Karten in zwei Spalten, die wie Knöpfe aussahen und nichts taten (Nutzertest 22.11.2026)
            SettingsCard {
                ForEach(features) { feature in
                    HStack(spacing: 10) {
                        PaneIcon(pane: feature.pane)
                        Text(feature.title)
                            .font(.system(size: 13.5))
                        Spacer(minLength: 12)
                        Text(feature.text)
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 40)
                }
            }
            // An derselben Kante wie die Karten, nicht eingerückt
            Text(L("To open Settings later, open BarDrop again from Applications or right-click an empty spot in the shelf.",
                   "Die Einstellungen findest du wieder, wenn du BarDrop noch einmal öffnest (etwa aus „Programme“) oder mit Rechtsklick auf eine leere Stelle der Ablage."))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, -8)

            // Erst am Ende, wenn man die App kennt; beim ersten Start schon eingeschaltet
            SettingsCard {
                ToggleRow(L("Open at login", "Beim Anmelden öffnen"), isOn: $model.launchAtLogin)
            }
            Spacer(minLength: 0)
        }
        .frame(width: DemoLayout.shown.width)
        .padding(.horizontal, OnboardingView.pagePadding)
        .padding(.top, 4)
    }
}

/// Das Beispielbild wie eine Datei im Finder: Bild und Name, zum Herausziehen. Es atmet
/// leicht (etwas größer und heller, dann wieder zurück), als Hinweis, dass man es anfassen
/// kann. Unter dem Zeiger und nach dem ersten Greifen steht es still, ebenso mit
/// „Bewegung reduzieren“. Wohin es soll, zeigt die Vorführung oben.
private struct SampleTile: View {
    let url: URL?
    let edge: ScreenEdge
    var onDragStarted: () -> Void = {}
    @State private var hovering = false
    /// Einmal gegriffen: nicht mehr atmen
    @State private var grabbed = false
    /// Das Foto bleibt im Speicher: Ändert sich die Datei (Umbenennen beim Sprachwechsel,
    /// Ziehen), verschwindet es nicht aus der Übung
    @State private var image: NSImage?

    private var breathes: Bool { !Motion.reduceMotion && !hovering && !grabbed }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !breathes)) { context in
                // Etwa 2,5 Sekunden je Atemzug, sanft (Sinus)
                let wave = breathes ? 0.5 + 0.5 * sin(context.date.timeIntervalSinceReferenceDate * 2 * .pi / 2.5) : 0
                tile
                    .scaleEffect(1 + 0.03 * wave)
                    .opacity(1 - 0.15 * wave)
            }
    }

    private var tile: some View {
        VStack(spacing: 4) {
            preview
                .frame(width: 76, height: 57)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
            Text(url?.lastPathComponent ?? "")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 110)
        }
        .scaleEffect(hovering ? 1.05 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: hovering)
        .onHover { hovering = $0 }
        .overlay(
            Group {
                if let url {
                    SampleDragArea(url: url, onDragStarted: {
                        if !grabbed { grabbed = true }
                        onDragStarted()
                    })
                }
            }
        )
        .help(L("Drag into the shelf", "In die Ablage ziehen"))
        .task(id: url) {
            if let url, let loaded = NSImage(contentsOf: url) { image = loaded }
        }
    }

    @ViewBuilder
    private var preview: some View {
        if let image = image ?? url.flatMap(NSImage.init(contentsOf:)) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
        } else {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.secondary.opacity(0.15))
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



/// Was während der Einführung in der Ablage angenommen wird: Das Beispielfoto soll nur dort
/// landen, wo die Übung es haben will (kein Stapel, keine falsche Aktion)
enum IntroGate {
    /// Die Einführung ist offen
    static var active = false
    /// Aktueller Schritt der Einführung
    static var step: OnboardingModel.Step?

    /// Darf etwas auf diese Aktion gelegt werden?
    static func allowsDrop(on kind: QuickAction.Kind) -> Bool {
        guard active else { return true }
        guard step == .retrieve else { return false }
        let hasTrash = AppSettings.shared.quickActions.contains { $0.kind == .trash }
        return kind == .trash || !hasTrash
    }

    /// Darf ein Objekt auf eine Kachel gelegt werden (Stapel bilden)?
    static var allowsMerge: Bool { !active }

    /// Darf die Ablage vom Rand gezogen werden? In der Einführung nur in ihrer Übung
    static var allowsTear: Bool { !active || step == .detach }
}
