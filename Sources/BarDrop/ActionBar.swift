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
    /// Herausziehen entfernt die Aktion (nur mit „Anheften in der Ablage“): Bild und Entfernen
    var dragOut: (image: () -> NSImage, remove: () -> Void)?
    weak var ui: ShelfUIModel?

    private var pressed = false
    private var downEvent: NSEvent?
    /// Fenster der Ablage beim Start des Herausziehens: außerhalb losgelassen wird entfernt
    private var dragStartFrame: NSRect = .zero

    /// Eigener Typ, den kein anderes Ziel annimmt
    static let actionType = NSPasteboard.PasteboardType("io.github.zzuuuiii.bardrop.quickaction")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes(ShelfStore.acceptedTypes)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        pressed = true
        downEvent = event
    }

    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        if pressed && inside { onClick(self) }
        pressed = false
        downEvent = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragOut, let down = downEvent, let window else { return }
        let a = down.locationInWindow, b = event.locationInWindow
        guard hypot(a.x - b.x, a.y - b.y) > 4 else { return }
        pressed = false
        downEvent = nil

        let item = NSPasteboardItem()
        item.setString("", forType: Self.actionType)
        let dragging = NSDraggingItem(pasteboardWriter: item)
        let size: CGFloat = 40
        let point = convert(a, from: nil)
        dragging.setDraggingFrame(NSRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size),
                                  contents: dragOut.image())
        // An der schwarzen Form messen, nicht am Fenster (das ist wegen des Schattens größer)
        let body = ui?.expandedBody ?? .zero
        dragStartFrame = body.isEmpty ? window.frame : body
        // Wie beim Herausziehen von Objekten: Die Ablage bleibt, solange der Drag läuft
        ui?.ownDragActive = true
        let session = beginDraggingSession(with: [dragging], event: down, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    // MARK: Herausziehen (Quelle)

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .move
    }

    func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        // Draußen verschwindet die Aktion beim Loslassen, drinnen gleitet sie zurück
        session.animatesToStartingPositionsOnCancelOrFail = dragStartFrame.contains(screenPoint)
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        ui?.ownDragActive = false
        guard operation == [], !dragStartFrame.contains(screenPoint), let remove = dragOut?.remove else { return }
        NSAnimationEffect.poof.show(centeredAt: screenPoint, size: NSSize(width: 40, height: 40))
        Haptics.drop()
        DispatchQueue.main.async { remove() }
    }

    // MARK: Drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        ui?.holdPinCandidate()
        onTargeted(true)
        Haptics.tap()
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        ui?.holdPinCandidate()
        return .copy
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
    var dragOut: (image: () -> NSImage, remove: () -> Void)? = nil

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
        view.dragOut = dragOut
    }
}

// MARK: Darstellung

/// Symbol einer Aktion: echte App-, Ordner- und AirDrop-Symbole,
/// „Teilen“ im selben Kachelstil gezeichnet.
struct QuickActionIcon: View {
    let action: QuickAction
    var size: CGFloat = 34

    var body: some View {
        if let icon = action.icon {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        } else {
            // Eigene Kachel im macOS-Icon-Raster, im Blau von AirDrop, Ordnern und Mail
            RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.36, green: 0.68, blue: 1.0),
                                              Color(red: 0.1, green: 0.45, blue: 0.95)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
                )
                .overlay(
                    Image(systemName: action.fallbackSymbol)
                        .font(.system(size: size * 0.42, weight: .semibold))
                        .foregroundStyle(.white)
                        .offset(y: action.kind == .share ? -size * 0.03 : 0)
                )
                .frame(width: size * 0.84, height: size * 0.84)
                .frame(width: size, height: size)
        }
    }
}

struct QuickActionButton: View {
    let action: QuickAction
    @ObservedObject var ui: ShelfUIModel
    let store: ShelfStore
    let actions: ShelfActions

    @State private var targeted = false

