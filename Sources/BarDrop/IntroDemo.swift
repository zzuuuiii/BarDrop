import AppKit
import SwiftUI
import Carbon
import Combine

// MARK: Vorführung der echten Ablage für die Einführung
//
// Die Szenen der Einführung zeigen die echte Ablage: dieselben Ansichten wie am
// Bildschirmrand (ShelfRootView), mit echten Kacheln und Vorschaubildern, der
// Aktionsleiste, den Rückmeldungen („Entfernt“) und den Animationen aus den
// Einstellungen, nur verkleinert. Dazu der echte Mauszeiger und ein gezogenes Bild wie
// beim Ziehen aus der Ablage.
//
// Die Vorführablage hat eine eigene Liste in einem temporären Ordner und eigene
// Beispieldateien. Sie läuft im Vorführmodus (`shelfDemo`): ohne Klick- und Drop-Flächen,
// sie kann also nichts auslösen. Die echte Ablage bleibt unberührt.

/// Ablauf einer Szene: setzt nacheinander Zustände der Vorführablage, in einer Schleife.
/// Mit „Bewegung reduzieren“ (und in Vorschaubildern) steht der aussagekräftigste Moment.
final class DemoShelf: ObservableObject {
    enum Scene { case overview, drop, takeOut, dragOut, shortcut, hover, detach }

    let scene: Scene
    let settings = AppSettings.shared
    let ui = ShelfUIModel()
    let store: ShelfStore
    let actions: ShelfActions

    /// Zeiger (Spitze) im Koordinatenraum des kleinen Schreibtischs
    @Published var pointer: CGPoint = .zero
    /// Ein Objekt wird gerade gezogen: Bild unter dem Zeiger
    @Published var dragging = false
    /// Beim Klicken kurz kleiner
    @Published var pointerDown = false
    /// Symbol auf dem Schreibtisch ausgewählt bzw. Ordner als Ziel markiert
    @Published var iconSelected = false
    @Published var folderTargeted = false
    /// Gerade gedrückte Tasten
    @Published var keys: [(symbol: String, name: String)]?
    /// Vom Rand abziehen: so weit ist die Ablage vom Rand weg
    @Published var shift: CGFloat = 0
    /// Bewegung beim Abziehen, Bild für Bild wie in EdgeController (Dehnen, dann Lösen)
    private var tearTimer: Timer?

    private let directory: URL?
    /// Das Bild, um das es geht (wie das Beispielbild der Einführung)
    let sampleURL: URL?
    /// Weitere Objekte, damit die Ablage nach Alltag aussieht
    private let otherURLs: [URL]
    private var generation = 0
    private var running = false
    private var edgeSubscription: AnyCancellable?

    init(scene: Scene) {
        self.scene = scene
        let sample = OnboardingController.makeSample()
        sampleURL = sample
        directory = sample?.deletingLastPathComponent()
        if let directory {
            otherURLs = Self.makeExamples(in: directory)
        } else {
            otherURLs = []
        }
        let base = (directory ?? FileManager.default.temporaryDirectory.appendingPathComponent("BarDropVorfuehrung-\(UUID().uuidString)"))
            .appendingPathComponent("Ablage", isDirectory: true)
        store = ShelfStore(baseDirectory: base)
        actions = ShelfActions(store: store, ui: ui, settings: settings)
        // Heller Rahmen: Die schwarze Ablage hebt sich so auch vom dunklen Hintergrund ab
        ui.forcesOutline = true
        for url in [sampleURL].compactMap({ $0 }) + otherURLs {
            // Ohne die kurze Wartezeit auf das Vorschaubild zeigen
            Thumbnails.shownOnce.insert(url.path)
            Thumbnails.load(url, size: CGFloat(settings.tileIconSize)) { _ in }
        }
        still()
        // Vor dem Zeichnen am neuen Rand (willSet): erst verbergen, dann neu zeigen
        edgeSubscription = settings.$edge.dropFirst().removeDuplicates()
            .sink { [weak self] _ in self?.edgeChanged() }
    }

