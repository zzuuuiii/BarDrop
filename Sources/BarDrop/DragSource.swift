import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers

/// AppKit-Ansicht über einer Kachel: Auswahl, Klicks, Kontextmenü, Hover und das
/// Herausziehen von Dateien (auch mehrere auf einmal).
final class DragSourceNSView: NSView, NSDraggingSource {
    var filesProvider: () -> [ShelfFile] = { [] }
    /// Klickflächen (Bild, Name) in Kachelkoordinaten, oben links gemessen; leer: alles
    var hitRects: [CGRect] = []

    /// Wie im Finder: Klicks neben Bild und Namen gehen an die Fläche der Ablage darunter
    /// (Auswahl aufheben, Auswahlrahmen)
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !hitRects.isEmpty, let superview else { return super.hitTest(point) }
        let local = convert(point, from: superview)
        let topLeft = CGPoint(x: local.x, y: isFlipped ? local.y : bounds.height - local.y)
        guard hitRects.contains(where: { $0.insetBy(dx: -2, dy: -2).contains(topLeft) }) else { return nil }
        return super.hitTest(point)
    }
    var onMouseDown: (NSEvent.ModifierFlags) -> Void = { _ in }
    var onClick: (Int, NSEvent.ModifierFlags) -> Void = { _, _ in }
    var onHover: (Bool) -> Void = { _ in }
    var onDragEnded: (NSDragOperation) -> Void = { _ in }
    var menuProvider: (NSView) -> NSMenu? = { _ in nil }
    /// Einträge, die beim Ziehen mitgenommen werden (für Ablegen auf andere Kacheln).
    var draggedIDs: () -> Set<UUID> = { [] }
    weak var ui: ShelfUIModel?

    /// Drop-Ziel: Objekte auf diese Kachel legen (Stapel bilden bzw. ergänzen).
    var dropTargetID: UUID? {
        didSet {
            guard dropTargetID != oldValue else { return }
            if dropTargetID != nil {
                registerForDraggedTypes(ShelfStore.acceptedTypes)
            } else {
                unregisterDraggedTypes()
            }
        }
    }
    var onDropTargeted: (Bool) -> Void = { _ in }
    var onExternalDrop: (NSPasteboard) -> Void = { _ in }
    var onOwnDrop: () -> Void = {}
    /// Ablegen über der Kachel, bevor sie zum Ziel geworden ist: normal in die Ablage
    var onShelfDrop: (NSPasteboard) -> Void = { _ in }
    var onShelfTargeted: (Bool) -> Void = { _ in }

    private var mouseDownEvent: NSEvent?
    private var trackingArea: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { onHover(true) }
    override func mouseExited(with event: NSEvent) { onHover(false) }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            showMenu(with: event)
            return
        }
        window?.makeKey()
        onMouseDown(event.modifierFlags)
        mouseDownEvent = event
    }

    override func rightMouseDown(with event: NSEvent) {
        showMenu(with: event)
    }

    private func showMenu(with event: NSEvent) {
        onMouseDown([])
        guard let menu = menuProvider(self) else { return }
        ui?.menuOpen = true
        ShelfMenu.popUp(menu, with: event, for: self)
        ui?.menuOpen = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down = mouseDownEvent else { return }
        let a = down.locationInWindow, b = event.locationInWindow
        guard hypot(a.x - b.x, a.y - b.y) > 3 else { return }
        mouseDownEvent = nil

        let files = filesProvider()
        guard !files.isEmpty else { return }

        let point = convert(down.locationInWindow, from: nil)
        // Ein Stapel wird als ein Stapel gezogen: ein Bild mit der Anzahl, nicht viele einzelne
        let isStack = files.count > 1 && draggedIDs().count == 1
        let items = isStack ? Self.stackDraggingItems(files, centeredAt: point)
            : files.enumerated().map { index, file in
                Self.draggingItem(for: file, centeredAt: point, offset: CGFloat(min(index, 4)) * 4)
            }
        ui?.ownDragActive = true
        ui?.lastDropWasInternal = false
        ui?.draggedEntryIDs = draggedIDs()
        ui?.draggedFileURLs = files.map(\.url)
        Log.export.info("Ziehe \(files.count, privacy: .public) Objekt(e), davon \(files.filter(\.owned).count, privacy: .public) als Versprechen")
        let session = beginDraggingSession(with: items, event: down, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .default   // Ziele wie der Finder ordnen die Dateien selbst an
    }

    override func mouseUp(with event: NSEvent) {
        if mouseDownEvent != nil { onClick(event.clickCount, event.modifierFlags) }
        mouseDownEvent = nil
    }

    // MARK: Drag-Bild wie im Finder: Symbol bzw. Vorschau und Dateiname

    private static func draggingItem(for file: ShelfFile, centeredAt point: NSPoint, offset: CGFloat) -> NSDraggingItem {
        let url = file.url
        let item = NSDraggingItem(pasteboardWriter: DragExport.writer(for: file))
        let icon = dragIcon(for: url)
        let label = labelImage(ShelfEntry.displayName(for: url))
        let gap: CGFloat = 3
        let width = max(icon.size.width, label.size.width)
        let height = icon.size.height + gap + label.size.height
        item.draggingFrame = NSRect(x: point.x - width / 2 + offset,
                                    y: point.y - icon.size.height / 2 - gap - label.size.height - offset,
                                    width: width, height: height)
        item.imageComponentsProvider = {
            let iconComponent = NSDraggingImageComponent(key: .icon)
            iconComponent.contents = icon
            iconComponent.frame = NSRect(x: (width - icon.size.width) / 2, y: label.size.height + gap,
                                         width: icon.size.width, height: icon.size.height)
            let labelComponent = NSDraggingImageComponent(key: .label)
            labelComponent.contents = label
            labelComponent.frame = NSRect(x: (width - label.size.width) / 2, y: 0,
                                          width: label.size.width, height: label.size.height)
            return [iconComponent, labelComponent]
        }
        return item
    }

    /// Ein Stapel als ein gezogenes Bild: vorn das erste Objekt, dahinter versetzt die nächsten,
    /// oben rechts ein roter Kreis mit der Anzahl, darunter der Name des ersten. Alle Dateien
    /// werden mitgezogen; nur das erste Element trägt das Bild, die übrigen sind unsichtbar.
    private static func stackDraggingItems(_ files: [ShelfFile], centeredAt point: NSPoint) -> [NSDraggingItem] {
        let image = stackImage(files)
        let label = labelImage(ShelfEntry.displayName(for: files[0].url))
        let gap: CGFloat = 3
        let width = max(image.size.width, label.size.width)
        let height = image.size.height + gap + label.size.height
        let frame = NSRect(x: point.x - width / 2, y: point.y - image.size.height / 2 - gap - label.size.height,
                           width: width, height: height)
        return files.enumerated().map { index, file in
            let item = NSDraggingItem(pasteboardWriter: DragExport.writer(for: file))
            item.draggingFrame = frame
            if index == 0 {
                item.imageComponentsProvider = {
                    let icon = NSDraggingImageComponent(key: .icon)
                    icon.contents = image
                    icon.frame = NSRect(x: (width - image.size.width) / 2, y: label.size.height + gap,
                                        width: image.size.width, height: image.size.height)
                    let name = NSDraggingImageComponent(key: .label)
                    name.contents = label
                    name.frame = NSRect(x: (width - label.size.width) / 2, y: 0,
                                        width: label.size.width, height: label.size.height)
                    return [icon, name]
                }
            } else {
                item.imageComponentsProvider = { [] }
            }
            return item
        }
    }

    /// Bild eines Stapels: bis zu drei Vorschauen leicht versetzt übereinander, mit Anzahl
    private static func stackImage(_ files: [ShelfFile]) -> NSImage {
        let icons = files.prefix(3).map { dragIcon(for: $0.url) }
        guard let front = icons.first else { return NSImage() }
        let shift: CGFloat = 5
        let layers = CGFloat(icons.count - 1)
        let count = "\(files.count)"
        let font = NSFont.systemFont(ofSize: 12, weight: .bold)
        let text = NSAttributedString(string: count, attributes: [.font: font, .foregroundColor: NSColor.white])
        let textSize = text.size()
        let badge = NSSize(width: max(20, ceil(textSize.width) + 10), height: 20)
        let overhang = badge.height / 2
        let size = NSSize(width: front.size.width + shift * layers + overhang,
                          height: front.size.height + shift * layers + overhang)
        return NSImage(size: size, flipped: false) { _ in
            let center = NSPoint(x: front.size.width / 2, y: front.size.height / 2)
            // Von hinten nach vorn: die hinteren nach rechts oben versetzt
            for (index, icon) in icons.enumerated().reversed() {
                let offset = shift * CGFloat(index)
                let rect = NSRect(x: center.x - icon.size.width / 2 + offset,
                                  y: center.y - icon.size.height / 2 + offset,
                                  width: icon.size.width, height: icon.size.height)
                NSGraphicsContext.saveGraphicsState()
                let shadow = NSShadow()
                shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
                shadow.shadowBlurRadius = 3
                shadow.shadowOffset = NSSize(width: 0, height: -1)
                shadow.set()
                icon.draw(in: rect, from: .zero, operation: .sourceOver, fraction: index == 0 ? 1 : 0.9)
                NSGraphicsContext.restoreGraphicsState()
            }
            // Anzahl oben rechts an der vorderen Vorschau, wie beim Ziehen mehrerer Dateien im Finder
            let badgeRect = NSRect(x: min(front.size.width - badge.width / 2, size.width - badge.width),
                                   y: front.size.height - overhang, width: badge.width, height: badge.height)
            NSColor.systemRed.setFill()
            NSBezierPath(roundedRect: badgeRect, xRadius: badge.height / 2, yRadius: badge.height / 2).fill()
            text.draw(at: NSPoint(x: badgeRect.midX - textSize.width / 2, y: badgeRect.midY - textSize.height / 2))
            return true
        }
    }

    /// Vorschau im echten Seitenverhältnis, so groß wie in der Kachel (wie im Finder: das
    /// gezogene Bild hat die Größe, in der man die Datei gerade sieht), sonst das Dateisymbol. Fehlt die
    /// Vorschau noch (etwa bei gerade umgewandelten Bildern), wird sie hier schnell erzeugt,
    /// damit das gezogene Bild wie die Kachel aussieht und nicht wie ein Standardsymbol.
    private static func dragIcon(for url: URL) -> NSImage {
        let box = TileLabel<EmptyView>.iconSize
        let source = Thumbnails.cached(url, size: TileLabel<EmptyView>.iconSize) ?? quickImagePreview(url) ?? Thumbnails.icon(url)
        let size = source.size
        guard size.width > 0, size.height > 0 else { return source }
        let scale = min(box / size.width, box / size.height)
        let fitted = NSSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let image = NSImage(size: fitted)
        image.lockFocus()
        source.draw(in: NSRect(origin: .zero, size: fitted), from: .zero, operation: .sourceOver, fraction: 1)
        image.unlockFocus()
        return image
    }

    /// Kleine Vorschau eines Bildes direkt aus der Datei (ImageIO, ohne Quick Look)
    private static func quickImagePreview(_ url: URL) -> NSImage? {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()), type.conforms(to: .image),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 128
              ] as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width / 2, height: image.height / 2))
    }

    /// Dateiname wie beim Ziehen im Finder: weiße Schrift auf der Markierungsfarbe.
    private static func labelImage(_ text: String) -> NSImage {
        let shown = text.count > 28 ? String(text.prefix(13)) + "…" + String(text.suffix(13)) : text
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.white
        ]
        let string = NSAttributedString(string: shown, attributes: attributes)
        let textSize = string.size()
        // Wie die Markierung eines Namens im Finder: knapp um den Text, nur leicht gerundet
        let size = NSSize(width: ceil(textSize.width) + 8, height: ceil(textSize.height) + 2)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.selectedContentBackgroundColor.setFill()
        NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 4, yRadius: 4).fill()
        string.draw(at: NSPoint(x: 4, y: 1))
        image.unlockFocus()
        return image
    }

    // MARK: NSDraggingSource

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // Innerhalb der App: nur die Aktionsleiste nimmt eigene Objekte an.
        guard context == .outsideApplication else { return [.copy, .generic] }
        // Wie im Finder: Ziele dürfen Dateien auch verschieben (nach boring.notch),
        // außer „Beim Herausziehen immer kopieren“ ist eingestellt.
        return AppSettings.shared.dragOutCopyOnly ? [.copy] : [.copy, .move]
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        ui?.ownDragActive = false
        Log.export.info("Ziehen beendet, Vorgang \(operation.rawValue, privacy: .public)")
        onDragEnded(operation)
        ui?.draggedEntryIDs = []
        ui?.draggedFileURLs = []
    }

    // MARK: Drop-Ziel (Objekte auf diese Kachel legen)
    //
    // Eine Kachel wird erst nach kurzem Verweilen zum Ziel (wie Ordner im Finder).
    // Lässt man vorher los, landet das Objekt ganz normal in der Ablage.

    private var hoverStart: Date?
    private var armed = false
    private static let armDelay: TimeInterval = 0.45

    private func isOwn(_ sender: NSDraggingInfo) -> Bool {
        sender.draggingSource is DragSourceNSView
    }

    /// Eigene Objekte dürfen nur auf andere Kacheln, nicht auf sich selbst.
    private func canMerge(_ sender: NSDraggingInfo) -> Bool {
        guard IntroGate.allowsMerge, let id = dropTargetID else { return false }
        guard isOwn(sender) else { return true }
        return !(ui?.draggedEntryIDs ?? []).subtracting([id]).isEmpty
    }

    private func setArmed(_ value: Bool) {
        guard armed != value else { return }
        armed = value
        onDropTargeted(value)
        if value { Haptics.tap() }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        hoverStart = Date()
        armed = false
        if !isOwn(sender) { onShelfTargeted(true) }
        return draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if canMerge(sender), let start = hoverStart, Date().timeIntervalSince(start) > Self.armDelay {
            setArmed(true)
        }
        if armed { return .copy }
        return isOwn(sender) ? .generic : .copy   // eigenes Objekt: zurücklegen; von außen: in die Ablage
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        resetDropState()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { resetDropState() }
        if armed {
            if isOwn(sender) { onOwnDrop() } else { onExternalDrop(sender.draggingPasteboard) }
        } else if isOwn(sender) {
            // Zurück auf die Ablage gelegt: bleibt, wo es war
            ui?.lastDropWasInternal = true
        } else {
            onShelfDrop(sender.draggingPasteboard)
        }
        Haptics.drop()
        return true
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) { resetDropState() }
    override func draggingEnded(_ sender: NSDraggingInfo) { resetDropState() }

    private func resetDropState() {
        hoverStart = nil
        setArmed(false)
        onShelfTargeted(false)
    }

}