    /// Herausziehen entfernt die Aktion, wenn Anheften in der Ablage eingeschaltet ist
    private var dragOut: (image: () -> NSImage, remove: () -> Void)? {
        guard AppSettings.shared.pinFromShelf else { return nil }
        let action = action
        let image: () -> NSImage = {
            action.icon
                ?? NSImage(systemSymbolName: action.fallbackSymbol, accessibilityDescription: nil)
                ?? NSImage()
        }
        let id = action.id
        let remove: () -> Void = {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                AppSettings.shared.removeQuickAction(id)
            }
        }
        return (image: image, remove: remove)
    }

    var body: some View {
        VStack(spacing: 4) {
            QuickActionIcon(action: action)
                .scaleEffect(targeted ? 1.1 : 1)
            Text(action.title)
                .font(.system(size: 10, weight: targeted ? .semibold : .medium))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(targeted ? 0.12 : 0))
        )
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: targeted)
        .overlay(
            ActionDropTarget(
                ui: ui,
                onTargeted: { targeted = $0 },
                onDrop: { pb, anchor in
                    let files = (pb.readObjects(forClasses: [NSURL.self],
                                                options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
                    if !files.isEmpty && files.allSatisfy(ContentImporter.isUserFile) {
                        // Dateien aus dem Finder direkt verwenden
                        DispatchQueue.main.async { actions.perform(action, urls: files, anchor: anchor) }
                    } else {
                        // Bilder aus dem Web, temporäre Dateien, Links, Text: zuerst in die
                        // Ablage übernehmen, dann ausführen
                        store.ingest(from: pb) { urls in
                            actions.perform(action, urls: urls, anchor: anchor)
                        }
                    }
                },
                onOwnDrop: { urls, anchor in
                    actions.perform(action, urls: urls, anchor: anchor)
                },
                onClick: { anchor in
                    actions.perform(action, urls: actions.selectedEntries.flatMap(\.urls), anchor: anchor)
                },
                dragOut: dragOut
            )
        )
        .help(action.help)
    }
}

struct QuickActionBar: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var ui: ShelfUIModel
    let store: ShelfStore
    let actions: ShelfActions

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
        let all = settings.quickActions
        // Der Platz zum Anheften kommt dorthin, wo die Aktion danach stünde: ans Ende
        let pin = ui.pinCandidate.flatMap { settings.pinFromShelf ? $0 : nil }
        let slots = all.map(Slot.action) + (pin.map { [Slot.pin($0)] } ?? [])
        Group {
            if settings.twoActionRows {
                // Zwei Reihen, wie in den Einstellungen verteilt. Beide auf demselben
                // Raster von fünf Plätzen, damit die Symbole übereinander stehen.
                let split = AppSettings.clampSplit(settings.actionRowSplit, count: slots.count)
                let top = Array(slots.prefix(split))
                let bottom = Array(slots.dropFirst(split).prefix(QuickAction.perRow))
                if top.isEmpty || bottom.isEmpty {
                    row(top.isEmpty ? bottom : top)
                } else {
                    VStack(spacing: 4) {
                        row(top)
                        row(bottom)
                    }
                }
            } else {
                row(Array(slots.prefix(QuickAction.limit(twoRows: false))))
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .onChange(of: ui.level) { _, level in
            if level != .expanded { ui.setPinCandidate(nil) }
        }
    }

    /// Eine Reihe: die Aktionen teilen sich die ganze Breite, jede mittig in ihrem Teil.
    private func row(_ items: [Slot]) -> some View {
        HStack(spacing: 2) {
            ForEach(items) { slot in
                switch slot {
                case .action(let action):
                    QuickActionButton(action: action, ui: ui, store: store, actions: actions)
                case .pin(let url):
                    PinSlot(url: url, ui: ui, settings: settings)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: Anheften

/// Freier Platz am Ende der Leiste, solange ein Ordner oder eine App über die Ablage
/// gezogen wird. Darauf loslassen heftet sie als Aktion an.
private struct PinSlot: View {
    let url: URL
    @ObservedObject var ui: ShelfUIModel
    let settings: AppSettings
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color.white.opacity(targeted ? 0.7 : 0.35),
                                  style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                Image(systemName: "pin.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(targeted ? 0.95 : 0.6))
            }
            .frame(width: 30, height: 30)
            .frame(width: 34, height: 34)
            .scaleEffect(targeted ? 1.1 : 1)
            Text(L("Pin", "Anheften"))
                .font(.system(size: 10, weight: targeted ? .semibold : .medium))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(targeted ? 0.12 : 0))
        )
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: targeted)
        .overlay(PinDropTarget(ui: ui, onTargeted: { targeted = $0 }) {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                settings.pin(url)
                ui.setPinCandidate(nil)
            }
        })
        .help(L("Pin “\(FileManager.default.displayName(atPath: url.path))” to the action bar",
                "„\(FileManager.default.displayName(atPath: url.path))“ an die Aktionsleiste anheften"))
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