    deinit {
        tearTimer?.invalidate()
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    // MARK: Geometrie

    var layout: DemoLayout { DemoLayout(settings: settings) }

    /// Mitte des Bildes in der offenen Ablage
    /// Freier Platz hinter den anderen Objekten: Dort wird beim Ablegen hingezogen,
    /// damit das gezogene Bild keine Kachel verdeckt
    /// Mitte der ersten freien Reihe, so bleibt auch der Name unter dem Bild ganz zu sehen.
    private var freeSlot: CGPoint {
        let l = layout
        let row = (others.count + l.columns - 1) / l.columns
        return l.away(l.full.width / 2, y: l.tileCenter(row * l.columns).y)
    }

    /// Weitere Objekte in der Szene. Beim Ablegen nur eine Reihe, damit darunter Platz für
    /// das gezogene Bild ist
    private var others: [URL] { scene == .drop ? Array(otherURLs.prefix(2)) : otherURLs }

    /// Mitte der Aktion „Papierkorb“ in der Leiste (ohne Papierkorb: die letzte Aktion)
    private var trashAction: CGPoint {
        let all = QuickAction.demo
        let index = all.firstIndex { $0.kind == .trash } ?? max(0, all.count - 1)
        return layout.actionCenter(index, count: max(1, min(all.count, QuickAction.perRow)))
    }

    private var sampleTile: CGPoint {
        let index = actions.orderedEntries.firstIndex { $0.files.contains { $0.url == sampleURL } } ?? 0
        return layout.tileCenter(index)
    }

    // MARK: Zustände

    /// Inhalt der Ablage: die weiteren Objekte, auf Wunsch mit dem Bild als neuestem
    private func fill(withSample: Bool) {
        ui.selection = []
        ui.notice = nil
        let wanted = (withSample ? [sampleURL].compactMap { $0 } : []) + others
        // Liegt schon alles so da (etwa nach ⌘Z), nichts neu aufbauen: das würde flackern
        guard store.entries.flatMap({ $0.files.map(\.url) }) != wanted else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            store.discard(Set(store.entries.map(\.id)))
            // Einzeln hinzufügen, sonst würden sie zu einem Stapel; das neueste zuletzt
            for url in wanted.reversed() { store.add([ShelfFile(url: url, owned: false)]) }
        }
    }