struct DragSource: NSViewRepresentable {
    var ui: ShelfUIModel
    var files: () -> [ShelfFile]
    /// Klickflächen in der Kachel (oben links gemessen); leer: die ganze Kachel
    var hitRects: [CGRect] = []
    var onMouseDown: (NSEvent.ModifierFlags) -> Void = { _ in }
    var onClick: (Int, NSEvent.ModifierFlags) -> Void = { _, _ in }
    var onHover: (Bool) -> Void = { _ in }
    var onDragEnded: (NSDragOperation) -> Void = { _ in }
    var menu: (NSView) -> NSMenu? = { _ in nil }
    var draggedIDs: () -> Set<UUID> = { [] }
    var dropTargetID: UUID? = nil
    var onDropTargeted: (Bool) -> Void = { _ in }
    var onExternalDrop: (NSPasteboard) -> Void = { _ in }
    var onOwnDrop: () -> Void = {}
    var onShelfDrop: (NSPasteboard) -> Void = { _ in }
    var onShelfTargeted: (Bool) -> Void = { _ in }

    func makeNSView(context: Context) -> DragSourceNSView {
        let view = DragSourceNSView()
        configure(view)
        return view
    }

    func updateNSView(_ view: DragSourceNSView, context: Context) {
        configure(view)
    }

