import AppKit
import SwiftUI

/// Drop-Ziel für eine Aktion. Nimmt Objekte aus der Ablage und von außen an,
/// gibt beim Drüberziehen einen einzelnen Haptik-Impuls und führt die Aktion
/// beim Loslassen aus. Ein Klick wendet die Aktion auf die Auswahl an.
final class ActionDropNSView: NSView, NSDraggingSource {
    var onTargeted: (Bool) -> Void = { _ in }
    var onDrop: (NSPasteboard, NSView) -> Void = { _, _ in }
    var onOwnDrop: ([URL], NSView) -> Void = { _, _ in }
    var onClick: (NSView) -> Void = { _ in }
    /// Zweiter Klick eines Doppelklicks (der erste kam als `onClick`)
    var onDoubleClick: () -> Void = {}
    /// Rechtsklick (oder ⌃-Klick): Menü der Aktion
    var menuProvider: (() -> NSMenu?)?
    /// Maustaste gedrückt bzw. losgelassen (die Aktion wird dabei kurz größer)
    var onPress: (Bool) -> Void = { _ in }
    /// Vorgang, den der Zeiger beim Drüberziehen zeigt (Ordner: verschieben oder kopieren)
    var operation: (NSDraggingInfo) -> NSDragOperation = { _ in .copy }
    /// Art der Aktion (Einführung: nur die passende Aktion nimmt etwas an)
    var kind: QuickAction.Kind?
    /// Name der Aktion: Diese Ansicht liegt über dem Knopf und nimmt die Klicks, darum ist sie
    /// das Element, das VoiceOver vorliest und drückt (ohne Namen unter dem Symbol war es stumm)
    var accessibilityTitle: String?
    override func isAccessibilityElement() -> Bool { accessibilityTitle != nil }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { accessibilityTitle }
    override func accessibilityPerformPress() -> Bool {
        onClick(self)
        return true
    }
    /// Ziehen einer Aktion (nur mit gedrückter ⌘-Taste, wie in der Menüleiste): Bild und
    /// Entfernen beim Herausziehen (nur mit „Per Ziehen anheften“, sonst nil)
    var dragOut: (image: () -> NSImage, remove: (() -> Void)?)?
    /// Diese Aktion (Ziel beim Verschieben)
    var actionID: QuickAction.ID?
    /// Eine andere Aktion wurde über diese gezogen: Die gezogene nimmt ihren Platz ein
    var onReorder: (QuickAction.ID) -> Void = { _ in }
    /// In der Leiste gezogen: wo der Zeiger steht, in SwiftUI-Koordinaten des Fensters
    /// (`.global`); nil: zurück an seinen Platz
    var onMove: (CGPoint?) -> Void = { _ in }
    /// Die Aktion hat sich aus der Leiste gelöst (ihr Platz bleibt leer, bis sie zurück ist)
    var onDraggingOut: (Bool) -> Void = { _ in }
    weak var ui: ShelfUIModel?

    private var pressed = false
    private var downEvent: NSEvent?
    /// Form der Ablage beim Start: dort losgelassen gleitet die Aktion zurück, draußen verschwindet sie
    private var dragStartFrame: NSRect = .zero
    /// Verlässt der Zeiger diesen Bereich, löst sich die Aktion: so früh, dass das Symbol in
    /// der Leiste den Rand der Ablage nie erreicht (dort würde es abgeschnitten)
    private var detachFrame: NSRect = .zero
    /// Bild am Zeiger nach dem Lösen, beim Start einmal erzeugt
    private var dragImage: NSImage?
    /// Der Zeiger zeigt gerade die Wolke (draußen, die Aktion verschwindet beim Loslassen)
    private var showsPoof = false