    private func set(level: ShelfUIModel.Level, animation: Animation?) {
        guard ui.level != level else { return }
        if let animation {
            withAnimation(animation) { ui.level = level }
        } else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { ui.level = level }
        }
        ui.isKey = level == .expanded && scene != .drop
    }

    private func move(to point: CGPoint, duration: Double) {
        withAnimation(.easeInOut(duration: duration)) { pointer = point }
    }

    private func click() {
        withAnimation(.easeOut(duration: 0.08)) { pointerDown = true }
        after(0.12) { withAnimation(.easeOut(duration: 0.12)) { self.pointerDown = false } }
    }

    private func show(_ keys: [(symbol: String, name: String)]?) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { self.keys = keys }
    }

    private var hotKeys: [(symbol: String, name: String)] { ShortcutKeys.keys(settings) }

    /// Standbild: der Moment, der die Szene am besten erklärt
    private func still() {
        let l = layout
        dragging = false
        iconSelected = false
        folderTargeted = false
        keys = nil
        switch scene {
        case .overview:
            fill(withSample: true)
            set(level: .expanded, animation: nil)
            pointer = l.away(l.full.width + 70, y: l.size.height * 0.68)
        case .drop:
            fill(withSample: false)
            set(level: .expanded, animation: nil)
            ui.isDropTargeted = true
            iconSelected = true
            dragging = true
            pointer = freeSlot
        case .takeOut:
            fill(withSample: !settings.removeAfterDragOut)
            set(level: .expanded, animation: nil)
            pointer = CGPoint(x: l.sample.x + 30, y: l.sample.y + 40)
        case .dragOut:
            fill(withSample: true)
            set(level: .expanded, animation: nil)
            dragging = true
            pointer = trashAction
        case .hover:
            fill(withSample: true)
            set(level: .expanded, animation: nil)
            pointer = l.away(20, y: l.size.height * 0.5)
        case .shortcut:
            fill(withSample: true)
            set(level: .expanded, animation: nil)
            keys = hotKeys
            pointer = l.away(l.full.width + 170, y: l.size.height * 0.7)
        case .detach:
            fill(withSample: true)
            set(level: .expanded, animation: nil)
            pull(Self.detachDistance)
            pointer = grip(Self.detachDistance)
        }
    }

    // MARK: Vom Rand abziehen

    /// So weit wird die Ablage in der Vorführung vom Rand gezogen
    static let detachDistance: CGFloat = 190

    /// Griff oben in der Kopfzeile, `distance` vom Rand weggezogen
    private func grip(_ distance: CGFloat) -> CGPoint {
        let l = layout
        return l.away(l.full.width / 2 + distance, y: l.shelfFrame.minY + l.full.fillet + 14)
    }

    /// Stand nach `distance` Punkten Ziehen, gerechnet wie beim echten Abziehen
    /// (EdgeController.updateTear): erst dehnt sie sich am Rand, ab `tearDistance` löst sie
    /// sich und folgt dem Zeiger
    private func pull(_ distance: CGFloat) {
        let edge = settings.edge
        var tear = ShelfUIModel.Tear(gap: 0, attach: 1, side: edge, dock: 1)
        if distance < EdgeTear.tearDistance {
            let gap = EdgeTear.stretchMax * (1 - exp(-distance / EdgeTear.stretchSoftness))
            tear.gap = gap
            tear.attach = 1 - 0.8 * pow(distance / EdgeTear.tearDistance, 1.4)
            tear.dock = max(0, 1 - distance / 14)
            shift = gap
        } else {
            // Gelöst: Die Verbindung zum Rand läuft auf den ersten Punkten aus
            let start = EdgeTear.stretchMax * (1 - exp(-EdgeTear.tearDistance / EdgeTear.stretchSoftness))
            let fade = min(1, (distance - EdgeTear.tearDistance) / 30)
            tear.gap = start + distance - EdgeTear.tearDistance
            tear.attach = 0.2 * (1 - fade)
            tear.dock = 0
            shift = tear.gap
        }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { ui.tear = tear }
    }

    /// Von `from` nach `to` ziehen, in `duration` Sekunden, sanft beschleunigt und gebremst
    private func animatePull(from: CGFloat, to: CGFloat, duration: Double) {
        tearTimer?.invalidate()
        let start = CACurrentMediaTime()
        let g = generation
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self, self.running, self.generation == g else { timer.invalidate(); return }
            let t = min(1, (CACurrentMediaTime() - start) / duration)
            let eased = t * t * (3 - 2 * t)
            let distance = from + (to - from) * CGFloat(eased)
            self.pull(distance)
            self.pointer = self.grip(distance)
            if t >= 1 { timer.invalidate() }
        }
        RunLoop.main.add(timer, forMode: .common)
        tearTimer = timer
    }

    /// Wieder angedockt (ohne Bewegung, die Ablage ist dabei zu)
    private func resetTear() {
        tearTimer?.invalidate()
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            ui.tear = nil
            ui.grabbing = false
            shift = 0
        }
    }

    // MARK: Ablauf

    /// Rand gewechselt: am alten Rand sofort weg, am neuen mit der normalen Animation
    /// wieder da, wie die echte Ablage. Laufende Szenen beginnen von vorn.
    private func edgeChanged() {
        generation += 1
        dragging = false
        keys = nil
        set(level: .hidden, animation: nil)
        let g = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self, self.generation == g else { return }
            if self.running {
                self.loop()
            } else {
                self.still()
                let level = self.ui.level
                self.set(level: .hidden, animation: nil)
                self.set(level: level, animation: self.settings.animationStyle.open)
            }
        }
    }

    func start() {
        guard !running, scene != .overview, !AnimationStyle.reduceMotion else { return }
        running = true
        loop()
    }

    func stop() {
        running = false
        generation += 1
        tearTimer?.invalidate()
    }

    /// Führt `f` nach `delay` aus, solange die Szene noch läuft
    private func after(_ delay: Double, _ f: @escaping () -> Void) {
        let g = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.running, self.generation == g else { return }
            f()
        }
    }

    private func loop() {
        guard running else { return }
        generation += 1
        let l = layout
        let style = settings.animationStyle
        let period: Double

        ui.isDropTargeted = false
        dragging = false
        iconSelected = false
        folderTargeted = false
        keys = nil

        switch scene {
        case .overview:
            return

        case .detach:
            // Offene Ablage oben an der Kopfzeile greifen, vom Rand wegziehen: sie dehnt sich,
            // löst sich und bleibt frei liegen. Dann zu und wieder angedockt
            period = 6.6
            resetTear()
            fill(withSample: true)
            set(level: .hidden, animation: nil)
            pointer = l.away(l.full.width + 220, y: l.size.height * 0.7)
            after(0.3) { self.set(level: .expanded, animation: style.open) }
            after(0.9) { self.move(to: self.grip(0), duration: 0.7) }
            after(1.8) {
                self.click()
                withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) { self.ui.grabbing = true }
                self.pull(0)
            }
            after(2.0) { self.animatePull(from: 0, to: Self.detachDistance, duration: 1.5) }
            after(3.6) { withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) { self.ui.grabbing = false } }
            after(4.0) { self.move(to: self.grip(Self.detachDistance + 60), duration: 0.5) }
            after(5.4) { self.set(level: .hidden, animation: style.close) }
            after(6.0) { self.resetTear() }

        case .drop:
            // Bild vom Schreibtisch an den Rand ziehen: die Ablage öffnet sich, loslassen
            period = 6.4
            fill(withSample: false)
            set(level: .hidden, animation: nil)
            pointer = l.sample
            after(0.5) { self.click(); self.iconSelected = true; self.dragging = true }
            after(0.7) { self.move(to: l.away(14, y: l.size.height * 0.5), duration: 1.1) }
            after(1.6) { self.set(level: .peek, animation: style.peekIn) }
            after(2.0) {
                self.set(level: .expanded, animation: style.open)
                withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) { self.ui.isDropTargeted = true }
            }
            after(2.1) { self.move(to: self.freeSlot, duration: 0.5) }
            after(2.9) {
                withAnimation(.easeOut(duration: 0.15)) { self.dragging = false }
                withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) { self.ui.isDropTargeted = false }
                self.iconSelected = false
                if let url = self.sampleURL { self.store.add([ShelfFile(url: url, owned: false)]) }
            }
            after(4.5) { self.move(to: l.away(l.full.width + 150, y: l.size.height * 0.62), duration: 0.6) }
            after(4.8) { self.set(level: .hidden, animation: style.close) }

        case .takeOut:
            // Zeiger an den Rand, Ablage öffnet sich, Foto heraus auf den Schreibtisch ziehen
            period = 6.6
            fill(withSample: true)
            set(level: .hidden, animation: nil)
            pointer = l.away(l.full.width + 250, y: l.size.height * 0.64)
            after(0.4) { self.move(to: l.away(4, y: l.size.height * 0.5), duration: 0.8) }
            let click = settings.openMode == .click
            after(1.2) { self.set(level: click ? .hint : .peek, animation: style.peekIn) }
            if click { after(1.6) { self.click() } }
            after(click ? 1.75 : 1.6) { self.set(level: .expanded, animation: style.open) }
            after(2.0) { self.move(to: self.sampleTile, duration: 0.6) }
            after(2.8) { self.click(); self.dragging = true }
            after(2.9) { self.move(to: l.sample, duration: 0.9) }
            after(3.6) { self.folderTargeted = true }
            after(3.9) {
                withAnimation(.easeOut(duration: 0.15)) { self.dragging = false }
                self.folderTargeted = false
                // Wie eingestellt: Herausgezogenes verlässt die Ablage oder bleibt liegen
                if self.settings.removeAfterDragOut {
                    let ids = Set(self.store.entries.filter { $0.files.contains { $0.url == self.sampleURL } }.map(\.id))
                    self.store.discard(ids)
                }
            }
            after(4.6) { self.move(to: CGPoint(x: l.sample.x + 40, y: l.sample.y + 70), duration: 0.5) }
            after(5.0) { self.set(level: .hidden, animation: style.close) }

        case .dragOut:
            // Zeiger an den Rand, Ablage öffnet sich, Foto auf den Papierkorb der Leiste ziehen
            period = 6.6
            fill(withSample: true)
            set(level: .hidden, animation: nil)
            pointer = l.away(l.full.width + 250, y: l.size.height * 0.64)
            after(0.4) { self.move(to: l.away(4, y: l.size.height * 0.5), duration: 0.8) }
            let click = settings.openMode == .click
            after(1.2) { self.set(level: click ? .hint : .peek, animation: style.peekIn) }
            if click { after(1.6) { self.click() } }
            after(click ? 1.75 : 1.6) { self.set(level: .expanded, animation: style.open) }
            after(2.0) { self.move(to: self.sampleTile, duration: 0.6) }
            after(2.8) { self.click(); self.dragging = true }
            after(2.9) { self.move(to: self.trashAction, duration: 0.9) }
            after(3.9) {
                withAnimation(.easeOut(duration: 0.15)) { self.dragging = false }
                // Das Foto ist im Papierkorb und damit nicht mehr in der Ablage
                let ids = Set(self.store.entries.filter { $0.files.contains { $0.url == self.sampleURL } }.map(\.id))
                self.store.discard(ids)
            }
            after(5.0) { self.move(to: l.away(l.full.width + 250, y: l.size.height * 0.64), duration: 0.6) }
            after(5.3) { self.set(level: .hidden, animation: style.close) }

        case .hover:
            // Ohne Datei: Zeiger an den Rand, Streifen, kurz darauf die Ablage; wieder weg
            period = 5.4
            fill(withSample: true)
            set(level: .hidden, animation: nil)
            pointer = l.away(l.full.width + 250, y: l.size.height * 0.62)
            after(0.4) { self.move(to: l.away(4, y: l.size.height * 0.5), duration: 0.8) }
            let click = settings.openMode == .click
            after(1.2) { self.set(level: .peek, animation: style.peekIn) }
            after(1.4) { self.set(level: .hint, animation: style.peekIn) }
            if click { after(1.9) { self.click() } }
            after(click ? 2.05 : 1.9) { self.set(level: .expanded, animation: style.open) }
            after(3.6) { self.move(to: l.away(l.full.width + 250, y: l.size.height * 0.62), duration: 0.6) }
            after(3.9) { self.set(level: .hidden, animation: style.close) }

        case .shortcut:
            // Kurzbefehl öffnet die Ablage, noch einmal schließt sie. Zu nur kurz: Vorher stand
            // die Bühne gut die Hälfte der Zeit leer da (Bildschirmfoto des Nutzers, 31.10.2026)
            period = 4.6
            fill(withSample: true)
            set(level: .hidden, animation: nil)
            pointer = l.away(l.full.width + 170, y: l.size.height * 0.7)
            after(0.4) { self.show(self.hotKeys) }
            after(0.5) { self.set(level: .expanded, animation: style.open) }
            after(1.2) { self.show(nil) }
            after(3.0) { self.show(self.hotKeys) }
            after(3.1) { self.set(level: .hidden, animation: style.close) }
            after(3.8) { self.show(nil) }
        }
        after(period) { self.loop() }
    }

    // MARK: Beispieldateien

    /// Ein Diagramm, ein Dokument und ein Foto, wie sie im Alltag in der Ablage liegen
    static func makeExamples(in directory: URL) -> [URL] {
        var urls: [URL] = []

        // Ein Diagramm statt Text: In der kleinen Kachel ist Text nicht zu erkennen
        let chart = directory.appendingPathComponent(L("Chart.png", "Diagramm.png"))
        let chartImage = NSImage(size: NSSize(width: 480, height: 360), flipped: false) { rect in
            NSColor.white.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 24, yRadius: 24).fill()
            let colors: [NSColor] = [.systemBlue, .systemTeal, .systemGreen, .systemOrange, .systemPink]
            let heights: [CGFloat] = [120, 190, 150, 250, 210]
            for (i, h) in heights.enumerated() {
                colors[i].setFill()
                NSBezierPath(roundedRect: NSRect(x: 52 + CGFloat(i) * 80, y: 50, width: 56, height: h),
                             xRadius: 10, yRadius: 10).fill()
            }
            return true
        }
        if let tiff = chartImage.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]),
           (try? png.write(to: chart)) != nil {
            urls.append(chart)
        }

        let document = directory.appendingPathComponent(L("Trip.pdf", "Reiseplan.pdf"))
        var box = CGRect(x: 0, y: 0, width: 420, height: 595)
        if let pdf = CGContext(document as CFURL, mediaBox: &box, nil) {
            pdf.beginPDFPage(nil)
            pdf.setFillColor(NSColor.white.cgColor)
            pdf.fill(box)
            pdf.setFillColor(NSColor(red: 0.2, green: 0.47, blue: 1, alpha: 1).cgColor)
            pdf.fill(CGRect(x: 40, y: 470, width: 340, height: 80))
            pdf.setFillColor(NSColor(white: 0.78, alpha: 1).cgColor)
            for i in 0..<11 {
                let width: CGFloat = i % 4 == 3 ? 190 : 340
                pdf.fill(CGRect(x: 40, y: 420 - CGFloat(i) * 30, width: width, height: 11))
            }
            pdf.endPDFPage()
            pdf.closePDF()
            urls.append(document)
        }

        let photo = directory.appendingPathComponent(L("Beach.jpg", "Strand.jpg"))
        let size = NSSize(width: 640, height: 480)
        let image = NSImage(size: size, flipped: false) { rect in
            NSGradient(colors: [NSColor(red: 0.98, green: 0.72, blue: 0.45, alpha: 1),
                                NSColor(red: 0.42, green: 0.62, blue: 0.95, alpha: 1)])?
                .draw(in: rect, angle: 90)
            NSColor(red: 1, green: 0.9, blue: 0.6, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: 380, y: 210, width: 120, height: 120)).fill()
            NSColor(red: 0.12, green: 0.42, blue: 0.68, alpha: 1).setFill()
            NSBezierPath(rect: NSRect(x: 0, y: 110, width: 640, height: 130)).fill()
            NSColor(red: 0.95, green: 0.85, blue: 0.66, alpha: 1).setFill()
            NSBezierPath(rect: NSRect(x: 0, y: 0, width: 640, height: 120)).fill()
            return true
        }
        if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]),
           (try? jpeg.write(to: photo)) != nil {
            urls.append(photo)
        }
        return urls
    }
}