    private func configure(_ view: DragSourceNSView) {
        view.ui = ui
        view.filesProvider = files
        view.onMouseDown = onMouseDown
        view.onClick = onClick
        view.onHover = onHover
        view.onDragEnded = onDragEnded
        view.menuProvider = menu
        view.draggedIDs = draggedIDs
        view.dropTargetID = dropTargetID
        view.onDropTargeted = onDropTargeted
        view.onExternalDrop = onExternalDrop
        view.onOwnDrop = onOwnDrop
        view.onShelfDrop = onShelfDrop
        view.onShelfTargeted = onShelfTargeted
        view.hitRects = hitRects
    }
}

/// Rechtsklick-Menüs der Ablage (Systemmenüs).
enum ShelfMenu {
    /// Zeigt das Menü erst, wenn BarDrop wirklich aktiv ist. Die Ablage öffnet sich, ohne
    /// BarDrop zu aktivieren, und das Aktivieren läuft verzögert ab. Ging das Menü vorher
    /// auf, folgte seine Markierung dem Zeiger nur teilweise, und ein Untermenü (Umwandeln),
    /// das erst danach erschien, sah anders durchscheinend aus als das Menü selbst.
    /// Während der Einführung keine Rechtsklickmenüs: Sie würden die Übungen stören
    static var disabled = false
    /// Ein Eintrag des Menüs hat bewusst ein eigenes Fenster geöffnet (Einstellungen): Dann
    /// behält dieses den Fokus, sonst bekommt ihn die Ablage zurück
    static var openedWindow = false