    private enum DragMode { case none, inBar, detached }
    private var mode: DragMode = .none
    /// Zuletzt verschoben: kurz nicht noch einmal, während die Leiste sich neu ordnet
    private static var reorderedAt = Date.distantPast
    /// Wann diese Aktion zuletzt ihren Platz geändert hat (auch mitten in der Feder)
    private var movedAt = Date.distantPast

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        if newOrigin != frame.origin { movedAt = Date() }
        super.setFrameOrigin(newOrigin)
    }

    override func setFrameSize(_ newSize: NSSize) {
        if newSize != frame.size { movedAt = Date() }
        super.setFrameSize(newSize)
    }
    /// Alle Aktionen der Leiste, um beim Ziehen die unter dem Zeiger zu finden
    private static let all = NSHashTable<ActionDropNSView>.weakObjects()

    /// Eigener Typ, den kein anderes Ziel annimmt
    static let actionType = NSPasteboard.PasteboardType("io.github.zzuuuiii.bardrop.quickaction")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes(ShelfStore.acceptedTypes)
        Self.all.add(self)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Verschwindet die Ansicht mitten im Ziehen mit ⌘, käme ihr Loslassen nie an und die
    /// Ablage bliebe gesperrt offen (`actionMoving`)
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil, mode == .inBar { endInBar() }
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control), menuProvider != nil {
            showMenu(with: event)
            return
        }
        pressed = true
        downEvent = event
        onPress(true)
    }

    override func rightMouseDown(with event: NSEvent) {
        showMenu(with: event)
    }

    /// Wie bei den Objekten: Die Ablage bleibt offen, solange das Menü steht
    private func showMenu(with event: NSEvent) {
        guard let menu = menuProvider?() else { return }
        ShelfUIModel.keepOpen(ui) { ShelfMenu.popUp(menu, with: event, for: self) }
    }

    override func mouseUp(with event: NSEvent) {
        if mode == .inBar {
            // Losgelassen in der Leiste: Das Symbol gleitet an seinen (neuen) Platz
            endInBar()
            return
        }
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        if pressed { onPress(false) }
        if pressed && inside {
            if event.clickCount >= 2 { onDoubleClick() } else { onClick(self) }
        }
        pressed = false
        downEvent = nil
    }

    override func mouseDragged(with event: NSEvent) {
        switch mode {
        case .detached:
            return
        case .inBar:
            trackInBar(event)
        case .none:
            guard dragOut != nil, let down = downEvent, let window else { return }
            let a = down.locationInWindow, b = event.locationInWindow
            guard hypot(a.x - b.x, a.y - b.y) > 4 else { return }
            if pressed { onPress(false) }
            pressed = false
            // Ohne ⌘ bleibt die Aktion, wo sie ist (und der Klick verfällt)
            guard down.modifierFlags.contains(.command) || event.modifierFlags.contains(.command) else {
                downEvent = nil
                return
            }
            mode = .inBar
            // An der schwarzen Form messen, nicht am Fenster (das ist wegen des Schattens größer)
            let body = ui?.expandedBody ?? .zero
            dragStartFrame = body.isEmpty ? window.frame : body
            let image = dragOut?.image()
            dragImage = image
            // Um den halben Symbolrand nach innen; steht die Aktion schon so nah am Rand
            // (untere Reihe), reicht dort ein kurzes Stück vom Startpunkt
            let half = max((image?.size.width ?? 40) / 2, 12)
            let start = window.convertPoint(toScreen: down.locationInWindow)
            detachFrame = dragStartFrame.insetBy(dx: half, dy: half)
                .union(NSRect(x: start.x - 8, y: start.y - 8, width: 16, height: 16))
            ui?.actionMoving = true
            trackInBar(event)
        }
    }

    /// In der Leiste: Das Symbol selbst hängt am Zeiger (kein zweites Bild). Über einer anderen
    /// Aktion rückt es an deren Platz. Verlässt der Zeiger die Ablage, löst es sich.
    private func trackInBar(_ event: NSEvent) {
        guard let window else { return }
        let screenPoint = window.convertPoint(toScreen: event.locationInWindow)
        if dragOut?.remove != nil, !detachFrame.contains(screenPoint) {
            detach(event)
            return
        }
        follow(event.locationInWindow)
        reorder(atScreen: screenPoint)
    }

    /// Steht der Zeiger über der Mitte einer anderen Aktion, rückt diese an ihren Platz.
    /// Auch nach dem Lösen, wenn der Zeiger zurück in die Ablage kommt: Sonst reagierten die
    /// anderen Aktionen nicht mehr, sobald man einmal kurz über den Rand hinaus war.
    ///
    /// In Bildschirmkoordinaten und über alle Aktionen der offenen Ablage, nicht nur über die
    /// eigene Ansicht: Schließt sich die Ablage, während die Aktion draußen am Zeiger hängt,
    /// und öffnet sich wieder, ist die Leiste neu aufgebaut und diese Ansicht nicht mehr darin.
    @discardableResult
    private func reorder(atScreen screenPoint: NSPoint) -> Bool {
        // Erst wenn die Leiste nach dem letzten Tausch wieder still steht (Feder etwa 0,3 s):
        // Solange die Symbole noch gleiten, lag der Zeiger noch über der alten Aktion, und sie
        // tauschten hin und her.
        guard let me = actionID, Date().timeIntervalSince(Self.reorderedAt) > 0.15 else { return false }
        let bar = Self.all.allObjects.filter { $0.window is ShelfPanel && $0.window?.isVisible == true && $0.actionID != nil }
        func local(_ view: ActionDropNSView) -> NSPoint {
            guard let window = view.window else { return NSPoint(x: -1e6, y: -1e6) }
            return view.convert(window.convertPoint(fromScreen: screenPoint), from: nil)
        }
        // Steht der Zeiger schon über dem eigenen Platz, nichts tun
        if let own = bar.first(where: { $0.actionID == me }), own.bounds.contains(local(own)) { return false }
        // Erst wenn keine Aktion mehr gleitet: Mitten in der Feder lag der Zeiger noch über
        // der Aktion, mit der gerade getauscht wurde, und sie tauschten wieder zurück
        let now = Date()
        guard bar.allSatisfy({ now.timeIntervalSince($0.movedAt) > 0.08 }) else { return false }
        for view in bar where view.actionID != me {
            // Nur über der Mitte der anderen Aktion, nicht schon an ihrem Rand
            let inner = view.bounds.insetBy(dx: view.bounds.width * 0.2, dy: 0)
            guard inner.contains(local(view)) else { continue }
            Self.reorderedAt = Date()
            view.onReorder(me)
            ShelfSnapshots.capture(view.window, "reorder", after: [0.05, 0.2, 0.5])
            return true
        }
        return false
    }

    /// Den Zeiger melden, nicht den Abstand zum eigenen Platz: Den rechnet die Ansicht beim
    /// Zeichnen selbst aus. Vorher kam nach einem Tausch der neue Platz ein Bild früher an
    /// als der neue Abstand, und das Symbol sprang kurz um eine Stelle weiter.
    private func follow(_ pointInWindow: NSPoint) {
        guard let host = window?.contentView else { return }
        let p = host.convert(pointInWindow, from: nil)
        onMove(host.isFlipped ? p : CGPoint(x: p.x, y: host.bounds.height - p.y))
    }

    private func endInBar() {
        mode = .none
        downEvent = nil
        ui?.actionMoving = false
        onMove(nil)
    }

    /// Aus der Ablage hinaus: Die Aktion löst sich mit einem spürbaren Ruck und hängt jetzt
    /// am Zeiger; draußen losgelassen verschwindet sie, über der Ablage gleitet sie zurück.
    private func detach(_ event: NSEvent) {
        guard let dragOut else { return }
        mode = .detached
        ui?.actionMoving = false
        // Erst ausblenden, dann an den Platz zurück: Sonst flog das Symbol sichtbar zurück,
        // während schon das Bild am Zeiger hing
        onDraggingOut(true)
        onMove(nil)
        // Spürbarer Ruck beim Lösen (Haptics.drop ist absichtlich stumm)
        Haptics.tap()
        let item = NSPasteboardItem()
        item.setString("", forType: Self.actionType)
        let dragging = NSDraggingItem(pasteboardWriter: item)
        // Genau dort, wo das Symbol in der Leiste gerade hing (mittig am Zeiger), gleich groß
        let image = dragImage ?? dragOut.image()
        let size = image.size
        let point = convert(event.locationInWindow, from: nil)
        dragging.setDraggingFrame(NSRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                                         width: size.width, height: size.height),
                                  contents: image)
        // Wie beim Herausziehen von Objekten: Die Ablage bleibt, solange der Drag läuft
        ui?.ownDragActive = true
        let session = beginDraggingSession(with: [dragging], event: event, source: self)
        // Nicht von macOS zurückgleiten lassen: Das Bild flog an den alten Platz, erst danach
        // erschien die Aktion dort, ruckartig. Zurück gleitet jetzt das Symbol selbst (endedAt)
        session.animatesToStartingPositionsOnCancelOrFail = false
    }

    // MARK: Herausziehen (Quelle)

    /// Über der Ablage losgelassen: Das Symbol erscheint genau dort, wo das Bild am Zeiger
    /// hing, und gleitet in einem Zug an seinen Platz, wie beim Loslassen in der Leiste.
    /// Ist die Leiste inzwischen neu aufgebaut, übernimmt das die Ansicht, die jetzt dort steht.
    private func settle(at screenPoint: NSPoint) {
        guard let me = actionID,
              let live = Self.all.allObjects.first(where: {
                  $0.actionID == me && $0.window is ShelfPanel && $0.window?.isVisible == true
              }), let window = live.window else {
            onDraggingOut(false)
            return
        }
        live.follow(window.convertPoint(fromScreen: screenPoint))
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { onDraggingOut(false) }
        DispatchQueue.main.async { live.onMove(nil) }
    }

    /// Über der Ablage: wo sie beim Start stand oder wo sie jetzt offen steht. Schließt sie
    /// sich unterwegs und öffnet sich wieder, kann sie woanders stehen (Höhe am Zeiger);
    /// dort losgelassen galt die Aktion sonst als herausgezogen und verschwand.
    private func isOverShelf(_ screenPoint: NSPoint) -> Bool {
        if dragStartFrame.contains(screenPoint) { return true }
        guard let ui, ui.level == .expanded else { return false }
        return ui.expandedBody.contains(screenPoint)
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .move
    }

    func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        // Draußen verschwindet die Aktion beim Loslassen, drinnen gleitet sie zurück
        let inside = isOverShelf(screenPoint)
        // Zurück in der Ablage: wieder verschieben wie vor dem Lösen
        if inside, mode == .detached { reorder(atScreen: screenPoint) }
        // Wie im Finder beim Herausziehen aus der Seitenleiste: Draußen zeigt der Zeiger die
        // Wolke mit dem x, drinnen wieder den normalen Zeiger
        if !inside {
            NSCursor.disappearingItem.set()
            showsPoof = true
        } else if showsPoof {
            NSCursor.arrow.set()
            showsPoof = false
        }
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        mode = .none
        downEvent = nil
        ui?.ownDragActive = false
        if showsPoof {
            NSCursor.arrow.set()
            showsPoof = false
        }
        if isOverShelf(screenPoint) {
            settle(at: screenPoint)
            return
        }
        onDraggingOut(false)
        guard operation == [], let remove = dragOut?.remove else { return }
        // Ohne Staubwolke: Die Aktion verschwindet einfach, ihr Platz schließt sich. Klang wie
        // beim Herausziehen eines Symbols aus dem Dock
        Haptics.drop()
        Sounds.poof()
        DispatchQueue.main.async { remove() }
    }

    // MARK: Drop

    private var introAllows: Bool { kind.map(IntroGate.allowsDrop(on:)) ?? true }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        ui?.holdPinCandidate()
        // Kommt ein Ordner oder eine App zuerst über einer Aktion in die Ablage (etwa weil sie
        // sich gerade unter dem Zeiger öffnet), sah die Ablage selbst ihn nie hereinkommen:
        // Der Platz zum Anheften fehlte dann
        if let ui, ui.pinCandidate == nil, !(sender.draggingSource is DragSourceNSView) {
            ui.setPinCandidate(ShelfDropHandler.pinCandidate(sender.draggingPasteboard))
        }
        guard introAllows else { return [] }
        onTargeted(true)
        Haptics.tap()
        return Self.allowed(operation(sender), by: sender.draggingSourceOperationMask)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        ui?.holdPinCandidate()
        guard introAllows else { return [] }
        return Self.allowed(operation(sender), by: sender.draggingSourceOperationMask)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { introAllows }

    /// Nur Vorgänge anzeigen, die die Quelle erlaubt. Verschieben ohne Erlaubnis zeigt
    /// den Zeiger ohne Zeichen, wie der Finder beim Verschieben.
    static func allowed(_ wanted: NSDragOperation, by mask: NSDragOperation) -> NSDragOperation {
        if mask.contains(wanted) { return wanted }
        if wanted == .move, mask.contains(.generic) { return .generic }
        return mask.contains(.copy) ? .copy : .generic
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onTargeted(false)
        ui?.releasePinCandidate()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if sender.draggingSource is DragSourceNSView, let ui {
            // Eigene Objekte: die gespeicherten Dateien verwenden, nicht die frischen
            // Kopien auf dem Drag-Pasteboard (sonst verschiebt z. B. eine Ordner-Aktion nur die Kopie)
            ui.lastDropWasInternal = true
            let urls = ui.draggedFileURLs
            DispatchQueue.main.async { self.onOwnDrop(urls, self) }
            Haptics.drop()
            return true
        }
        ui?.setPinCandidate(nil)
        onDrop(sender.draggingPasteboard, self)
        Haptics.drop()
        return true
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) { onTargeted(false) }
    override func draggingEnded(_ sender: NSDraggingInfo) { onTargeted(false) }
}