/// Maße des kleinen Schreibtischs. Er ist so groß gerechnet, dass die Ablage in ihrer
/// eingestellten Größe hineinpasst, und wird dann verkleinert gezeigt.
struct DemoLayout {
    /// Größe auf der Seite der Einführung
    static let shown = CGSize(width: 500, height: 220)

    let edge: ScreenEdge
    let full: ShelfMetrics
    let iconSize: CGFloat
    /// Größe in Punkten der echten Ablage
    let size: CGSize
    let scale: CGFloat

    init(settings: AppSettings) {
        edge = settings.edge
        full = ShelfMetrics.for(.expanded, settings: settings)
        iconSize = CGFloat(settings.tileIconSize)
        let height = full.height + 2 * full.fillet + 44
        scale = Self.shown.height / height
        size = CGSize(width: Self.shown.width / scale, height: height)
    }

    /// Punkt mit Abstand `d` vom Rand der Ablage
    func away(_ d: CGFloat, y: CGFloat) -> CGPoint {
        CGPoint(x: edge == .right ? size.width - d : d, y: y)
    }

    /// Bild auf dem Schreibtisch und Ordner als Ziel
    var sample: CGPoint { away(full.width + 300, y: size.height * 0.42) }
    var folder: CGPoint { away(full.width + 330, y: size.height * 0.5) }

