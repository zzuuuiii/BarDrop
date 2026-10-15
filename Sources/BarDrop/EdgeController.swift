import AppKit
import SwiftUI
import Combine

/// Steuert, wann und wo die Ablage am Rand auftaucht: beim Ziehen von Dateien,
/// beim Berühren des Rands mit dem Mauszeiger und per Kurzbefehl.
///
/// Es gibt genau ein Fenster. Es wandert zum Bildschirm, auf dem sich der Zeiger
/// befindet, aber erst, wenn die Ablage dort vollständig verschwunden ist. So ist
/// sie nie auf zwei Bildschirmen gleichzeitig zu sehen und springt nicht mitten
/// in einer Animation.
///
/// Energie: Solange etwas passiert, läuft ein Takt mit 60 Hz. Im Ruhezustand
/// (verborgen, Zeiger weit vom Rand) steht er still. Dann meldet macOS selbst,
/// wenn sich der Zeiger dem Rand nähert oder ein Ziehen beginnt (nach boring.notch,
/// DragDetector). Die Entscheidungen selbst trifft `EdgeLogic`.
final class EdgeController: NSObject {
    let ui: ShelfUIModel
    let store: ShelfStore
    let settings: AppSettings
    let actions: ShelfActions
    let panel: ShelfPanel

    /// true, solange z. B. das Einstellungsfenster die App aktiv halten soll.
    var keepAppActive: () -> Bool = { false }

    private var screen: NSScreen?
    /// Bildschirm, an dem die Ablage gerade sitzt (dort öffnen auch die Einstellungen)
    var currentScreen: NSScreen? { screen }
    private var logic = EdgeLogic.State()
    private var previewUntil: Date?
    /// Welche Stufe die Vorschau beim Ändern der Einstellungen zeigt
    private var previewLevel: ShelfUIModel.Level = .hint
    private var lastPeekSignature = ""
    private var lastSizeSignature = ""
    /// Adaptive Höhe: Zeigerhöhe, an der die Ablage erscheinen soll.
    private var adaptiveY: CGFloat?
    private var lastLayoutSignature = ""
    private var acceptsMouse = false

    // Takt: 60 Hz, solange etwas passiert; im Ruhezustand aus
    private var tickTimer: Timer?
    private static let interval: TimeInterval = 1.0 / 60.0
    private let dragPasteboard = NSPasteboard(name: .drag)
    /// Stand des Drag-Pasteboards beim letzten Drücken der Maustaste
    private var dragBaseline = NSPasteboard(name: .drag).changeCount
    private var monitors: [Any] = []
    private var layoutDirty = false
    private var settingsObserver: AnyCancellable?
    private var contentObserver: AnyCancellable?
    private var appObserver: NSObjectProtocol?
    private var excludedObserver: AnyCancellable?
    /// Die App vorn ist ausgenommen: Der Rand öffnet die Ablage dann nicht
    private var frontmostExcluded = false
    /// Bildschirme, auf denen die App vorn gerade im Vollbild ist (nur wenn das
    /// Öffnen im Vollbild ausgeschaltet ist, sonst leer)
    private var fullScreenFrames: [CGRect] = []
    private var spaceObserver: NSObjectProtocol?
    private var terminateObserver: NSObjectProtocol?
    private var fullScreenObserver: AnyCancellable?

    /// Bildschirme, die gerade einen Vollbild-Schreibtisch zeigen. Gefragt wird macOS
    /// selbst, welche Art Schreibtisch aktiv ist, nicht die Fenstergröße: Ein Fenster, das
    /// nur den Bildschirm ausfüllt, ist kein Vollbild. Läuft nur beim App- oder
    /// Schreibtischwechsel, nicht im Takt.
    private func updateFullScreen(enabled: Bool? = nil) {
        let open = enabled ?? settings.openInFullScreen
        guard !open, let spaces = FullScreenSpaces.displays() else {
            fullScreenFrames = []
            return
        }
        fullScreenFrames = NSScreen.screens
            .filter { spaces.all || spaces.uuids.contains(FullScreenSpaces.uuid(of: $0) ?? "") }
            .map(\.frame)
    }