struct ActionDropTarget: NSViewRepresentable {
    var ui: ShelfUIModel
    var onTargeted: (Bool) -> Void
    var onDrop: (NSPasteboard, NSView) -> Void
    var onOwnDrop: ([URL], NSView) -> Void
    var onClick: (NSView) -> Void
    var onDoubleClick: () -> Void = {}
    var menuProvider: (() -> NSMenu?)? = nil
    var onPress: (Bool) -> Void = { _ in }
    var operation: (NSDraggingInfo) -> NSDragOperation = { _ in .copy }
    var kind: QuickAction.Kind? = nil
    /// Name der Aktion für VoiceOver
    var accessibilityTitle: String? = nil
    var dragOut: (image: () -> NSImage, remove: (() -> Void)?)? = nil
    var onDraggingOut: (Bool) -> Void = { _ in }
    var actionID: QuickAction.ID? = nil
    var onReorder: (QuickAction.ID) -> Void = { _ in }
    var onMove: (CGPoint?) -> Void = { _ in }

    func makeNSView(context: Context) -> ActionDropNSView {
        let view = ActionDropNSView(frame: .zero)
        configure(view)
        return view
    }

    func updateNSView(_ view: ActionDropNSView, context: Context) { configure(view) }

    private func configure(_ view: ActionDropNSView) {
        view.ui = ui
        view.onTargeted = onTargeted
        view.onDrop = onDrop
        view.onOwnDrop = onOwnDrop
        view.onClick = onClick
        view.onDoubleClick = onDoubleClick
        view.menuProvider = menuProvider
        view.onPress = onPress
        view.operation = operation
        view.kind = kind
        view.accessibilityTitle = accessibilityTitle
        view.dragOut = dragOut
        view.onDraggingOut = onDraggingOut
        view.actionID = actionID
        view.onReorder = onReorder
        view.onMove = onMove
    }
}