    /// Rahmen der offenen Ablage (mit den Übergängen oben und unten)
    var shelfFrame: CGRect {
        let h = full.height + 2 * full.fillet
        let x = edge == .right ? size.width - full.width : 0
        return CGRect(x: x, y: (size.height - h) / 2, width: full.width, height: h)
    }

    /// Mitte des Symbols der Kachel an Stelle `index`, nachgerechnet wie das Raster der
    /// Ablage (ShelfContent: Kopf, Abstände, anpassbare Spalten)
    /// Spalten des Rasters (anpassbare Spalten wie in ShelfContent)
    var columns: Int {
        max(1, Int((full.width - 24 + 8) / (iconSize + 22 + 8)))
    }

    /// Mitte der Aktion an Stelle `index` in der Leiste unten (eine Reihe, gleich breite Plätze
    /// wie QuickActionBar)
    func actionCenter(_ index: Int, count: Int) -> CGPoint {
        let frame = shelfFrame
        let inner = full.width - 2 * 10 - 2 * 6
        let slot = inner / CGFloat(count)
        let x = frame.minX + 10 + 6 + slot * (CGFloat(min(index, count - 1)) + 0.5)
        let y = frame.maxY - full.fillet - 8 - 2 - 6 - 17
        return CGPoint(x: x, y: y)
    }