    private func updateFrontmostExcluded(_ excluded: [String]? = nil) {
        let list = excluded ?? settings.excludedApps
        let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        frontmostExcluded = id.map(list.contains) ?? false
    }
    /// Fokus zurückgeben, sobald ein eigener Drag beendet ist.
    private var pendingResignFocus = false

    /// Dauer der Schließanimation; erst danach darf das Fenster den Bildschirm wechseln.
    private let collapseDuration: TimeInterval = 0.35

    init(store: ShelfStore, ui: ShelfUIModel, settings: AppSettings) {
        self.store = store
        self.ui = ui
        self.settings = settings
        self.actions = ShelfActions(store: store, ui: ui, settings: settings)
        self.panel = ShelfPanel()
        super.init()

        actions.panel = panel
        panel.actions = actions
        panel.onEscape = { [weak self] in self?.close() }

        let host = ShelfHostingView(rootView: ShelfRootView(ui: ui, store: store, settings: settings, actions: actions))
        host.dropHandler = ShelfDropHandler(store: store, ui: ui)
        panel.contentView = host

        panel.ignoresMouseEvents = true
        screen = screenUnderMouse() ?? allowedScreens().first
        lastLayoutSignature = settings.layoutSignature
        lastPeekSignature = settings.peekSignature
        lastSizeSignature = settings.sizeSignature
        layoutPanel()
        panel.orderFrontRegardless()

        installMonitors()
        // Ausgenommene Apps: merken, ob gerade eine davon vorn ist (nicht in jedem Takt fragen)
        appObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.updateFrontmostExcluded()
            self?.updateFullScreen()
        }
        // Vollbild hat einen eigenen Schreibtisch: nach dem Wechsel (und der Animation) prüfen
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.updateFullScreen()
            // Die Vollbild-Animation kann länger dauern: zweimal nachsehen
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self?.updateFullScreen() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { self?.updateFullScreen() }
        }
        // Eine Vollbild-App wird beendet: Ihr Schreibtisch verschwindet
        terminateObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.updateFullScreen() }
        fullScreenObserver = settings.$openInFullScreen
            .receive(on: DispatchQueue.main)
            .sink { [weak self] open in self?.updateFullScreen(enabled: open) }
        excludedObserver = settings.$excludedApps
            .receive(on: DispatchQueue.main)
            .sink { [weak self] list in self?.updateFrontmostExcluded(list) }
        wake()
        settingsObserver = settings.objectWillChange.sink { [weak self] _ in
            self?.layoutDirty = true
            DispatchQueue.main.async { self?.wake() }
        }
        // Neuer Inhalt, der erst später fertig wird (Bilder aus dem Web, große Dateien,
        // iCloud): Ohne Fokus zeichnet macOS das Fenster teils erst beim nächsten Öffnen
        // neu. Deshalb hier selbst neu zeichnen, sobald sich der Inhalt ändert.
        contentObserver = store.$entries.map { _ in () }
            .merge(with: store.$pendingImports.map { _ in () })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.refreshContent() }

        let cleanup = Timer(timeInterval: 60, target: self, selector: #selector(removeExpired), userInfo: nil, repeats: true)
        RunLoop.main.add(cleanup, forMode: .common)
        removeExpired()

        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification,
                                               object: nil)
    }

    // MARK: Ereignisse des Systems

    private func installMonitors() {
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.handle(event)
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.handle(event)
            return event
        }) {
            monitors.append(local)
        }
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            // Neuer Ausgangsstand: Ändert sich das Drag-Pasteboard danach, wird etwas gezogen
            dragBaseline = dragPasteboard.changeCount
        case .leftMouseDragged:
            // Nur wecken; ausgewertet wird im Takt. Zieh-Ereignisse anderer Apps werden
            // nur beobachtet, nie verzögert oder verändert.
            guard tickTimer == nil, dragPasteboard.changeCount != dragBaseline, hasDroppableContent() else { return }
            wake()
        case .mouseMoved:
            guard tickTimer == nil, isNearEdge(NSEvent.mouseLocation) else { return }
            wake()
        default:
            break
        }
    }

    /// Wird etwas gezogen, das die Ablage annehmen kann? Fenster und markierter Text
    /// ändern das Drag-Pasteboard nicht oder enthalten nichts davon.
    private func hasDroppableContent() -> Bool {
        let count = dragPasteboard.changeCount
        if let cached = droppableCache, cached.count == count { return cached.value }
        let accepted = Set(ShelfStore.acceptedTypes)
        let value = dragPasteboard.types?.contains(where: accepted.contains) ?? false
        droppableCache = (count, value)
        return value
    }
    /// Ergebnis der letzten Prüfung je Stand des Drag-Pasteboards (spart Abfragen im Takt)
    private var droppableCache: (count: Int, value: Bool)?

    private func isNearEdge(_ loc: NSPoint) -> Bool {
        guard let s = Self.screen(containing: loc, in: allowedScreens()) else { return false }
        let dx = settings.edge == .right ? s.frame.maxX - loc.x : loc.x - s.frame.minX
        return dx <= EdgeLogic.wakeDistance
    }

    /// Startet den Takt (falls er ruht).
    func wake() {
        guard tickTimer == nil else { return }
        let timer = Timer(timeInterval: Self.interval, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        timer.tolerance = 0.004
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
        tick()
    }

    private func pauseTicking() {
        tickTimer?.invalidate()
        tickTimer = nil
    }

    // MARK: Bildschirme

    private func allowedScreens() -> [NSScreen] {
        let all = NSScreen.screens
        let filtered = all.filter { settings.displayMode.allows($0) }
        return filtered.isEmpty ? all : filtered
    }

    /// Bildschirm unter dem Zeiger, sofern BarDrop dort verfügbar ist.
    private func screenUnderMouse() -> NSScreen? {
        Self.screen(containing: NSEvent.mouseLocation, in: allowedScreens())
    }

    /// Bildschirm an einem Punkt. Am äußersten Rand meldet macOS den Zeiger teils einen
    /// Punkt außerhalb des Bildschirms; dann zählt der nächstgelegene (höchstens 2 pt entfernt).
    static func screen(containing point: NSPoint, in screens: [NSScreen]) -> NSScreen? {
        if let exact = screens.first(where: { NSMouseInRect(point, $0.frame, false) }) { return exact }
        return screens
            .map { ($0, distance(point, $0.frame)) }
            .filter { $0.1 <= 2 }
            .min { $0.1 < $1.1 }?.0
    }

    private static func distance(_ p: NSPoint, _ r: NSRect) -> CGFloat {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX)
        let dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return hypot(dx, dy)
    }

    /// Derselbe Bildschirm? Nach Ruhezustand oder Änderungen liefert macOS teils neue
    /// NSScreen-Objekte für denselben Bildschirm; verglichen wird deshalb die Kennung.
    private static func same(_ a: NSScreen?, _ b: NSScreen?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        return a.displayID == b.displayID
    }

    @objc private func screensChanged() {
        // Bildschirm abgesteckt oder Auflösung geändert: neu ausrichten
        if let s = screen, !allowedScreens().contains(where: { Self.same($0, s) }) {
            screen = screenUnderMouse() ?? allowedScreens().first
            Log.edge.info("Bildschirme geändert, Ablage neu ausgerichtet")
        }
        layoutPanel()
        wake()
    }

    // MARK: Geometrie

    /// Mitte des Fensters: so gewählt, dass die offene Ablage ganz auf den Bildschirm passt.
    private func panelCenterY(on screen: NSScreen) -> CGFloat {
        let vf = screen.visibleFrame
        let half = CGFloat(settings.shelfHeight) / 2 + ShelfMetrics.maxFillet + 8
        return min(max(desiredY(on: screen), vf.minY + half), vf.maxY - half)
    }

    /// Wunschhöhe: feste Position oder (adaptiv) die Zeigerhöhe.
    private func desiredY(on screen: NSScreen) -> CGFloat {
        let vf = screen.visibleFrame
        let fixed = vf.minY + vf.height * CGFloat(settings.verticalPosition)
        guard settings.adaptivePosition, let y = adaptiveY else { return fixed }
        if let zone = settings.adaptiveZoneFraction {
            // Nur im mittleren Bereich: außerhalb bleibt die Ablage am Rand dieses Bereichs
            // stehen, der Zeiger ist dann zu weit entfernt, um sie auszulösen.
            let margin = vf.height * (1 - zone) / 2
            return min(max(y, vf.minY + margin), vf.maxY - margin)
        }
        let margin: CGFloat = 70
        return min(max(y, vf.minY + margin), vf.maxY - margin)
    }

    /// Darf die Ablage an dieser Zeigerhöhe erscheinen? Bei „nur mittleres Drittel“ nur
    /// innerhalb des Drittels, damit der Streifen nie versetzt am Rand des Bereichs auftaucht.
    private func inRevealZone(_ y: CGFloat, on screen: NSScreen) -> Bool {
        guard let zone = settings.adaptiveZoneFraction else { return true }
        let vf = screen.visibleFrame
        let margin = vf.height * (1 - zone) / 2
        return y >= vf.minY + margin && y <= vf.maxY - margin
    }

    /// Mitte der schwarzen Form je Zustand. Die kleinen Stufen sitzen genau auf der
    /// Wunschhöhe, die offene Ablage auf der Fenstermitte.
    private func shapeCenterY(_ level: ShelfUIModel.Level, on screen: NSScreen) -> CGFloat {
        level == .expanded ? panelCenterY(on: screen) : desiredY(on: screen)
    }

    /// Fläche der schwarzen Form (inklusive Rundungen) in Bildschirmkoordinaten.
    private func bodyRect(_ level: ShelfUIModel.Level, on screen: NSScreen) -> NSRect {
        let m = ShelfMetrics.for(level, settings: settings)
        let h = m.height + 2 * m.fillet
        let x = settings.edge == .right ? screen.frame.maxX - m.width : screen.frame.minX
        return NSRect(x: x, y: shapeCenterY(level, on: screen) - h / 2, width: m.width, height: h)
    }

    private func layoutPanel() {
        guard let screen = screen ?? allowedScreens().first else { return }
        let margin = ShelfMetrics.panelMargin
        let w = CGFloat(settings.shelfWidth) + margin
        let h = CGFloat(settings.shelfHeight) + 2 * ShelfMetrics.maxFillet + 2 * margin
        let x = settings.edge == .right ? screen.frame.maxX - w : screen.frame.minX
        let center = panelCenterY(on: screen)
        let frame = NSRect(x: x, y: center - h / 2, width: w, height: h)
        if panel.frame != frame { panel.setFrame(frame, display: true) }

        // Versatz der kleinen Stufen gegenüber der Fenstermitte (SwiftUI: y nach unten)
        let offset = center - desiredY(on: screen)
        if ui.anchorOffset != offset { ui.anchorOffset = offset }
    }

    // MARK: Zustände

    /// Zuletzt sichtbar oder benutzt (für stille Updates)
    private(set) var lastActivity = Date()

    /// Ruht die Ablage seit `interval` Sekunden (zu und nichts in Arbeit)?
    func isIdle(for interval: TimeInterval) -> Bool {
        ui.level == .hidden && !ui.ownDragActive && store.pendingImports == 0
            && Date().timeIntervalSince(lastActivity) >= interval
    }

    private func setLevel(_ new: ShelfUIModel.Level) {
        let old = ui.level
        guard new != old else { return }
        lastActivity = Date()
        let style = settings.animationStyle
        // Kleine Stufen haben ihre eigene, elastische Bewegung; die Ablage selbst die gewählte
        let animation: Animation
        if new == .expanded { animation = style.open }
        else if old == .expanded { animation = style.close }
        else { animation = new > old ? style.peekIn : style.peekOut }
        withAnimation(animation) {
            ui.level = new
            if new == .hidden { ui.openStack = nil }   // nächstes Öffnen zeigt wieder die ganze Ablage
        }
        logic.level = new
        logic.levelSince = Date()
        logic.outsideSince = nil

        if new == .expanded {
            Thumbnails.forgetIcons()
            store.pruneMissingFiles()
            // Vorschau beim Verstellen in den Einstellungen: den Fokus dort lassen
            if previewUntil == nil { takeFocus() }
        }
        if new < .expanded && old == .expanded {
            // Während eines eigenen Drags darf das Fenster nicht vom Bildschirm,
            // sonst bricht macOS den Drag ab.
            if ui.ownDragActive {
                pendingResignFocus = true
            } else {
                resignFocus()
            }
        }
        if new == .hidden {
            logic.manualOpen = false
            logic.manualHovered = false
        }
    }

    /// Offene Ablage bekommt den Tastaturfokus, damit ⌘A, Pfeiltasten & Co. hier
    /// wirken und nicht in der App dahinter. Das Fenster aktiviert BarDrop dabei
    /// nicht (nonactivatingPanel): Die andere App bleibt vorn und bekommt den Fokus
    /// beim Schließen zurück. Während etwas gezogen wird, bleibt alles, wie es ist.
    private func takeFocus() {
        guard (NSEvent.pressedMouseButtons & 1) == 0 else { return }
        if !panel.isKeyWindow { panel.makeKey() }
        // Gleich nach dem Öffnen nimmt das Fenster noch keine Mausereignisse an;
        // das regelt erst der nächste Takt. Danach noch einmal sicherstellen.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, self.ui.level == .expanded, !self.panel.isKeyWindow,
                  (NSEvent.pressedMouseButtons & 1) == 0 else { return }
            self.panel.makeKey()
        }
    }

    /// Zeichnet die offene Ablage sofort neu und holt den Fokus zurück, wenn der Zeiger
    /// darüber ist (so wie direkt nach dem Ablegen).
    private func refreshContent() {
        guard ui.level == .expanded, let host = panel.contentView else { return }
        host.needsLayout = true
        host.needsDisplay = true
        panel.displayIfNeeded()
        // Kurz danach noch einmal: Die Einfüge-Animation beginnt erst im nächsten Durchlauf
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, self.ui.level == .expanded else { return }
            self.panel.contentView?.needsDisplay = true
            self.panel.displayIfNeeded()
            if !self.panel.isKeyWindow, (NSEvent.pressedMouseButtons & 1) == 0,
               let screen = self.screen,
               self.bodyRect(.expanded, on: screen).contains(NSEvent.mouseLocation) {
                self.panel.makeKey()
            }
        }
    }

    /// Gibt Tastaturfokus und Aktivierung an die vorherige App zurück.
    private func resignFocus() {
        pendingResignFocus = false
        if panel.isKeyWindow {
            panel.orderOut(nil)
            panel.orderFrontRegardless()
        }
        if NSApp.isActive && !keepAppActive() && !actions.isQuickLookVisible {
            NSApp.deactivate()
        }
    }

    /// Beim Start kurz den Streifen am Rand zeigen, damit man sieht, dass BarDrop läuft
    /// und wo die Ablage wartet.
    func greet() {
        previewLevel = .hint
        previewUntil = Date().addingTimeInterval(1.6)
        wake()
    }

    func toggle() {
        if ui.level == .expanded {
            close()
            return
        }
        if let s = screenUnderMouse() { screen = s }
        if settings.adaptivePosition { adaptiveY = NSEvent.mouseLocation.y }
        layoutPanel()
        logic.manualOpen = true
        logic.manualHovered = false
        setLevel(.expanded)
        wake()
    }

    func close() {
        logic.manualOpen = false
        setLevel(.hidden)
        wake()
    }

    @objc private func removeExpired() {
        store.removeExpired(olderThan: settings.autoRemoveAfter)
        Outbox.shared.cleanUp()
    }

    // MARK: Takt

    @objc private func tick() {
        let now = Date()
        let loc = NSEvent.mouseLocation
        let mouseDown = (NSEvent.pressedMouseButtons & 1) == 1
        let dragCount = dragPasteboard.changeCount
        if !mouseDown { dragBaseline = dragCount }
        let dragging = mouseDown && dragCount != dragBaseline && (ui.ownDragActive || hasDroppableContent())

        if pendingResignFocus && !ui.ownDragActive {
            resignFocus()
        }

        // Einstellungen nur prüfen, wenn sich etwas geändert hat
        if layoutDirty, settings.layoutSignature != lastLayoutSignature {
            lastLayoutSignature = settings.layoutSignature
            if let s = screen, !allowedScreens().contains(where: { Self.same($0, s) }) {
                screen = screenUnderMouse() ?? allowedScreens().first
            }
            layoutPanel()
            // Breite oder Länge geändert: die offene Ablage zeigen, damit man die neue
            // Größe sieht. Sonst (Rand, Höhe, Lage) den Griff an der neuen Stelle.
            if settings.sizeSignature != lastSizeSignature {
                lastSizeSignature = settings.sizeSignature
                previewUntil = now.addingTimeInterval(1.5)
                previewLevel = .expanded
            } else {
                previewUntil = now.addingTimeInterval(1.2)
                previewLevel = .hint
            }
        }
        // Form des ersten Streifens geändert: genau diesen kurz zeigen
        if layoutDirty, settings.peekSignature != lastPeekSignature {
            lastPeekSignature = settings.peekSignature
            previewUntil = now.addingTimeInterval(1.5)
            previewLevel = .peek
        }
        layoutDirty = false

        // Zeiger auf einem anderen Bildschirm, während dort nur Streifen oder Griff zu sehen
        // ist: sofort ohne Animation verschwinden, damit die Ablage gleich am neuen
        // Bildschirm bereitsteht (nie auf zwei Bildschirmen gleichzeitig).
        let mouseScreen = screenUnderMouse()
        if ui.level == .peek || ui.level == .hint, !logic.manualOpen, !ui.ownDragActive,
           let s = mouseScreen, !Self.same(s, screen) {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { ui.level = .hidden }
            logic.level = .hidden
            logic.levelSince = .distantPast
            logic.outsideSince = nil
        }

        // Bildschirm wechseln: nur wenn die Ablage verborgen und fertig animiert ist
        let fullyHidden = ui.level == .hidden && now.timeIntervalSince(logic.levelSince) > collapseDuration
        if fullyHidden, !logic.manualOpen, let s = mouseScreen, !Self.same(s, screen) {
            screen = s
            layoutPanel()
            Log.edge.info("Ablage wechselt den Bildschirm")
        }
        guard let screen else { pauseTicking(); return }

        let onScreen = Self.same(mouseScreen, screen) || NSMouseInRect(loc, screen.frame, false)

        // Adaptive Höhe: Beim Ziehen einer Datei erscheint die Ablage mittig an der
        // Bildschirmseite und folgt der Datei nicht. Sonst folgt sie dem Zeiger, solange
        // sie verborgen ist (erst nach der Schließanimation, damit nichts „mitzieht“).
        if settings.adaptivePosition, onScreen, fullyHidden, !logic.manualOpen {
            let y = dragging && !ui.ownDragActive ? screen.visibleFrame.midY : loc.y
            if abs((adaptiveY ?? -1) - y) > 0.5 {
                adaptiveY = y
                layoutPanel()
            }
        }

        let dx = settings.edge == .right ? screen.frame.maxX - loc.x : loc.x - screen.frame.minX
        let expandedBody = bodyRect(.expanded, on: screen)
        ui.expandedBody = expandedBody
        let locked = ui.isLocked || actions.isQuickLookVisible

        if ui.expandRequested {
            ui.expandRequested = false
            if ui.level == .hint { setLevel(.expanded) }
        }

        if let until = previewUntil, until <= now { previewUntil = nil }

        // Rand zu einem Bildschirm daneben, der selbst eine Ablage hat: Dort gehört sie nicht hin.
        // Darf nur dieser Bildschirm eine Ablage haben, bleibt sie wie bisher an diesem Rand.
        let innerEdge = EdgeLogic.edgeContinues(screen.frame, edge: settings.edge, at: loc.y,
                                                into: allowedScreens().map(\.frame))
        let m = ShelfMetrics.for(ui.level, settings: settings)
        let sample = EdgeLogic.Sample(
            now: now,
            dx: dx,
            dy: abs(loc.y - shapeCenterY(ui.level, on: screen)),
            onScreen: onScreen,
            onOtherScreen: mouseScreen != nil && !Self.same(mouseScreen, screen),
            inRevealZone: inRevealZone(loc.y, on: screen) && !innerEdge,
            innerEdge: innerEdge,
            overExpanded: ui.level == .expanded && expandedBody.insetBy(dx: -18, dy: -18).contains(loc),
            dragging: dragging,
            ownDrag: ui.ownDragActive,
            locked: locked,
            preview: previewUntil != nil ? previewLevel : nil,
            width: m.width, height: m.height, fillet: m.fillet
        )
        let config = EdgeLogic.Config(dragReveal: settings.dragReveal,
                                      // In ausgenommenen Apps und (auf Wunsch) im Vollbild öffnet nur das Hinfahren nicht;
                                      // Dateien hineinziehen und der Kurzbefehl gehen weiter
                                      revealOnHover: !frontmostExcluded
                                          && !fullScreenFrames.contains(screen.frame),
                                      openMode: settings.openMode,
                                      openDelay: settings.openDelay,
                                      generousHitArea: settings.generousHitArea)
        logic.level = ui.level
        let result = EdgeLogic.decide(&logic, sample, config)
        if result.haptic { Haptics.tap() }   // erster Streifen oder Datei erreicht die Ablage
        if result.target != ui.level {
            setLevel(result.target)
        }

        // Mausereignisse nur annehmen, wenn der Zeiger über der offenen Ablage ist
        // Modus „Per Klick“ oder lange Verzögerung mit „Klick öffnet sofort“:
        // die mittlere Stufe nimmt einen Klick an
        let slack = config.hitSlack
        let hintBody = bodyRect(.hint, on: screen).insetBy(dx: -slack.x, dy: -slack.y)
        // Mit Schwung an den Rand geworfene Dateien: Das Fenster nimmt den Drop schon an,
        // bevor die Ablage ganz offen ist, auch knapp neben der Form. Sonst landet die
        // Datei beim Loslassen in der App dahinter.
        // Nur im Bereich der Ablage selbst, damit Drops in Fenster daneben ungestört bleiben
        let catchesThrow = dragging && !ui.ownDragActive && settings.dragReveal != .off
            && onScreen && !innerEdge && dx < EdgeLogic.dragExpandDistance
            && expandedBody.insetBy(dx: 0, dy: -12).contains(loc)
        let accept = (ui.level == .expanded && (expandedBody.contains(loc) || locked))
            || (ui.level == .hint && settings.hintAcceptsClick && !dragging && hintBody.contains(loc))
            || catchesThrow
        if accept != acceptsMouse {
            acceptsMouse = accept
            panel.ignoresMouseEvents = !accept
        }

        // Ruhezustand: Takt anhalten, Ereignisse des Systems wecken ihn wieder
        if EdgeLogic.isCalm(fullyHidden: fullyHidden && ui.level == .hidden, mouseDown: mouseDown,
                            manualOpen: logic.manualOpen, previewActive: previewUntil != nil,
                            locked: ui.isLocked, onScreen: onScreen, dx: dx) {
            pauseTicking()
        }
    }
}