// MARK: Darstellung

/// Symbol einer Aktion: echte App-, Ordner- und AirDrop-Symbole,
/// „Teilen“ im selben Kachelstil gezeichnet.
struct QuickActionIcon: View {
    let action: QuickAction
    var size: CGFloat = 34
    /// Zeichnet neu, wenn sich der Papierkorb füllt oder leert
    @ObservedObject private var trash = TrashState.shared
    /// Hell oder dunkel (Einstellungen → Aussehen → Symbole)
    @ObservedObject private var appearance = IconAppearance.shared
    @Environment(\.colorfulIcons) private var colorful

    /// App-Symbole und eigene Kacheln etwas größer als die Fläche: Mit dem Rand der
    /// App-Symbole von macOS (Kachel 80,5 %) wirkten sie neben Ordner und Papierkorb, die fast
    /// die ganze Fläche füllen, zu klein (Nutzer, 30.10.2026). Der Zuschlag liegt im
    /// durchsichtigen Rand, die Kachel nimmt so knapp 89 % ein
    private var scale: CGFloat { action.kind == .folder || action.kind == .trash ? 1 : 1.1 }

    /// Kante der Kachel in der Fläche des Symbols
    private var tileSize: CGFloat { size * AppIconShape.bodyFraction * scale }

    var body: some View {
        if let service = action.cloudService {
            // Logo des Dienstes, so groß wie die anderen Kacheln der Leiste
            CloudLogoTile(service: service, size: tileSize)
                .frame(width: size, height: size)
        } else if action.kind == .airdrop && appearance.isDark {
            // Das AirDrop-Symbol des Systems gibt es nur hell: im dunklen Stil auf dem dunklen
            // Grund nachgezeichnet, gut erkennbar im Blau von AirDrop (Nutzer, 29.10.2026)
            AppIconBackground(size: tileSize, dark: true, light: SettingsTheme.iconGradient(.blue))
                .overlay(AirDropDarkGlyph(size: tileSize))
                .appIconShadow(size: tileSize)
                .frame(width: size, height: size)
        } else if let icon = action.icon {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size * scale, height: size * scale)
                .frame(width: size, height: size)
        } else {
            ownTile
        }
    }

    /// Teilen und AirDrop im Blau von AirDrop, Plugins in ihrer eigenen Farbe
    private var tileColors: [Color] {
        if action.kind == .plugin {
            let tint = PluginManager.shared.plugin(action.path)?.manifest.icon?.tint ?? PluginIconView.fallbackTint
            return SettingsTheme.iconColors(tint)
        }
        if let service = action.cloudService {
            return SettingsTheme.iconColors(service.tint)
        }
        return AirDropColors.shared.gradient
    }

    /// Eigene Kachel im macOS-Icon-Raster (Form und Größe wie die App-Symbole daneben)
    private var ownTile: some View {
        SymbolIconTile(symbol: action.fallbackSymbol, colors: tileColors, size: tileSize,
                       glyphOffset: action.kind == .share ? -0.043 : 0)
            // Nur Plugins bleiben in den Einstellungen farbig (siehe colorfulIcons)
            .environment(\.colorfulIcons, action.kind == .plugin && colorful)
            .frame(width: size, height: size)
    }
}