    func tileCenter(_ index: Int) -> CGPoint {
        let available = full.width - 24
        let maximum = iconSize + 40, spacing: CGFloat = 8
        let column = min(maximum, (available - spacing * CGFloat(columns - 1)) / CGFloat(columns))
        let used = column * CGFloat(columns) + spacing * CGFloat(columns - 1)
        let start = 12 + (available - used) / 2
        let row = CGFloat(index / columns), col = CGFloat(index % columns)
        let top: CGFloat = full.fillet + 12 + 30 + 4 + 6
        let box = TileMetrics.box(iconSize)
        let rowHeight = box + 4 + 30 + 12
        let frame = shelfFrame
        return CGPoint(x: frame.minX + start + col * (column + spacing) + column / 2,
                       y: frame.minY + top + row * (rowHeight + 6) + 6 + box / 2)
    }
}

/// Tasten des Kurzbefehls in der Reihenfolge wie bei Apple: ⌃ ⌥ ⇧ ⌘
enum ShortcutKeys {
    static func keys(_ settings: AppSettings) -> [(symbol: String, name: String)] {
        let m = settings.hotKeyModifiers
        var keys: [(symbol: String, name: String)] = []
        if m & controlKey != 0 { keys.append((symbol: "⌃", name: "control")) }
        if m & optionKey != 0 { keys.append((symbol: "⌥", name: "option")) }
        if m & shiftKey != 0 { keys.append((symbol: "⇧", name: "shift")) }
        if m & cmdKey != 0 { keys.append((symbol: "⌘", name: "command")) }
        keys.append((symbol: settings.hotKeyLabel, name: ""))
        return keys
    }
}