    static func popUp(_ menu: NSMenu, with event: NSEvent, for view: NSView) {
        guard !disabled else { return }
        withoutImages(menu)
        openedWindow = false
        let active = AppActivation.isFrontmost
        Diagnostics.shared.record("menu", "popUp active=\(active)")
        if active {
            view.window?.makeKey()
            NSMenu.popUpContextMenu(menu, with: event, for: view)
        } else {
            // BarDrop ist nicht vorn: Erst aktivieren und dann das Menü zeigen ging nicht, die
            // Aktivierung schloss es gleich wieder (Protokoll: Menü nach 15 ms zu, erst der
            // zweite Rechtsklick ging). Also gleich ohne Aktivieren an der Stelle zeigen,
            // aktiviert wird danach
            menu.popUp(positioning: nil, at: view.convert(event.locationInWindow, from: nil), in: view)
            activate()
            // Hat ein Eintrag bewusst ein Fenster geöffnet (Einstellungen), behält es den Fokus.
            // Sonst nahm ihn die Ablage gleich wieder, und die Einstellungen waren grau wie im
            // Hintergrund (Protokoll: „key+ Einstellungen“, 0,1 s später „key+ Ablage“)
            if !openedWindow { view.window?.makeKey() }
        }
        // Nach dem Menü gab macOS den Fokus dem Hauptfenster von BarDrop, den Einstellungen,
        // und holte sie nach vorn (Diagnoseprotokoll: „key+ Einstellungen“ gleich danach,
        // teils erst, wenn die Aktivierung verspätet ankommt). Die Ablage, aus der das Menü
        // kam, behält ihn, außer ein Eintrag hat bewusst ein Fenster geöffnet
        guard let shelf = view.window else { return }
        let reclaim = {
            guard !ShelfMenu.openedWindow, shelf.isVisible, NSApp.modalWindow == nil,
                  let key = NSApp.keyWindow, key !== shelf, key.level == .normal, !(key is NSPanel) else { return }
            shelf.makeKey()
        }
        reclaim()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: reclaim)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: reclaim)
    }

    /// Rechtsklickmenüs zeigen keine Symbole vor den Einträgen, auch nicht in Untermenüs
    /// und nicht für Plugins: schlicht und einheitlich
    private static func withoutImages(_ menu: NSMenu) {
        for item in menu.items {
            item.image = nil
            if let submenu = item.submenu { withoutImages(submenu) }
        }
    }

    /// Aktivieren und auf die Bestätigung des Systems warten, höchstens `timeout` Sekunden.
    /// Dabei werden nur die Systemereignisse der Aktivierung verarbeitet; Klicks und
    /// Tasten bleiben in der Warteschlange.
    /// Andere eigene Fenster (Einstellungen) bleiben dabei, wo sie waren.
    static func activate(timeout: TimeInterval = 0.25) {
        AppActivation.activateKeepingWindows(timeout: timeout)
    }
}

/// Menüeintrag mit Closure statt Target/Action.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, key: String = "",
         modifiers: NSEvent.ModifierFlags = .command, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
        keyEquivalentModifierMask = modifiers
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) not supported") }

    @objc private func fire() { handler() }
}