/// Farben des AirDrop-Symbols des Systems, oben und unten gemessen. Die Teilen-Kachel
/// übernimmt sie, damit beide nebeneinander wie aus einem Guss aussehen, auch wenn
/// Apple das Symbol mit einer neuen macOS-Version umfärbt.
final class AirDropColors {
    static let shared = AirDropColors()

    /// Verlauf von oben nach unten
    let gradient: [Color]

    /// Ohne lesbares Symbol: das bisherige Blau von AirDrop
    private static let fallback = [Color(red: 0.42, green: 0.78, blue: 1.0),
                                   Color(red: 0.04, green: 0.46, blue: 0.98)]

    private init() {
        let icon: NSImage? = NSSharingService(named: .sendViaAirDrop)?.image
        gradient = icon.flatMap(Self.measure) ?? Self.fallback
    }

    /// Mittlere Farbe der deckenden, farbigen Bildpunkte im oberen und unteren Viertel
    /// (weiße Wellen und Glanz zählen nicht)
    static func measure(_ image: NSImage) -> [Color]? {
        let size = 48
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
        NSGraphicsContext.restoreGraphicsState()

        func average(rows: Range<Int>) -> Color? {
            var r = 0.0, g = 0.0, b = 0.0, n = 0.0
            for y in rows {
                for x in 0..<size {
                    guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                          c.alphaComponent > 0.9, c.saturationComponent > 0.35 else { continue }
                    r += c.redComponent; g += c.greenComponent; b += c.blueComponent; n += 1
                }
            }
            guard n > 20 else { return nil }
            return Color(red: r / n, green: g / n, blue: b / n)
        }
        // colorAt zählt von oben
        guard let top = average(rows: 0..<size / 4),
              let bottom = average(rows: size * 3 / 4..<size) else { return nil }
        return [top, bottom]
    }
}

struct QuickActionButton: View {
    let action: QuickAction
    @ObservedObject var ui: ShelfUIModel
    /// Vorführung in der Einführung: ohne Drop-Fläche
    @Environment(\.shelfDemo) private var shelfDemo
    let store: ShelfStore
    let actions: ShelfActions
    /// Als Wert übergeben, damit die Leiste beim Verstellen sofort neu zeichnet
    var iconSize: CGFloat = 34

    @State private var targeted = false
    /// Hat sich aus der Leiste gelöst: Ihr Platz bleibt leer, es gibt nur das Bild am Zeiger
    /// Die Aktion hängt draußen am Zeiger: Ihr Platz bleibt leer. Im gemeinsamen Zustand,
    /// nicht in der Ansicht: Schloss sich die Ablage dabei und öffnete sich wieder, war die
    /// Ansicht neu und zeigte das Symbol, obwohl es noch am Zeiger hing
    private var draggingOut: Bool { ui.detachedAction == action.id }
    /// Mit ⌘ in der Leiste gezogen: So weit hängt das Symbol am Zeiger von seinem Platz weg
    /// Beim Ziehen mit ⌘: Zeiger in `.global`-Koordinaten (siehe ActionDropNSView.follow)
    @State private var movePoint: CGPoint?
    /// Gerade angeklickt: kurz größer wie beim Draufziehen, ohne Fläche dahinter und ohne Impuls
    @State private var pressed = false
    @State private var pressedAt = Date.distantPast

    /// Ein schneller Klick soll trotzdem sichtbar sein: so lange bleibt sie mindestens groß
    private static let minimumPress: TimeInterval = 0.14

    private func setPressed(_ down: Bool) {
        if down {
            pressedAt = Date()
            pressed = true
        } else {
            let wait = max(0, Self.minimumPress - Date().timeIntervalSince(pressedAt))
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { pressed = false }
        }
    }