/// Die Bühne: ein Stück Schreibtisch am gewählten Rand mit der echten Ablage darauf
struct ShelfStage: View {
    @StateObject private var demo: DemoShelf
    @ObservedObject private var settings = AppSettings.shared

    init(scene: DemoShelf.Scene) {
        _demo = StateObject(wrappedValue: DemoShelf(scene: scene))
    }

    var body: some View {
        let l = demo.layout
        ZStack(alignment: .topLeading) {
            DesktopBackground(edge: l.edge)
                .frame(width: l.size.width, height: l.size.height)

            if demo.scene == .takeOut {
                DesktopFolder(targeted: demo.folderTargeted)
                    .position(x: l.sample.x, y: l.sample.y + 14)
            }
            if demo.scene == .drop, let url = demo.sampleURL {
                DesktopIcon(url: url, selected: demo.iconSelected)
                    .position(x: l.sample.x, y: l.sample.y + 14)
            }

            // Vom Rand gezogen: wie das Fenster der echten Ablage breiter, die Ablage in seiner
            // Mitte, um `shift` vom Rand weg. Eine Ansicht für beide Fälle, sonst würde die
            // Ablage beim Lösen neu aufgebaut
            let torn = demo.ui.isTorn
            let width = torn ? l.full.width + 2 * EdgeTear.reach : l.full.width + ShelfMetrics.panelMargin
            ShelfRootView(ui: demo.ui, store: demo.store, settings: settings, actions: demo.actions)
                .frame(width: width, height: l.size.height)
                .position(x: torn ? l.away(l.full.width / 2 + demo.shift, y: 0).x : l.away(width / 2, y: 0).x,
                          y: l.size.height / 2)

            if let keys = demo.keys {
                KeyHUD(keys: keys)
                    .position(x: l.away(l.full.width + 0.5 * (l.size.width - l.full.width), y: 0).x,
                              y: l.size.height * 0.5)
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            }

            if demo.dragging, let url = demo.sampleURL {
                DragImage(url: url)
                    .position(x: demo.pointer.x, y: demo.pointer.y + 10)
                    .transition(.opacity)
            }

            DemoPointer(down: demo.pointerDown)
                .position(demo.pointer)
        }
        .frame(width: l.size.width, height: l.size.height, alignment: .topLeading)
        // Rand gewechselt: Die Bühne wird neu aufgebaut statt umgestellt. Sonst kam der
        // Wechsel teils erst zusammen mit der Öffnen-Animation an, und die Ablage glitt
        // sichtbar quer durchs Bild zum anderen Rand (Bildschirmaufnahmen)
        .id(l.edge)
        .transition(.identity)
        .environment(\.shelfDemo, true)
        .allowsHitTesting(false)
        .scaleEffect(l.scale, anchor: .topLeading)
        .frame(width: DemoLayout.shown.width, height: DemoLayout.shown.height, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(SettingsTheme.cardBorder, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
        .onAppear { demo.start() }
        .onDisappear { demo.stop() }
        .accessibilityHidden(true)
    }
}

/// Schreibtisch der Vorführungen: das Schiefergrau des App-Symbols, oben etwas heller, wie
/// auf den Bildern im README. Immer gleich, damit die Einführung zu BarDrop passt.
struct DesktopBackground: View {
    let edge: ScreenEdge

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.275, green: 0.314, blue: 0.388),
                                    Color(red: 0.196, green: 0.227, blue: 0.286),
                                    Color(red: 0.110, green: 0.125, blue: 0.161)],
                           startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Color(red: 0.51, green: 0.57, blue: 0.69).opacity(0.36), .clear],
                           center: UnitPoint(x: 0.5, y: -0.06), startRadius: 0, endRadius: 420)
        }
    }
}