    /// Ordner: wie der Finder verschieben oder kopieren, sonst immer „Kopieren“
    private func dropOperation(_ info: NSDraggingInfo) -> NSDragOperation {
        guard action.kind == .folder, let folder = action.url else { return .copy }
        let urls: [URL]
        if info.draggingSource is DragSourceNSView {
            urls = ui.draggedFileURLs
        } else {
            urls = (info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                         options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        }
        guard let first = urls.first else { return .copy }
        return ShelfActions.folderOperation(for: first, into: folder, modifiers: NSEvent.modifierFlags)
    }

    /// Ziehen: mit ⌘ in der Leiste verschieben; Herausziehen entfernt die Aktion, wenn
    /// „Per Ziehen anheften“ eingeschaltet ist
    private var dragOut: (image: () -> NSImage, remove: (() -> Void)?) {
        let action = action
        // Genau das Symbol aus der Leiste, in der Größe, in der es gerade am Zeiger hängt.
        // Vorher war es das Bild der Datei bzw. das Systemsymbol: Bei „Teilen“ (in der Leiste
        // als Kachel gezeichnet) hing dann nur das Zeichen ohne Kachel am Zeiger.
        let size = iconSize * 1.1
        let image: () -> NSImage = {
            let renderer = ImageRenderer(content: QuickActionIcon(action: action, size: size))
            renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
            return renderer.nsImage
                ?? action.icon
                ?? NSImage(systemSymbolName: action.fallbackSymbol, accessibilityDescription: nil)
                ?? NSImage()
        }
        let id = action.id
        let remove: (() -> Void)? = AppSettings.shared.pinFromShelf ? {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                AppSettings.shared.removeQuickAction(id)
            }
        } : nil
        return (image: image, remove: remove)
    }

    var body: some View {
        // Produktbilder zeigen eine Aktion mit einer Datei darüber
        let highlighted = targeted || ui.previewTargetedAction == action.id
        let label = VStack(spacing: 4) {
            // Ohne Namen größer, damit die Leiste nicht leer wirkt
            QuickActionIcon(action: action, size: iconSize)
                .scaleEffect(highlighted || pressed || movePoint != nil ? 1.1 : 1)
                .opacity(draggingOut ? 0 : 1)
            if AppSettings.shared.showActionLabels {
                // „Nur Ordner“: die übrigen Aktionen halten den Platz frei, damit alle
                // Symbole auf einer Höhe stehen
                let named = !AppSettings.shared.labelsOnlyFolders || action.kind == .folder
                Text(action.title)
                    .font(.system(size: 10, weight: highlighted ? .semibold : .medium))
                    .foregroundStyle(Color.primary.opacity(0.7))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .opacity(named ? 1 : 0)
                    .accessibilityHidden(!named)
            }
        }
        // Der Platz bleibt unsichtbar stehen und gibt die Größe vor; gezeichnet wird das Symbol
        // darüber, beim Ziehen mit ⌘ samt Namen am Zeiger. Der Abstand zum Platz entsteht im
        // selben Durchgang wie der Platz selbst: Nach einem Tausch steht es sofort richtig.
        // Die Fläche zum Ablegen (unten) bleibt am Platz, damit die Leiste weiß, wo die Aktion steht
        return label
            .hidden()
            .overlay {
                GeometryReader { g in
                    let slot = g.frame(in: .global)
                    label
                        .frame(width: g.size.width, height: g.size.height)
                        .offset(movePoint.map { CGSize(width: $0.x - slot.midX, height: $0.y - slot.midY) } ?? .zero)
                }
            }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(highlighted ? 0.12 : 0))
        )
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: highlighted)
        .animation(.spring(response: 0.22, dampingFraction: 0.7), value: pressed)
        .overlay(Group { if !shelfDemo {
            ActionDropTarget(
                ui: ui,
                onTargeted: { targeted = $0 },
                onDrop: { pb, anchor in
                    // Tasten beim Loslassen: ⌥ kopiert, ⌘ verschiebt (Ordner-Aktion)
                    let modifiers = NSEvent.modifierFlags
                    let files = (pb.readObjects(forClasses: [NSURL.self],
                                                options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
                    // Plugins arbeiten mit Objekten der Ablage (das Ergebnis erscheint daneben):
                    // Dateien aus dem Finder erst übernehmen, sonst hieß es „Nicht passend“ (Issue 57)
                    // Ebenso Cloud: Der Platzhalter steht neben dem Objekt in der Ablage
                    if action.kind != .plugin && action.kind != .cloud && !files.isEmpty && files.allSatisfy(ContentImporter.isUserFile) {
                        // Dateien aus dem Finder direkt verwenden
                        DispatchQueue.main.async {
                            actions.perform(action, urls: files, anchor: anchor, modifiers: modifiers)
                        }
                    } else {
                        // Bilder aus dem Web, temporäre Dateien, Links, Text: zuerst in die
                        // Ablage übernehmen, dann ausführen
                        store.ingest(from: pb) { urls in
                            // Für einen Kurzbefehl nur Zwischenschritt: danach zählt nur das Ergebnis
                            if action.kind == .shortcut { actions.shortcutOnlyInputs.formUnion(urls) }
                            actions.perform(action, urls: urls, anchor: anchor, modifiers: modifiers)
                        }
                    }
                },
                onOwnDrop: { urls, anchor in
                    actions.perform(action, urls: urls, anchor: anchor)
                },
                onClick: { _ in
                    // Ein Klick führt die Aktion nicht mit der Auswahl aus (dafür Objekte darauf
                    // ziehen): Ordner zeigen ihren Inhalt in der Ablage, Apps öffnen sich
                    actions.click(action)
                },
                onDoubleClick: { actions.doubleClick(action) },
                menuProvider: { actions.menu(for: action) },
                onPress: { down in setPressed(down) },
                operation: { info in dropOperation(info) },
                kind: action.kind,
                accessibilityTitle: action.title,
                dragOut: dragOut,
                onDraggingOut: { value in
                    // Beim Lösen sofort weg (nur ein Symbol), beim Zurückkommen sanft
                    if value {
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) { ui.detachedAction = action.id }
                    } else if ui.detachedAction == action.id {
                        withAnimation(.easeOut(duration: 0.15)) { ui.detachedAction = nil }
                    }
                },
                actionID: action.id,
                onReorder: { from in
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        AppSettings.shared.moveQuickAction(from, to: action.id)
                    }
                    Haptics.tap()
                },
                onMove: { point in
                    if point == nil {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { movePoint = nil }
                    } else {
                        // Genau am Zeiger, ohne Nachziehen
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) { movePoint = point }
                    }
                }
            )
        } })
        // Das gezogene Symbol liegt über den anderen; sein Platz springt ohne Animation mit,
        // sonst liefe es beim Umordnen kurz dem Zeiger davon
        .zIndex(movePoint != nil ? 1 : 0)
        .transaction { if movePoint != nil { $0.animation = nil } }
        .help(action.help)
    }
}