/// Datei auf dem Schreibtisch wie im Finder
private struct DesktopIcon: View {
    let url: URL
    let selected: Bool

    var body: some View {
        DesktopItem(image: NSImage(contentsOf: url) ?? Thumbnails.icon(url),
                    name: url.lastPathComponent, highlighted: selected, selectedName: selected)
    }
}

/// Ordner auf dem Schreibtisch als Ziel
private struct DesktopFolder: View {
    let targeted: Bool

    var body: some View {
        DesktopItem(image: NSWorkspace.shared.icon(for: .folder),
                    name: L("Projects", "Projekte"), highlighted: targeted, selectedName: false)
    }
}

struct DesktopItem: View {
    let image: NSImage
    let name: String
    let highlighted: Bool
    let selectedName: Bool

    var body: some View {
        VStack(spacing: 3) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 64, height: 64)
                .padding(4)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.black.opacity(highlighted ? 0.28 : 0))
                )
            Text(name)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(selectedName ? Color(nsColor: .selectedContentBackgroundColor) : .clear)
                )
                .shadow(color: .black.opacity(selectedName ? 0 : 0.7), radius: 1.5, y: 1)
                .frame(width: 104)
        }
    }
}

/// Gezogenes Bild wie beim Ziehen aus der Ablage (DragSource): Vorschau und Name auf der
/// Markierungsfarbe, leicht durchscheinend wie bei macOS
private struct DragImage: View {
    let url: URL

    var body: some View {
        VStack(spacing: 3) {
            Image(nsImage: NSImage(contentsOf: url) ?? Thumbnails.icon(url))
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 64, height: 64)
            Text(url.lastPathComponent)
                .font(.system(size: 12))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color(nsColor: .selectedContentBackgroundColor))
                )
                .fixedSize()
        }
        .opacity(0.8)
    }
}

/// Der Mauszeiger von macOS; `position` ist die Spitze
private struct DemoPointer: View {
    let down: Bool

    var body: some View {
        let cursor = NSCursor.arrow
        let size = cursor.image.size
        Image(nsImage: cursor.image)
            .scaleEffect(down ? 0.9 : 1, anchor: UnitPoint(x: cursor.hotSpot.x / max(size.width, 1),
                                                          y: cursor.hotSpot.y / max(size.height, 1)))
            .frame(width: size.width, height: size.height)
            // Spitze auf den Punkt legen
            .offset(x: size.width / 2 - cursor.hotSpot.x, y: size.height / 2 - cursor.hotSpot.y)
    }
}

/// Gerade gedrückte Tasten, groß über dem Schreibtisch
private struct KeyHUD: View {
    let keys: [(symbol: String, name: String)]

    var body: some View {
        KeyCaps(keys: keys, size: 64, pressed: false)
            .padding(18)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color.black.opacity(0.55))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
            )
            .environment(\.colorScheme, .dark)
    }
}