struct QuickActionBar: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var ui: ShelfUIModel
    /// Plugins ein- oder ausgeschaltet: ihre Aktionen erscheinen bzw. verschwinden
    @ObservedObject private var pluginManager = PluginManager.shared
    let store: ShelfStore
    let actions: ShelfActions
    @Environment(\.shelfDemo) private var shelfDemo

    /// Eine Stelle in der Leiste: eine Aktion oder der freie Platz zum Anheften
    private enum Slot: Identifiable {
        case action(QuickAction)
        case pin(URL)
        var id: String {
            switch self {
            case .action(let a): return a.id.uuidString
            case .pin: return "pin"
            }
        }
    }

    var body: some View {
        // Plugins nur, solange sie eingeschaltet sind
        // In der Einführung immer die Standardaktionen in einer Reihe
        let all = shelfDemo ? QuickAction.demo
            : settings.quickActions.filter { $0.kind != .plugin || PluginManager.shared.isActive($0.path) }
        // Der Platz zum Anheften kommt dorthin, wo die Aktion danach stünde: ans Ende
        let pin = ui.pinCandidate.flatMap { settings.pinFromShelf ? $0 : nil }
        let slots = all.map(Slot.action) + (pin.map { [Slot.pin($0)] } ?? [])
        Group {
            // Zwei Reihen, wie in den Einstellungen verteilt
            let split = shelfDemo ? slots.count : AppSettings.clampSplit(settings.actionRowSplit, count: slots.count)
            let top = Array(slots.prefix(split))
            let bottom = Array(slots.dropFirst(split).prefix(QuickAction.perRow))
            // Beide Reihen gleich groß: so groß, wie es die vollere Reihe erlaubt
            let size = iconSize(forActions: max(Self.actionCount(top), Self.actionCount(bottom)))
            // Beide Reihen in einem Container mit einem ForEach: Jede Aktion behält ihre Ansicht,
            // auch wenn sie beim Ziehen mit ⌘ in die andere Reihe wechselt. Mit einem HStack je
            // Reihe baute SwiftUI sie dabei neu: Sie folgte dem Zeiger nicht mehr, ihr Loslassen
            // kam nie an und die Ablage blieb gesperrt offen (Nutzer, 25.10.2026)
            ActionRowsLayout(split: top.count) {
                ForEach(top + bottom) { slot in
                    switch slot {
                    case .action(let action):
                        QuickActionButton(action: action, ui: ui, store: store, actions: actions, iconSize: size)
                    case .pin(let url):
                        PinSlot(url: url, ui: ui, settings: settings, iconSize: size)
                            .transition(.scale(scale: 0.6).combined(with: .opacity))
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .onChange(of: ui.level) { _, level in
            if level != .expanded { ui.setPinCandidate(nil) }
        }
    }

    /// Symbolgröße: eingestellt, ohne Namen etwas größer, damit die Leiste nicht leer wirkt
    private var iconSize: CGFloat {
        CGFloat(settings.actionIconSize) + (settings.showActionLabels ? 0 : 10)
    }

    /// Symbolgröße, wenn `count` Aktionen nebeneinander stehen: wie eingestellt, aber nie
    /// breiter als ihr Platz (große Symbole bei vielen Aktionen überlappten sonst). Breite wie
    /// in ShelfContent: Ablage minus Ränder der Leiste, 2 pt zwischen den Plätzen. Gezählt
    /// werden nur Aktionen, nicht der Platz zum Anheften: Sonst schrumpften beim Ziehen eines
    /// Ordners über die Ablage alle Symbole.
    private func iconSize(forActions count: Int) -> CGFloat {
        let places = CGFloat(max(count, 1))
        let inner = CGFloat(settings.shelfWidth) - 2 * 10 - 2 * 6
        let slot = (inner - 2 * (places - 1)) / places
        return min(iconSize, max(20, slot - 6))
    }

    private static func actionCount(_ items: [Slot]) -> Int {
        items.filter { if case .action = $0 { return true } else { return false } }.count
    }

}

/// Die Aktionsleiste in bis zu zwei Reihen: oben die ersten `split` Plätze, unten der Rest. In
/// jeder Reihe teilen sich die Aktionen die ganze Breite, jede mittig in ihrem Teil (wie ein
/// HStack mit 2 pt Abstand), die Reihen 4 pt auseinander.
private struct ActionRowsLayout: Layout {
    let split: Int
    var spacing: CGFloat = 2
    var rowSpacing: CGFloat = 4

    private func rows(_ count: Int) -> [Range<Int>] {
        let s = min(max(split, 0), count)
        return [0..<s, s..<count].filter { !$0.isEmpty }
    }

    private func itemWidth(_ width: CGFloat, count: Int) -> CGFloat {
        max(0, (width - spacing * CGFloat(count - 1)) / CGFloat(max(count, 1)))
    }

    private func rowHeight(_ range: Range<Int>, width: CGFloat?, subviews: Subviews) -> CGFloat {
        let proposal = ProposedViewSize(width: width.map { itemWidth($0, count: range.count) }, height: nil)
        return range.map { subviews[$0].sizeThatFits(proposal).height }.max() ?? 0
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let all = rows(subviews.count)
        guard !all.isEmpty else { return .zero }
        var width: CGFloat = 0
        if let proposed = proposal.width {
            width = proposed
        } else {
            for range in all {
                var row: CGFloat = spacing * CGFloat(range.count - 1)
                for index in range { row += subviews[index].sizeThatFits(.unspecified).width }
                width = max(width, row)
            }
        }
        var height: CGFloat = rowSpacing * CGFloat(all.count - 1)
        for range in all { height += rowHeight(range, width: width, subviews: subviews) }
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for range in rows(subviews.count) {
            let w = itemWidth(bounds.width, count: range.count)
            let h = rowHeight(range, width: bounds.width, subviews: subviews)
            for (n, index) in range.enumerated() {
                let x = bounds.minX + CGFloat(n) * (w + spacing)
                subviews[index].place(at: CGPoint(x: x + w / 2, y: y + h / 2), anchor: .center,
                                      proposal: ProposedViewSize(width: w, height: nil))
            }
            y += h + rowSpacing
        }
    }
}

// MARK: Anheften

/// Freier Platz am Ende der Leiste, solange ein Ordner oder eine App über die Ablage
/// gezogen wird. Darauf loslassen heftet sie als Aktion an.
private struct PinSlot: View {
    let url: URL
    @ObservedObject var ui: ShelfUIModel
    /// Vorführung in der Einführung: ohne Drop-Fläche
    @Environment(\.shelfDemo) private var shelfDemo
    let settings: AppSettings
    var iconSize: CGFloat = 34
    @State private var targeted = false

    private var name: String {
        let n = FileManager.default.displayName(atPath: url.path)
        return url.pathExtension.lowercased() == "app" ? (n as NSString).deletingPathExtension : n
    }

    var body: some View {
        // Aufgebaut wie die übrigen Aktionen: das echte Symbol des Ordners bzw. der App,
        // erst blass als Vorschau, über dem Platz voll; ein Plus zeigt, dass es dazukommt
        VStack(spacing: 4) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: iconSize, height: iconSize)
                .opacity(targeted ? 1 : 0.45)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color(nsColor: .controlAccentColor))
                        .background(Circle().fill(Color.black).padding(1))
                        .offset(x: 3, y: 3)
                }
                .scaleEffect(targeted ? 1.1 : 1)
            if settings.showActionLabels {
                Text(L("Pin", "Anheften"))
                    .font(.system(size: 10, weight: targeted ? .semibold : .medium))
                    .foregroundStyle(Color.primary.opacity(0.7))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(targeted ? 0.12 : 0))
        )
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: targeted)
        .overlay(Group { if !shelfDemo {PinDropTarget(ui: ui, onTargeted: { targeted = $0 }) {
            // Ohne Animation: Die neue Aktion steht sofort an der Stelle, an der sie
            // abgelegt wurde, statt von der Seite hereinzugleiten
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                let pinned = settings.pin(url)
                Diagnostics.shared.record("pin", "dropped pinned=\(pinned) kind=\(QuickAction.pinnableKind(url).map { "\($0)" } ?? "–")")
                ui.setPinCandidate(nil, animated: false)
            }
        }} })
        .help(L("Pin “\(name)” to the action bar", "„\(name)“ an die Aktionsleiste anheften"))
    }
}

private final class PinDropNSView: NSView {
    weak var ui: ShelfUIModel?
    var onTargeted: (Bool) -> Void = { _ in }
    var onPin: () -> Void = {}

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        ui?.holdPinCandidate()
        onTargeted(true)
        Haptics.tap()
        return .link
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        ui?.holdPinCandidate()
        return .link
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onTargeted(false)
        ui?.releasePinCandidate()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onTargeted(false)
        Haptics.drop()
        let pin = onPin
        DispatchQueue.main.async { pin() }
        return true
    }
}

private struct PinDropTarget: NSViewRepresentable {
    var ui: ShelfUIModel
    var onTargeted: (Bool) -> Void
    var onPin: () -> Void

    func makeNSView(context: Context) -> PinDropNSView {
        let view = PinDropNSView(frame: .zero)
        configure(view)
        return view
    }

    func updateNSView(_ view: PinDropNSView, context: Context) { configure(view) }

    private func configure(_ view: PinDropNSView) {
        view.ui = ui
        view.onTargeted = onTargeted
        view.onPin = onPin
    }
}
